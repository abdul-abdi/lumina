// Sources/LuminaDesktopKit/VMCard.swift
//
// The library's unit of attention: a single VM surfaced as a card in
// grid view, with the chip/preview/action primitives shared across
// grid + list layouts. Extracted from LibraryView.swift so the card
// has an obvious home — it's the most-read surface in the app.

import SwiftUI
import LuminaBootable

// ── STATE CHIP ─────────────────────────────────────────────────────

/// Active (colored) state chip. Returns nil for `.stopped` — per Victor's
/// rule, idle gets no chip. The eye should be drawn to states that
/// demand response, not to "exists".
@MainActor
struct StateChip: View {
    let status: LuminaDesktopSession.Status

    var body: some View {
        if let (label, color, pulse) = chipSpec {
            HStack(spacing: 5) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                    .shadow(color: pulse ? color.opacity(0.7) : .clear, radius: 4)
                Text(label)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .tracking(0.5)
                    .textCase(.uppercase)
                    .foregroundStyle(color)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .overlay(
                Capsule().stroke(color.opacity(0.35), lineWidth: 0.5)
            )
        }
    }

    private var chipSpec: (label: String, color: Color, pulse: Bool)? {
        switch status {
        case .running:      ("RUNNING",  LuminaTheme.ok,  true)
        case .booting:      ("BOOTING",  LuminaTheme.accent, true)
        case .paused:       ("PAUSED",   LuminaTheme.warn, false)
        case .crashed:      ("CRASHED",  LuminaTheme.err, false)
        case .shuttingDown: ("STOPPING", LuminaTheme.inkDim, false)
        case .stopped:      nil   // Idle = silence
        }
    }
}

// ── STATE PREVIEW ──────────────────────────────────────────────────

/// Terminal-style preview of a VM's current state — the card's primary
/// content. Replaces the decorative centered glyph. Shows what's
/// actually going on: last-boot time, disk usage, snapshot count,
/// install state if the VM hasn't been booted yet.
@MainActor
struct VMStatePreview: View {
    let bundle: VMBundle
    let status: LuminaDesktopSession.Status
    let bootedAt: Date?
    let density: Density

    enum Density { case card, row }

    private var isInstalling: Bool {
        // No lastBootedAt + a pending ISO sidecar present = first boot incoming.
        if bundle.manifest.lastBootedAt != nil { return false }
        let sidecar = bundle.rootURL.appendingPathComponent("pending-iso.path")
        return FileManager.default.fileExists(atPath: sidecar.path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: density == .card ? 4 : 2) {
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.system(size: density == .card ? 11 : 10, design: .monospaced))
                    .foregroundStyle(LuminaTheme.inkDim)
                    .lineLimit(1)
            }
        }
    }

    private var lines: [String] {
        if isInstalling {
            return [
                "› stage  installer attached",
                "› disk   0 of \(bundle.diskCapFormatted)",
                "› awaiting first boot",
            ]
        }
        switch status {
        case .running:
            return [
                "› up     \(Self.formatUptime(since: bootedAt))",
                "› disk   \(bundle.diskUsedFormatted) / \(bundle.diskCapFormatted)",
                "› snaps  \(bundle.snapshotCount)",
            ]
        case .booting:
            return [
                "› vm.boot() in flight",
                "› virtio devices initialising",
                "› disk   \(bundle.diskUsedFormatted) / \(bundle.diskCapFormatted)",
            ]
        case .crashed:
            return [
                "› vm_crashed",
                "› last   \(bundle.lastBootedRelative)",
                "› logs   available",
            ]
        case .stopped, .shuttingDown, .paused:
            return [
                "› last   \(bundle.lastBootedRelative)",
                "› disk   \(bundle.diskUsedFormatted) / \(bundle.diskCapFormatted)",
                "› snaps  \(bundle.snapshotCount)",
            ]
        }
    }

    /// Uptime since `bootedAt`. Used only for the `.running` case; re-evaluated
    /// whenever the view body runs (status flip, bundle reload via FSEvents).
    /// Coarse bucketing matches `VMBundle.lastBootedRelative` so cards stay
    /// visually consistent across running/stopped states.
    static func formatUptime(since bootedAt: Date?) -> String {
        guard let bootedAt else { return "(unknown)" }
        let secs = Int(Date().timeIntervalSince(bootedAt))
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(secs / 60)m" }
        if secs < 86400 {
            let h = secs / 3600
            let m = (secs % 3600) / 60
            return m == 0 ? "\(h)h" : "\(h)h \(m)m"
        }
        return "\(secs / 86400)d"
    }
}

// ── ACTION BUTTON ──────────────────────────────────────────────────

/// Explicit action on the card/row: ▶ Boot / ■ Stop. Appears always in
/// list view; hover-only in grid view. Direct manipulation — the verb
/// is visible, not hidden behind a navigation step.
@MainActor
struct VMActionButton: View {
    @Bindable var session: LuminaDesktopSession
    let compact: Bool

    @Environment(\.openWindow) private var openWindow
    @State private var hovering = false

    var body: some View {
        Button {
            switch session.status {
            case .stopped, .crashed:
                // Open the VM window immediately so the user sees the
                // booting screen → framebuffer handoff, then kick off
                // the boot. Without this the VM boots headless and the
                // user has to click the card to see anything.
                openWindow(id: "vm-window", value: session.bundle.manifest.id)
                Task { await session.boot() }
            case .running, .paused:
                Task { await session.shutdown() }
            case .booting, .shuttingDown:
                break
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: verb.glyph)
                    .font(.system(size: compact ? 10 : 11, weight: .semibold))
                if !compact {
                    Text(verb.label)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(0.5)
                }
            }
            .foregroundStyle(verb.foreground(hovering: hovering))
            .padding(.horizontal, compact ? 8 : 10)
            .padding(.vertical, compact ? 5 : 6)
            .background(
                Capsule().fill(verb.background(hovering: hovering))
            )
            .overlay(
                Capsule().stroke(verb.stroke(hovering: hovering), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(verb.tooltip)
        .disabled(verb.disabled)
    }

    private enum Verb {
        case boot, stop, bootingNow, stoppingNow, restart

        var label: String {
            switch self {
            case .boot: "BOOT"
            case .stop: "STOP"
            case .bootingNow: "BOOTING"
            case .stoppingNow: "STOPPING"
            case .restart: "RESTART"
            }
        }

        var glyph: String {
            switch self {
            case .boot: "play.fill"
            case .stop: "stop.fill"
            case .bootingNow, .stoppingNow: "circle.dashed"
            case .restart: "arrow.counterclockwise"
            }
        }

        var disabled: Bool {
            self == .bootingNow || self == .stoppingNow
        }

        var tooltip: String {
            switch self {
            case .boot: "Boot this VM"
            case .stop: "Shut down this VM"
            case .bootingNow: "Booting in progress…"
            case .stoppingNow: "Shutting down…"
            case .restart: "Restart this VM"
            }
        }

        func foreground(hovering: Bool) -> Color {
            switch self {
            case .boot: hovering ? Color.black : LuminaTheme.accent
            case .stop: hovering ? Color.white : LuminaTheme.err
            default: LuminaTheme.inkMute
            }
        }

        func background(hovering: Bool) -> Color {
            switch self {
            case .boot: hovering ? LuminaTheme.accent : LuminaTheme.accent.opacity(0.1)
            case .stop: hovering ? LuminaTheme.err : LuminaTheme.err.opacity(0.1)
            default: Color.clear
            }
        }

        func stroke(hovering: Bool) -> Color {
            switch self {
            case .boot: hovering ? LuminaTheme.accent : LuminaTheme.accent.opacity(0.5)
            case .stop: hovering ? LuminaTheme.err : LuminaTheme.err.opacity(0.5)
            default: LuminaTheme.rule2
            }
        }
    }

    private var verb: Verb {
        switch session.status {
        case .stopped, .crashed: .boot
        case .running, .paused: .stop
        case .booting: .bootingNow
        case .shuttingDown: .stoppingNow
        }
    }
}

// ── OS STRIPE ──────────────────────────────────────────────────────

/// Left-edge OS stripe — 3pt vertical strip. The card/row body stays
/// neutral; identity comes from the stripe, not the background.
struct OSStripe: View {
    let family: OSFamily
    let height: CGFloat
    var body: some View {
        Rectangle()
            .fill(LuminaTheme.osStripe(family.rawValue))
            .frame(width: 3)
            .frame(maxHeight: height > 0 ? height : .infinity)
    }
}

// ── DISTRO CHIP ────────────────────────────────────────────────────

/// Distro badge — small pill with the OS's glyph + its own brand name
/// in its own typographic style. Ubuntu's lowercase serif, Kali's bold
/// caps, macOS's sans-semibold. At-a-glance recognition.
@MainActor
struct DistroChip: View {
    let brand: OSBrand

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: brand.glyph)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(brand.textOnAccent)
            Text(brand.displayName)
                .font(OSBranding.nameFont(for: brand))
                .foregroundStyle(brand.textOnAccent)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(brand.accent)
        )
    }
}

// ── GRID CONTAINER ─────────────────────────────────────────────────

@MainActor
public struct VMGridView: View {
    @Bindable var model: AppModel
    let bundles: [VMBundle]
    @Environment(\.openWindow) private var openWindow

    public init(model: AppModel, bundles: [VMBundle]) {
        self.model = model
        self.bundles = bundles
    }

    private let columns = [
        GridItem(.adaptive(minimum: 300, maximum: 380), spacing: 14)
    ]

    public var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(bundles, id: \.manifest.id) { bundle in
                    VMCard(model: model, bundle: bundle,
                           openWindow: { openWindow(id: "vm-window", value: bundle.manifest.id) })
                }
            }
            .padding(20)
        }
    }
}

// ── CARD ───────────────────────────────────────────────────────────

@MainActor
public struct VMCard: View {
    @Bindable var model: AppModel
    let bundle: VMBundle
    let openWindow: () -> Void
    @State private var isHovering = false

    public init(model: AppModel, bundle: VMBundle, openWindow: @escaping () -> Void) {
        self.model = model
        self.bundle = bundle
        self.openWindow = openWindow
    }

    // Stats are model-owned (issue #11). Grid and list rows of the
    // same bundle now share a single `VMLiveStats` instance and its
    // timer, instead of each view spinning its own.
    private var stats: VMLiveStats { model.liveStats(for: bundle) }

    private var session: LuminaDesktopSession {
        model.session(for: bundle)
    }

    public var body: some View {
        let brand = OSBranding.brand(for: bundle.manifest.osVariant,
                                     family: bundle.manifest.osFamily)
        HStack(spacing: 0) {
            // Per-OS brand stripe (thicker than the default 3pt for impact)
            Rectangle()
                .fill(brand.accent)
                .frame(width: 4)
                .shadow(color: isHovering ? brand.accent.opacity(0.4) : .clear,
                        radius: isHovering ? 4 : 0)
            content(brand: brand)
        }
        .background(
            ZStack {
                // Base plate
                RoundedRectangle(cornerRadius: 8)
                    .fill(LuminaTheme.bg1.opacity(isHovering ? 0.82 : 0.62))
                // Per-OS subtle tint gradient top→bottom
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        LinearGradient(
                            colors: brand.bodyGradient,
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .opacity(isHovering ? 1.0 : 0.7)
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isHovering ? brand.accent.opacity(0.7) : LuminaTheme.rule,
                        lineWidth: isHovering ? 1 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .animation(.easeOut(duration: 0.14), value: isHovering)
        .onHover { isHovering = $0 }
        .onTapGesture { openWindow() }
        .onDisappear { stats.stop() }
        .contextMenu {
            Button("Open") { openWindow() }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([bundle.rootURL])
            }
            Divider()
            Button("Move to Trash", role: .destructive) {
                model.deleteBundle(bundle)
            }
        }
    }

    private func content(brand: OSBrand) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header: heartbeat + VM name + state pill
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if session.status == .running {
                    Heartbeat(color: LuminaTheme.ok)
                }
                Text(bundle.manifest.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LuminaTheme.ink)
                    .lineLimit(1)
                Spacer()
                StateChip(status: session.status)
            }

            // Distro chip — distinctive brand badge
            DistroChip(brand: brand)

            VMStatePreview(bundle: bundle, status: session.status,
                           bootedAt: bundle.manifest.lastBootedAt,
                           density: .card)
            DiskSparkline(stats: stats,
                          tint: brand.accent,
                          running: session.status == .running)
                .frame(height: 24)
            HStack {
                Text(bundle.manifest.osVariant)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .tracking(0.4)
                    .textCase(.uppercase)
                    .foregroundStyle(LuminaTheme.inkMute)
                Spacer()
                if isHovering {
                    VMActionButton(session: session, compact: false)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .animation(.easeOut(duration: 0.15), value: isHovering)
        }
        .padding(14)
    }
}
