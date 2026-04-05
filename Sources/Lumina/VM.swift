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

        // If the image includes a guest agent binary, create a combined initrd
        // that injects the agent + custom init into the Alpine initramfs.
        // This avoids requiring the rootfs to have lumina-agent pre-installed.
        if let agentURL = imagePaths.agent {
            let combinedInitrd = diskClone.directory.appendingPathComponent("initrd.combined")
            try InitrdPatcher.createCombinedInitrd(
                baseInitrd: imagePaths.initrd,
                agentBinary: agentURL,
                modulesDir: imagePaths.modulesDir,
                outputURL: combinedInitrd
            )
            bootLoader.initialRamdiskURL = combinedInitrd
        } else {
            bootLoader.initialRamdiskURL = imagePaths.initrd
        }

        var cmdLine = "console=hvc0 root=/dev/vda rw"

        // Encode mount specs as kernel param so the init script can mount them.
        // Format: lumina_mounts=tag:path,tag:path
        if !options.mounts.isEmpty {
            let specs = options.mounts.enumerated().map { "lumina\($0.offset):\($0.element.guestPath)" }
            cmdLine += " lumina_mounts=\(specs.joined(separator: ","))"
        }
        bootLoader.commandLine = cmdLine
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

        // Network (pluggable via NetworkProvider protocol)
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        do {
            networkDevice.attachment = try options.networkProvider.createAttachment()
        } catch {
            clone?.remove()
            _state = .idle
            throw .bootFailed(underlying: error)
        }
        config.networkDevices = [networkDevice]

        // vsock
        let vsockDevice = VZVirtioSocketDeviceConfiguration()
        config.socketDevices = [vsockDevice]

        // Directory sharing (virtio-fs) for --mount
        if !options.mounts.isEmpty {
            var sharingDevices: [VZDirectorySharingDeviceConfiguration] = []
            for (index, mount) in options.mounts.enumerated() {
                let sharedDir = VZSharedDirectory(url: mount.hostPath, readOnly: mount.readOnly)
                let share = VZSingleDirectoryShare(directory: sharedDir)
                let tag = "lumina\(index)"
                let device = VZVirtioFileSystemDeviceConfiguration(tag: tag)
                device.share = share
                sharingDevices.append(device)
            }
            config.directorySharingDevices = sharingDevices
        }

        // Entropy
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        do {
            try config.validate()
        } catch {
            clone?.remove()
            _state = .idle
            throw .bootFailed(underlying: error)
        }

        // Create VM on the executor's queue.
        // Note: VZ start/stop use completion-handler dispatch because Swift's
        // ObjC async bridge doesn't guarantee the call lands on the actor's
        // executor — only the continuation does. Explicit dispatch is required.
        let queue = executor.queue
        let vm = VZVirtualMachine(configuration: config, queue: queue)
        self.virtualMachine = vm

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                queue.async {
                    vm.start { result in
                        cont.resume(with: result)
                    }
                }
            }
        } catch {
            clone?.remove()
            _state = .idle
            throw .bootFailed(underlying: error)
        }

        // Connect CommandRunner via vsock
        // Access vm.socketDevices on the VZ queue (thread-affinity requirement)
        let socketDevice: VZVirtioSocketDevice
        do {
            socketDevice = try await withCheckedThrowingContinuation { cont in
                queue.async {
                    if let device = vm.socketDevices.first as? VZVirtioSocketDevice {
                        cont.resume(returning: device)
                    } else {
                        cont.resume(throwing: VMError.noSocketDevice)
                    }
                }
            }
        } catch {
            await shutdownVM()
            throw .bootFailed(underlying: error)
        }

        let runner = CommandRunner(socketDevice: socketDevice, queue: queue)
        do {
            try await runner.connect()
        } catch {
            let serial = serialConsole.output
            await shutdownVM()
            if !serial.isEmpty {
                throw .guestCrashed(serialOutput: serial)
            }
            throw error
        }
        self.commandRunner = runner
        _state = .ready
    }

    // MARK: - Internal Result API
    // Used by Lumina.swift to avoid typed-throws boxing across actor boundaries.
    // Swift 6 can lose the concrete LuminaError type when errors cross from a
    // custom-executor actor back to the caller. Catching inside the actor and
    // returning Result preserves the type as a value.

    func bootResult() async -> Result<Void, LuminaError> {
        do {
            try await boot()
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    func execResult(
        _ command: String,
        timeout: Int = 60,
        env: [String: String] = [:]
    ) async -> Result<RunResult, LuminaError> {
        do {
            return .success(try await exec(command, timeout: timeout, env: env))
        } catch {
            return .failure(error)
        }
    }

    // MARK: - File Transfer

    /// Upload files to the guest. Must be called after boot(), before exec().
    public func uploadFiles(_ uploads: [FileUpload]) throws(LuminaError) {
        guard _state == .ready, let runner = commandRunner else {
            throw .bootFailed(underlying: VMError.invalidState("Cannot upload from state: \(_state)"))
        }
        for file in uploads {
            try runner.upload(file)
        }
    }

    /// Download files from the guest. Must be called after exec() completes.
    public func downloadFiles(_ downloads: [FileDownload]) throws(LuminaError) {
        guard _state == .ready, let runner = commandRunner else {
            throw .bootFailed(underlying: VMError.invalidState("Cannot download from state: \(_state)"))
        }
        for file in downloads {
            try runner.download(file)
        }
    }

    func uploadFilesResult(_ uploads: [FileUpload]) -> Result<Void, LuminaError> {
        do {
            try uploadFiles(uploads)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    func downloadFilesResult(_ downloads: [FileDownload]) -> Result<Void, LuminaError> {
        do {
            try downloadFiles(downloads)
            return .success(())
        } catch {
            return .failure(error)
        }
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

    /// Stream output chunks from a command in real time.
    /// Each output message from the guest agent is yielded as it arrives.
    /// Returns the stream directly from CommandRunner — no intermediate wrapping.
    public func stream(
        _ command: String,
        timeout: Int = 60,
        env: [String: String] = [:]
    ) throws(LuminaError) -> AsyncThrowingStream<OutputChunk, any Error> {
        guard _state == .ready, let runner = commandRunner else {
            throw .bootFailed(underlying: VMError.invalidState("Cannot stream from state: \(_state)"))
        }
        _state = .executing
        return try runner.execStream(command: command, timeout: timeout, env: env)
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
            let queue = executor.queue
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                queue.async {
                    vm.stop(completionHandler: { _ in
                        cont.resume()
                    })
                }
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
