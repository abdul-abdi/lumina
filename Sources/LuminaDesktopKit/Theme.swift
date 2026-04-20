// Sources/LuminaDesktopKit/Theme.swift
//
// v0.7.0 M6 — phosphor-amber dark palette aligned to lumina.run web design.
// Forced dark-mode inside the app for consistent typography contrast and to
// match the marketing site. macOS dark-mode users get the system look;
// light-mode users get the same dark palette anyway (it's the brand).

import SwiftUI

public enum LuminaTheme {
    // ── Surfaces ────────────────────────────────────────────────────
    public static let bg       = hex("#0A0A0A")  // page background
    public static let bg1      = hex("#0F0F0F")  // panel
    public static let bg2      = hex("#141414")  // header chrome
    public static let bgInset  = hex("#050505")  // terminal-deep

    // ── Ink (text) ─────────────────────────────────────────────────
    public static let ink      = hex("#E8E4D8")  // primary text — warm cream
    public static let inkDim   = hex("#9A9384")
    public static let inkMute  = hex("#6B6558")

    // ── Rules / dividers ───────────────────────────────────────────
    public static let rule     = hex("#1F1D18")  // solid hairline
    public static let rule2    = hex("#2A2620")  // dashed sub-divider

    // ── Accent + status ────────────────────────────────────────────
    public static let accent   = hex("#FFB347")  // phosphor amber
    public static let accent2  = hex("#FF7A3D")  // amber 2 (hover, accents)
    public static let ok       = hex("#8FC97A")  // running green
    public static let warn     = hex("#E5C96A")  // paused yellow
    public static let err      = hex("#E87272")  // crashed red

    // ── Per-OS chip colors (for VM cards) ──────────────────────────
    public static func osAccent(_ family: String) -> Color {
        switch family {
        case "linux": hex("#E95420")    // Ubuntu orange
        case "windows": hex("#0078D4")  // Windows blue
        case "macOS": hex("#A5B4C7")    // macOS silver
        default: hex("#9CA3AF")
        }
    }

    // ── Type ───────────────────────────────────────────────────────
    /// SF Mono — closest system substitute for JetBrains Mono.
    public static let mono = Font.system(.body, design: .monospaced)
    public static let monoSmall = Font.system(size: 11, design: .monospaced)
    public static let monoTiny = Font.system(size: 10, design: .monospaced)

    /// New York italic — closest system substitute for Fraunces.
    public static let serifItalic = Font.system(.title3, design: .serif).italic()
    public static let serifLargeItalic = Font.system(.largeTitle, design: .serif).italic()

    /// Hero display — mono, heavy weight, tight tracking.
    public static let hero = Font.system(size: 56, weight: .medium, design: .monospaced)
    public static let title = Font.system(size: 24, weight: .medium, design: .monospaced)
    public static let headline = Font.system(size: 14, weight: .medium, design: .monospaced)
    public static let body = Font.system(size: 13, weight: .regular, design: .monospaced)
    public static let caption = Font.system(size: 11, weight: .regular, design: .monospaced)
    public static let label = Font.system(size: 10, weight: .medium, design: .monospaced)
}

// ── ViewModifier helpers ───────────────────────────────────────────
public extension View {
    /// Apply Lumina's panel chrome: dark bg + 1px hairline border.
    func luminaPanel(padding: CGFloat = 0) -> some View {
        self
            .padding(padding)
            .background(LuminaTheme.bg1)
            .overlay(
                Rectangle()
                    .stroke(LuminaTheme.rule, lineWidth: 1)
            )
    }

    /// Tracked uppercase label (eyebrow) — used for section headers + cap text.
    func luminaEyebrow() -> some View {
        self
            .font(LuminaTheme.label)
            .tracking(2)
            .textCase(.uppercase)
            .foregroundStyle(LuminaTheme.inkMute)
    }
}

// ── Color helpers ──────────────────────────────────────────────────
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
