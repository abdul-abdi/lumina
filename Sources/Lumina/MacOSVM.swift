// Sources/Lumina/MacOSVM.swift
//
// v0.7.0 M5 — actor wrapping VZVirtualMachine for macOS guests.
// Parallel to `VM` (which handles Linux + Windows). VZ exposes
// VZMacOSVirtualMachine in framework documentation as a "type" but the
// runtime class returned by `VZVirtualMachine(configuration:)` *is*
// VZVirtualMachine for both — the differentiator is the platform
// configuration. So MacOSVM uses VZVirtualMachine just like VM, with a
// VZMacPlatformConfiguration applied via MacOSBootable.
//
// Why a separate actor: macOS guests have a different lifecycle (install
// via VZMacOSInstaller before first boot; no vsock agent inside; no
// CommandRunner). Conflating them with VM would either dilute VM's API
// surface or push macOS-specific exec handling into a Linux/Windows
// path that doesn't need it.

import Foundation
@preconcurrency import Virtualization

public actor MacOSVM {
    public enum State: Sendable, Equatable {
        case idle
        case installing(progress: Double)
        case booting
        case ready
        case shutdown
    }

    private nonisolated let executor: VMExecutor
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    private var virtualMachine: VZVirtualMachine?
    private var _state: State = .idle
    private var _bootConfig: MacOSBootConfig
    private let memoryBytes: UInt64
    private let cpuCount: Int
    private let graphics: GraphicsConfig?
    private let sound: SoundConfig?
    private let macAddressString: String?

    public var state: State { _state }
    public var bootConfig: MacOSBootConfig { _bootConfig }

    public init(
        bootConfig: MacOSBootConfig,
        memoryBytes: UInt64 = 8 * 1024 * 1024 * 1024,
        cpuCount: Int = 4,
        graphics: GraphicsConfig? = GraphicsConfig(
            widthInPixels: 2560,
            heightInPixels: 1440,
            keyboardKind: .mac,
            pointingDeviceKind: .trackpad
        ),
        sound: SoundConfig? = SoundConfig(enabled: true),
        macAddress: String? = nil
    ) {
        self._bootConfig = bootConfig
        self.memoryBytes = memoryBytes
        self.cpuCount = cpuCount
        self.graphics = graphics
        self.sound = sound
        self.macAddressString = macAddress
        self.executor = VMExecutor(
            queue: DispatchQueue(label: "com.lumina.macosvm", qos: .userInitiated)
        )
    }

    public enum Error: Swift.Error, Equatable {
        case invalidState(String)
        case installFailed(String)
        case bootFailed(String)
    }

    /// Run VZMacOSInstaller. Updates `state` to `.installing(progress:)`
    /// at each progress callback. On success, updates `_bootConfig` with
    /// the hardware model + machine identifier read from the IPSW.
    public func install(
        progress progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        guard _state == .idle else {
            throw Error.invalidState("install requires .idle state, was \(_state)")
        }

        let prepared: (config: MacOSBootConfig, restoreImage: VZMacOSRestoreImage)
        do {
            prepared = try await MacOSBootable.prepare(bootConfig: _bootConfig)
        } catch {
            throw Error.installFailed("prepare: \(error)")
        }
        _bootConfig = prepared.config

        let vzConfig = VZVirtualMachineConfiguration()
        vzConfig.cpuCount = cpuCount
        vzConfig.memorySize = memoryBytes

        do {
            try MacOSBootable(config: _bootConfig).apply(to: vzConfig)
        } catch {
            throw Error.installFailed("MacOSBootable.apply: \(error)")
        }

        // Network for install (downloads inside recovery). Pinning the
        // MAC when the bundle has one keeps vmnet's DHCP lease stable
        // between the install run and subsequent regular boots, so the
        // guest sees the same IP across reboots.
        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        if let macString = macAddressString,
           let mac = VZMACAddress(string: macString) {
            network.macAddress = mac
        }
        vzConfig.networkDevices = [network]
        vzConfig.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        if let graphics {
            attachMacGraphicsDevices(to: vzConfig, graphics: graphics)
        }
        if let sound, sound.enabled {
            attachSoundDevice(to: vzConfig, sound: sound)
        }

        do {
            try vzConfig.validate()
        } catch {
            throw Error.installFailed("config validation: \(error)")
        }

        let queue = executor.queue
        let vm = VZVirtualMachine(configuration: vzConfig, queue: queue)
        self.virtualMachine = vm
        _state = .installing(progress: 0.0)

        let vmBox = UncheckedSendable(vm)
        let preparedBox = UncheckedSendable(prepared)
        let installerBox: UncheckedSendable<VZMacOSInstaller> = await withCheckedContinuation { (cont: CheckedContinuation<UncheckedSendable<VZMacOSInstaller>, Never>) in
            queue.async {
                let inst = VZMacOSInstaller(
                    virtualMachine: vmBox.value,
                    restoringFromImageAt: preparedBox.value.restoreImage.url
                )
                cont.resume(returning: UncheckedSendable(inst))
            }
        }
        let installer = installerBox.value

        // Observe progress. This is the one exception to the
        // VZ-calls-on-executor rule in this file: `NSProgress` KVO is
        // documented thread-safe by Apple, and `VZMacOSInstaller.progress`
        // is a plain `NSProgress` property (not a VZ-isolated call), so
        // the observation itself doesn't need to be queued. The
        // `install(completionHandler:)` call below IS a VZ call and runs
        // on `queue` via withCheckedThrowingContinuation.
        let progressToken: NSKeyValueObservation? = installer.progress.observe(\.fractionCompleted) { progress, _ in
            progressHandler?(progress.fractionCompleted)
        }
        defer { progressToken?.invalidate() }

        do {
            // Cooperative cancellation during a 30+ minute IPSW restore.
            // If the user cancels mid-restore (closes the install window,
            // hits Stop), `onCancel` calls `vm.stop(…)` on the executor
            // queue which unwinds the installer's completion with an
            // error. The outer `catch` then releases the `flock()` on
            // `disk.img` / `aux.img` via `stopVZMachineIfRunning`, so a
            // subsequent `install()` or `boot()` succeeds cold. Without
            // this, cancelled installs orphaned the VZ machine and the
            // next attempt failed with `VZErrorDomain Code 2`.
            let startQueue = queue
            try await withTaskCancellationHandler(
                operation: {
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Swift.Error>) in
                        startQueue.async {
                            installerBox.value.install { result in
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
            // Installer failed mid-flight (or was cancelled): a VZ machine
            // is already running on the executor queue from the
            // VZVirtualMachine(configuration:) call above. Tear it down
            // before resetting state so a retry doesn't orphan the old VZ
            // instance inside this actor.
            await stopVZMachineIfRunning()
            _state = .idle
            throw Error.installFailed("\(error)")
        }
        // Installer finished. VZMacOSInstaller leaves the VZ machine stopped
        // on success, but `self.virtualMachine` still points at the
        // installer-configured instance. Tear it down and return to .idle so
        // boot() can construct a fresh configuration — subsequent boots do
        // not share installer-path state (CD-ROM attachment, installer
        // NSProgress observers, etc.).
        await stopVZMachineIfRunning()
        _state = .idle
    }

    /// Boot a macOS guest that's already installed.
    ///
    /// A mid-boot Task cancel (user clicks Stop in the desktop app before
    /// the guest reaches userspace) triggers `onCancel` on the start
    /// continuation, which invokes `vm.stop(…)` on the executor queue.
    /// That resumes `start`'s completion with an error; the `catch` funnels
    /// through `stopVZMachineIfRunning` to release `flock()` on the
    /// primary disk, so a subsequent `boot()` succeeds cold.
    public func boot() async throws {
        guard _state == .idle else {
            throw Error.invalidState("boot requires .idle state, was \(_state)")
        }
        _state = .booting

        do {
            let vzConfig = VZVirtualMachineConfiguration()
            vzConfig.cpuCount = cpuCount
            vzConfig.memorySize = memoryBytes

            try MacOSBootable(config: _bootConfig).apply(to: vzConfig)

            let network = VZVirtioNetworkDeviceConfiguration()
            network.attachment = VZNATNetworkDeviceAttachment()
            if let macString = macAddressString,
               let mac = VZMACAddress(string: macString) {
                network.macAddress = mac
            }
            vzConfig.networkDevices = [network]
            vzConfig.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
            if let graphics {
                attachMacGraphicsDevices(to: vzConfig, graphics: graphics)
            }
            if let sound, sound.enabled {
                attachSoundDevice(to: vzConfig, sound: sound)
            }

            try vzConfig.validate()
            try Task.checkCancellation()

            let queue = executor.queue
            let vm = VZVirtualMachine(configuration: vzConfig, queue: queue)
            self.virtualMachine = vm

            let vmBox = UncheckedSendable(vm)
            let startQueue = queue
            try await withTaskCancellationHandler(
                operation: {
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Swift.Error>) in
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

            _state = .ready
        } catch {
            await stopVZMachineIfRunning()
            _state = .idle
            throw Error.bootFailed("\(error)")
        }
    }

    public func shutdown() async {
        guard _state != .shutdown else { return }
        _state = .shutdown
        await stopVZMachineIfRunning()
    }

    /// Stop and release any live `VZVirtualMachine` this actor holds. Safe
    /// to call when none is set. VZ's `stop()` is called on the executor
    /// queue per the thread-affinity rule; the completion result is ignored
    /// because failure to stop gracefully is not actionable here — the
    /// next `start` will create a fresh VZ machine.
    private func stopVZMachineIfRunning() async {
        guard let vm = virtualMachine else { return }
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
}

// MARK: - macOS-flavoured graphics + sound (avoid name clash with VM.swift)

/// Attach a `VZMacGraphicsDeviceConfiguration` matching `graphics`. macOS
/// guests use a different graphics class from the virtio-gpu used by
/// Linux/Windows guests in `VM.swift`'s `attachGraphicsDevices`.
private func attachMacGraphicsDevices(
    to config: VZVirtualMachineConfiguration,
    graphics: GraphicsConfig
) {
    let display = VZMacGraphicsDisplayConfiguration(
        widthInPixels: graphics.widthInPixels,
        heightInPixels: graphics.heightInPixels,
        pixelsPerInch: 220
    )
    let gpu = VZMacGraphicsDeviceConfiguration()
    gpu.displays = [display]
    config.graphicsDevices = [gpu]

    config.keyboards = [VZMacKeyboardConfiguration()]
    config.pointingDevices = [VZMacTrackpadConfiguration()]
}
