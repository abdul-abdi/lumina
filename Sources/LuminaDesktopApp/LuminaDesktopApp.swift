// Apps/LuminaDesktop/LuminaDesktop/LuminaDesktopApp.swift
//
// v0.7.0 M6 — @main entry for the Lumina Desktop app.
// All UI lives in the LuminaDesktopKit SPM target; this file is just the
// scene + window orchestration.

import SwiftUI
import LuminaDesktopKit
import LuminaBootable

@main
struct LuminaDesktopApp: App {
    @State private var model = AppModel()
    @State private var uiState = AppUIState.shared
    @State private var coordinator = LauncherCoordinator()

    var body: some Scene {
        WindowGroup("Lumina", id: "library") {
            LibraryView(model: model, coordinator: coordinator)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1200, height: 720)
        .commands {
            LuminaCommands(model: model, uiState: uiState, coordinator: coordinator)
        }

        WindowGroup(id: "vm-window", for: UUID.self) { $vmID in
            if let id = vmID, let bundle = model.bundles.first(where: { $0.manifest.id == id }) {
                RunningVMView(session: model.session(for: bundle))
                    .frame(minWidth: 1024, minHeight: 600)
            } else {
                Text("VM not found").padding()
            }
        }
        // `unified(showsTitle: false)` strips the toolbar's own
        // title rendering (the left-aligned label AND the center
        // "pill" — both are drawn by the unified title bar when
        // `showsTitle` is true). The only VM name that remains
        // visible is the plain centered label drawn via the
        // `.principal` ToolbarItem in `RunningVMView`. The
        // companion `.windowToolbarFullScreenVisibility(.onHover)`
        // call (macOS 15+) that drives fullscreen auto-hide lives
        // on the view body in `RunningVMView` — it's declared on
        // `extension View` in SwiftUI, not on Scene.
        .windowToolbarStyle(.unified(showsTitle: false))

        Settings {
            PreferencesView(model: model)
        }

        // ── MENU BAR EXTRA ──────────────────────────────────────
        // Always-visible status item in the system menu bar. Shows the
        // number of running VMs next to a Lumina glyph; click to reveal
        // a dropdown with quick actions. Works even when the main
        // window is hidden or the app is in fullscreen.
        MenuBarExtra {
            MenuBarContent(model: model, coordinator: coordinator)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.menu)
    }

}

// ── MENU BAR GLYPH + COUNT ────────────────────────────────────────
@MainActor
struct MenuBarLabel: View {
    @Bindable var model: AppModel

    var body: some View {
        // Read status on every iterated session so @Observable tracking
        // fires when any individual session's status flips — not just
        // when the sessions dict itself mutates. Without this the label
        // goes stale when a VM transitions stopped↔running and the
        // dict's identity hasn't changed.
        let running = model.sessions.values.reduce(into: 0) { count, session in
            if session.status.isLive { count += 1 }
        }
        HStack(spacing: 3) {
            // SF Symbol `square.on.square` — two offset squares,
            // shape-identical to the app icon's brand mark. Template
            // rendering so macOS auto-tints it for the menu-bar
            // appearance (dark on light bar, white on dark bar).
            Image(systemName: "square.on.square")
            if running > 0 {
                Text("\(running)")
                    .monospacedDigit()
            }
        }
    }
}

@MainActor
struct MenuBarContent: View {
    @Bindable var model: AppModel
    @Bindable var coordinator: LauncherCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let running = model.bundles.filter {
            model.sessions[$0.manifest.id]?.status.isLive == true
        }
        let recent = model.bundles
            .sorted { ($0.manifest.lastBootedAt ?? .distantPast)
                     > ($1.manifest.lastBootedAt ?? .distantPast) }
            .prefix(5)

        Button("Open Lumina") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "library")
        }

        Divider()

        if running.isEmpty {
            Text("No running VMs").foregroundStyle(.secondary)
        } else {
            Section("RUNNING") {
                ForEach(running, id: \.manifest.id) { b in
                    Button("■ Stop \(b.manifest.name)") {
                        Task { await model.session(for: b).shutdown() }
                    }
                }
            }
        }

        if !recent.isEmpty {
            Divider()
            Section("RECENT") {
                ForEach(recent, id: \.manifest.id) { b in
                    Button("▶ \(b.manifest.name)") {
                        Task { await model.session(for: b).boot() }
                        NSApp.activate(ignoringOtherApps: true)
                        openWindow(id: "vm-window", value: b.manifest.id)
                    }
                    .disabled(model.sessions[b.manifest.id]?.status.isLive == true)
                }
            }
        }

        Divider()

        Button("New VM…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "library")
            coordinator.openWizard(preselecting: "ubuntu-24.04")
        }
        .keyboardShortcut("n", modifiers: .command)

        Button("Command Launcher (⌘K)") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "library")
            coordinator.showLauncher()
        }

        Divider()

        Button("Quit Lumina") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}

// ── MENU BAR ──────────────────────────────────────────────────────
/// Full macOS menu bar. The native place for every verb. Fullscreen
/// users get a menu at the top of the screen via the OS's automatic
/// menu-reveal-on-hover. First-time discovery happens here, not in a
/// floating toast.
// ── APP-LEVEL UI STATE ────────────────────────────────────────────
/// Tracks cross-window UI state the menu bar needs to observe:
/// whether any Lumina window is currently in fullscreen. The VM menu
/// uses this to switch the label between "Enter Full Screen" and
/// "Exit Full Screen" without flashing a floating overlay on content.
@MainActor
@Observable
final class AppUIState {
    static let shared = AppUIState()

    var hasFullscreenWindow: Bool = false

    private init() {
        let center = NotificationCenter.default
        center.addObserver(
            forName: NSWindow.didEnterFullScreenNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.hasFullscreenWindow = true }
        }
        center.addObserver(
            forName: NSWindow.didExitFullScreenNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // Any *other* window might still be fullscreen — re-check
            // instead of blindly clearing.
            Task { @MainActor in
                self?.hasFullscreenWindow = NSApplication.shared.windows
                    .contains { $0.styleMask.contains(.fullScreen) }
            }
        }
    }
}

@MainActor
struct LuminaCommands: Commands {
    @Bindable var model: AppModel
    @Bindable var uiState: AppUIState
    @Bindable var coordinator: LauncherCoordinator

    var body: some Commands {
        // ── Lumina menu (app menu) ──
        CommandGroup(replacing: .appInfo) {
            Button("About Lumina") {
                NSApplication.shared.orderFrontStandardAboutPanel(options: [
                    .applicationName: "Lumina",
                    .applicationVersion: "0.7.0",
                    .credits: NSAttributedString(
                        string: "Native Apple Workload Runtime for Agents.\nBoot a VM. Run a command. Parse the JSON.",
                        attributes: [.foregroundColor: NSColor.secondaryLabelColor]
                    )
                ])
            }
        }

        // ── File menu ──
        CommandGroup(replacing: .newItem) {
            Button("New VM…") {
                coordinator.openWizard(preselecting: "ubuntu-24.04")
            }
            .keyboardShortcut("n", modifiers: .command)

            Menu("New VM from OS") {
                Button("Ubuntu 24.04 LTS") { openWizard(tile: "ubuntu-24.04") }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                Button("Kali (rolling)") { openWizard(tile: "kali-rolling") }
                Button("Fedora Workstation 42") { openWizard(tile: "fedora-42") }
                Button("Debian 12") { openWizard(tile: "debian-12") }
                Divider()
                Button("Windows 11 on ARM") { openWizard(tile: "windows-11-arm") }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                Button("macOS (latest)") { openWizard(tile: "macos-latest") }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Divider()
                Button("From ISO or IPSW file…") { openWizard(tile: "byo-file") }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }

            Divider()

            Button("Open Bundle…") {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = false
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.title = "Open .luminaVM bundle"
                if panel.runModal() == .OK, let _ = panel.url {
                    model.refresh()
                }
            }
            .keyboardShortcut("o", modifiers: .command)
        }

        // ── VM menu ──
        CommandMenu("VM") {
            Button("Boot Selected") { runSelected(.boot) }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(model.selection == nil)
            Button("Stop Selected") { runSelected(.stop) }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(model.selection == nil)
            Button("Restart Selected") { runSelected(.restart) }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.selection == nil)
            Divider()
            Button("Take Snapshot") { runSelected(.snapshot) }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(model.selection == nil)
            Button("Clone VM…") { runSelected(.clone) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(model.selection == nil)
            Divider()
            Button("Reveal in Finder") { runSelected(.reveal) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.selection == nil)
            Button("Delete…") { runSelected(.delete) }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.selection == nil)
            Divider()
            // Standard macOS pattern: label flips based on whether any
            // window is already fullscreen. No floating chrome — the
            // menu bar itself is the escape route (OS reveals it on
            // mouse-to-top in immersive fullscreen).
            Button(uiState.hasFullscreenWindow ? "Exit Full Screen" : "Enter Full Screen") {
                enterFullscreen()
            }
            .keyboardShortcut("f", modifiers: [.command, .control])
        }

        // ── View menu ──
        CommandGroup(after: .toolbar) {
            Button("Open Command Launcher") {
                coordinator.showLauncher()
            }
            .keyboardShortcut("k", modifiers: .command)
            Divider()
            Button("Grid Layout") {
                UserDefaults.standard.set("grid", forKey: "lumina.layout")
            }
            .keyboardShortcut("1", modifiers: .command)
            Button("List Layout") {
                UserDefaults.standard.set("list", forKey: "lumina.layout")
            }
            .keyboardShortcut("2", modifiers: .command)
            Divider()
            Menu("Appearance") {
                Button("System") { setAppearance("system") }
                Button("Light") { setAppearance("light") }
                Button("Dark") { setAppearance("dark") }
            }
        }

        // ── Help menu ──
        CommandGroup(replacing: .help) {
            Button("Lumina Documentation") {
                NSWorkspace.shared.open(URL(string: "https://github.com/abdul-abdi/lumina/wiki")!)
            }
            Button("Keyboard Shortcuts") {
                NSWorkspace.shared.open(URL(string: "https://github.com/abdul-abdi/lumina/wiki/Keyboard-Shortcuts")!)
            }
            .keyboardShortcut("/", modifiers: .command)
            Divider()
            Button("Report an Issue…") {
                NSWorkspace.shared.open(URL(string: "https://github.com/abdul-abdi/lumina/issues/new")!)
            }
            Button("Release Notes") {
                NSWorkspace.shared.open(URL(string: "https://github.com/abdul-abdi/lumina/releases")!)
            }
        }
    }

    // ── Helpers ──

    private enum VMAction {
        case boot, stop, restart, snapshot, clone, reveal, delete
    }

    private func runSelected(_ action: VMAction) {
        guard let id = model.selection,
              let bundle = model.bundles.first(where: { $0.manifest.id == id }) else { return }
        let session = model.session(for: bundle)
        switch action {
        case .boot: Task { await session.boot() }
        case .stop: Task { await session.shutdown() }
        case .restart: Task {
            await session.shutdown()
            await session.boot()
        }
        case .snapshot: break  // wired in M8
        case .clone: break
        case .reveal: NSWorkspace.shared.activateFileViewerSelecting([bundle.rootURL])
        case .delete:
            let alert = NSAlert()
            alert.messageText = "Move '\(bundle.manifest.name)' to Trash?"
            alert.informativeText = "The bundle disk image and snapshots will be moved. You can restore from Trash."
            alert.addButton(withTitle: "Move to Trash")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            if alert.runModal() == .alertFirstButtonReturn {
                model.deleteBundle(bundle)
            }
        }
    }

    private func openWizard(tile: String) {
        coordinator.openWizard(preselecting: tile)
    }

    private func setAppearance(_ raw: String) {
        UserDefaults.standard.set(raw, forKey: "lumina.appearance")
    }

    private func enterFullscreen() {
        if let w = NSApp.keyWindow {
            w.toggleFullScreen(nil)
        }
    }
}

@MainActor
struct PreferencesView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            generalTab.tabItem { Label("General", systemImage: "gear") }
            libraryTab.tabItem { Label("Library", systemImage: "folder") }
            aboutTab.tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 320)
    }

    private var generalTab: some View {
        Form {
            Picker("Sort order", selection: $model.sortOrder) {
                ForEach(AppModel.SortOrder.allCases, id: \.rawValue) { o in
                    Text(o.rawValue).tag(o)
                }
            }
            Picker("Group by", selection: $model.groupBy) {
                ForEach(AppModel.GroupBy.allCases, id: \.rawValue) { g in
                    Text(g.rawValue).tag(g)
                }
            }
        }
        .padding(20)
    }

    private var libraryTab: some View {
        Form {
            HStack {
                Text("VM library")
                Spacer()
                Text(model.store.rootURL.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Text("Shared with the `lumina` CLI. Edit Preferences in v0.8 to relocate.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private var aboutTab: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 56))
                .foregroundStyle(LinearGradient(
                    colors: [.purple, .blue, .pink, .orange],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
            Text("Lumina Desktop")
                .font(.title3.weight(.semibold))
            Text("v0.7.0")
                .foregroundStyle(.secondary)
            Text("Native Apple Workload Runtime for Agents")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
}
