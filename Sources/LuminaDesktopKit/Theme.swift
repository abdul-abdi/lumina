import SwiftUI
import AppKit

/// Observable mirror of macOS's global appearance preference
/// (`AppleInterfaceStyle`). Views that want to react to system
/// dark↔light toggles while `AppearancePreference.system` is selected
/// should read `SystemAppearance.shared.isDark` so their body
/// re-evaluates on change.
///
/// Without this, eagerly resolving `.system` to a concrete scheme (in
/// `AppearancePreference.colorScheme`) would break auto-follow: users
/// flipping macOS dark/light via Control Center would see Lumina stay
/// on the last-resolved scheme until another re-render.
@MainActor
@Observable
public final class SystemAppearance {
    public static let shared = SystemAppearance()

    public private(set) var isDark: Bool

    private init() {
        self.isDark = Self.readSystemIsDark()
        // `AppleInterfaceThemeChangedNotification` is a distributed
        // notification macOS posts to every running app when the user
        // toggles system appearance (System Settings, Control Center,
        // Shortcuts, etc.). No KVO on NSApp.effectiveAppearance — that
        // one triggers on OUR window overrides too, which would cause
        // a re-render loop.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isDark = Self.readSystemIsDark()
            }
        }
    }

    private static func readSystemIsDark() -> Bool {
        if let style = UserDefaults.standard.string(forKey: "AppleInterfaceStyle"),
           style.lowercased().contains("dark") {
            return true
        }
        return false
    }
}

public enum AppearancePreference: String, CaseIterable, Sendable {
    case system, light, dark

    /// Resolved color scheme for `.preferredColorScheme`.
    ///
    /// `.system` returns a concrete `.dark` or `.light` rather than `nil`.
    /// Passing `nil` to `.preferredColorScheme` triggers a two-hop
    /// transition (remove override → query system → apply) which macOS
    /// visibly crossfades — that's the Light→System lag. Returning a
    /// concrete scheme collapses it to one hop.
    ///
    /// Callers that want `.system` selections to auto-follow macOS
    /// Dark↔Light toggles should read `SystemAppearance.shared.isDark`
    /// in the view body — observing it causes re-evaluation when the
    /// user flips the system appearance externally.
    @MainActor
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: SystemAppearance.shared.isDark ? .dark : .light
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
    public static let bg      = dynamic(dark: "#0A0A0A", light: "#FAF8F2")
    public static let bg1     = dynamic(dark: "#0F0F0F", light: "#F4F1EA")
    public static let bg2     = dynamic(dark: "#141414", light: "#EDE9E0")
    public static let bgInset = dynamic(dark: "#050505", light: "#FFFFFF")

    public static let ink     = dynamic(dark: "#E8E4D8", light: "#1A1814")
    public static let inkDim  = dynamic(dark: "#9A9384", light: "#5A554A")
    public static let inkMute = dynamic(dark: "#6B6558", light: "#8C8678")

    public static let rule    = dynamic(dark: "#1F1D18", light: "#E0DCD2")
    public static let rule2   = dynamic(dark: "#2A2620", light: "#D2CDC0")

    public static let accent  = hex("#FFB347")  // phosphor amber
    public static let ok      = dynamic(dark: "#8FC97A", light: "#3F9B22")
    public static let warn    = dynamic(dark: "#E5C96A", light: "#A07700")
    public static let err     = dynamic(dark: "#E87272", light: "#B02A2A")

    public static let monoSmall = Font.system(size: 11, design: .monospaced)

    public static let title = Font.system(size: 24, weight: .medium, design: .monospaced)
    public static let headline = Font.system(size: 14, weight: .medium, design: .monospaced)
    public static let caption = Font.system(size: 11, weight: .regular, design: .monospaced)
    public static let label = Font.system(size: 10, weight: .medium, design: .monospaced)
}

func hex(_ s: String) -> Color {
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

// Earlier drafts referenced macOS 26 Liquid Glass APIs (`Glass`,
// `.glassEffect`). Dropped because `#available` is a runtime check;
// the compiler still needs the symbols in the SDK. CI runs on
// macos-15 (SDK 15.x) which doesn't have those types, so the build
// failed. System materials render indistinguishably for our use.

import LuminaBootable

public extension VMBundle {
    var actualDiskBytes: UInt64 {
        let url = primaryDiskURL
        guard let rsrc = try? url.resourceValues(forKeys: [.fileAllocatedSizeKey]) else {
            return 0
        }
        return UInt64(rsrc.fileAllocatedSize ?? 0)
    }

    var snapshotCount: Int {
        let url = snapshotsDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return 0 }
        return entries.compactMap { e in
            (try? e.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? e : nil
        }.count
    }

    var lastBootedRelative: String {
        guard let d = manifest.lastBootedAt else { return "never booted" }
        let secs = Int(Date().timeIntervalSince(d))
        if secs < 60 { return "moments ago" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        if secs < 86400 { return "\(secs / 3600)h ago" }
        return "\(secs / 86400)d ago"
    }

    var diskUsedFormatted: String {
        formatBytesHuman(actualDiskBytes)
    }

    var diskCapFormatted: String { formatBytesHuman(manifest.diskBytes) }
}

