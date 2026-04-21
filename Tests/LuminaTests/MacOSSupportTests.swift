// Tests/LuminaTests/MacOSSupportTests.swift
import Foundation
import Testing
@testable import Lumina

@Suite struct MacOSSupportTests {
    @Test func machineIdentifier_generateProducesUniqueIDs() {
        let a = MachineIdentifierStore.generate()
        let b = MachineIdentifierStore.generate()
        let aData = MachineIdentifierStore.serialize(a)
        let bData = MachineIdentifierStore.serialize(b)
        #expect(aData != bData)
    }

    @Test func machineIdentifier_serializeRoundTrip() {
        let id = MachineIdentifierStore.generate()
        let data = MachineIdentifierStore.serialize(id)
        let restored = MachineIdentifierStore.deserialize(data)
        #expect(restored != nil)
        if let restored {
            #expect(MachineIdentifierStore.serialize(restored) == data)
        }
    }

    @Test func machineIdentifier_deserializeNilOnInvalid() {
        let bogus = Data([0x00, 0x01, 0x02])
        #expect(MachineIdentifierStore.deserialize(bogus) == nil)
    }

    @Test func macOSBootable_throwsMissingHardwareModelOnEmptyConfig() throws {
        let cfg = MacOSBootConfig(
            ipsw: URL(fileURLWithPath: "/tmp/x.ipsw"),
            auxiliaryStorage: URL(fileURLWithPath: "/tmp/aux.img"),
            primaryDisk: URL(fileURLWithPath: "/tmp/disk.img")
        )
        let bootable = MacOSBootable(config: cfg)
        #expect(throws: MacOSBootable.Error.missingHardwareModel) {
            try bootable.apply(to: VZVirtualMachineConfigurationStub())
        }
    }
}

/// Type alias to keep imports of `Virtualization` out of the test surface
/// — we only need to assert MacOSBootable's pre-checks. Importing the real
/// VZVirtualMachineConfiguration from here is fine because Lumina already
/// links it; tests just need a value that triggers the pre-check.
import Virtualization
typealias VZVirtualMachineConfigurationStub = VZVirtualMachineConfiguration
