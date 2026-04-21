// Sources/LuminaBootable/LuminaBootable.swift
//
// ISO / IPSW / EFI boot pipelines for full-OS guests.
//
// Three pipelines land here across v0.7.0 M3–M5:
//
//   - Linux desktop ISO boot (M3):
//       VZLinuxBootLoader + VZUSBMassStorageDeviceConfiguration for
//       CD-ROM, VZDiskImageStorageDeviceAttachment for persistent HDD.
//
//   - Windows 11 on ARM (M4):
//       VZEFIBootLoader + VZEFIVariableStore; retail ARM64 ISO.
//       Input scancode quirks, VZVirtioSoundDevice for audio.
//
//   - macOS guests (M5):
//       VZMacOSVirtualMachine (a sibling type to VZVirtualMachine, not
//       a subclass). IPSW download + VZMacOSInstaller + auxiliary
//       storage + hardware model + machine identifier. macOS 12+ only.
//
// This target does NOT touch `VM` in Lumina directly — it provides
// config builders that `lumina-cli` (when extended in later milestones)
// or the Desktop app can pass into `VMOptions`.

import Foundation
import Virtualization

/// Marker type reserved for M3+. Actual API lands milestone-by-milestone.
public enum LuminaBootableVersion {
    public static let placeholder = "0.7.0-m1-scaffold"
}
