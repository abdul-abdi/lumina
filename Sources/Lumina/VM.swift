// Sources/Lumina/VM.swift
import Foundation
import os
@preconcurrency import Virtualization
import Darwin

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

/// One-shot gate for coordinating the stdin pump with exec dispatch.
/// `wait()` suspends until `open()` is called; subsequent waiters return
/// immediately. Uses OSAllocatedUnfairLock which is safe from both sync and
/// async contexts (NSLock became async-unavailable in Swift 6).
final class StdinPumpGate: @unchecked Sendable {
    private struct State {
        var opened = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func open() {
        let toResume = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            if s.opened { return [] }
            s.opened = true
            let w = s.waiters
            s.waiters.removeAll()
            return w
        }
        for c in toResume { c.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let shouldResume = state.withLock { s -> Bool in
                if s.opened { return true }
                s.waiters.append(c)
                return false
            }
            if shouldResume { c.resume() }
        }
    }
}

public actor VM {
    // TODO: Remove once all deployed images include the pre-register fix
    // (Guest/lumina-agent >v0.5.0). The fixed agent inserts the runningCmd entry
    // synchronously before spawning the goroutine, so stdin/stdin_close cannot race.
    private static let stdinPumpWarmupMs: Int = 5

    private var virtualMachine: VZVirtualMachine?
    private var commandRunner: CommandRunner?
    private let serialConsole = SerialConsole()
    private let options: VMOptions
    private let imageStore: ImageStore
    private var clone: DiskClone?
    private var _state: VMState = .idle
    private var pipeHandles: [FileHandle] = []

    /// Delegate to install on the VZ machine as soon as it exists but
    /// before `vm.start(…)` is invoked. Callers register it via
    /// `setDelegate(_:)` prior to `boot()`; the boot path then applies it
    /// synchronously on the executor queue just after
    /// `VZVirtualMachine(configuration:queue:)` returns, so any crash in
    /// the 300–500 ms kernel→init window fires `guestDidStop` /
    /// `didStopWithError` into a live observer instead of a nil delegate.
    /// Delegate install is also idempotent post-boot through the same
    /// accessor so existing post-boot callers keep working.
    private var pendingDelegate: (any VZVirtualMachineDelegate)?

    /// Latest boot-phase timings, populated by `recordPhase(…)` during
    /// `boot()`. Surfaced via `bootPhases` for instrumentation and the
    /// upcoming cold-boot regression bench. Zero-cost when unused.
    private var _bootPhases = BootPhases()

    public var bootPhases: BootPhases { _bootPhases }

    /// Background tasks reading serial console output. Retained so
    /// `shutdownVM()` can cancel them explicitly rather than relying
    /// on EOF-from-pipe-close as the termination signal.
    private var serialReadTasks: [Task<Void, Never>] = []
    private var macLastByte: UInt8?  // Last byte of MAC for IP derivation

    /// The actor executor, backed by a serial DispatchQueue.
    /// VZVirtualMachine is created with executor.queue so all VZ calls
    /// happen on the correct queue automatically.
    private nonisolated let executor: VMExecutor

    nonisolated public var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    public var state: VMState { _state }

    /// Expose the current disk clone for image creation workflows.
    public var diskClone: DiskClone? { clone }

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

        // v0.7.0 M3: route non-agent profiles off the hot agent path.
        // The .agent case is a single-cmp-and-branch before falling through
        // to the v0.6.0 code below — the CI agent-boot P50 gate is the
        // source of truth on timing.
        switch options.effectiveBootable {
        case .agent:
            break  // fall through to the v0.6.0 agent boot path
        case .efi(let cfg):
            try await bootEFIPath(cfg: cfg)
            return
        case .macOS:
            // Library callers with `VMOptions.bootable = .macOS(...)` must
            // go through `MacOSVM` directly; `VM` drives VZVirtualMachine
            // and cannot configure a VZMacOSVirtualMachine. The CLI wires
            // this correctly at DesktopCommand.bootMacOS().
            _state = .idle
            throw .bootFailed(underlying: VMError.invalidState(
                "VM.boot() does not support macOS guests — use MacOSVM directly"
            ))
        }

        // Clean orphans from previous crashes
        DiskClone.cleanOrphans()

        // Resolve image
        let imagePaths = try imageStore.resolve(name: options.image)

        // Create COW clone (and resize if requested)
        let diskClone = try DiskClone.create(from: imagePaths.rootfs)
        if let diskSize = options.diskSize {
            try diskClone.resize(to: diskSize)
        }
        self.clone = diskClone

        // Configure VM
        let config = VZVirtualMachineConfiguration()
        config.platform = VZGenericPlatformConfiguration()
        config.cpuCount = options.cpuCount
        config.memorySize = options.memory

        // Boot loader
        // ── Boot loader: initrd setup ──
        let bootLoader = VZLinuxBootLoader(kernelURL: imagePaths.kernel)

        if let baseInitrd = imagePaths.initrd {
            // Legacy image: has initrd (Alpine kernel with modules)
            if let agentURL = imagePaths.agent {
                let combinedInitrd = diskClone.directory.appendingPathComponent("initrd.combined")
                try InitrdPatcher.createCombinedInitrd(
                    baseInitrd: baseInitrd,
                    agentBinary: agentURL,
                    modulesDir: imagePaths.modulesDir,
                    outputURL: combinedInitrd
                )
                if let hosts = options.networkHosts, let ip = options.networkIP {
                    try InitrdPatcher.appendNetworkOverlay(
                        initrdURL: combinedInitrd,
                        hosts: hosts,
                        ip: ip
                    )
                }
                bootLoader.initialRamdiskURL = combinedInitrd
            } else {
                bootLoader.initialRamdiskURL = baseInitrd
            }
        }
        // else: baked image — no initrd, kernel boots directly to rootfs

        // ── Kernel command line ──
        // All cmdline params built in one block. Both paths share mounts and IP;
        // baked images additionally pass hosts via cmdline (legacy uses initrd overlay).
        var cmdLine = "console=hvc0 root=/dev/vda rw"

        if !options.mounts.isEmpty {
            let specs = options.mounts.enumerated().map { "lumina\($0.offset):\($0.element.guestPath)" }
            cmdLine += " lumina_mounts=\(specs.joined(separator: ","))"
        }
        if let ip = options.networkIP {
            cmdLine += " lumina_ip=\(ip)"
        }
        // For baked images, hosts go through the kernel cmdline (no initrd overlay
        // available). For legacy images, InitrdPatcher.appendNetworkOverlay writes
        // them into /lumina-hosts instead.
        if imagePaths.bootContract == .baked, let hosts = options.networkHosts {
            cmdLine += " lumina_hosts=\(Self.encodeHosts(hosts))"
        }

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
        pipeHandles = [hostToGuestRead, hostToGuestWrite, guestToHostRead, guestToHostWrite]

        // Drain serial output in the background. Retained so teardown can
        // cancel explicitly; the blocking `availableData` read still
        // unblocks via pipe-close EOF, but cooperative cancellation is
        // now expressed in the loop condition rather than implicit.
        let console = self.serialConsole
        serialReadTasks.append(Task.detached {
            let handle = guestToHostRead
            while !Task.isCancelled {
                let data = handle.availableData
                if data.isEmpty { break }
                console.append(data)
            }
        })

        // Network (pluggable via NetworkProvider protocol)
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        do {
            networkDevice.attachment = try options.networkProvider.createAttachment()
        } catch {
            clone?.remove()
            _state = .idle
            throw .bootFailed(underlying: error)
        }
        // Pin the MAC if the caller provided one. Desktop bundles persist a
        // stable MAC in their manifest so every boot uses the same L2 id —
        // vmnet's DHCP lease stays hot and the guest's IP is reproducible.
        // A malformed string silently falls through to VZ's default (random
        // locally-administered on every boot).
        if let macString = options.macAddress,
           let mac = VZMACAddress(string: macString) {
            networkDevice.macAddress = mac
        }
        self.macLastByte = networkDevice.macAddress.ethernetAddress.octet.5
        var networkDevices: [VZVirtioNetworkDeviceConfiguration] = [networkDevice]

        // Private network interface (eth1) for VM-to-VM networking
        if let netFd = options.privateNetworkFd {
            let privateNet = VZVirtioNetworkDeviceConfiguration()
            let netHandle = FileHandle(fileDescriptor: netFd, closeOnDealloc: false)
            privateNet.attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: netHandle)
            networkDevices.append(privateNet)
        }
        config.networkDevices = networkDevices

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

        // Rosetta for x86_64 binary translation in Linux guests
        if options.rosetta {
            if #available(macOS 13.0, *) {
                let availability = VZLinuxRosettaDirectoryShare.availability
                switch availability {
                case .installed:
                    do {
                        let rosettaShare = try VZLinuxRosettaDirectoryShare()
                        let rosettaDevice = VZVirtioFileSystemDeviceConfiguration(tag: "rosetta")
                        rosettaDevice.share = rosettaShare
                        var sharingDevices = config.directorySharingDevices
                        sharingDevices.append(rosettaDevice)
                        config.directorySharingDevices = sharingDevices
                        cmdLine += " lumina_rosetta=1"
                    } catch {
                        clone?.remove()
                        _state = .idle
                        throw .bootFailed(underlying: error)
                    }
                case .notSupported:
                    clone?.remove()
                    _state = .idle
                    throw .bootFailed(underlying: VMError.invalidState("Rosetta is not supported on this Mac"))
                case .notInstalled:
                    clone?.remove()
                    _state = .idle
                    throw .bootFailed(underlying: VMError.invalidState("Rosetta is not installed. Run: softwareupdate --install-rosetta"))
                @unknown default:
                    clone?.remove()
                    _state = .idle
                    throw .bootFailed(underlying: VMError.invalidState("Unknown Rosetta availability status"))
                }
            } else {
                clone?.remove()
                _state = .idle
                throw .bootFailed(underlying: VMError.invalidState("Rosetta requires macOS 13.0 or later"))
            }
        }

        // ARM64 COMMAND_LINE_SIZE is 2048. Guard against silent truncation
        // from large host maps, many mounts, or rosetta param.
        if cmdLine.utf8.count > 2048 {
            clone?.remove()
            _state = .idle
            throw .bootFailed(underlying: VMError.invalidState(
                "Kernel cmdline exceeds 2048 bytes (\(cmdLine.utf8.count)). "
                + "Reduce the number of network hosts or mounts."
            ))
        }

        bootLoader.commandLine = cmdLine

        // Entropy
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        // v0.7.0: Optional display + input devices for the desktop use case.
        // The agent path leaves `options.graphics` nil and both `if let`s
        // compile to a single nil-check + branch-not-taken — measurably
        // within the CI agent-boot P50 budget
        // (.github/workflows/ci.yml enforces this).
        if let graphics = options.graphics {
            attachGraphicsDevices(to: config, graphics: graphics)
        }
        if let sound = options.sound, sound.enabled {
            attachSoundDevice(to: config, sound: sound)
        }

        do {
            try config.validate()
        } catch {
            clone?.remove()
            _state = .idle
            throw .bootFailed(underlying: error)
        }

        // Create VM on the executor's queue.
        let queue = executor.queue
        let vm = VZVirtualMachine(configuration: config, queue: queue)
        self.virtualMachine = vm

        // Install the delegate BEFORE `vm.start(…)` so crashes in the
        // kernel-boot window fire `didStopWithError` into a live observer
        // instead of a nil delegate. See `setDelegate(_:)` for full
        // rationale.
        if let d = pendingDelegate {
            vm.delegate = d
        }

        do {
            try Task.checkCancellation()
            let vmBox = UncheckedSendable(vm)
            let startQueue = queue
            // Cooperative cancellation: an outer Task cancel (UI Stop
            // mid-boot) triggers `onCancel`, which calls `vm.stop(…)` on
            // the executor queue. That resumes the `start` completion
            // with an error, the `catch` below funnels through
            // `shutdownVM()`, the `flock()` on `disk.img` is released,
            // and the next `boot()` starts cleanly.
            try await withTaskCancellationHandler(
                operation: {
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                        startQueue.async {
                            vmBox.value.start { result in
                                cont.resume(with: result)
                            }
                        }
                    }
                },
                onCancel: {
                    startQueue.async {
                        vmBox.value.stop(completionHandler: { _ in })
                    }
                }
            )
        } catch {
            await shutdownVM()
            _state = .idle
            if error is CancellationError {
                throw .bootFailed(underlying: VMError.cancelled)
            }
            throw .bootFailed(underlying: error)
        }

        // Connect CommandRunner via vsock
        let socketDevice: VZVirtioSocketDevice
        do {
            let vmBox = UncheckedSendable(vm)
            let boxed: UncheckedSendable<VZVirtioSocketDevice> = try await withCheckedThrowingContinuation { cont in
                queue.async {
                    if let device = vmBox.value.socketDevices.first as? VZVirtioSocketDevice {
                        cont.resume(returning: UncheckedSendable(device))
                    } else {
                        cont.resume(throwing: VMError.noSocketDevice)
                    }
                }
            }
            socketDevice = boxed.value
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

    // MARK: - EFI Boot Path (v0.7.0 M3)

    /// Boot a VM from the EFI pipeline (Linux desktop ISOs, Windows 11 ARM).
    ///
    /// EFI guests have NO `lumina-agent` inside — the vsock CommandRunner is
    /// not set up. `exec()` / `stream()` will throw `invalidState` because
    /// `commandRunner` stays nil. Callers that want to run commands in a
    /// desktop guest must use session-level agent guests (agent-path VMs),
    /// not this boot pipeline.
    ///
    /// The state machine: `.idle` → `.booting` → `.ready` (VM started, no
    /// command connection). All failure paths — configuration errors, VZ
    /// validation, failed `start(…)`, and Task cancellation — funnel into a
    /// single `catch` that calls `shutdownVM()` to tear down pipes, serial
    /// drain tasks, and the VZ machine if it was already instantiated.
    /// That way a cancelled boot (user clicks Stop at any phase) releases
    /// the `flock()` on `disk.img` + `efi.vars` and the next `boot()`
    /// succeeds cold — the prior design leaked those locks and produced
    /// `VZErrorDomain Code 2` on retry.
    private func bootEFIPath(cfg: EFIBootConfig) async throws(LuminaError) {
        let phaseStart = ContinuousClock.now
        var phaseMark = phaseStart

        do {
            let config = VZVirtualMachineConfiguration()
            config.cpuCount = options.cpuCount
            config.memorySize = options.memory

            // Boot loader + storage.
            try EFIBootable(config: cfg).apply(to: config)
            phaseMark = recordPhase(\.configMs, since: phaseMark)

            // Serial console — capture guest output for diagnostics.
            let serialPort = VZVirtioConsoleDeviceSerialPortConfiguration()
            let (hostToGuestRead, hostToGuestWrite) = try createPipePair()
            let (guestToHostRead, guestToHostWrite) = try createPipePair()
            serialPort.attachment = VZFileHandleSerialPortAttachment(
                fileHandleForReading: hostToGuestRead,
                fileHandleForWriting: guestToHostWrite
            )
            config.serialPorts = [serialPort]
            pipeHandles = [hostToGuestRead, hostToGuestWrite, guestToHostRead, guestToHostWrite]

            let console = self.serialConsole
            // Optional on-disk serial log. Opened in append mode so
            // re-boots of the same bundle accumulate history (useful for
            // diagnosing "install went further this time" regressions).
            // Create the parent directory if the bundle shipped without
            // one — non-fatal if either step fails; the in-memory
            // SerialConsole is unaffected.
            let persistHandle: FileHandle? = {
                guard let url = options.serialLogURL else { return nil }
                let dir = url.deletingLastPathComponent()
                try? FileManager.default.createDirectory(
                    at: dir, withIntermediateDirectories: true
                )
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                guard let h = try? FileHandle(forWritingTo: url) else { return nil }
                _ = try? h.seekToEnd()
                return h
            }()
            if let h = persistHandle {
                // Record a boot-delimiter marker so humans reading the
                // file can tell where one boot ends and the next begins.
                let marker = "\n--- lumina boot \(ISO8601DateFormatter().string(from: Date())) ---\n"
                do { try h.write(contentsOf: Data(marker.utf8)) } catch { /* non-fatal */ }
                pipeHandles.append(h)
            }

            serialReadTasks.append(Task.detached {
                let handle = guestToHostRead
                while !Task.isCancelled {
                    let data = handle.availableData
                    if data.isEmpty { break }
                    console.append(data)
                    if let h = persistHandle {
                        _ = try? h.write(contentsOf: data)
                    }
                }
            })

            // Network — same pluggable provider as the agent path, plus the
            // same MAC-pinning behavior so desktop .luminaVM bundles present a
            // stable L2 identity to vmnet on every boot. Without this, VZ picks
            // a fresh random MAC each boot; vmnet then issues a new DHCP lease,
            // which in turn produces the "Network autoconfiguration failed"
            // race observed in the Kali installer when netcfg probes before
            // the fresh lease is recorded host-side.
            let networkDevice = VZVirtioNetworkDeviceConfiguration()
            networkDevice.attachment = try options.networkProvider.createAttachment()
            if let macString = options.macAddress,
               let mac = VZMACAddress(string: macString) {
                networkDevice.macAddress = mac
            }
            self.macLastByte = networkDevice.macAddress.ethernetAddress.octet.5
            config.networkDevices = [networkDevice]

            // Entropy — load-bearing for reliability. systemd-random-seed
            // and Windows TPM-less RNG stall boot 30s+ waiting for entropy
            // without a virtio-rng device.
            config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

            // Graphics + input — same opt-in wiring as agent path. When
            // `options.graphics == nil` this is a no-op (agent-path guarantee
            // preserved for EFI runs that happen to be headless).
            if let graphics = options.graphics {
                attachGraphicsDevices(to: config, graphics: graphics)
            }
            if let sound = options.sound, sound.enabled {
                attachSoundDevice(to: config, sound: sound)
            }

            // v0.7.0 M8: optional Rosetta directory share — Linux guests can
            // run x86_64 user binaries via /run/lumina-rosetta. Same VZ class
            // as the agent path; gated behind options.rosetta.
            if options.rosetta {
                if #available(macOS 13.0, *), VZLinuxRosettaDirectoryShare.availability == .installed {
                    if let rosettaShare = try? VZLinuxRosettaDirectoryShare() {
                        let device = VZVirtioFileSystemDeviceConfiguration(tag: "rosetta")
                        device.share = rosettaShare
                        var sharing = config.directorySharingDevices
                        sharing.append(device)
                        config.directorySharingDevices = sharing
                    }
                }
            }

            try config.validate()
            try Task.checkCancellation()

            let queue = executor.queue
            let vm = VZVirtualMachine(configuration: config, queue: queue)
            self.virtualMachine = vm

            // Install the delegate BEFORE `vm.start(…)` so guest crashes
            // during the kernel boot window surface as delegate callbacks
            // rather than silent hangs at `.running`.
            if let d = pendingDelegate {
                vm.delegate = d
            }

            try Task.checkCancellation()
            phaseMark = recordPhase(\.configMs, since: phaseMark)

            // Start — with cooperative cancellation. If the outer Task is
            // cancelled (user clicked Stop mid-boot, window closed, host
            // shutdown), the `onCancel` block calls `vm.stop(…)` on the
            // executor queue. That causes the `start` completion to fire
            // with an error, resuming the continuation and unwinding cleanly
            // into the outer `catch` — no orphaned continuations, no leaked
            // `flock()`.
            let vmBox = UncheckedSendable(vm)
            let startQueue = queue
            try await withTaskCancellationHandler(
                operation: {
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                        startQueue.async {
                            vmBox.value.start { result in
                                cont.resume(with: result)
                            }
                        }
                    }
                },
                onCancel: {
                    startQueue.async {
                        vmBox.value.stop(completionHandler: { _ in })
                    }
                }
            )
            phaseMark = recordPhase(\.vzStartMs, since: phaseMark)
            _bootPhases.totalMs = msSince(phaseStart)

            _state = .ready
        } catch {
            await shutdownVM()
            _state = .idle
            if error is CancellationError {
                throw .bootFailed(underlying: VMError.cancelled)
            }
            throw .bootFailed(underlying: error)
        }
    }

    // Elapsed-ms helper keeping the boot path free of Duration conversion
    // noise. Returns the phase boundary for chaining.
    private func msSince(_ start: ContinuousClock.Instant) -> Double {
        let delta = ContinuousClock.now - start
        let comps = delta.components
        return Double(comps.seconds) * 1000 + Double(comps.attoseconds) / 1e15
    }

    private func recordPhase(
        _ keyPath: WritableKeyPath<BootPhases, Double>,
        since: ContinuousClock.Instant
    ) -> ContinuousClock.Instant {
        let now = ContinuousClock.now
        _bootPhases[keyPath: keyPath] += msSince(since)
        return now
    }

    // MARK: - Internal Result API

    public func bootResult() async -> Result<Void, LuminaError> {
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
        env: [String: String] = [:],
        cwd: String? = nil,
        stdin: Stdin = .closed
    ) async -> Result<RunResult, LuminaError> {
        do {
            return .success(try await exec(command, timeout: timeout, env: env, cwd: cwd, stdin: stdin))
        } catch {
            return .failure(error)
        }
    }

    // MARK: - File Transfer

    /// Upload files to the guest. Must be called after boot().
    public func uploadFiles(_ uploads: [FileUpload]) async throws(LuminaError) {
        guard _state == .ready, let runner = commandRunner else {
            throw .bootFailed(underlying: VMError.invalidState("Cannot upload from state: \(_state)"))
        }
        for file in uploads {
            try await runner.upload(file)
        }
    }

    /// Download files from the guest.
    public func downloadFiles(_ downloads: [FileDownload]) async throws(LuminaError) {
        guard _state == .ready, let runner = commandRunner else {
            throw .bootFailed(underlying: VMError.invalidState("Cannot download from state: \(_state)"))
        }
        for file in downloads {
            try await runner.download(file)
        }
    }

    // MARK: - Directory Transfer

    /// Upload a local directory to the guest by creating a tarball, uploading it,
    /// and extracting on the guest side.
    public func uploadDirectory(localPath: URL, remotePath: String) async throws(LuminaError) {
        guard _state == .ready, let runner = commandRunner else {
            throw .bootFailed(underlying: VMError.invalidState("Cannot upload from state: \(_state)"))
        }

        let tarName = ".lumina-upload-\(UUID().uuidString).tar.gz"
        let tarLocal = FileManager.default.temporaryDirectory.appendingPathComponent(tarName)
        defer { try? FileManager.default.removeItem(at: tarLocal) }

        let tarProcess = Process()
        tarProcess.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tarProcess.arguments = ["czf", tarLocal.path, "-C", localPath.path, "."]
        tarProcess.standardOutput = FileHandle.nullDevice
        tarProcess.standardError = FileHandle.nullDevice
        do {
            try tarProcess.run()
            tarProcess.waitUntilExit()
        } catch {
            throw .uploadFailed(path: localPath.path, reason: "Failed to create tarball: \(error)")
        }
        guard tarProcess.terminationStatus == 0 else {
            throw .uploadFailed(path: localPath.path, reason: "tar exited with code \(tarProcess.terminationStatus)")
        }

        let guestTar = "/tmp/\(tarName)"
        try await runner.upload(FileUpload(localPath: tarLocal, remotePath: guestTar))

        let mkdirResult = try await exec("mkdir -p '\(remotePath)'", timeout: 10)
        guard mkdirResult.success else {
            throw .uploadFailed(path: localPath.path, reason: "mkdir failed: \(mkdirResult.stderr)")
        }

        let extractResult = try await exec("tar xzf '\(guestTar)' -C '\(remotePath)' && rm -f '\(guestTar)'", timeout: 60)
        guard extractResult.success else {
            throw .uploadFailed(path: localPath.path, reason: "extract failed: \(extractResult.stderr)")
        }
    }

    /// Download a remote directory from the guest.
    public func downloadDirectory(remotePath: String, localPath: URL) async throws(LuminaError) {
        guard _state == .ready, let runner = commandRunner else {
            throw .bootFailed(underlying: VMError.invalidState("Cannot download from state: \(_state)"))
        }

        let tarName = ".lumina-download-\(UUID().uuidString).tar.gz"
        let guestTar = "/tmp/\(tarName)"
        let tarResult = try await exec("tar czf '\(guestTar)' -C '\(remotePath)' .", timeout: 60)
        guard tarResult.success else {
            throw .downloadFailed(path: remotePath, reason: "tar failed: \(tarResult.stderr)")
        }

        let tarLocal = FileManager.default.temporaryDirectory.appendingPathComponent(tarName)
        defer { try? FileManager.default.removeItem(at: tarLocal) }

        try await runner.download(FileDownload(remotePath: guestTar, localPath: tarLocal))

        _ = try? await exec("rm -f '\(guestTar)'", timeout: 10)

        do {
            try FileManager.default.createDirectory(at: localPath, withIntermediateDirectories: true)
        } catch {
            throw .downloadFailed(path: remotePath, reason: "Failed to create local directory: \(error)")
        }

        let extractProcess = Process()
        extractProcess.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        extractProcess.arguments = ["xzf", tarLocal.path, "-C", localPath.path]
        extractProcess.standardOutput = FileHandle.nullDevice
        extractProcess.standardError = FileHandle.nullDevice
        do {
            try extractProcess.run()
            extractProcess.waitUntilExit()
        } catch {
            throw .downloadFailed(path: remotePath, reason: "Failed to extract tarball: \(error)")
        }
        guard extractProcess.terminationStatus == 0 else {
            throw .downloadFailed(path: remotePath, reason: "tar extract exited with code \(extractProcess.terminationStatus)")
        }
    }

    func uploadFilesResult(_ uploads: [FileUpload]) async -> Result<Void, LuminaError> {
        do {
            try await uploadFiles(uploads)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    func downloadFilesResult(_ downloads: [FileDownload]) async -> Result<Void, LuminaError> {
        do {
            try await downloadFiles(downloads)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Exec (concurrent — multiple execs can be in flight)

    public func exec(
        _ command: String,
        timeout: Int = 60,
        env: [String: String] = [:],
        cwd: String? = nil,
        stdin: Stdin = .closed
    ) async throws(LuminaError) -> RunResult {
        guard _state == .ready, let runner = commandRunner else {
            throw .bootFailed(underlying: VMError.invalidState("Cannot exec from state: \(_state)"))
        }

        // Reconnect if the CommandRunner lost its connection
        if runner.state == .failed || runner.state == .disconnected {
            try await runner.reconnect()
        }

        let id = UUID().uuidString
        let start = ContinuousClock.now
        // Gate the stdin pump on exec dispatch. runner.exec fires afterDispatched
        // synchronously after sendExecMessage completes, so the exec message is
        // guaranteed to reach the guest before the pump's first stdin/stdin_close
        // message. Without this gate the pump races sendExecMessage and the
        // guest may receive stdin_close for an unknown exec id.
        let pumpGate = StdinPumpGate()
        let stdinTask = Self.spawnStdinPump(runner: runner, execId: id, stdin: stdin, gate: pumpGate)
        defer { stdinTask.cancel() }
        let result = try await runner.exec(
            id: id,
            command: command,
            timeout: timeout,
            env: env,
            cwd: cwd,
            afterDispatched: { pumpGate.open() }
        )
        let wallTime = ContinuousClock.now - start
        return RunResult(
            stdout: result.stdout,
            stderr: result.stderr,
            exitCode: result.exitCode,
            wallTime: wallTime,
            stdoutBytes: result.stdoutBytes,
            stderrBytes: result.stderrBytes
        )
    }

    /// Stream output chunks from a command in real time.
    /// Multiple streams can be active concurrently on the same VM.
    public func stream(
        _ command: String,
        timeout: Int = 60,
        env: [String: String] = [:],
        cwd: String? = nil,
        stdin: Stdin = .closed
    ) async throws(LuminaError) -> AsyncThrowingStream<OutputChunk, any Error> {
        guard _state == .ready, let runner = commandRunner else {
            throw .bootFailed(underlying: VMError.invalidState("Cannot stream from state: \(_state)"))
        }

        if runner.state == .failed || runner.state == .disconnected {
            try await runner.reconnect()
        }

        let id = UUID().uuidString
        let pumpGate = StdinPumpGate()
        let stream = try runner.execStream(
            id: id,
            command: command,
            timeout: timeout,
            env: env,
            cwd: cwd,
            afterDispatched: { pumpGate.open() }
        )
        let stdinTask = Self.spawnStdinPump(runner: runner, execId: id, stdin: stdin, gate: pumpGate)
        // Wrap the inner stream so stdinTask is cancelled when the caller
        // stops consuming (completion, error, or explicit cancel).
        return AsyncThrowingStream { continuation in
            let forwardTask = Task {
                do {
                    for try await chunk in stream {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                stdinTask.cancel()
            }
            continuation.onTermination = { _ in
                forwardTask.cancel()
                stdinTask.cancel()
            }
        }
    }

    /// Spawn a background task that forwards stdin to the guest for a given
    /// exec id. Returns immediately. The task waits on `gate.wait()` before
    /// any stdin/stdin_close write, so the exec message is guaranteed dispatched
    /// first. The task closes stdin on EOF, cancel, or error.
    ///
    /// Uses `Task.detached` so the pump does NOT inherit the VM actor's serial
    /// executor. A CLI stdin source (FileHandle.availableData) blocks on a
    /// read syscall — if run on VM's executor queue, it would starve the main
    /// task waiting on guest output messages. Detached runs on the global
    /// concurrent pool.
    private static func spawnStdinPump(
        runner: CommandRunner,
        execId: String,
        stdin: Stdin,
        gate: StdinPumpGate
    ) -> Task<Void, Never> {
        switch stdin {
        case .closed:
            return Task.detached {
                await gate.wait()
                // Defensive delay for agents predating the pre-register fix
                // (see Guest/lumina-agent/main.go serveConnection exec case).
                // With the fixed guest, stdin/stdin_close cannot race goroutine
                // registration because the scanner loop inserts the runningCmd
                // entry synchronously before spawning. This delay is harmless
                // on fixed agents (~5ms added to cold boot) and load-bearing
                // for older images until they are rebuilt in CI.
                try? await Task.sleep(for: .milliseconds(Self.stdinPumpWarmupMs))
                try? runner.closeStdin(id: execId)
            }
        case .source(let source):
            return Task.detached {
                await gate.wait()
                try? await Task.sleep(for: .milliseconds(Self.stdinPumpWarmupMs))
                do {
                    while !Task.isCancelled {
                        guard let chunk = try await source() else { break }  // EOF
                        // Today's protocol stdin is UTF-8. Non-UTF-8 bytes are
                        // lossy-converted via String(decoding:as:). Binary-safe
                        // stdin rides on the binary-stdout base64 work.
                        let s = String(decoding: chunk, as: UTF8.self)
                        try runner.sendStdin(id: execId, data: s)
                    }
                } catch {
                    // Source errored or sendStdin failed (connection dropped).
                    // Fall through to close.
                }
                try? runner.closeStdin(id: execId)
            }
        }
    }

    // MARK: - Stdin

    /// Send stdin data to a running command.
    public func sendStdin(_ data: String, execId: String) throws(LuminaError) {
        guard let runner = commandRunner else { throw .connectionFailed }
        try runner.sendStdin(id: execId, data: data)
    }

    /// Close the stdin pipe for a running command.
    public func closeStdin(execId: String) throws(LuminaError) {
        guard let runner = commandRunner else { throw .connectionFailed }
        try runner.closeStdin(id: execId)
    }

    /// Low-level streaming exec with a caller-supplied exec ID.
    /// Use this when you need to interleave sendStdin(_:execId:) calls during execution.
    /// The caller is responsible for stdin timing — no StdinPumpGate is applied.
    public func execStream(
        id: String,
        _ command: String,
        timeout: Int = 60,
        env: [String: String] = [:],
        cwd: String? = nil
    ) throws(LuminaError) -> AsyncThrowingStream<OutputChunk, any Error> {
        guard _state == .ready, let runner = commandRunner else {
            throw .bootFailed(underlying: VMError.invalidState("Cannot stream from state: \(_state)"))
        }
        return try runner.execStream(id: id, command: command, timeout: timeout, env: env, cwd: cwd)
    }

    // MARK: - PTY Exec (v0.6.0)

    /// Execute a command in a PTY on the guest. Returns a stream of PtyChunk
    /// (raw terminal bytes + exit code). The caller supplies `id` and is
    /// responsible for feeding input via `sendPtyInput(id:data:)` and resizing
    /// via `sendWindowResize(id:cols:rows:)`.
    public func execPtyStream(
        id: String,
        command: String,
        timeout: Int,
        env: [String: String] = [:],
        cols: Int,
        rows: Int
    ) throws(LuminaError) -> AsyncThrowingStream<PtyChunk, any Error> {
        guard _state == .ready, let runner = commandRunner else {
            throw .bootFailed(underlying: VMError.invalidState("Cannot execPty from state: \(_state)"))
        }
        return try runner.execPty(id: id, command: command, timeout: timeout, env: env, cols: cols, rows: rows)
    }

    /// Send raw bytes to a running PTY session's master fd.
    public func sendPtyInput(id: String, data: Data) throws(LuminaError) {
        guard let runner = commandRunner else { throw .connectionFailed }
        try runner.sendPtyInput(id: id, data: data)
    }

    /// Resize the window of a running PTY session (triggers SIGWINCH in guest).
    public func sendWindowResize(id: String, cols: Int, rows: Int) throws(LuminaError) {
        guard let runner = commandRunner else { throw .connectionFailed }
        try runner.sendWindowResize(id: id, cols: cols, rows: rows)
    }

    // MARK: - Port Forwarding (v0.6.0)

    /// Ask the guest agent to open a TCP listener on `guestPort` and return the
    /// vsock port the host should dial for each new proxied connection.
    ///
    /// Actor-isolated: runs on the VM's executor queue. Callers (e.g. the
    /// SessionProcess port-forward proxy) await this method, and the write to
    /// the vsock happens on the correct queue.
    public func requestPortForward(guestPort: Int) async throws(LuminaError) -> Int {
        guard _state == .ready, let runner = commandRunner else {
            throw .connectionFailed
        }
        return try await runner.requestPortForward(guestPort: guestPort)
    }

    /// Tell the guest agent to stop forwarding `guestPort`. Idempotent.
    public func stopPortForward(guestPort: Int) throws(LuminaError) {
        guard let runner = commandRunner else { throw .connectionFailed }
        try runner.stopPortForward(guestPort: guestPort)
    }

    /// Open a vsock connection to the guest on `port` and return a duplicated
    /// POSIX file descriptor the caller owns. This method is actor-isolated —
    /// the underlying `VZVirtioSocketDevice.connect(toPort:)` call must run on
    /// the VM's executor queue (Carmack review: detached tasks would violate
    /// VZ's thread-affinity requirement).
    ///
    /// Callers from detached tasks (e.g. port-forward TCP proxies) await this
    /// method, read/write the returned fd with standard POSIX syscalls, and
    /// MUST `close()` the fd when done. The original VZVirtioSocketConnection
    /// is released inside the actor once its fd is duped — the dup'd fd stays
    /// valid independently.
    ///
    /// Returns a fd instead of VZVirtioSocketConnection so the non-Sendable
    /// VZ object never leaves the actor isolation domain.
    public func connectVsock(port: UInt32) async throws(LuminaError) -> Int32 {
        guard _state == .ready, let vm = virtualMachine else {
            throw .connectionFailed
        }
        guard let socketDevice = vm.socketDevices.first as? VZVirtioSocketDevice else {
            throw .connectionFailed
        }
        let queue = executor.queue
        // Dup the connection's fd inside the callback so the non-Sendable
        // VZVirtioSocketConnection never crosses the actor boundary — only
        // an Int32 does. The VZ object drops out of scope on the queue and its
        // underlying fd is closed on dealloc; the dup'd fd remains valid.
        let fd: Int32
        do {
            let socketBox = UncheckedSendable(socketDevice)
            fd = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, any Error>) in
                queue.async {
                    socketBox.value.connect(toPort: port) { result in
                        switch result {
                        case .success(let c):
                            let d = dup(c.fileDescriptor)
                            if d < 0 {
                                cont.resume(throwing: LuminaError.connectionFailed)
                            } else {
                                cont.resume(returning: d)
                            }
                        case .failure(let err):
                            cont.resume(throwing: err)
                        }
                    }
                }
            }
        } catch {
            throw .connectionFailed
        }
        return fd
    }

    /// Attempt to reconnect to the guest agent after a connection drop.
    /// State is only set to `.ready` after the reconnect succeeds.
    public func reconnect() async throws(LuminaError) {
        guard let runner = commandRunner else {
            throw .connectionFailed
        }
        try await runner.reconnect()
        _state = .ready
    }

    /// Configure guest network via host-driven protocol.
    /// Derives IP from the VZ-assigned MAC address, sends config to the guest agent,
    /// and waits for network_ready before returning — ensuring DNS is live for all
    /// subsequent exec commands.
    public func configureNetwork() async throws(LuminaError) {
        guard let runner = commandRunner else { throw .connectionFailed }
        guard let lastByte = macLastByte else { throw .connectionFailed }

        // Discover the actual vmnet gateway by reading the host bridge interface
        // that VZNATNetworkDeviceAttachment created. The subnet can vary (e.g.
        // 192.168.65.0/24 instead of 192.168.64.0/24) if another process or VPN
        // already holds the default range. Fall back to the historic default if
        // discovery fails (e.g. no bridge interfaces found yet).
        let (gateway, subnetPrefix) = await Self.discoverVmnetGateway(macLastByte: self.macLastByte) ?? ("192.168.64.1", "192.168.64")

        let hostNum = (Int(lastByte) % 253) + 2
        let ip = "\(subnetPrefix).\(hostNum)/24"

        try await runner.configureNetwork(ip: ip, gateway: gateway, dns: gateway)
    }

    /// Find the IPv4 address of the host-side vmnet bridge (bridge100, bridge101, …).
    /// VZNATNetworkDeviceAttachment creates a bridgeXXX interface on the host; its
    /// IPv4 address is the gateway the guest must route through. The default subnet
    /// Apple uses is 192.168.64.0/24 but vmnet will pick another (e.g. 192.168.65.0/24)
    /// when that range is already in use.
    ///
    /// The bridge exists immediately, but vmnet assigns its IPv4 address ~20-50ms after
    /// the VM starts. We poll briefly (up to 300ms) to handle this race.
    ///
    /// Returns (gatewayIP, subnetPrefix) e.g. ("192.168.65.1", "192.168.65"), or nil
    /// if no suitable bridge is found within the timeout.
    ///
    /// Note: with multiple concurrent VMs each VM gets its own bridge. This heuristic
    /// picks the first one found, which is correct for sequential boots but may pick
    /// the wrong bridge when several VMs boot simultaneously. MAC-based matching would
    /// be needed for a fully correct multi-VM implementation.
    private static func discoverVmnetGateway(
        macLastByte: UInt8? = nil
    ) async -> (gateway: String, subnetPrefix: String)? {
        // Poll up to 300ms in 25ms increments. The bridge IPv4 typically appears
        // within 50ms of boot; 300ms gives comfortable headroom.
        // Task.sleep suspends the task (releases the actor executor) rather than
        // blocking the underlying OS thread between polls.
        for attempt in 0..<12 {
            if attempt > 0 {
                try? await Task.sleep(for: .milliseconds(25))
            }
            if let result = discoverVmnetGatewayOnce(preferringMAC: macLastByte) {
                return result
            }
        }
        return nil
    }

    /// Match a vmnet bridge by the last octet of the VM's MAC address.
    /// Returns the gateway IP and subnet prefix if a matching bridge is found.
    /// The vmnet bridge assigns IPs in the same /24 as its gateway, and the
    /// bridge's ARP table contains the VM's MAC. We match by iterating bridges
    /// and checking if the VM's MAC last-octet appears in the bridge's subnet.
    ///
    /// For now: match by bridge name + AF_INET. The MAC-based matching requires
    /// reading the ARP table (or using vmnet's interface mapping), which we defer
    /// to when we can reproduce multi-bridge scenarios.
    ///
    /// Simplified v1: accept a `macLastByte` and prefer bridges whose subnet
    /// matches the DHCP-assigned range for that byte.
    static func discoverVmnetGatewayOnce(
        preferringMAC macLastByte: UInt8? = nil
    ) -> (gateway: String, subnetPrefix: String)? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let head = ifap else { return nil }
        defer { freeifaddrs(head) }

        var candidates: [(gateway: String, subnetPrefix: String, name: String)] = []
        var ptr: UnsafeMutablePointer<ifaddrs>? = head
        while let iface = ptr {
            defer { ptr = iface.pointee.ifa_next }

            guard let namePtr = iface.pointee.ifa_name,
                  let addrPtr = iface.pointee.ifa_addr else { continue }

            let name = String(cString: namePtr)
            guard name.hasPrefix("bridge"), name != "bridge0" else { continue }
            guard addrPtr.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let rc = getnameinfo(addrPtr, socklen_t(addrPtr.pointee.sa_len),
                                 &host, socklen_t(NI_MAXHOST),
                                 nil, 0, NI_NUMERICHOST)
            guard rc == 0 else { continue }

            // Decode the null-terminated C string into Swift without the
            // deprecated `String(cString: [CChar])` initializer.
            let ip = host.withUnsafeBufferPointer { buf -> String in
                guard let base = buf.baseAddress else { return "" }
                return String(cString: base)
            }
            let parts = ip.split(separator: ".")
            guard parts.count == 4 else { continue }

            let prefix = parts.dropLast().joined(separator: ".")
            candidates.append((gateway: ip, subnetPrefix: prefix, name: name))
        }

        guard !candidates.isEmpty else { return nil }

        // If only one bridge, return it (most common case)
        if candidates.count == 1 {
            let c = candidates[0]
            NSLog("[Lumina.VM] Discovered vmnet gateway %@ on %@", c.gateway, c.name)
            return (gateway: c.gateway, subnetPrefix: c.subnetPrefix)
        }

        // Multiple bridges: if we have a MAC byte, match by bridge index ordering.
        // vmnet assigns bridges in creation order; we rely on the MAC hint to
        // disambiguate. This is a best-effort heuristic — true MAC-to-bridge
        // mapping requires vmnet API access.
        if let mac = macLastByte {
            let sorted = candidates.sorted { $0.name < $1.name }
            let idx = Int(mac) % sorted.count
            let c = sorted[idx]
            NSLog("[Lumina.VM] Matched vmnet gateway %@ on %@ (MAC hint: 0x%02X)", c.gateway, c.name, mac)
            return (gateway: c.gateway, subnetPrefix: c.subnetPrefix)
        }

        // No MAC hint: fall back to first bridge (legacy behavior)
        let c = candidates[0]
        NSLog("[Lumina.VM] Discovered vmnet gateway %@ on %@ (first-found, no MAC hint)", c.gateway, c.name)
        return (gateway: c.gateway, subnetPrefix: c.subnetPrefix)
    }

    /// Number of exec commands currently in flight on this VM.
    public var activeExecCount: Int {
        commandRunner?.activeExecCount ?? 0
    }

    /// Send a signal to a running guest command (by ID) or all commands (nil).
    public func cancel(signal: Int32 = 15, gracePeriod: Int = 5) throws(LuminaError) {
        guard let runner = commandRunner else { return }
        try runner.cancel(id: nil, signal: signal, gracePeriod: gracePeriod)
    }

    /// Send a signal to a specific running guest command.
    public func cancel(execId: String, signal: Int32 = 15, gracePeriod: Int = 5) throws(LuminaError) {
        guard let runner = commandRunner else { return }
        try runner.cancel(id: execId, signal: signal, gracePeriod: gracePeriod)
    }

    public func shutdown() async {
        guard _state != .shutdown else { return }
        _state = .shutdown
        await shutdownVM()
    }

    /// Detach the disk clone from this VM (caller takes ownership).
    public func detachClone() -> DiskClone? {
        let c = clone
        clone = nil
        return c
    }

    public var serialOutput: String {
        serialConsole.output
    }

    /// Last `lines` newline-terminated lines from the serial console
    /// buffer, stripped of ANSI CSI sequences that terminals use for
    /// cursor/color control. Designed for the desktop's boot-window
    /// tail ticker: the framebuffer goes blank during EFI→kernel
    /// handoff and during silent kernel panics, so the serial tail is
    /// the only evidence a user can see when something's gone wrong.
    public func serialTail(lines: Int = 12) -> String {
        let raw = serialConsole.output
        if raw.isEmpty { return "" }
        // Strip CSI sequences (ESC [ … final-byte) that would garble a
        // plain SwiftUI Text. This is lossy — non-CSI escape sequences
        // (e.g., OSC for title changes) are left alone — but good
        // enough for human-readable tail output.
        var cleaned = ""
        cleaned.reserveCapacity(raw.count)
        var iter = raw.unicodeScalars.makeIterator()
        while let c = iter.next() {
            if c == "\u{1B}" {
                // Swallow ESC + possible [ + parameter bytes + final.
                if let next = iter.next(), next == "[" {
                    while let p = iter.next() {
                        if (0x40...0x7E).contains(p.value) { break }
                    }
                } // otherwise just drop the lone ESC
                continue
            }
            cleaned.unicodeScalars.append(c)
        }
        let split = cleaned.split(
            separator: "\n", omittingEmptySubsequences: false
        )
        let tail = split.suffix(lines)
        return tail.joined(separator: "\n")
    }

    /// Sendable handle wrapping the underlying VZVirtualMachine for the
    /// SwiftUI display layer. VZ's class is not Sendable; this opt-in
    /// `@unchecked Sendable` wrapper lets us cross the actor boundary
    /// while preserving the "VZ calls happen on the main thread" contract
    /// (`LuminaVirtualMachineView` lives on `@MainActor`).
    public struct VZMachineHandle: @unchecked Sendable {
        public let machine: VZVirtualMachine?
    }

    /// Direct accessor for the underlying VZVirtualMachine, used by the
    /// SwiftUI display layer (`LuminaVirtualMachineView` in
    /// LuminaDesktopKit).
    public func vzMachine() -> VZMachineHandle {
        VZMachineHandle(machine: virtualMachine)
    }

    /// Install a `VZVirtualMachineDelegate`. Safe to call before or
    /// after `boot()`:
    ///
    /// - **Before boot:** the delegate is stored and applied to the VZ
    ///   machine the moment it is created, *before* `vm.start(…)`. This
    ///   is the correct call site because any guest crash during kernel
    ///   boot (panic, dracut timeout, missing hardware model) fires
    ///   `didStopWithError` — which today is lost if the delegate
    ///   hasn't been wired yet. With pre-start install the crash flows
    ///   through the delegate and the session transitions to
    ///   `.crashed(reason:)` instead of hanging at `.running`.
    /// - **After boot:** applied immediately to the existing VZ machine;
    ///   preserved for identical behavior for pre-existing callers.
    ///
    /// The delegate is weakly held by VZ; the caller owns retention.
    public func setDelegate(_ delegate: (any VZVirtualMachineDelegate)?) {
        pendingDelegate = delegate
        virtualMachine?.delegate = delegate
    }

    // MARK: - Private

    private func shutdownVM() async {
        if let vm = virtualMachine {
            let queue = executor.queue
            let vmBox = UncheckedSendable(vm)
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                queue.async {
                    vmBox.value.stop(completionHandler: { _ in
                        cont.resume()
                    })
                }
            }
            virtualMachine = nil
        }
        commandRunner = nil
        // Cancel serial drain tasks before closing handles so the cooperative
        // cancellation signal arrives first; the handle close then delivers
        // the EOF that unblocks any in-flight `availableData` read.
        for task in serialReadTasks { task.cancel() }
        serialReadTasks = []
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

    /// Encode network hosts map as a kernel cmdline param value.
    /// Sanitizes hostnames to DNS-safe characters (alphanumeric + hyphens)
    /// to prevent shell injection via the init script's cmdline parsing.
    private static func encodeHosts(_ hosts: [String: String]) -> String {
        hosts.sorted(by: { $0.key < $1.key })
            .map { (name, addr) in
                let safeName = String(name.unicodeScalars.filter {
                    CharacterSet.alphanumerics.contains($0) || $0 == "-"
                })
                let safeAddr = String(addr.unicodeScalars.filter {
                    CharacterSet.decimalDigits.contains($0) || $0 == "."
                })
                return "\(safeName):\(safeAddr)"
            }
            .joined(separator: ",")
    }
}

// MARK: - Internal Errors

enum VMError: Error, Sendable {
    case invalidState(String)
    case noSocketDevice
    case pipeFailed
    case cancelled
}

/// Host-side boot-phase timings in milliseconds. Populated during
/// `VM.boot()` and accessible via `VM.bootPhases`. `totalMs` is the
/// wall-clock from `boot()` entry to `.ready`; the per-phase fields are
/// host-side only (guest userspace is observed through the agent-path
/// `CommandRunner` handshake or the EFI-path serial-console first-byte).
/// All fields default to zero — zero-cost when unused.
///
/// Consumed by the cold-boot regression bench (see `Tests/LuminaTests/
/// BootPhaseTests.swift`) and by the `LUMINA_BOOT_TRACE=1` CLI hook
/// which prints the struct to stderr after `boot()` returns.
///
/// **Agent-path semantics:** On `lumina run`/`exec` callers, this struct
/// is zero-valued because the agent path attaches to an existing VM
/// rather than invoking `VM.boot()` directly — no phase is observed so
/// none is written. Use `BootPhases.isValid` to distinguish a populated
/// struct from an unobserved one before rendering timings in UI.
/// Desktop callers (and any code that owns the `VM.boot()` call) see
/// fully populated values.
public struct BootPhases: Sendable, Equatable {
    public var configMs: Double = 0
    public var vzStartMs: Double = 0
    public var totalMs: Double = 0

    public init() {}

    /// True when any phase was observed (i.e. `VM.boot()` ran to the
    /// point of writing at least one field). False on the agent path
    /// where the VM was attached, not booted here. Callers rendering
    /// boot timings in UI should gate on this to avoid "0 ms" rows.
    public var isValid: Bool {
        totalMs > 0
    }
}

// MARK: - Sendable crossing shim

/// `@unchecked Sendable` box for the single-closure crossings this target
/// makes into `DispatchQueue.async` and friends with non-`Sendable`
/// references — principally VZ API objects. The caller's contract: the
/// wrapped value is used on the correct isolation domain inside the
/// closure (e.g. `VZVirtualMachine` on its creation queue). Without this
/// box, Swift 6's `SendableClosureCaptures` diagnostic fires on every
/// `queue.async { vm.something(...) }` call site; wrapping makes the
/// intent explicit rather than silencing it with `@preconcurrency`.
struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

// MARK: - Sound (v0.7.0 M4, agent-path-neutral)

/// Attach a `VZVirtioSoundDeviceConfiguration` with `sound.streamCount`
/// output streams. Free function so it doesn't pull anything into the
/// agent path until `options.sound` is non-nil. `internal` so MacOSVM
/// (same target) can reuse it.
internal func attachSoundDevice(
    to config: VZVirtualMachineConfiguration,
    sound: SoundConfig
) {
    let device = VZVirtioSoundDeviceConfiguration()
    var streams: [VZVirtioSoundDeviceStreamConfiguration] = []
    for _ in 0..<max(1, sound.streamCount) {
        let output = VZVirtioSoundDeviceOutputStreamConfiguration()
        output.sink = VZHostAudioOutputStreamSink()
        streams.append(output)
    }
    device.streams = streams
    var existing = config.audioDevices
    existing.append(device)
    config.audioDevices = existing
}

// MARK: - Graphics (v0.7.0, agent-path-neutral)

/// Attach display + input devices matching `graphics` to `config`.
///
/// Free function (not a VM-actor method) so it has no implicit access to
/// actor state — it operates purely on the supplied configuration. Called
/// only when `VMOptions.graphics != nil`, so agent-path runs never
/// invoke it and never link any of these VZ device classes at runtime.
private func attachGraphicsDevices(
    to config: VZVirtualMachineConfiguration,
    graphics: GraphicsConfig
) {
    // Virtio-GPU scanouts: primary display plus any `additionalDisplays`.
    // The SwiftUI running-VM window still renders display 0 only; extra
    // scanouts are live on the VZ side (Linux guests see multiple
    // framebuffers via `/sys/class/drm/`) for callers driving the VM from
    // their own view layer. Multi-display UI in the Desktop app is
    // follow-up work.
    let gfx = VZVirtioGraphicsDeviceConfiguration()
    var scanouts: [VZVirtioGraphicsScanoutConfiguration] = [
        VZVirtioGraphicsScanoutConfiguration(
            widthInPixels: graphics.widthInPixels,
            heightInPixels: graphics.heightInPixels
        )
    ]
    for extra in graphics.additionalDisplays {
        scanouts.append(VZVirtioGraphicsScanoutConfiguration(
            widthInPixels: extra.widthInPixels,
            heightInPixels: extra.heightInPixels
        ))
    }
    gfx.scanouts = scanouts
    config.graphicsDevices = [gfx]

    // Keyboard. `.mac` only makes sense on macOS guests (M5); on a generic
    // VM it falls back to USB so the caller doesn't get a validation error.
    switch graphics.keyboardKind {
    case .usb:
        config.keyboards = [VZUSBKeyboardConfiguration()]
    case .mac:
        #if swift(>=6)
        if #available(macOS 14.0, *) {
            config.keyboards = [VZMacKeyboardConfiguration()]
        } else {
            config.keyboards = [VZUSBKeyboardConfiguration()]
        }
        #else
        config.keyboards = [VZUSBKeyboardConfiguration()]
        #endif
    }

    // Pointing device. Trackpad requires a macOS guest for full fidelity;
    // on Linux/Windows it doesn't validate, so fall back to USB mouse.
    switch graphics.pointingDeviceKind {
    case .usbScreenCoordinate:
        config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
    case .trackpad:
        #if swift(>=6)
        if #available(macOS 14.0, *) {
            config.pointingDevices = [VZMacTrackpadConfiguration()]
        } else {
            config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        }
        #else
        config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        #endif
    }
}
