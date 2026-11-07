import Foundation
import Lumina
import Testing
@testable import LuminaBootable

@Suite struct MacOSBundleTests {
    private func makeBundle() throws -> VMBundle {
        try VMBundle.create(
            at: FileManager.default.temporaryDirectory.appendingPathComponent("LuminaMacOSBundle-\(UUID().uuidString)"),
            name: "mac",
            osFamily: .macOS,
            osVariant: "macos-latest",
            memoryBytes: 8 << 30,
            cpuCount: 4,
            diskBytes: 64 << 30
        )
    }

    @Test func installedOnlyOnceIdentityAndAuxStorageExist() throws {
        let bundle = try makeBundle()
        #expect(!bundle.isMacOSInstalled)
        try Data([1]).write(to: bundle.macOSHardwareModelURL)
        #expect(!bundle.isMacOSInstalled)
        try Data([2]).write(to: bundle.auxiliaryStorageURL)
        #expect(bundle.isMacOSInstalled)
    }

    @Test func bootConfigCarriesPersistedIdentity() async throws {
        let bundle = try makeBundle()
        try Data([1, 2, 3]).write(to: bundle.macOSHardwareModelURL)
        try Data([4, 5]).write(to: bundle.macOSMachineIDURL)
        let config = await bundle.macOSVM().bootConfig
        #expect(config.hardwareModel == Data([1, 2, 3]))
        #expect(config.machineIdentifier == Data([4, 5]))
        #expect(config.ipsw == nil)
        #expect(config.primaryDisk == bundle.primaryDiskURL)
    }

    @Test func prepareWithoutRestoreImageFails() async {
        let config = MacOSBootConfig(auxiliaryStorage: URL(fileURLWithPath: "/tmp/aux"), primaryDisk: URL(fileURLWithPath: "/tmp/disk"))
        await #expect(throws: MacOSBootable.Error.missingRestoreImage) {
            _ = try await MacOSBootable.prepare(bootConfig: config)
        }
    }
}
