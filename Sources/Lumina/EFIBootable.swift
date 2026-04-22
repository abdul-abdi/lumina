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
// Disk + CD-ROM strategy (hardened v0.7.1):
//
// - Primary disk uses `cachingMode:.automatic`. Synchronization is
//   `.fsync` when `EFIBootConfig.installPhase == true` (halves the
//   partman/mkfs install time on APFS by coalescing guest flushes into
//   `fsync(2)` instead of barrier-fsync) and `.full` afterwards (real
//   crash safety for the user's installed system).
//
// - Installer ISO uses `cachingMode:.cached`, `synchronizationMode:.none`.
//   The ISO is read-only, so sync mode is meaningless, and `cached` keeps
//   the hot blocks in the unified buffer cache so the second pass through
//   the installer does not re-read from APFS.
//
// - When `preferUSBCDROM == true` the ISO is attached via
//   `VZUSBMassStorageDeviceConfiguration` (macOS 13+, available since
//   Ventura). Windows 11 ARM setup refuses virtio-block-as-CD-ROM; USB
//   mass-storage presents as a genuine removable drive and works.
//   Linux installers accept either. The virtio-block fallback remains
//   for macOS 12 and for `preferUSBCDROM == false`.

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

        // Storage devices: primary read-write disk, optional CD-ROM
        // (USB mass-storage on macOS 13+ when preferred, else virtio
        // block), then any extra disks.
        var storage: [VZStorageDeviceConfiguration] = []
        do {
            let primary = try Self.makePrimaryDiskAttachment(
                url: config.primaryDisk,
                installPhase: config.installPhase
            )
            storage.append(VZVirtioBlockDeviceConfiguration(attachment: primary))
        } catch {
            throw Error.diskAttachmentFailed(config.primaryDisk, "\(error)")
        }

        if let iso = config.cdromISO {
            do {
                let isoAttachment = try Self.makeISOAttachment(url: iso)
                storage.append(Self.makeCDROMDevice(
                    attachment: isoAttachment,
                    preferUSB: config.preferUSBCDROM
                ))
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

    /// Build the primary disk attachment. In install phase we relax
    /// synchronization to `.fsync` — guest flushes reach disk via
    /// `fsync(2)` instead of the more expensive barrier-fsync, which
    /// roughly halves partman install time on APFS. Post-install we
    /// return to `.full` for real crash safety.
    private static func makePrimaryDiskAttachment(
        url: URL,
        installPhase: Bool
    ) throws -> VZDiskImageStorageDeviceAttachment {
        if #available(macOS 12.0, *) {
            let sync: VZDiskImageSynchronizationMode = installPhase ? .fsync : .full
            return try VZDiskImageStorageDeviceAttachment(
                url: url,
                readOnly: false,
                cachingMode: .automatic,
                synchronizationMode: sync
            )
        }
        return try VZDiskImageStorageDeviceAttachment(url: url, readOnly: false)
    }

    /// Build the installer-ISO attachment. The ISO is read-only so
    /// synchronization is irrelevant; `.cached` keeps hot installer
    /// blocks resident across reads.
    private static func makeISOAttachment(
        url: URL
    ) throws -> VZDiskImageStorageDeviceAttachment {
        if #available(macOS 12.0, *) {
            return try VZDiskImageStorageDeviceAttachment(
                url: url,
                readOnly: true,
                cachingMode: .cached,
                synchronizationMode: .none
            )
        }
        return try VZDiskImageStorageDeviceAttachment(url: url, readOnly: true)
    }

    /// Wrap an ISO attachment in the appropriate `VZStorageDeviceConfiguration`.
    /// On macOS 13+ with `preferUSB == true` (typically Windows guests),
    /// use `VZUSBMassStorageDeviceConfiguration` so EFI + guest setup see
    /// a genuine CD-ROM/removable drive. Otherwise fall back to virtio
    /// block, which every ARM64 Linux installer handles.
    private static func makeCDROMDevice(
        attachment: VZDiskImageStorageDeviceAttachment,
        preferUSB: Bool
    ) -> VZStorageDeviceConfiguration {
        if #available(macOS 13.0, *), preferUSB {
            return VZUSBMassStorageDeviceConfiguration(attachment: attachment)
        }
        return VZVirtioBlockDeviceConfiguration(attachment: attachment)
    }
}
