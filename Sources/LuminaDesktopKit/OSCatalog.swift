// Sources/LuminaDesktopKit/OSCatalog.swift
//
// v0.7.0 M6 — unified catalog of OS tiles for the New VM wizard.
// Wraps `LuminaBootable.DesktopOSCatalog` (Linux distros) and adds
// Windows 11 ARM (BYO ISO only — Microsoft can't be redistributed) and
// macOS (downloaded from `MesuIPSWCatalogScraper`).

import Foundation
import LuminaBootable

public struct OSWizardTile: Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let family: OSFamily
    public let glyph: String       // SF Symbol name
    public let accentHex: String   // Catppuccin-aligned per OS
    public let description: String
    public let constraint: String? // e.g. "Needs retail license"
    public let acquisition: Acquisition

    public enum Acquisition: Sendable {
        case catalogISO(DesktopOSEntry)        // Linux — URL + checksum
        case microsoftAccountDownload          // Windows 11 ARM — opens browser
        case appleIPSW                          // macOS — IPSW catalog
        case userProvided                       // BYO file
    }
}

public enum OSCatalog {
    public static let allTiles: [OSWizardTile] = [
        // Linux from DesktopOSCatalog
        tile(for: "ubuntu-24.04", glyph: "circle.hexagongrid.fill", accentHex: "#E95420",
             desc: "Stable LTS release. Server installer with optional desktop environment."),
        tile(for: "kali-rolling", glyph: "shield.lefthalf.filled", accentHex: "#367BF0",
             desc: "Penetration-testing distribution; rolling release."),
        tile(for: "fedora-41", glyph: "circle.grid.cross.fill", accentHex: "#3C6EB4",
             desc: "Bleeding-edge GNOME experience from Red Hat."),
        tile(for: "debian-12", glyph: "leaf.fill", accentHex: "#A80030",
             desc: "Conservative, dependable; the foundation many other distros build on."),

        // Windows
        OSWizardTile(
            id: "windows-11-arm",
            displayName: "Windows 11 (ARM64)",
            family: .windows,
            glyph: "macwindow",
            accentHex: "#0078D4",
            description: "Microsoft's ARM build of Windows 11. Activation needs your own license.",
            constraint: "Needs retail license",
            acquisition: .microsoftAccountDownload
        ),

        // macOS
        OSWizardTile(
            id: "macos-latest",
            displayName: "macOS (latest available)",
            family: .macOS,
            glyph: "apple.logo",
            accentHex: "#1D1D1F",
            description: "Apple's macOS as a guest. Restored from an IPSW (~15 GB).",
            constraint: "Apple Silicon host only",
            acquisition: .appleIPSW
        ),

        // BYO
        OSWizardTile(
            id: "byo-file",
            displayName: "Use my own ISO/IPSW",
            family: .linux,  // displayed under linux family but can be anything
            glyph: "doc.badge.plus",
            accentHex: "#9CA3AF",
            description: "Drop a file you've already downloaded.",
            constraint: nil,
            acquisition: .userProvided
        ),
    ]

    private static func tile(for catalogID: String, glyph: String, accentHex: String, desc: String) -> OSWizardTile {
        let entry = DesktopOSCatalog.entry(for: catalogID)!
        return OSWizardTile(
            id: catalogID,
            displayName: entry.displayName,
            family: entry.family,
            glyph: glyph,
            accentHex: accentHex,
            description: desc,
            constraint: nil,
            acquisition: .catalogISO(entry)
        )
    }

    public static func tile(id: String) -> OSWizardTile? {
        allTiles.first { $0.id == id }
    }
}
