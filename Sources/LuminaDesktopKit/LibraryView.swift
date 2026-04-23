// Sources/LuminaDesktopKit/LibraryView.swift
//
// v0.7.0 M6 — Mac-native rewrite. NavigationSplitView + materials +
// proper sidebar + detail pane. Phosphor-amber accent on a translucent
// dark surface that picks up the desktop wallpaper through the window.
//
// Split across files for locatability:
//   - `HostStatusRibbon.swift`     — top-of-detail metric strip
//   - `LibraryEmptyStates.swift`   — empty-library hero + filter empties
//   - `VMCard.swift`               — grid card + state chip + preview + action + distro chip
//   - `VMListView.swift`           — dense-row list layout
//   - `Heartbeat.swift`            — pulse indicator used by card and row
//   - this file: top-level library composition + toolbar chrome

import SwiftUI
import LuminaBootable

public enum SidebarSection: String, Hashable, CaseIterable {
    case all = "All VMs"
    case running = "Running"
    case linux = "Linux"
    case windows = "Windows"
    case macOS = "macOS"
    case agentImages = "Agent Images"
    case downloads = "Downloads"
    case snapshots = "Snapshots"

    var systemImage: String {
        switch self {
        case .all: "square.grid.2x2"
        case .running: "play.circle"
        case .linux: "circle.hexagongrid.fill"
        case .windows: "macwindow"
        case .macOS: "apple.logo"
        case .agentImages: "shippingbox"
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
    @Bindable public var coordinator: LauncherCoordinator
    @State private var section: SidebarSection = .all
    @State private var showingWizard = false
    @State private var wizardInitialTile: String? = nil
    @State private var showingLauncher = false
    @State private var lastSeenLauncherStamp: UUID? = nil
    @State private var appearanceState: AppearancePreference
    @AppStorage("lumina.appearance") private var appearanceRaw: String = AppearancePreference.system.rawValue
    @AppStorage("lumina.layout") private var layoutRaw: String = LibraryLayout.list.rawValue

    private var layout: LibraryLayout {
        LibraryLayout(rawValue: layoutRaw) ?? .list
    }

    public init(model: AppModel, coordinator: LauncherCoordinator) {
        self.model = model
        self.coordinator = coordinator
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
        // Instant scheme swap — native macOS behavior (Mail, Safari, Xcode).
        // The prior `.animation(.easeInOut(duration: 0.18), value: appearanceState)`
        // cross-faded the whole tree over 180ms, which reads as lag. Let
        // SwiftUI handle color scheme switching without an explicit animation.
        .preferredColorScheme(appearanceState.colorScheme)
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
            CommandLauncher(model: model, coordinator: coordinator, isPresented: $showingLauncher)
        }
        .background(
            // Global ⌘K / ⌘P shortcut even when focus is on sidebar
            Button("") { showingLauncher = true }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
        )
        .onChange(of: coordinator.pendingWizardTile) { _, tile in
            guard let tile else { return }
            showWizard(preselect: tile)
            coordinator.pendingWizardTile = nil
        }
        .onChange(of: coordinator.launcherRequestStamp) { _, stamp in
            // Open only when the stamp actually changes so reopening while the
            // sheet is already visible still works.
            guard stamp != nil, stamp != lastSeenLauncherStamp else { return }
            lastSeenLauncherStamp = stamp
            showingLauncher = true
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            Task { await handleDrop(providers) }
            return true
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) async {
        // NSItemProvider.loadItem returns an NSSecureCoding, which is not
        // Sendable. We extract the file path via the Data-representation
        // callback API (Sendable-safe) and reconstruct URL on the main
        // actor.
        for provider in providers {
            let path: String? = await withCheckedContinuation { cont in
                provider.loadDataRepresentation(forTypeIdentifier: "public.file-url") { data, _ in
                    guard let data = data,
                          let str = String(data: data, encoding: .utf8),
                          let url = URL(string: str) else {
                        cont.resume(returning: nil)
                        return
                    }
                    cont.resume(returning: url.path)
                }
            }
            guard let p = path else { continue }
            let url = URL(fileURLWithPath: p)
            let ext = url.pathExtension.lowercased()
            guard ["iso", "img", "ipsw"].contains(ext) else { continue }
            wizardInitialTile = ext == "ipsw" ? "macos-latest" : "byo-file"
            showingWizard = true
            UserDefaults.standard.set(url.path, forKey: "lumina.wizard.droppedFile")
            break
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

            sectionHeader("AGENT")
            sidebarRow(.agentImages, count: 0)

            sectionHeader("ACTIVITY")
            sidebarRow(.downloads, count: 0)
            sidebarRow(.snapshots, count: 0)
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
        .scrollContentBackground(.hidden)
        .background(MaterialBackground(material: .sidebar))
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
            if section == .agentImages {
                CustomImagesView()
            } else if filteredForSection.isEmpty && model.bundles.isEmpty {
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
        case .linux:
            base = model.filteredBundles.filter { $0.manifest.osFamily == .linux }
        case .windows:
            base = model.filteredBundles.filter { $0.manifest.osFamily == .windows }
        case .macOS:
            base = model.filteredBundles.filter { $0.manifest.osFamily == .macOS }
        case .downloads, .snapshots, .agentImages:
            base = []
        }
        return base
    }
}

// ── LAYOUT PICKER ─────────────────────────────────────────────────
@MainActor
public struct LayoutPicker: View {
    @Binding var layoutRaw: String
    private var current: LibraryLayout {
        LibraryLayout(rawValue: layoutRaw) ?? .list
    }

    public init(layoutRaw: Binding<String>) {
        _layoutRaw = layoutRaw
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

    public init(current: Binding<AppearancePreference>, persistedRaw: Binding<String>) {
        _current = current
        _persistedRaw = persistedRaw
    }

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
        // Instant flip — no animation. macOS appearance changes are
        // native-instant in Apple apps; wrapping in `withAnimation`
        // cross-faded the tree and read as lag. The @State write drives
        // the visible redraw in the current runloop tick.
        current = next
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
