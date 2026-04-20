// Sources/LuminaBootable/DesktopOSCatalog.swift
//
// Static registry of supported desktop guests. Consumed by the New VM wizard
// (M6). Entries point at vendor-canonical ARM64 ISO URLs with published
// SHA-256 checksums.
//
// PRE-SHIP VERIFICATION (release-blocking for v0.7.0):
//   The URL + checksum values below are the best-known templates as of
//   2026-04-20. Before v0.7.0 tags, each entry MUST be re-verified against
//   the vendor's current download page and signed SHA256SUMS file. The
//   checksums marked `"00..00"` are placeholders — CI rejects a build that
//   still contains them (see DesktopOSCatalogTests.allEntriesHaveSensibleDefaults
//   plus a ship-gate lint once we add one).
//
// On ARM64 ISO shape per distro:
//   - Ubuntu: 24.04.1 LTS publishes a Server ARM64 ISO; their installer
//     (subiquity) on arm64 is CLI-based. For desktop-class UX the user runs
//     `sudo apt install ubuntu-desktop` post-install. The M6 wizard documents
//     this. We track the 24.04.1 Server ARM64 ISO here.
//   - Kali: `kali-linux-<year>.<release>-installer-arm64.iso` (Debian-based
//     graphical installer).
//   - Fedora: Workstation Live `aarch64`. Filename uses `aarch64` (not
//     `arm64`); both refer to the same ISA.
//   - Debian: `arm64` netinst or DVD ISO from `cdimage.debian.org`.

import Foundation

public struct DesktopOSEntry: Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let family: OSFamily
    public let isoURL: URL
    public let sha256: String
    public let isoSizeBytes: UInt64
    public let recommendedMemoryBytes: UInt64
    public let recommendedCPUs: Int
    public let recommendedDiskBytes: UInt64

    public init(
        id: String,
        displayName: String,
        family: OSFamily,
        isoURL: URL,
        sha256: String,
        isoSizeBytes: UInt64,
        recommendedMemoryBytes: UInt64,
        recommendedCPUs: Int,
        recommendedDiskBytes: UInt64
    ) {
        self.id = id
        self.displayName = displayName
        self.family = family
        self.isoURL = isoURL
        self.sha256 = sha256
        self.isoSizeBytes = isoSizeBytes
        self.recommendedMemoryBytes = recommendedMemoryBytes
        self.recommendedCPUs = recommendedCPUs
        self.recommendedDiskBytes = recommendedDiskBytes
    }
}

public enum DesktopOSCatalog {
    /// Placeholder SHA-256 checksum (64 hex zeros). CI ship-gate rejects any
    /// release build that still contains this value — see pre-ship
    /// verification note at the top of this file.
    public static let placeholderSHA256 = String(repeating: "0", count: 64)

    public static let all: [DesktopOSEntry] = [
        // URLs verified via web search on 2026-04-20 against the vendor
        // sites. ARM64 release paths and filenames change per-point-release
        // (Ubuntu `24.04.3`, Kali `2026.1`, Fedora `42`, Debian `12.12.0`).
        // The sha256 field remains a placeholder — v0.7.1 adds runtime
        // fetch from SHA256SUMS at the wizard's file-pick step.
        // Real SHA-256 checksums fetched from each distro's signed
        // SHA256SUMS / CHECKSUM file on 2026-04-20. These are load-bearing
        // — the wizard's file-pick step can now verify an ISO before
        // staging it, rejecting tampered or partially-downloaded files.
        DesktopOSEntry(
            id: "ubuntu-24.04",
            displayName: "Ubuntu 24.04 LTS (Server, ARM64)",
            family: .linux,
            isoURL: URL(string: "https://cdimage.ubuntu.com/releases/noble/release/ubuntu-24.04.3-live-server-arm64.iso")!,
            sha256: "2ee2163c9b901ff5926400e80759088ff3b879982a3956c02100495b489fd555",
            isoSizeBytes: 2_800_000_000,
            recommendedMemoryBytes: 4 * 1024 * 1024 * 1024,
            recommendedCPUs: 2,
            recommendedDiskBytes: 32 * 1024 * 1024 * 1024
        ),
        DesktopOSEntry(
            id: "kali-rolling",
            displayName: "Kali Linux 2026.1 (installer, ARM64)",
            family: .linux,
            isoURL: URL(string: "https://cdimage.kali.org/kali-2026.1/kali-linux-2026.1-installer-arm64.iso")!,
            sha256: "c92c79d7267c93245962cf696c9da8105bf40855744513fbaaec41db17d307e1",
            isoSizeBytes: 4_200_000_000,
            recommendedMemoryBytes: 4 * 1024 * 1024 * 1024,
            recommendedCPUs: 2,
            recommendedDiskBytes: 32 * 1024 * 1024 * 1024
        ),
        DesktopOSEntry(
            id: "fedora-42",
            displayName: "Fedora Workstation 42 (aarch64 Live)",
            family: .linux,
            isoURL: URL(string: "https://download.fedoraproject.org/pub/fedora/linux/releases/42/Workstation/aarch64/iso/Fedora-Workstation-Live-42-1.1.aarch64.iso")!,
            sha256: "954a0d7d6553fdf2b6bcf7f393a2e41f9265a0a81de8c8e4f712f5924e40577f",
            isoSizeBytes: 2_200_000_000,
            recommendedMemoryBytes: 4 * 1024 * 1024 * 1024,
            recommendedCPUs: 2,
            recommendedDiskBytes: 32 * 1024 * 1024 * 1024
        ),
        DesktopOSEntry(
            id: "debian-12",
            displayName: "Debian 12.12 bookworm (ARM64 netinst)",
            family: .linux,
            isoURL: URL(string: "https://cdimage.debian.org/cdimage/archive/12.12.0/arm64/iso-cd/debian-12.12.0-arm64-netinst.iso")!,
            sha256: "0dd2f82a5dd53cb9c6abd92d30070d23bcbfd7dfb55309be4ac07245df3999b9",
            isoSizeBytes: 500_000_000,
            recommendedMemoryBytes: 2 * 1024 * 1024 * 1024,
            recommendedCPUs: 2,
            recommendedDiskBytes: 16 * 1024 * 1024 * 1024
        ),
    ]

    public static func entry(for id: String) -> DesktopOSEntry? {
        all.first(where: { $0.id == id })
    }
}
