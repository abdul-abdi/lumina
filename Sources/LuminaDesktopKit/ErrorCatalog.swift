// Sources/LuminaDesktopKit/ErrorCatalog.swift
//
// v0.7.0 M6 — enumerated error states surfaced in the UI. Each state has
// a title, body template, and a remediation action. Mapped from §9 of the
// M6 UX design doc.

import Foundation

public enum AppError: Sendable, Equatable {
    case virtualizationEntitlementMissing
    case appleSiliconRequired
    case macOSHostTooOld(have: String)
    case diskFullAtCreate(needed: UInt64, available: UInt64)
    case diskFullAtBoot(needed: UInt64, available: UInt64)
    case isoDownloadFailed(name: String, complete: UInt64, total: UInt64)
    case ipswDownloadFailed(complete: UInt64, total: UInt64)
    case checksumMismatch(file: String)
    case isoNotARM64(path: String)
    case isoUnbootable(path: String)
    case windowsISONotARM64(path: String)
    case vmCrashed(name: String)
    case suspendFailed
    case multiBridgeAmbiguity(picked: String)
    case networkPermission
    case vzFrameworkError(code: Int, description: String)
    case ipswUnsupported(version: String)
    case guestDiskFull
    case snapshotRevertFailed
    case fileAccessDenied(path: String)

    public var title: String {
        switch self {
        case .virtualizationEntitlementMissing: "Can't start virtualization"
        case .appleSiliconRequired: "Apple Silicon required"
        case .macOSHostTooOld: "Update macOS"
        case .diskFullAtCreate, .diskFullAtBoot: "Not enough disk space"
        case .isoDownloadFailed, .ipswDownloadFailed: "Download interrupted"
        case .checksumMismatch: "Downloaded file is corrupted"
        case .isoNotARM64, .windowsISONotARM64: "This ISO isn't for ARM"
        case .isoUnbootable: "Didn't boot"
        case .vmCrashed: "VM stopped unexpectedly"
        case .suspendFailed: "Couldn't pause VM"
        case .multiBridgeAmbiguity: "Pick a network"
        case .networkPermission: "Allow network access"
        case .vzFrameworkError(let code, _): "Virtualization error (\(code))"
        case .ipswUnsupported: "macOS version not supported"
        case .guestDiskFull: "Guest ran out of disk"
        case .snapshotRevertFailed: "Couldn't revert snapshot"
        case .fileAccessDenied: "Couldn't access file"
        }
    }

    public var body: String {
        switch self {
        case .virtualizationEntitlementMissing:
            "This build isn't signed with the Virtualization entitlement. Download the signed release from GitHub."
        case .appleSiliconRequired:
            "Lumina Desktop only runs on Apple Silicon Macs (M1 or later)."
        case .macOSHostTooOld(let have):
            "Desktop guests need macOS 14 Sonoma or newer. You're on \(have)."
        case .diskFullAtCreate(let n, let a):
            "VM needs \(formatBytes(n)) free, but the library disk only has \(formatBytes(a)) available."
        case .diskFullAtBoot(let n, let a):
            "This VM's snapshots need \(formatBytes(n)) free space. Free \(formatBytes(a)) or compact snapshots."
        case .isoDownloadFailed(let name, let c, let t):
            "Couldn't download \(name) (\(formatBytes(c)) of \(formatBytes(t))). Check your network."
        case .ipswDownloadFailed(let c, let t):
            "The macOS IPSW download failed at \(formatBytes(c)) of \(formatBytes(t)). This usually means a temporary Apple CDN issue."
        case .checksumMismatch(let f):
            "\(f) didn't match its expected checksum. It may have been altered in transit."
        case .isoNotARM64(let p):
            "Lumina only boots ARM64 (aarch64) guests. \(p) appears to be x86_64."
        case .isoUnbootable(let p):
            "\(p) didn't start booting within 30 seconds. It may be corrupt or not installable."
        case .windowsISONotARM64(let p):
            "\(p) is Windows 11 for x86. Lumina only runs ARM builds of Windows."
        case .vmCrashed(let n):
            "\(n) stopped unexpectedly. This usually means the guest kernel panicked."
        case .suspendFailed:
            "Saving VM state ran out of disk or took too long. Your VM is still running."
        case .multiBridgeAmbiguity(let p):
            "Multiple network bridges found. Lumina guessed \(p); change it in Settings → Network."
        case .networkPermission:
            "macOS blocked Lumina's network bridge. Approve it in System Settings → Privacy & Security."
        case .vzFrameworkError(_, let d):
            "\(d). Copy diagnostics to include in a bug report."
        case .ipswUnsupported(let v):
            "Only macOS 12 and newer can run as a guest. This IPSW is macOS \(v)."
        case .guestDiskFull:
            "The guest OS's disk is full. Expand disk size in Settings (requires reboot)."
        case .snapshotRevertFailed:
            "The saved RAM state is incompatible with the current VM config."
        case .fileAccessDenied(let p):
            "\(p) is outside Lumina's allowed folders. Drop it into the Library folder or Documents."
        }
    }

    public var primaryAction: String {
        switch self {
        case .virtualizationEntitlementMissing: "Open Download Page"
        case .appleSiliconRequired: "Learn More"
        case .macOSHostTooOld: "Open System Settings"
        case .diskFullAtCreate: "Change Library Location"
        case .diskFullAtBoot: "Open Snapshots"
        case .isoDownloadFailed, .ipswDownloadFailed: "Retry"
        case .checksumMismatch: "Re-download"
        case .isoNotARM64, .windowsISONotARM64: "Find ARM ISO"
        case .isoUnbootable: "Pick Another"
        case .vmCrashed: "View Logs"
        case .suspendFailed: "Retry"
        case .multiBridgeAmbiguity: "Open Settings"
        case .networkPermission: "Open System Settings"
        case .vzFrameworkError, .snapshotRevertFailed: "Copy Diagnostics"
        case .ipswUnsupported: "Pick Another"
        case .guestDiskFull: "Open Settings"
        case .fileAccessDenied: "Pick Again"
        }
    }
}

private func formatBytes(_ n: UInt64) -> String {
    let gb = Double(n) / (1024 * 1024 * 1024)
    if gb >= 1.0 { return String(format: "%.1f GB", gb) }
    let mb = Double(n) / (1024 * 1024)
    return String(format: "%.0f MB", mb)
}
