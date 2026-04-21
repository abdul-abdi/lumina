// Sources/Lumina/MacOSSupport.swift
//
// v0.7.0 M5 — VZMacOSVirtualMachine glue. Lives in `Lumina` (not
// `LuminaBootable`) for the same reason as `EFIBootable`: `MacOSVM`
// (in this same target) calls into it.

import Foundation
import Virtualization

/// Round-trip helpers for VZMacHardwareModel — its canonical form is
/// `dataRepresentation`. We persist the bytes in `MacOSBootConfig.hardwareModel`.
public enum HardwareModelStore {
    public static func serialize(_ model: VZMacHardwareModel) -> Data {
        model.dataRepresentation
    }

    public static func deserialize(_ data: Data) -> VZMacHardwareModel? {
        VZMacHardwareModel(dataRepresentation: data)
    }
}

/// Same pattern for `VZMacMachineIdentifier`.
public enum MachineIdentifierStore {
    public static func generate() -> VZMacMachineIdentifier {
        VZMacMachineIdentifier()
    }

    public static func serialize(_ id: VZMacMachineIdentifier) -> Data {
        id.dataRepresentation
    }

    public static func deserialize(_ data: Data) -> VZMacMachineIdentifier? {
        VZMacMachineIdentifier(dataRepresentation: data)
    }
}

/// Wraps `VZMacAuxiliaryStorage` creation/load. Reuses the file if it
/// exists; creates a fresh one with the given hardware model otherwise.
public enum AuxiliaryStorageStore {
    public enum Error: Swift.Error {
        case createFailed(String)
    }

    public static func loadOrCreate(
        at url: URL,
        hardwareModel: VZMacHardwareModel
    ) throws -> VZMacAuxiliaryStorage {
        if FileManager.default.fileExists(atPath: url.path) {
            return VZMacAuxiliaryStorage(url: url)
        }
        do {
            return try VZMacAuxiliaryStorage(
                creatingStorageAt: url,
                hardwareModel: hardwareModel,
                options: []
            )
        } catch {
            throw Error.createFailed("\(error)")
        }
    }
}

/// Configures a `VZVirtualMachineConfiguration` for a macOS guest.
///
/// Caller responsibilities:
///   - Provide an `MacOSBootConfig` whose `hardwareModel` and
///     `machineIdentifier` are populated. Use `MacOSBootable.prepare(...)`
///     or do it manually from the IPSW's `mostFeaturefulSupportedConfiguration`.
///   - Provide CPU count + memory size on the config before calling apply.
///
/// MacOSBootable does NOT touch graphics, network, audio, entropy — those
/// stay caller-owned, mirroring `EFIBootable`'s layering.
public struct MacOSBootable: Sendable {
    public let config: MacOSBootConfig

    public init(config: MacOSBootConfig) {
        self.config = config
    }

    public enum Error: Swift.Error, Equatable {
        case missingHardwareModel
        case invalidHardwareModel
        case missingMachineIdentifier
        case invalidMachineIdentifier
        case auxiliaryStorageFailed(String)
        case primaryDiskFailed(String)
    }

    public func apply(to vzConfig: VZVirtualMachineConfiguration) throws {
        guard let hwModelData = config.hardwareModel else {
            throw Error.missingHardwareModel
        }
        guard let hwModel = HardwareModelStore.deserialize(hwModelData) else {
            throw Error.invalidHardwareModel
        }
        guard let machineIDData = config.machineIdentifier else {
            throw Error.missingMachineIdentifier
        }
        guard let machineID = MachineIdentifierStore.deserialize(machineIDData) else {
            throw Error.invalidMachineIdentifier
        }

        let aux: VZMacAuxiliaryStorage
        do {
            aux = try AuxiliaryStorageStore.loadOrCreate(
                at: config.auxiliaryStorage,
                hardwareModel: hwModel
            )
        } catch {
            throw Error.auxiliaryStorageFailed("\(error)")
        }

        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = hwModel
        platform.machineIdentifier = machineID
        platform.auxiliaryStorage = aux
        vzConfig.platform = platform

        vzConfig.bootLoader = VZMacOSBootLoader()

        // Primary disk — read-write virtio block.
        do {
            let primaryAttachment = try VZDiskImageStorageDeviceAttachment(
                url: config.primaryDisk,
                readOnly: false
            )
            vzConfig.storageDevices = [
                VZVirtioBlockDeviceConfiguration(attachment: primaryAttachment)
            ]
        } catch {
            throw Error.primaryDiskFailed("\(error)")
        }
    }

    /// Convenience: load a `VZMacOSRestoreImage` from an IPSW URL and
    /// fill in `MacOSBootConfig.hardwareModel` + `.machineIdentifier`
    /// from its `mostFeaturefulSupportedConfiguration`. Returns the
    /// updated config + the restore image (caller passes both into
    /// VZMacOSInstaller).
    public static func prepare(
        bootConfig: MacOSBootConfig
    ) async throws -> (config: MacOSBootConfig, restoreImage: VZMacOSRestoreImage) {
        let restore = try await VZMacOSRestoreImage.image(from: bootConfig.ipsw)
        guard let supported = restore.mostFeaturefulSupportedConfiguration else {
            throw Error.invalidHardwareModel
        }
        var updated = bootConfig
        updated.hardwareModel = supported.hardwareModel.dataRepresentation
        if updated.machineIdentifier == nil {
            updated.machineIdentifier = MachineIdentifierStore.serialize(MachineIdentifierStore.generate())
        }
        return (updated, restore)
    }
}
