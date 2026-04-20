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
    @State private var openVMID: UUID?

    var body: some Scene {
        WindowGroup("Lumina", id: "library") {
            LibraryView(model: model)
                .onReceive(NotificationCenter.default.publisher(for: .luminaOpenVMWindow)) { note in
                    if let id = note.object as? UUID {
                        openVMID = id
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1200, height: 720)
        .commands {
            LuminaCommands(model: model)
        }

        WindowGroup(id: "vm-window", for: UUID.self) { $vmID in
            if let id = vmID, let bundle = model.bundles.first(where: { $0.manifest.id == id }) {
                RunningVMView(session: model.session(for: bundle))
                    .frame(minWidth: 1024, minHeight: 600)
            } else {
                Text("VM not found").padding()
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: true))

        Settings {
            PreferencesView(model: model)
        }

        // ── MENU BAR EXTRA ──────────────────────────────────────
        // Always-visible status item in the system menu bar. Shows the
        // number of running VMs next to a Lumina glyph; click to reveal
        // a dropdown with quick actions. Works even when the main
        // window is hidden or the app is in fullscreen.
        MenuBarExtra {
            MenuBarContent(model: model)
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
        let running = model.sessions.values.filter { $0.status.isLive }.count
        HStack(spacing: 3) {
            // Lumina brand mark — double-square offset, matching the
            // app icon + the website's .brand-mark. Rendered as a
            // template image so macOS auto-tints it dark/light
            // depending on menu-bar appearance.
            LuminaMenuBarMark()
                .frame(width: 14, height: 14)
            if running > 0 {
                Text("\(running)")
                    .monospacedDigit()
            }
        }
    }
}

/// Template-image Lumina brand mark for the menu bar. Two offset
/// hollow squares drawn with `Path` — macOS system will tint them
/// monochrome to match the menu-bar appearance (black on light,
/// white on dark). The app's own `AppIcon.icns` has the amber+cream
/// colouring; in the menu bar, the template image convention is to
/// provide shape only.
@MainActor
struct LuminaMenuBarMark: View {
    var body: some View {
        Canvas { ctx, size in
            // macOS menu-bar template semantics: draw in any color,
            // the system will replace it with the menu-bar-appropriate
            // tint. We use primary foregroundStyle which is already
            // the right hook for dynamic tinting in SwiftUI.
            let squareSize = size.width * 0.65
            let stroke = max(1, size.width * 0.08)
            // Back square (offset down-right)
            let backRect = CGRect(
                x: size.width - squareSize,
                y: size.height - squareSize,
                width: squareSize - stroke,
                height: squareSize - stroke
            )
            ctx.stroke(Path(backRect),
                       with: .color(.primary.opacity(0.5)),
                       lineWidth: stroke)
            // Front square (top-left)
            let frontRect = CGRect(
                x: 0, y: 0,
                width: squareSize - stroke,
                height: squareSize - stroke
            )
            ctx.stroke(Path(frontRect),
                       with: .color(.primary),
                       lineWidth: stroke)
        }
    }
}

@MainActor
struct MenuBarContent: View {
    @Bindable var model: AppModel
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
            NotificationCenter.default.post(name: .luminaLauncherOpenWizard, object: "ubuntu-24.04")
        }
        .keyboardShortcut("n", modifiers: .command)

        Button("Command Launcher (⌘K)") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "library")
            NotificationCenter.default.post(name: .luminaShowLauncher, object: nil)
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
@MainActor
struct LuminaCommands: Commands {
    @Bindable var model: AppModel

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
                NotificationCenter.default.post(name: .luminaLauncherOpenWizard, object: "ubuntu-24.04")
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
            Button("Enter Full Screen") { enterFullscreen() }
                .keyboardShortcut("f", modifiers: [.command, .control])
        }

        // ── View menu ──
        CommandGroup(after: .toolbar) {
            Button("Open Command Launcher") {
                NotificationCenter.default.post(name: .luminaShowLauncher, object: nil)
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
                NotificationCenter.default.post(name: .luminaShowShortcuts, object: nil)
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
        NotificationCenter.default.post(name: .luminaLauncherOpenWizard, object: tile)
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

public extension Notification.Name {
    static let luminaShowLauncher = Notification.Name("LuminaShowLauncher")
    static let luminaShowShortcuts = Notification.Name("LuminaShowShortcuts")
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
