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
        sound: SoundConfig? = SoundConfig(enabled: true)
    ) {
        self._bootConfig = bootConfig
        self.memoryBytes = memoryBytes
        self.cpuCount = cpuCount
        self.graphics = graphics
        self.sound = sound
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

        // Network for install (downloads inside recovery).
        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
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

        // Observe progress.
        let progressToken: NSKeyValueObservation? = installer.progress.observe(\.fractionCompleted) { progress, _ in
            progressHandler?(progress.fractionCompleted)
        }
        defer { progressToken?.invalidate() }

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Swift.Error>) in
                queue.async {
                    installerBox.value.install { result in
                        cont.resume(with: result)
                    }
                }
            }
        } catch {
            _state = .idle
            throw Error.installFailed("\(error)")
        }
        _state = .ready
    }

    /// Boot a macOS guest that's already installed.
    public func boot() async throws {
        guard _state == .idle else {
            throw Error.invalidState("boot requires .idle state, was \(_state)")
        }
        _state = .booting

        let vzConfig = VZVirtualMachineConfiguration()
        vzConfig.cpuCount = cpuCount
        vzConfig.memorySize = memoryBytes

        do {
            try MacOSBootable(config: _bootConfig).apply(to: vzConfig)
        } catch {
            _state = .idle
            throw Error.bootFailed("MacOSBootable.apply: \(error)")
        }

        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
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
            _state = .idle
            throw Error.bootFailed("config validation: \(error)")
        }

        let queue = executor.queue
        let vm = VZVirtualMachine(configuration: vzConfig, queue: queue)
        self.virtualMachine = vm

        do {
            let vmBox = UncheckedSendable(vm)
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Swift.Error>) in
                queue.async {
                    vmBox.value.start { result in
                        cont.resume(with: result)
                    }
                }
            }
        } catch {
            _state = .idle
            throw Error.bootFailed("\(error)")
        }

        _state = .ready
    }

    public func shutdown() async {
        guard _state != .shutdown else { return }
        _state = .shutdown
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
