import Foundation
import LuminaBootable

public struct OSWizardTile: Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let family: OSFamily
    public let glyph: String       // SF Symbol name
    public let description: String
    public let constraint: String? // e.g. "Needs retail license"
    public let acquisition: Acquisition

    public enum Acquisition: Sendable {
        case catalogISO(DesktopOSEntry)        // Linux — URL + checksum
        case microsoftAccountDownload          // Windows 11 ARM — opens browser
        case appleIPSW
        case omarchy
        case userProvided                       // BYO file
    }
}

public enum OSCatalog {
    public static let allTiles: [OSWizardTile] = [
        OSWizardTile(
            id: "omarchy",
            displayName: "Omarchy",
            family: .linux,
            glyph: "terminal.fill",
            description: "Arch Linux with Hyprland, set up by Omarchy. Installs itself unattended; you sign in as yourself.",
            constraint: "First boot installs Omarchy (10-15 min)",
            acquisition: .omarchy
        ),
        tile(for: "ubuntu-24.04", name: "Ubuntu 24.04", glyph: "circle.hexagongrid.fill",
             desc: "Stable LTS release. Installs unattended with the minimal GNOME desktop; sign in as lumina / lumina.",
             constraint: "First boot installs Ubuntu (20-30 min)"),
        tile(for: "kali-rolling", name: "Kali Linux", glyph: "shield.lefthalf.filled",
             desc: "Penetration-testing distribution, rolling release. Installs unattended with Xfce; sign in as lumina / lumina.",
             constraint: "First boot installs Kali (20-30 min)"),
        tile(for: "fedora-42", name: "Fedora 42", glyph: "circle.grid.cross.fill",
             desc: "Bleeding-edge GNOME from Red Hat. Boots straight into the live desktop.",
             constraint: "Live session, install from the desktop"),
        tile(for: "debian-12", name: "Debian 12", glyph: "leaf.fill",
             desc: "Conservative and dependable. Installs unattended with GNOME; sign in as lumina / lumina.",
             constraint: "First boot installs Debian (20-30 min)"),

        OSWizardTile(
            id: "windows-11-arm",
            displayName: "Windows 11",
            family: .windows,
            glyph: "macwindow",
            description: "Microsoft's ARM build of Windows 11. Activation needs your own license.",
            constraint: "Needs retail license",
            acquisition: .microsoftAccountDownload
        ),

        OSWizardTile(
            id: "macos-latest",
            displayName: "macOS",
            family: .macOS,
            glyph: "apple.logo",
            description: "Apple's macOS as a guest, restored from the newest IPSW this Mac supports (~18 GB download, cached).",
            constraint: "First boot installs macOS (15-30 min)",
            acquisition: .appleIPSW
        ),

        OSWizardTile(
            id: "byo-file",
            displayName: "Your own ISO",
            family: .linux,  // displayed under linux family but can be anything
            glyph: "doc.badge.plus",
            description: "Drop a file you've already downloaded.",
            constraint: nil,
            acquisition: .userProvided
        ),
    ]

    private static func tile(
        for catalogID: String,
        name: String,
        glyph: String,
        desc: String,
        constraint: String? = nil
    ) -> OSWizardTile {
        guard let entry = DesktopOSCatalog.entry(for: catalogID) else {
            preconditionFailure(
                "OSCatalog.tile: no DesktopOSCatalog entry for '\(catalogID)' — "
                + "IDs here must match Sources/LuminaBootable/DesktopOSCatalog.swift"
            )
        }
        return OSWizardTile(
            id: catalogID,
            displayName: name,
            family: entry.family,
            glyph: glyph,
            description: desc,
            constraint: constraint,
            acquisition: .catalogISO(entry)
        )
    }

    public static func tile(id: String) -> OSWizardTile? {
        allTiles.first { $0.id == id }
    }
}
