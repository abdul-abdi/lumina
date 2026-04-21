// Sources/Lumina/EFIBootable.swift
//
// Configures a VZVirtualMachineConfiguration for EFI boot — the v0.7.0 M3
// pipeline shared by Linux desktop installs (Ubuntu / Kali / Fedora /
// Debian) and Windows 11 on ARM (M4).
//
// Placement: this type lives in the `Lumina` target (not `LuminaBootable`)
// because `VM.boot()` calls it directly; `LuminaBootable` already depends
// on `Lumina`, so putting EFIBootable the other way around would cycle.
// `LuminaBootable` keeps the higher-level surfaces (VMBundle, catalog,
// disk allocator) which `VM` does NOT need at boot.
//
// CD-ROM attachment note: pre-macOS 15, `VZUSBMassStorageDeviceConfiguration`
// is unavailable. We attach the installer ISO as a read-only virtio block
// device, which VZEFIBootLoader's firmware enumerates alongside the primary
// disk. For most Linux/Windows installers this works transparently; the
// user may need to pick the CD-ROM from the EFI boot menu on first boot
// if the firmware doesn't auto-prefer removable media.

import Foundation
import Virtualization

public struct EFIBootable: Sendable {
    public let config: EFIBootConfig

    public init(config: EFIBootConfig) {
        self.config = config
    }

    public enum Error: Swift.Error, Equatable {
        case variableStoreFailed(URL, String)
        case diskAttachmentFailed(URL, String)
    }

    public func apply(to vzConfig: VZVirtualMachineConfiguration) throws {
        // Platform: generic for both Linux and Windows guests.
        if !(vzConfig.platform is VZGenericPlatformConfiguration) {
            vzConfig.platform = VZGenericPlatformConfiguration()
        }

        // Variable store: reuse an existing file or create a fresh one.
        let variableStore: VZEFIVariableStore
        if FileManager.default.fileExists(atPath: config.variableStoreURL.path) {
            variableStore = VZEFIVariableStore(url: config.variableStoreURL)
        } else {
            do {
                variableStore = try VZEFIVariableStore(
                    creatingVariableStoreAt: config.variableStoreURL,
                    options: []
                )
            } catch {
                throw Error.variableStoreFailed(config.variableStoreURL, "\(error)")
            }
        }

        let loader = VZEFIBootLoader()
        loader.variableStore = variableStore
        vzConfig.bootLoader = loader

        // Storage devices: primary read-write disk, then optional CD-ROM
        // (read-only virtio block on macOS 14), then any extra disks.
        var storage: [VZStorageDeviceConfiguration] = []
        do {
            let primary = try VZDiskImageStorageDeviceAttachment(
                url: config.primaryDisk,
                readOnly: false
            )
            storage.append(VZVirtioBlockDeviceConfiguration(attachment: primary))
        } catch {
            throw Error.diskAttachmentFailed(config.primaryDisk, "\(error)")
        }

        if let iso = config.cdromISO {
            do {
                let isoAttachment = try VZDiskImageStorageDeviceAttachment(
                    url: iso,
                    readOnly: true
                )
                storage.append(VZVirtioBlockDeviceConfiguration(attachment: isoAttachment))
            } catch {
                throw Error.diskAttachmentFailed(iso, "\(error)")
            }
        }

        for extra in config.extraDisks {
            do {
                let att = try VZDiskImageStorageDeviceAttachment(url: extra, readOnly: false)
                storage.append(VZVirtioBlockDeviceConfiguration(attachment: att))
            } catch {
                throw Error.diskAttachmentFailed(extra, "\(error)")
            }
        }

        vzConfig.storageDevices = storage
    }
}
