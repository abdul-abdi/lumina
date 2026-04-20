// Sources/LuminaDesktopKit/Theme.swift
//
// v0.7.0 M6 — Catppuccin-aligned palette + typography helpers.

import SwiftUI

public enum LuminaTheme {
    /// Brand accent — lavender. WCAG AA against system backgrounds.
    public static let accent = Color(light: hex("#8839EF"), dark: hex("#CBA6F7"))

    /// Status colors.
    public static let runningGreen  = Color(light: hex("#40A02B"), dark: hex("#A6E3A1"))
    public static let pausedYellow  = Color(light: hex("#DF8E1D"), dark: hex("#F9E2AF"))
    public static let crashedRed    = Color(light: hex("#D20F39"), dark: hex("#F38BA8"))
    public static let surfaceMuted  = Color(light: hex("#EFF1F5"), dark: hex("#1E1E2E"))

    /// Per-OS accent for VM cards (matches OSCatalog tile accents).
    public static func osAccent(_ family: String) -> Color {
        switch family {
        case "linux": hex("#E95420")
        case "windows": hex("#0078D4")
        case "macOS": hex("#1D1D1F")
        default: hex("#9CA3AF")
        }
    }

    /// SF Mono for terminal / log panels.
    public static let mono = Font.system(.body, design: .monospaced)
    /// SF Pro Title for hero headers.
    public static let title = Font.system(.title, design: .default).weight(.semibold)
    /// SF Pro headline.
    public static let headline = Font.system(.headline, design: .default)
}

private extension Color {
    init(light: Color, dark: Color) {
        self.init(NSColor(name: nil, dynamicProvider: { appearance in
            switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
            case .darkAqua: NSColor(dark)
            default: NSColor(light)
            }
        }))
    }
}

private func hex(_ s: String) -> Color {
    var trimmed = s
    if trimmed.hasPrefix("#") { trimmed.removeFirst() }
    guard trimmed.count == 6, let value = UInt32(trimmed, radix: 16) else {
        return .black
    }
    let r = Double((value >> 16) & 0xFF) / 255.0
    let g = Double((value >> 8) & 0xFF) / 255.0
    let b = Double(value & 0xFF) / 255.0
    return Color(red: r, green: g, blue: b)
}
