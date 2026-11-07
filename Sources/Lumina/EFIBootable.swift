// Configures a VZVirtualMachineConfiguration for EFI boot — the v0.7.0 M3
// pipeline shared by Linux desktop installs (Ubuntu / Kali / Fedora /
// Debian) and Windows 11 on ARM (M4).
//
// Placement: this type lives in the `Lumina` target (not `LuminaBootable`)
// because `VM.boot()` calls it directly; `LuminaBootable` already depends
// on `Lumina`, so putting EFIBootable the other way around would cycle.
// `LuminaBootable` keeps the higher-level surfaces (VMBundle, catalog,
// disk allocator) which `VM` does NOT need at boot.

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
        if !(vzConfig.platform is VZGenericPlatformConfiguration) {
            vzConfig.platform = VZGenericPlatformConfiguration()
        }

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

        // Linux-direct override path: if the caller supplied a pre-extracted
        // kernel + initramfs, bypass the ISO's own GRUB and boot via
        // VZLinuxBootLoader so we can set `console=hvc0` on the kernel
        // cmdline. Intended only for serial capture — stock arm64 Linux
        // ISOs ship GRUB configs with `console=tty0` / `console=efifb`
        // and would otherwise emit zero bytes on our virtio serial.
        //
        // The EFI variable store is still created (harmless, cheap) so the
        // bundle's future "boot normally" flip doesn't have to create it.
        if let kernel = config.linuxDirectKernel {
            let linuxLoader = VZLinuxBootLoader(kernelURL: kernel)
            if let initrd = config.linuxDirectInitramfs {
                linuxLoader.initialRamdiskURL = initrd
            }
            if let cmdline = config.linuxDirectCmdline {
                linuxLoader.commandLine = cmdline
            }
            vzConfig.bootLoader = linuxLoader
        } else {
            let loader = VZEFIBootLoader()
            loader.variableStore = variableStore
            vzConfig.bootLoader = loader
        }

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

        // Always attached as USB mass-storage so Windows Setup sees them
        // as removable drives and scans for autounattend.xml.
        for extraISO in config.extraCDROMs {
            do {
                let att = try Self.makeISOAttachment(url: extraISO)
                storage.append(Self.makeCDROMDevice(
                    attachment: att,
                    preferUSB: true
                ))
            } catch {
                throw Error.diskAttachmentFailed(extraISO, "\(error)")
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
        let sync: VZDiskImageSynchronizationMode = installPhase ? .fsync : .full
        return try VZDiskImageStorageDeviceAttachment(
            url: url,
            readOnly: false,
            cachingMode: .automatic,
            synchronizationMode: sync
        )
    }

    /// Build the installer-ISO attachment. The ISO is read-only so
    /// synchronization is irrelevant; `.cached` keeps hot installer
    /// blocks resident across reads.
    private static func makeISOAttachment(
        url: URL
    ) throws -> VZDiskImageStorageDeviceAttachment {
        return try VZDiskImageStorageDeviceAttachment(
            url: url,
            readOnly: true,
            cachingMode: .cached,
            synchronizationMode: .none
        )
    }

    /// With `preferUSB == true` (typically Windows guests),
    /// use `VZUSBMassStorageDeviceConfiguration` so EFI + guest setup see
    /// a genuine CD-ROM/removable drive. Otherwise fall back to virtio
    /// block, which every ARM64 Linux installer handles.
    private static func makeCDROMDevice(
        attachment: VZDiskImageStorageDeviceAttachment,
        preferUSB: Bool
    ) -> VZStorageDeviceConfiguration {
        if preferUSB {
            return VZUSBMassStorageDeviceConfiguration(attachment: attachment)
        }
        return VZVirtioBlockDeviceConfiguration(attachment: attachment)
    }
}
