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

public enum LibraryLayout: String, CaseIterable, Sendable {
    case grid, list
    var systemImage: String { self == .grid ? "square.grid.2x2" : "list.bullet" }
    var label: String { self == .grid ? "Grid" : "List" }
}

@MainActor
public struct LibraryView: View {
    @Bindable public var model: AppModel
    @State private var section: SidebarSection = .all
    @State private var showingWizard = false
    @State private var wizardInitialTile: String? = nil
    @State private var showingLauncher = false
    @State private var appearanceState: AppearancePreference
    @AppStorage("lumina.appearance") private var appearanceRaw: String = AppearancePreference.system.rawValue
    @AppStorage("lumina.layout") private var layoutRaw: String = LibraryLayout.list.rawValue

    private var layout: LibraryLayout {
        LibraryLayout(rawValue: layoutRaw) ?? .list
    }

    public init(model: AppModel) {
        self.model = model
        // Seed local @State from whatever AppStorage held last session so
        // the initial render matches the persisted choice without an
        // extra propagation cycle.
        let raw = UserDefaults.standard.string(forKey: "lumina.appearance") ?? "system"
        self._appearanceState = State(initialValue: AppearancePreference(rawValue: raw) ?? .system)
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .preferredColorScheme(appearanceState.colorScheme)
        .animation(.easeInOut(duration: 0.18), value: appearanceState)
        .frame(minWidth: 1080, minHeight: 660)
        .background(MaterialBackground(material: .underWindowBackground))
        .luminaWindowChrome()
        .toolbar {
            ToolbarItem(placement: .principal) {
                LuminaSearchField(text: $model.search)
                    .frame(width: 320)
            }
            ToolbarItem(placement: .primaryAction) {
                LayoutPicker(layoutRaw: $layoutRaw)
            }
            ToolbarItem(placement: .primaryAction) {
                AppearanceMenu(current: $appearanceState, persistedRaw: $appearanceRaw)
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
        .tint(LuminaTheme.accent)
        .sheet(isPresented: $showingWizard) {
            NewVMWizard(model: model, isPresented: $showingWizard,
                        initialTileID: wizardInitialTile)
                .onDisappear { wizardInitialTile = nil }
        }
        .sheet(isPresented: $showingLauncher) {
            CommandLauncher(model: model, isPresented: $showingLauncher)
        }
        .background(
            // Global ⌘K / ⌘P shortcut even when focus is on sidebar
            Button("") { showingLauncher = true }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
        )
        .onReceive(NotificationCenter.default.publisher(for: .luminaLauncherOpenWizard)) { note in
            if let tileID = note.object as? String {
                showWizard(preselect: tileID)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            Task { await handleDrop(providers) }
            return true
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) async {
        for provider in providers {
            if let url = try? await provider.loadItem(forTypeIdentifier: "public.file-url") as? URL {
                let ext = url.pathExtension.lowercased()
                guard ["iso", "img", "ipsw"].contains(ext) else { continue }
                // Stage the file as a BYO-flavored wizard launch.
                wizardInitialTile = ext == "ipsw" ? "macos-latest" : "byo-file"
                showingWizard = true
                // Persist the chosen file path for the wizard to pick up.
                UserDefaults.standard.set(url.path, forKey: "lumina.wizard.droppedFile")
                break
            }
        }
    }

    fileprivate func showWizard(preselect tileID: String? = nil) {
        wizardInitialTile = tileID
        showingWizard = true
    }

    // ── SIDEBAR ──────────────────────────────────────────────────
    private var sidebar: some View {
        List(selection: $section) {
            sectionHeader("LIBRARY")
            sidebarRow(.all, count: model.bundles.count)
            sidebarRow(.running,
                       count: model.sessions.values.filter { $0.status.isLive }.count,
                       accent: LuminaTheme.ok)

            sectionHeader("BY OS")
            let byFamily = Dictionary(grouping: model.bundles, by: { $0.manifest.osFamily })
            sidebarRow(.linux, count: byFamily[.linux]?.count ?? 0)
            sidebarRow(.windows, count: byFamily[.windows]?.count ?? 0)
            sidebarRow(.macOS, count: byFamily[.macOS]?.count ?? 0)

            sectionHeader("ACTIVITY")
            sidebarRow(.downloads, count: 0)
            sidebarRow(.snapshots, count: 0)
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
        .scrollContentBackground(.hidden)
        .background {
            if #available(macOS 26.0, *) {
                Rectangle().fill(.regularMaterial).glassEffect(.regular, in: Rectangle())
            } else {
                MaterialBackground(material: .sidebar)
            }
        }
        .environment(\.defaultMinListRowHeight, 30)
        // Force the selection tint to our brand amber. .tint() at the
        // NavigationSplitView level doesn't always cascade into List row
        // selection — needs to be set on the List/row itself.
        .accentColor(LuminaTheme.accent)
        .navigationTitle("Lumina")
    }

    /// Section header with proper breathing room. macOS default section
    /// rendering in sidebar lists is 10pt text jammed against the
    /// preceding row with ~2pt padding; it reads "squished". This adds
    /// 14pt top + 4pt bottom + clearer tracking.
    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold, design: .default))
            .tracking(1.2)
            .foregroundStyle(LuminaTheme.inkMute)
            .padding(.top, 14)
            .padding(.bottom, 2)
            .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 0))
            .listRowBackground(Color.clear)
            .selectionDisabled()
    }

    private func sidebarRow(_ s: SidebarSection, count: Int, accent: Color? = nil) -> some View {
        HStack(spacing: 10) {
            Image(systemName: s.systemImage)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(accent ?? LuminaTheme.accent)
                .frame(width: 18)
            Text(s.rawValue)
                .font(.system(size: 13))
            Spacer()
            if count > 0 {
                Text("\(count)")
                    .monospacedDigit()
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(accent ?? LuminaTheme.inkMute)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(LuminaTheme.rule.opacity(0.7))
                    )
            }
        }
        .padding(.vertical, 2)
        .tag(s)
    }

    // ── DETAIL ───────────────────────────────────────────────────
    @ViewBuilder
    private var detail: some View {
        ZStack {
            MaterialBackground(material: .contentBackground).ignoresSafeArea()
            if filteredForSection.isEmpty && model.bundles.isEmpty {
                EmptyStateView(onChoose: { tileID in showWizard(preselect: tileID) })
            } else if filteredForSection.isEmpty {
                EmptyFilterView(section: section)
            } else {
                VStack(spacing: 0) {
                    HostStatusRibbon(model: model)
                    switch layout {
                    case .grid:
                        VMGridView(model: model, bundles: filteredForSection)
                    case .list:
                        VMListView(model: model, bundles: filteredForSection)
                    }
                    AggregatesFooter(model: model)
                }
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

// ── AGGREGATES FOOTER ─────────────────────────────────────────────
/// Roll-up metrics at the bottom of the detail pane. Makes the pane
/// about the user's VM activity, not just a card grid — per Victor's
/// "detail pane as workbench" critique.
@MainActor
public struct AggregatesFooter: View {
    @Bindable var model: AppModel

    public var body: some View {
        let totalDisk = model.bundles.reduce(0) { $0 + $1.actualDiskBytes }
        let totalSnaps = model.bundles.reduce(0) { $0 + $1.snapshotCount }
        let running = model.sessions.values.filter { $0.status.isLive }.count
        let mostRecent = model.bundles
            .compactMap { $0.manifest.lastBootedAt }
            .max()
        let mostRecentStr: String = {
            guard let d = mostRecent else { return "never" }
            let secs = Int(Date().timeIntervalSince(d))
            if secs < 60 { return "just now" }
            if secs < 3600 { return "\(secs / 60)m ago" }
            if secs < 86400 { return "\(secs / 3600)h ago" }
            return "\(secs / 86400)d ago"
        }()

        HStack(spacing: 22) {
            footerMetric(icon: "square.stack.3d.up.fill",
                         label: "USED",
                         value: formatBytesHuman(totalDisk))
            footerMetric(icon: "camera.fill",
                         label: "SNAPSHOTS",
                         value: "\(totalSnaps)")
            footerMetric(icon: "bolt.horizontal.fill",
                         label: "LAST BOOT",
                         value: mostRecentStr)
            Spacer()
            if running > 0 {
                HStack(spacing: 6) {
                    Heartbeat(color: LuminaTheme.ok)
                    Text("\(running) RUNNING")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(LuminaTheme.ok)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(LuminaTheme.ok.opacity(0.1))
                )
                .overlay(
                    Capsule().stroke(LuminaTheme.ok.opacity(0.3), lineWidth: 0.5)
                )
            } else {
                Text("ALL IDLE")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(LuminaTheme.inkMute)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(
            Rectangle().fill(LuminaTheme.bg2.opacity(0.5))
        )
        .overlay(
            Rectangle().fill(LuminaTheme.rule).frame(height: 1),
            alignment: .top
        )
    }

    @ViewBuilder
    private func footerMetric(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(LuminaTheme.inkMute)
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(LuminaTheme.inkMute)
                Text(value)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(LuminaTheme.ink)
                    .monospacedDigit()
            }
        }
    }
}

// ── HOST STATUS RIBBON ────────────────────────────────────────────
/// Thin strip at the top of the detail pane. Always shows host
/// constraints (model / RAM / free disk) + running-VM count. This fills
/// the library's breathing room with *useful* information — Victor's
/// "make the invisible visible" applied to the host/guest contract.
@MainActor
public struct HostStatusRibbon: View {
    @Bindable var model: AppModel

    public var body: some View {
        let host = HostInfo.current
        let freeDisk = HostInfo.freeDiskBytes(at: model.store.rootURL) ?? 0
        let running = model.sessions.values.filter { $0.status.isLive }.count
        let totalUsed = model.bundles.reduce(0) { $0 + $1.actualDiskBytes }

        HStack(spacing: 16) {
            metric(label: "HOST", value: host.modelName.uppercased())
            divider
            metric(label: "RAM", value: formatBytesHuman(host.physicalMemoryBytes))
            metric(label: "CORES", value: "\(host.processorCount)")
            metric(label: "LIBRARY FREE", value: formatBytesHuman(freeDisk),
                   warn: freeDisk < 16 * 1024 * 1024 * 1024)
            divider
            metric(label: "VMS", value: "\(model.bundles.count)")
            metric(label: "USED", value: formatBytesHuman(totalUsed))
            metric(label: "RUNNING", value: "\(running)",
                   accent: running > 0 ? LuminaTheme.ok : LuminaTheme.inkDim)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(
            Rectangle().fill(LuminaTheme.bg2.opacity(0.5))
        )
        .overlay(
            Rectangle().fill(LuminaTheme.rule).frame(height: 1),
            alignment: .bottom
        )
    }

    @ViewBuilder
    private func metric(label: String, value: String,
                        accent: Color = LuminaTheme.ink,
                        warn: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(LuminaTheme.inkMute)
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(warn ? LuminaTheme.warn : accent)
                .monospacedDigit()
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(LuminaTheme.rule2)
            .frame(width: 1, height: 14)
    }
}

// ── LAYOUT PICKER ─────────────────────────────────────────────────
@MainActor
public struct LayoutPicker: View {
    @Binding var layoutRaw: String
    private var current: LibraryLayout {
        LibraryLayout(rawValue: layoutRaw) ?? .list
    }
    public var body: some View {
        Picker("Layout", selection: $layoutRaw) {
            ForEach(LibraryLayout.allCases, id: \.rawValue) { l in
                Image(systemName: l.systemImage).tag(l.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 80)
        .help("Layout: \(current.label)")
    }
}

// ── APPEARANCE TOGGLE ─────────────────────────────────────────────
@MainActor
public struct AppearanceMenu: View {
    @Binding var current: AppearancePreference
    @Binding var persistedRaw: String

    public var body: some View {
        // Fast path: flip the @State (triggers instant redraw) + persist
        // UserDefaults in parallel. The old AppStorage-only path added
        // ~700ms — AppStorage wraps UserDefaults in a willSet that fires
        // synchronously through the whole view graph before the picker
        // menu even dismisses.
        Menu {
            ForEach(AppearancePreference.allCases, id: \.rawValue) { pref in
                Button {
                    setAppearance(pref)
                } label: {
                    HStack {
                        Label(pref.label, systemImage: pref.glyph)
                        Spacer()
                        if current == pref {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: current.glyph)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(LuminaTheme.accent)
                .frame(width: 28, height: 22)
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Appearance — \(current.label)")
    }

    private func setAppearance(_ next: AppearancePreference) {
        guard current != next else { return }
        // Flip @State first — this is what drives the visible redraw.
        withAnimation(.easeInOut(duration: 0.14)) {
            current = next
        }
        // Persist in the next runloop tick so UserDefaults' synchronous
        // willSet chain doesn't block the paint.
        DispatchQueue.main.async {
            persistedRaw = next.rawValue
        }
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
    let onChoose: (String?) -> Void   // nil = open blank wizard, else pre-pick tile id

    public var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 28) {
                BrandMarkLarge()
                    .frame(width: 80, height: 80)
                VStack(spacing: 8) {
                    Text("subprocess.run()")
                        .foregroundStyle(LuminaTheme.accent)
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
                        onChoose("ubuntu-24.04")
                    }
                    PrimaryAction(label: "Install Windows 11", systemImage: "macwindow") {
                        onChoose("windows-11-arm")
                    }
                    PrimaryAction(label: "Install macOS", systemImage: "apple.logo") {
                        onChoose("macos-latest")
                    }
                    PrimaryAction(label: "Use my own…", systemImage: "doc.badge.plus") {
                        onChoose("byo-file")
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
// ── STATE SHARED BY CARD + ROW ─────────────────────────────────────
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
                "› up     just now",
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
}

/// Explicit action on the card/row: ▶ Boot / ■ Stop. Appears always in
/// list view; hover-only in grid view. Direct manipulation — the verb
/// is visible, not hidden behind a navigation step.
@MainActor
struct VMActionButton: View {
    @Bindable var session: LuminaDesktopSession
    let compact: Bool

    @State private var hovering = false

    var body: some View {
        Button {
            Task {
                switch session.status {
                case .stopped, .crashed:
                    await session.boot()
                case .running, .paused:
                    await session.shutdown()
                case .booting, .shuttingDown:
                    break
                }
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

// ── GRID VIEW ─────────────────────────────────────────────────────
@MainActor
public struct VMGridView: View {
    @Bindable var model: AppModel
    let bundles: [VMBundle]
    @Environment(\.openWindow) private var openWindow

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

@MainActor
public struct VMCard: View {
    @Bindable var model: AppModel
    let bundle: VMBundle
    let openWindow: () -> Void
    @State private var isHovering = false
    @State private var stats: VMLiveStats

    init(model: AppModel, bundle: VMBundle, openWindow: @escaping () -> Void) {
        self.model = model
        self.bundle = bundle
        self.openWindow = openWindow
        _stats = State(initialValue: VMLiveStats(bundle: bundle))
    }

    private var session: LuminaDesktopSession {
        model.session(for: bundle)
    }

    public var body: some View {
        HStack(spacing: 0) {
            OSStripe(family: bundle.manifest.osFamily, height: 0)
            content
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(LuminaTheme.bg1.opacity(isHovering ? 0.78 : 0.58))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isHovering ? LuminaTheme.accent.opacity(0.55) : LuminaTheme.rule,
                        lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .onHover { isHovering = $0 }
        .onTapGesture { openWindow() }
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

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
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
            VMStatePreview(bundle: bundle, status: session.status,
                           bootedAt: bundle.manifest.lastBootedAt,
                           density: .card)
            // Live sparkline — the category shift. Disk growth over the
            // last ~2 minutes; a flat line is idle, a rising line is
            // the guest writing. You SEE the VM working.
            DiskSparkline(stats: stats,
                          tint: LuminaTheme.accent,
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

// ── LIST VIEW (default) ───────────────────────────────────────────
@MainActor
public struct VMListView: View {
    @Bindable var model: AppModel
    let bundles: [VMBundle]
    @Environment(\.openWindow) private var openWindow

    public var body: some View {
        ScrollView {
            VStack(spacing: 4) {
                // Column header — dense like Activity Monitor / Linear / `lumina ps`
                HStack(spacing: 12) {
                    columnHeader("NAME", width: nil, align: .leading)
                    columnHeader("STATE", width: 80)
                    columnHeader("LAST BOOT", width: 100)
                    columnHeader("DISK", width: 120)
                    columnHeader("SNAPS", width: 50)
                    columnHeader("", width: 72)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    Rectangle().fill(LuminaTheme.bg2.opacity(0.5))
                )
                .overlay(
                    Rectangle().fill(LuminaTheme.rule).frame(height: 1),
                    alignment: .bottom
                )

                LazyVStack(spacing: 1) {
                    ForEach(bundles, id: \.manifest.id) { bundle in
                        VMRow(model: model, bundle: bundle)
                            .onTapGesture {
                                openWindow(id: "vm-window", value: bundle.manifest.id)
                            }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
    }

    private func columnHeader(_ label: String, width: CGFloat?, align: Alignment = .leading) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .tracking(1.2)
            .foregroundStyle(LuminaTheme.inkMute)
            .frame(width: width, alignment: align)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: align)
    }
}

@MainActor
public struct VMRow: View {
    @Bindable var model: AppModel
    let bundle: VMBundle
    @State private var isHovering = false
    @State private var stats: VMLiveStats

    init(model: AppModel, bundle: VMBundle) {
        self.model = model
        self.bundle = bundle
        _stats = State(initialValue: VMLiveStats(bundle: bundle))
    }

    private var session: LuminaDesktopSession {
        model.session(for: bundle)
    }

    public var body: some View {
        HStack(spacing: 0) {
            OSStripe(family: bundle.manifest.osFamily, height: 44)
            HStack(spacing: 12) {
                // NAME + live heartbeat when running
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if session.status == .running {
                            Heartbeat(color: LuminaTheme.ok)
                        }
                        Text(bundle.manifest.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(LuminaTheme.ink)
                            .lineLimit(1)
                    }
                    Text(bundle.manifest.osVariant)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(LuminaTheme.inkMute)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // STATE
                HStack {
                    StateChip(status: session.status)
                    Spacer()
                }
                .frame(width: 80)

                // LAST BOOT
                Text(bundle.lastBootedRelative)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(LuminaTheme.inkDim)
                    .frame(width: 100, alignment: .leading)

                // DISK — text + live sparkline
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(bundle.diskUsedFormatted) / \(bundle.diskCapFormatted)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(LuminaTheme.inkDim)
                        .monospacedDigit()
                    DiskSparkline(stats: stats,
                                  tint: LuminaTheme.accent,
                                  running: session.status == .running)
                        .frame(height: 12)
                }
                .frame(width: 120, alignment: .leading)

                // SNAPS
                Text("\(bundle.snapshotCount)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(LuminaTheme.inkDim)
                    .frame(width: 50, alignment: .leading)
                    .monospacedDigit()

                // ACTION (always visible in list — this is the working view)
                VMActionButton(session: session, compact: true)
                    .frame(width: 72, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .background(
            Rectangle()
                .fill(isHovering ? LuminaTheme.bg1.opacity(0.75) : Color.clear)
        )
        .overlay(
            Rectangle()
                .fill(LuminaTheme.rule2.opacity(0.5))
                .frame(height: 1),
            alignment: .bottom
        )
        .animation(.easeOut(duration: 0.08), value: isHovering)
        .onHover { isHovering = $0 }
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
}

public extension Notification.Name {
    static let luminaOpenVMWindow = Notification.Name("LuminaOpenVMWindow")
}
