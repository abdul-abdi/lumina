// Sources/Lumina/VM.swift
import Foundation
@preconcurrency import Virtualization

/// Custom executor that pins all actor work to a specific DispatchQueue.
/// This satisfies VZVirtualMachine's thread-affinity requirement by making
/// the actor's isolation domain the same queue VZ was created with.
final class VMExecutor: SerialExecutor {
    let queue: DispatchQueue

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let unownedJob = UnownedJob(job)
        let unownedExecutor = asUnownedSerialExecutor()
        queue.async {
            unownedJob.runSynchronously(on: unownedExecutor)
        }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }
}

public actor VM {
    private var virtualMachine: VZVirtualMachine?
    private var commandRunner: CommandRunner?
    private let serialConsole = SerialConsole()
    private let options: VMOptions
    private let imageStore: ImageStore
    private var clone: DiskClone?
    private var _state: VMState = .idle
    private var pipeHandles: [FileHandle] = []

    /// The actor executor, backed by a serial DispatchQueue.
    /// VZVirtualMachine is created with executor.queue so all VZ calls
    /// happen on the correct queue automatically.
    private nonisolated let executor: VMExecutor

    nonisolated public var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    public var state: VMState { _state }

    public init(options: VMOptions = .default) {
        self.options = options
        self.imageStore = ImageStore()
        self.executor = VMExecutor(
            queue: DispatchQueue(label: "com.lumina.vm", qos: .userInitiated)
        )
    }

    public func boot() async throws(LuminaError) {
        guard _state == .idle else {
            throw .bootFailed(underlying: VMError.invalidState("Cannot boot from state: \(_state)"))
        }
        _state = .booting

        // Clean orphans from previous crashes
        DiskClone.cleanOrphans()

        // Resolve image
        let imagePaths = try imageStore.resolve(name: options.image)

        // Create COW clone
        let diskClone = try DiskClone.create(from: imagePaths.rootfs)
        self.clone = diskClone

        // Configure VM
        let config = VZVirtualMachineConfiguration()
        config.platform = VZGenericPlatformConfiguration()
        config.cpuCount = options.cpuCount
        config.memorySize = options.memory

        // Boot loader
        let bootLoader = VZLinuxBootLoader(kernelURL: imagePaths.kernel)
        bootLoader.initialRamdiskURL = imagePaths.initrd
        bootLoader.commandLine = "console=hvc0 root=/dev/vda rw quiet"
        config.bootLoader = bootLoader

        // Disk
        do {
            let diskAttachment = try VZDiskImageStorageDeviceAttachment(
                url: diskClone.rootfs,
                readOnly: false
            )
            config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)]
        } catch {
            clone?.remove()
            _state = .idle
            throw .bootFailed(underlying: error)
        }

        // Serial console — pipe pair for host<->guest communication
        let serialPort = VZVirtioConsoleDeviceSerialPortConfiguration()
        let (hostToGuestRead, hostToGuestWrite) = try createPipePair()
        let (guestToHostRead, guestToHostWrite) = try createPipePair()
        serialPort.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: hostToGuestRead,
            fileHandleForWriting: guestToHostWrite
        )
        config.serialPorts = [serialPort]
        // Track all pipe handles for cleanup in shutdownVM()
        pipeHandles = [hostToGuestRead, hostToGuestWrite, guestToHostRead, guestToHostWrite]

        // Start reading serial output in background
        let console = self.serialConsole
        Task.detached {
            let handle = guestToHostRead
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                console.append(data)
            }
        }

        // Network
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        networkDevice.attachment = VZNATNetworkDeviceAttachment()
        config.networkDevices = [networkDevice]

        // vsock
        let vsockDevice = VZVirtioSocketDeviceConfiguration()
        config.socketDevices = [vsockDevice]

        // Entropy
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        do {
            try config.validate()
        } catch {
            clone?.remove()
            _state = .idle
            throw .bootFailed(underlying: error)
        }

        // Create VM on the executor's queue (same queue the actor runs on)
        let vm = VZVirtualMachine(configuration: config, queue: executor.queue)
        self.virtualMachine = vm

        do {
            try await vm.start()
        } catch {
            clone?.remove()
            _state = .idle
            throw .bootFailed(underlying: error)
        }

        // Connect CommandRunner via vsock
        guard let socketDevice = vm.socketDevices.first as? VZVirtioSocketDevice else {
            await shutdownVM()
            throw .bootFailed(underlying: VMError.noSocketDevice)
        }

        let runner = CommandRunner(socketDevice: socketDevice)
        do {
            try await runner.connect()
        } catch {
            await shutdownVM()
            throw error
        }
        self.commandRunner = runner
        _state = .ready
    }

    public func exec(
        _ command: String,
        timeout: Int = 60,
        env: [String: String] = [:]
    ) async throws(LuminaError) -> RunResult {
        guard _state == .ready, let runner = commandRunner else {
            throw .bootFailed(underlying: VMError.invalidState("Cannot exec from state: \(_state)"))
        }
        _state = .executing

        let start = ContinuousClock.now

        let result: RunResult
        do {
            result = try runner.exec(command: command, timeout: timeout, env: env)
        } catch {
            _state = .ready
            throw error
        }

        let wallTime = ContinuousClock.now - start
        _state = .ready
        return RunResult(
            stdout: result.stdout,
            stderr: result.stderr,
            exitCode: result.exitCode,
            wallTime: wallTime
        )
    }

    /// Note: v0.1 is buffered-then-emit, not true real-time streaming. True streaming in v0.2.
    public func stream(
        _ command: String,
        env: [String: String] = [:]
    ) -> AsyncThrowingStream<OutputChunk, Error> {
        AsyncThrowingStream { continuation in
            Task { [self] in
                do {
                    let result = try await self.exec(command, env: env)
                    if !result.stdout.isEmpty {
                        continuation.yield(.stdout(result.stdout))
                    }
                    if !result.stderr.isEmpty {
                        continuation.yield(.stderr(result.stderr))
                    }
                    continuation.yield(.exit(result.exitCode))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func shutdown() async {
        guard _state != .shutdown else { return }
        _state = .shutdown
        await shutdownVM()
    }

    public var serialOutput: String {
        serialConsole.output
    }

    // MARK: - Private

    private func shutdownVM() async {
        if let vm = virtualMachine {
            do {
                try await vm.stop()
            } catch {
                // stop() is already a hard kill; ignore errors
            }
            virtualMachine = nil
        }
        commandRunner = nil
        // Close pipe file handles to prevent FD leaks
        for handle in pipeHandles {
            try? handle.close()
        }
        pipeHandles = []
        clone?.remove()
        clone = nil
    }

    private func createPipePair() throws(LuminaError) -> (FileHandle, FileHandle) {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else {
            throw .bootFailed(underlying: VMError.pipeFailed)
        }
        return (FileHandle(fileDescriptor: fds[0]), FileHandle(fileDescriptor: fds[1]))
    }
}

// MARK: - Internal Errors

enum VMError: Error, Sendable {
    case invalidState(String)
    case noSocketDevice
    case pipeFailed
}
