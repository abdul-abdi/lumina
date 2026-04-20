// Sources/LuminaDesktopKit/OSBrand.swift
//
// v0.7.0 M6 — visual identity per guest OS. Each card in the library
// speaks its guest's brand: Ubuntu gets orange warmth, Kali gets the
// dark-blue + dragon feel, macOS gets silver, Windows gets the fluent
// blue. The goal is at-a-glance recognition — you look at 10 cards
// and know which is which without reading a label.

import SwiftUI
import LuminaBootable

public struct OSBrand: Sendable {
    public let displayName: String
    public let accent: Color
    public let textOnAccent: Color
    public let glyph: String             // SF Symbol name
    public let bodyGradient: [Color]     // top → bottom subtle tint
    public let stripeWidth: CGFloat
    public let nameStyle: NameStyle

    public enum NameStyle: Sendable {
        case caps            // KALI, DEBIAN
        case serif           // ubuntu (lowercase elegant)
        case sansSemibold    // Windows 11, macOS
    }

    public init(displayName: String, accent: Color, textOnAccent: Color,
                glyph: String, bodyGradient: [Color],
                stripeWidth: CGFloat = 3,
                nameStyle: NameStyle = .caps) {
        self.displayName = displayName
        self.accent = accent
        self.textOnAccent = textOnAccent
        self.glyph = glyph
        self.bodyGradient = bodyGradient
        self.stripeWidth = stripeWidth
        self.nameStyle = nameStyle
    }
}

public enum OSBranding {
    /// Resolve a brand from a catalog variant ID or a freeform OS string
    /// (manifest.osVariant). Falls back to the family default when the
    /// variant is unrecognised.
    public static func brand(for variant: String, family: OSFamily) -> OSBrand {
        let v = variant.lowercased()

        if v.hasPrefix("ubuntu") {
            return OSBrand(
                displayName: "ubuntu",
                accent: hex("#E95420"),   // Ubuntu orange
                textOnAccent: .white,
                glyph: "circle.hexagongrid.fill",
                bodyGradient: [hex("#E95420").opacity(0.14), hex("#772953").opacity(0.04)],
                nameStyle: .serif
            )
        }
        if v.hasPrefix("kali") {
            return OSBrand(
                displayName: "KALI",
                accent: hex("#367BF0"),   // Kali cyber blue
                textOnAccent: .white,
                glyph: "shield.lefthalf.filled",
                bodyGradient: [hex("#0F1624").opacity(0.45), hex("#0F1624").opacity(0.10)],
                nameStyle: .caps
            )
        }
        if v.hasPrefix("fedora") {
            return OSBrand(
                displayName: "fedora",
                accent: hex("#3C6EB4"),   // Fedora blue
                textOnAccent: .white,
                glyph: "f.circle.fill",
                bodyGradient: [hex("#3C6EB4").opacity(0.14), hex("#294172").opacity(0.04)],
                nameStyle: .sansSemibold
            )
        }
        if v.hasPrefix("debian") {
            return OSBrand(
                displayName: "DEBIAN",
                accent: hex("#A80030"),   // Debian red
                textOnAccent: .white,
                glyph: "swirl.circle.righthalf.filled",
                bodyGradient: [hex("#A80030").opacity(0.12), hex("#610024").opacity(0.04)],
                nameStyle: .caps
            )
        }
        if v.hasPrefix("alpine") {
            return OSBrand(
                displayName: "alpine",
                accent: hex("#0D597F"),   // Alpine blue
                textOnAccent: .white,
                glyph: "mountain.2.fill",
                bodyGradient: [hex("#0D597F").opacity(0.14), hex("#102A3C").opacity(0.04)],
                nameStyle: .serif
            )
        }
        if v.hasPrefix("windows") {
            return OSBrand(
                displayName: "Windows 11",
                accent: hex("#0078D4"),   // Windows blue
                textOnAccent: .white,
                glyph: "macwindow",
                bodyGradient: [hex("#0078D4").opacity(0.14), hex("#003E6B").opacity(0.04)],
                nameStyle: .sansSemibold
            )
        }
        if v.hasPrefix("macos") {
            return OSBrand(
                displayName: "macOS",
                accent: hex("#8E8E93"),   // macOS system gray
                textOnAccent: .black,
                glyph: "apple.logo",
                bodyGradient: [hex("#D1D5DB").opacity(0.10), hex("#1A1A1F").opacity(0.04)],
                nameStyle: .sansSemibold
            )
        }

        // Family fallback.
        switch family {
        case .linux:
            return OSBrand(
                displayName: variant.uppercased(),
                accent: hex("#FFB347"),
                textOnAccent: .black,
                glyph: "terminal.fill",
                bodyGradient: [hex("#FFB347").opacity(0.10), hex("#FFB347").opacity(0.02)],
                nameStyle: .caps
            )
        case .windows:
            return OSBrand(
                displayName: "Windows",
                accent: hex("#0078D4"),
                textOnAccent: .white,
                glyph: "macwindow",
                bodyGradient: [hex("#0078D4").opacity(0.12), hex("#003E6B").opacity(0.04)],
                nameStyle: .sansSemibold
            )
        case .macOS:
            return OSBrand(
                displayName: "macOS",
                accent: hex("#8E8E93"),
                textOnAccent: .black,
                glyph: "apple.logo",
                bodyGradient: [hex("#D1D5DB").opacity(0.10), hex("#1A1A1F").opacity(0.04)],
                nameStyle: .sansSemibold
            )
        }
    }

    public static func nameFont(for brand: OSBrand) -> Font {
        switch brand.nameStyle {
        case .caps:
            return .system(size: 10, weight: .bold, design: .monospaced)
        case .serif:
            return .system(size: 13, design: .serif).italic()
        case .sansSemibold:
            return .system(size: 12, weight: .semibold, design: .default)
        }
    }
}

private func hex(_ s: String) -> Color {
    var t = s
    if t.hasPrefix("#") { t.removeFirst() }
    guard t.count == 6, let v = UInt32(t, radix: 16) else { return .gray }
    return Color(
        red: Double((v >> 16) & 0xFF) / 255,
        green: Double((v >> 8) & 0xFF) / 255,
        blue: Double(v & 0xFF) / 255
    )
}
