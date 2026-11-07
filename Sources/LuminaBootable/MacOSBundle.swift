import Foundation
import Lumina

extension VMBundle {
    public enum MacOSPhase: Sendable, Equatable {
        case downloading
        case installing
    }

    var macOSHardwareModelURL: URL { rootURL.appendingPathComponent("macos.hwmodel") }
    var macOSMachineIDURL: URL { rootURL.appendingPathComponent("macos.machineid") }

    public var isMacOSInstalled: Bool {
        FileManager.default.fileExists(atPath: macOSHardwareModelURL.path)
            && FileManager.default.fileExists(atPath: auxiliaryStorageURL.path)
    }

    public func macOSVM(graphics: GraphicsConfig? = GraphicsConfig(widthInPixels: 2560, heightInPixels: 1440)) -> MacOSVM {
        MacOSVM(
            bootConfig: MacOSBootConfig(
                auxiliaryStorage: auxiliaryStorageURL,
                primaryDisk: primaryDiskURL,
                hardwareModel: try? Data(contentsOf: macOSHardwareModelURL),
                machineIdentifier: try? Data(contentsOf: macOSMachineIDURL)
            ),
            memoryBytes: manifest.memoryBytes,
            cpuCount: manifest.cpuCount,
            graphics: graphics,
            macAddress: manifest.macAddress
        )
    }

    public mutating func installMacOS(
        ipsw: URL? = nil,
        progress: @escaping @Sendable (MacOSPhase, Double) -> Void = { _, _ in }
    ) async throws {
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated],
            reason: "Installing macOS into \(manifest.name)"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }
        ensureMACAddress()
        let restoreImage: URL
        if let ipsw = ipsw ?? pendingISO {
            restoreImage = ipsw
        } else {
            restoreImage = try await MacOSRestore.latestIPSW { progress(.downloading, $0) }
        }
        try? FileManager.default.removeItem(at: auxiliaryStorageURL)
        let vm = MacOSVM(
            bootConfig: MacOSBootConfig(ipsw: restoreImage, auxiliaryStorage: auxiliaryStorageURL, primaryDisk: primaryDiskURL),
            memoryBytes: manifest.memoryBytes,
            cpuCount: manifest.cpuCount,
            macAddress: manifest.macAddress
        )
        try await vm.install { progress(.installing, $0) }
        await vm.shutdown()
        let installed = await vm.bootConfig
        guard let model = installed.hardwareModel, let machineID = installed.machineIdentifier else {
            throw MacOSRestore.Error(description: "install finished without a hardware model or machine identifier")
        }
        try machineID.write(to: macOSMachineIDURL, options: .atomic)
        try model.write(to: macOSHardwareModelURL, options: .atomic)
        try? FileManager.default.removeItem(at: rootURL.appendingPathComponent("pending-iso.path"))
    }
}
