// Sources/LuminaDesktopKit/LibraryView.swift
//
// v0.7.0 M6 — Mac-native rewrite. NavigationSplitView + materials +
// proper sidebar + detail pane. Phosphor-amber accent on a translucent
// dark surface that picks up the desktop wallpaper through the window.

import SwiftUI
import LuminaBootable

public enum SidebarSection: String, Hashable, CaseIterable {
    case all = "All VMs"
    case running = "Running"
    case linux = "Linux"
    case windows = "Windows"
    case macOS = "macOS"
    case downloads = "Downloads"
    case snapshots = "Snapshots"

    var systemImage: String {
        switch self {
        case .all: "square.grid.2x2"
        case .running: "play.circle"
        case .linux: "circle.hexagongrid.fill"
        case .windows: "macwindow"
        case .macOS: "apple.logo"
        case .downloads: "arrow.down.circle"
        case .snapshots: "clock.arrow.circlepath"
        }
    }

    var isOSFilter: Bool {
        switch self {
        case .linux, .windows, .macOS: true
        default: false
        }
    }

    var matchingFamily: OSFamily? {
        switch self {
        case .linux: .linux
        case .windows: .windows
        case .macOS: .macOS
        default: nil
        }
    }
}

@MainActor
public struct LibraryView: View {
    @Bindable public var model: AppModel
    @State private var section: SidebarSection = .all
    @State private var showingWizard = false
    @State private var hoveringID: UUID?

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .preferredColorScheme(.dark)
        .frame(minWidth: 1080, minHeight: 660)
        .background(MaterialBackground(material: .underWindowBackground))
        .luminaWindowChrome()
        .toolbar {
            ToolbarItem(placement: .navigation) {
                // Empty placeholder so traffic lights have left padding —
                // SwiftUI puts toolbar items right after the lights, which
                // looks cramped. A 44pt spacer is the canonical fix.
                Color.clear.frame(width: 12, height: 1)
            }
            ToolbarItem(placement: .principal) {
                LuminaSearchField(text: $model.search)
                    .frame(width: 320)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingWizard = true
                } label: {
                    Label("New VM", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
                .help("Create a new VM (⌘N)")
            }
        }
        .sheet(isPresented: $showingWizard) {
            NewVMWizard(model: model, isPresented: $showingWizard)
        }
    }

    // ── SIDEBAR ──────────────────────────────────────────────────
    private var sidebar: some View {
        List(selection: $section) {
            Section("LIBRARY") {
                sidebarRow(.all, count: model.bundles.count)
                sidebarRow(.running, count: model.sessions.values.filter { $0.status.isLive }.count, accent: .green)
            }
            Section("BY OS") {
                let byFamily = Dictionary(grouping: model.bundles, by: { $0.manifest.osFamily })
                sidebarRow(.linux, count: byFamily[.linux]?.count ?? 0)
                sidebarRow(.windows, count: byFamily[.windows]?.count ?? 0)
                sidebarRow(.macOS, count: byFamily[.macOS]?.count ?? 0)
            }
            Section("ACTIVITY") {
                sidebarRow(.downloads, count: 0)
                sidebarRow(.snapshots, count: 0)
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200, idealWidth: 220, maxWidth: 280)
        .scrollContentBackground(.hidden)
        .background(MaterialBackground(material: .sidebar))
        .navigationTitle("Lumina")
    }

    private func sidebarRow(_ s: SidebarSection, count: Int, accent: Color? = nil) -> some View {
        Label {
            HStack {
                Text(s.rawValue)
                Spacer()
                if count > 0 {
                    Text("\(count)")
                        .monospacedDigit()
                        .foregroundStyle(accent ?? LuminaTheme.inkMute)
                        .font(.caption)
                }
            }
        } icon: {
            Image(systemName: s.systemImage)
                .foregroundStyle(accent ?? LuminaTheme.accent)
        }
        .tag(s)
    }

    // ── DETAIL ───────────────────────────────────────────────────
    @ViewBuilder
    private var detail: some View {
        ZStack {
            MaterialBackground(material: .contentBackground).ignoresSafeArea()
            if filteredForSection.isEmpty && model.bundles.isEmpty {
                EmptyStateView(showingWizard: $showingWizard)
            } else if filteredForSection.isEmpty {
                EmptyFilterView(section: section)
            } else {
                VMGridView(
                    model: model,
                    bundles: filteredForSection,
                    hoveringID: $hoveringID
                )
            }
        }
    }

    private var filteredForSection: [VMBundle] {
        let base: [VMBundle]
        switch section {
        case .all:
            base = model.filteredBundles
        case .running:
            let live = Set(model.sessions.compactMap { $0.value.status.isLive ? $0.key : nil })
            base = model.filteredBundles.filter { live.contains($0.manifest.id) }
        case .linux, .windows, .macOS:
            let fam = section.matchingFamily!
            base = model.filteredBundles.filter { $0.manifest.osFamily == fam }
        case .downloads, .snapshots:
            base = []
        }
        return base
    }
}

// ── SEARCH ────────────────────────────────────────────────────────
@MainActor
public struct LuminaSearchField: View {
    @Binding var text: String

    public init(text: Binding<String>) { _text = text }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(LuminaTheme.inkMute)
            TextField("Search VMs", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(LuminaTheme.ink)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(LuminaTheme.inkMute)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(LuminaTheme.bg2.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(LuminaTheme.rule2, lineWidth: 0.5)
        )
    }
}

// ── EMPTY STATES ──────────────────────────────────────────────────
@MainActor
public struct EmptyStateView: View {
    @Binding var showingWizard: Bool

    public var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 28) {
                BrandMarkLarge()
                    .frame(width: 80, height: 80)
                VStack(spacing: 8) {
                    HStack(spacing: 0) {
                        Text("subprocess.run()")
                            .foregroundStyle(LuminaTheme.accent)
                    }
                    .font(.system(size: 36, weight: .medium, design: .monospaced))
                    .tracking(-0.5)

                    HStack(spacing: 10) {
                        Text("for")
                            .font(.system(size: 36, weight: .medium, design: .monospaced))
                            .foregroundStyle(LuminaTheme.ink)
                            .tracking(-0.5)
                        Text("virtual machines.")
                            .font(.system(.title, design: .serif).italic())
                            .foregroundStyle(LuminaTheme.inkDim)
                    }
                }
                Text("Spin up Ubuntu, Kali, Windows 11 ARM, or macOS — \nand throw it away when you're done.")
                    .font(.system(size: 14))
                    .foregroundStyle(LuminaTheme.inkDim)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)

                HStack(spacing: 10) {
                    PrimaryAction(label: "Try Ubuntu", systemImage: "circle.hexagongrid.fill", isPrimary: true) {
                        showingWizard = true
                    }
                    PrimaryAction(label: "Install Windows 11", systemImage: "macwindow") {
                        showingWizard = true
                    }
                    PrimaryAction(label: "Install macOS", systemImage: "apple.logo") {
                        showingWizard = true
                    }
                    PrimaryAction(label: "Use my own…", systemImage: "doc.badge.plus") {
                        showingWizard = true
                    }
                }
                .padding(.top, 8)
            }
            Spacer()
            HStack(spacing: 14) {
                Image(systemName: "arrow.down.doc")
                    .foregroundStyle(LuminaTheme.inkMute)
                Text("Drop an ISO or IPSW anywhere on this window")
                    .font(.system(size: 12))
                    .foregroundStyle(LuminaTheme.inkMute)
            }
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
public struct EmptyFilterView: View {
    let section: SidebarSection
    public var body: some View {
        VStack(spacing: 12) {
            Image(systemName: section.systemImage)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(LuminaTheme.inkMute)
            Text("No VMs in \(section.rawValue)")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(LuminaTheme.ink)
            Text("Create one from the toolbar.")
                .font(.system(size: 12))
                .foregroundStyle(LuminaTheme.inkDim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
public struct BrandMarkLarge: View {
    public init() {}
    public var body: some View {
        ZStack {
            // back square (cream)
            RoundedRectangle(cornerRadius: 8)
                .stroke(LuminaTheme.ink.opacity(0.4), lineWidth: 2)
                .frame(width: 56, height: 56)
                .offset(x: 12, y: 12)
            // front square (amber, with subtle glow)
            RoundedRectangle(cornerRadius: 8)
                .stroke(LuminaTheme.accent, lineWidth: 2)
                .frame(width: 56, height: 56)
                .shadow(color: LuminaTheme.accent.opacity(0.4), radius: 8)
        }
    }
}

@MainActor
public struct PrimaryAction: View {
    let label: String
    let systemImage: String
    let isPrimary: Bool
    let action: () -> Void
    @State private var hovering = false

    public init(label: String, systemImage: String, isPrimary: Bool = false, action: @escaping () -> Void) {
        self.label = label
        self.systemImage = systemImage
        self.isPrimary = isPrimary
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                Text(label)
                    .font(.system(size: 13, weight: isPrimary ? .semibold : .regular))
            }
            .foregroundStyle(isPrimary ? Color.black : (hovering ? LuminaTheme.accent : LuminaTheme.ink))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isPrimary ? LuminaTheme.accent : LuminaTheme.bg1.opacity(hovering ? 0.9 : 0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(isPrimary ? Color.clear : (hovering ? LuminaTheme.accent.opacity(0.5) : LuminaTheme.rule2),
                            lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// ── GRID ──────────────────────────────────────────────────────────
@MainActor
public struct VMGridView: View {
    @Bindable var model: AppModel
    let bundles: [VMBundle]
    @Binding var hoveringID: UUID?

    private let columns = [
        GridItem(.adaptive(minimum: 280, maximum: 340), spacing: 16)
    ]

    public var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(bundles, id: \.manifest.id) { bundle in
                    VMCard(model: model, bundle: bundle,
                           isHovering: hoveringID == bundle.manifest.id)
                        .onHover { h in hoveringID = h ? bundle.manifest.id : nil }
                        .onTapGesture {
                            model.selection = bundle.manifest.id
                            NotificationCenter.default.post(
                                name: .luminaOpenVMWindow,
                                object: bundle.manifest.id
                            )
                        }
                }
            }
            .padding(24)
        }
    }
}

@MainActor
public struct VMCard: View {
    @Bindable var model: AppModel
    let bundle: VMBundle
    let isHovering: Bool

    private var session: LuminaDesktopSession {
        model.session(for: bundle)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top: framebuffer placeholder with gradient + OS glyph
            ZStack {
                LinearGradient(
                    colors: [
                        LuminaTheme.osAccent(bundle.manifest.osFamily.rawValue).opacity(0.22),
                        LuminaTheme.osAccent(bundle.manifest.osFamily.rawValue).opacity(0.06)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: glyphForFamily(bundle.manifest.osFamily))
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(LuminaTheme.osAccent(bundle.manifest.osFamily.rawValue))
                    .opacity(0.85)
                // status pill
                VStack {
                    HStack {
                        statusPill
                        Spacer()
                    }
                    .padding(10)
                    Spacer()
                }
            }
            .aspectRatio(16.0/9.0, contentMode: .fit)

            VStack(alignment: .leading, spacing: 6) {
                Text(bundle.manifest.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LuminaTheme.ink)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(bundle.manifest.osVariant)
                        .font(.system(size: 11))
                        .foregroundStyle(LuminaTheme.inkDim)
                    Text("·")
                        .foregroundStyle(LuminaTheme.inkMute)
                    Text("\(formatGB(bundle.manifest.memoryBytes)) · \(bundle.manifest.cpuCount) CPU · \(formatGB(bundle.manifest.diskBytes))")
                        .font(.system(size: 11))
                        .foregroundStyle(LuminaTheme.inkMute)
                        .monospacedDigit()
                }

                HStack {
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 11))
                        .foregroundStyle(isHovering ? LuminaTheme.accent : LuminaTheme.inkMute)
                }
                .padding(.top, 4)
            }
            .padding(14)
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(LuminaTheme.bg1.opacity(isHovering ? 0.95 : 0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isHovering ? LuminaTheme.accent.opacity(0.5) : LuminaTheme.rule2,
                        lineWidth: 1)
        )
        .shadow(color: isHovering ? .black.opacity(0.4) : .black.opacity(0.15),
                radius: isHovering ? 16 : 6,
                y: isHovering ? 8 : 3)
        .scaleEffect(isHovering ? 1.012 : 1.0)
        .animation(.spring(response: 0.35, dampingFraction: 0.78), value: isHovering)
        .contextMenu {
            Button("Open") {
                NotificationCenter.default.post(name: .luminaOpenVMWindow, object: bundle.manifest.id)
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([bundle.rootURL])
            }
            Divider()
            Button("Move to Trash", role: .destructive) {
                model.deleteBundle(bundle)
            }
        }
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(stateColor)
                .frame(width: 6, height: 6)
                .shadow(color: session.status == .running ? stateColor.opacity(0.7) : .clear, radius: 4)
            Text(stateLabel)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .tracking(0.5)
                .textCase(.uppercase)
                .foregroundStyle(stateColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(.black.opacity(0.45))
        )
        .overlay(
            Capsule().stroke(stateColor.opacity(0.3), lineWidth: 0.5)
        )
    }

    private var stateColor: Color {
        switch session.status {
        case .running: LuminaTheme.ok
        case .booting, .shuttingDown: LuminaTheme.warn
        case .crashed: LuminaTheme.err
        case .paused: LuminaTheme.warn
        case .stopped: LuminaTheme.inkMute
        }
    }

    private var stateLabel: String {
        switch session.status {
        case .running: "Running"
        case .booting: "Booting"
        case .paused: "Paused"
        case .crashed: "Crashed"
        case .shuttingDown: "Stopping"
        case .stopped: "Idle"
        }
    }

    private func glyphForFamily(_ family: OSFamily) -> String {
        switch family {
        case .linux: "circle.hexagongrid.fill"
        case .windows: "macwindow"
        case .macOS: "apple.logo"
        }
    }

    private func formatGB(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / (1024 * 1024 * 1024)
        if gb >= 1 { return String(format: "%.0f GB", gb) }
        let mb = Double(bytes) / (1024 * 1024)
        return String(format: "%.0f MB", mb)
    }
}

public extension Notification.Name {
    static let luminaOpenVMWindow = Notification.Name("LuminaOpenVMWindow")
}
