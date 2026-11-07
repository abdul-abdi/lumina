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
        case userProvided                       // BYO file
    }
}

public enum OSCatalog {
    public static let allTiles: [OSWizardTile] = [
        tile(for: "ubuntu-24.04", glyph: "circle.hexagongrid.fill",
             desc: "Stable LTS release. Canonical's ARM64 ISO is server-only — after install, run `sudo apt install ubuntu-desktop-minimal` inside the VM for GUI.",
             constraint: "Server ISO · GUI is a one-liner post-install"),
        tile(for: "kali-rolling", glyph: "shield.lefthalf.filled",
             desc: "Penetration-testing distribution; rolling release. Installer offers XFCE desktop out of the box."),
        tile(for: "fedora-42", glyph: "circle.grid.cross.fill",
             desc: "Bleeding-edge GNOME experience from Red Hat. Live ISO boots straight into the desktop — no post-install steps."),
        tile(for: "debian-12", glyph: "leaf.fill",
             desc: "Conservative, dependable; the foundation many other distros build on. Netinst lets you pick GNOME/KDE/XFCE during setup."),

        OSWizardTile(
            id: "windows-11-arm",
            displayName: "Windows 11 (ARM64)",
            family: .windows,
            glyph: "macwindow",
            description: "Microsoft's ARM build of Windows 11. Activation needs your own license.",
            constraint: "Needs retail license",
            acquisition: .microsoftAccountDownload
        ),

        OSWizardTile(
            id: "byo-file",
            displayName: "Use my own ISO",
            family: .linux,  // displayed under linux family but can be anything
            glyph: "doc.badge.plus",
            description: "Drop a file you've already downloaded.",
            constraint: nil,
            acquisition: .userProvided
        ),
    ]

    private static func tile(
        for catalogID: String,
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
            displayName: entry.displayName,
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
