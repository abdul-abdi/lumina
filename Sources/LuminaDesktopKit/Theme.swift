// Sources/LuminaDesktopKit/Theme.swift
//
// v0.7.0 M6 — phosphor-amber palette aligned to lumina.run.
// Two themes (dark/light), system-following by default, user-overridable.
// Tokens resolve dynamically to the active color scheme.

import SwiftUI

public enum AppearancePreference: String, CaseIterable, Sendable {
    case system, light, dark

    public var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    public var glyph: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }

    public var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

public enum LuminaTheme {
    // ── Surfaces (auto-resolve to dark/light) ──────────────────────
    public static let bg      = dynamic(dark: "#0A0A0A", light: "#FAF8F2")
    public static let bg1     = dynamic(dark: "#0F0F0F", light: "#F4F1EA")
    public static let bg2     = dynamic(dark: "#141414", light: "#EDE9E0")
    public static let bgInset = dynamic(dark: "#050505", light: "#FFFFFF")

    // ── Ink (text) ─────────────────────────────────────────────────
    public static let ink     = dynamic(dark: "#E8E4D8", light: "#1A1814")
    public static let inkDim  = dynamic(dark: "#9A9384", light: "#5A554A")
    public static let inkMute = dynamic(dark: "#6B6558", light: "#8C8678")

    // ── Rules / dividers ───────────────────────────────────────────
    public static let rule    = dynamic(dark: "#1F1D18", light: "#E0DCD2")
    public static let rule2   = dynamic(dark: "#2A2620", light: "#D2CDC0")

    // ── Accent + status (same in both modes — brand) ───────────────
    public static let accent  = hex("#FFB347")  // phosphor amber
    public static let accent2 = hex("#FF7A3D")
    public static let ok      = dynamic(dark: "#8FC97A", light: "#3F9B22")
    public static let warn    = dynamic(dark: "#E5C96A", light: "#A07700")
    public static let err     = dynamic(dark: "#E87272", light: "#B02A2A")

    // ── Per-OS chip colors (for VM cards) ──────────────────────────
    public static func osAccent(_ family: String) -> Color {
        switch family {
        case "linux": hex("#E95420")    // Ubuntu orange
        case "windows": hex("#0078D4")  // Windows blue
        case "macOS": dynamic(dark: "#C7CDD9", light: "#3A3D45")
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

private func dynamic(dark: String, light: String) -> Color {
    Color(NSColor(name: nil, dynamicProvider: { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark]) != nil
        return NSColor(hex(isDark ? dark : light))
    }))
}

// ── Translucent material helpers ───────────────────────────────────
// Earlier drafts referenced macOS 26 Liquid Glass APIs (`Glass`,
// `.glassEffect`). Dropped because `#available` is a runtime check;
// the compiler still needs the symbols in the SDK. CI runs on
// macos-15 (SDK 15.x) which doesn't have those types, so the build
// failed. System materials render indistinguishably for our use.
public extension View {
    @ViewBuilder
    func luminaGlass(intensity: GlassIntensity = .regular,
                     in shape: some Shape = Rectangle()) -> some View {
        self.background(intensity.fallback, in: shape)
    }

    @ViewBuilder
    func luminaGlassRow() -> some View {
        self.background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

// ── Live state readers for the VM card ────────────────────────────

import LuminaBootable

public extension VMBundle {
    /// Actual on-disk size of the primary disk image (sparse-aware).
    /// Returns 0 if the disk file doesn't exist yet.
    var actualDiskBytes: UInt64 {
        let url = primaryDiskURL
        guard let rsrc = try? url.resourceValues(forKeys: [.fileAllocatedSizeKey]) else {
            return 0
        }
        return UInt64(rsrc.fileAllocatedSize ?? 0)
    }

    /// Count of snapshot subdirectories under snapshots/.
    var snapshotCount: Int {
        let url = snapshotsDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return 0 }
        return entries.compactMap { e in
            (try? e.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? e : nil
        }.count
    }

    /// "never" / "2h ago" / "3d ago" — human-readable last boot.
    var lastBootedRelative: String {
        guard let d = manifest.lastBootedAt else { return "never booted" }
        let secs = Int(Date().timeIntervalSince(d))
        if secs < 60 { return "moments ago" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        if secs < 86400 { return "\(secs / 3600)h ago" }
        return "\(secs / 86400)d ago"
    }

    /// "1.2 GB" / "480 MB" — sparse disk usage, human.
    var diskUsedFormatted: String {
        fmtBytes(actualDiskBytes)
    }

    var diskCapFormatted: String { fmtBytes(manifest.diskBytes) }

    /// "Ubuntu 24.04 · Linux · 4 GB / 2 CPU" — used as subtitle.
    var subtitle: String {
        "\(manifest.osVariant) · \(fmtBytes(manifest.memoryBytes)) · \(manifest.cpuCount) CPU"
    }

    private func fmtBytes(_ n: UInt64) -> String {
        let gb = Double(n) / (1024 * 1024 * 1024)
        if gb >= 1.0 { return String(format: "%.1f GB", gb) }
        let mb = Double(n) / (1024 * 1024)
        if mb >= 1.0 { return String(format: "%.0f MB", mb) }
        return "\(n) B"
    }
}

// ── Brand color stripes per OS (thin-stripe identity, not body fill) ─
public extension LuminaTheme {
    /// Saturated OS stripe color — for 3pt left-edge chips, not card bodies.
    /// These stay the same in dark + light modes (brand constants).
    static func osStripe(_ family: String) -> Color {
        switch family {
        case "linux": hex("#E95420")    // Ubuntu orange, saturated
        case "windows": hex("#0078D4")  // Windows blue
        case "macOS": hex("#8E8E93")    // macOS system gray
        default: hex("#9CA3AF")
        }
    }
}

public enum GlassIntensity: Sendable {
    case thin, regular, thick

    var fallback: Material {
        switch self {
        case .thin: .ultraThinMaterial
        case .regular: .regularMaterial
        case .thick: .thickMaterial
        }
    }
}
