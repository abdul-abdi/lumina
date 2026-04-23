// Sources/LuminaDesktopKit/RunningVMView.swift
//
// v0.7.0 M6 — per-VM running window. Embeds LuminaVirtualMachineView
// edge-to-edge with a centered VM name and right-aligned toolbar
// buttons (STOP / RESTART / SNAPSHOT). Fullscreen is handled by
// macOS — toggled via ⌘⌃F or the VM menu's `Enter / Exit Full
// Screen` item. In fullscreen the entire toolbar auto-hides and
// reveals on hover-to-top: on macOS 15+ via the Scene-level
// `.windowToolbarFullScreenVisibility(.onHover)` modifier; on macOS
// 14 via `LegacyFullscreenConfigurator` below, which flips
// `NSApp.presentationOptions` on the enter/exit notifications.

import SwiftUI
@preconcurrency import Virtualization
import LuminaBootable

@MainActor
public struct RunningVMView: View {
    @Bindable var session: LuminaDesktopSession
    @AppStorage("lumina.appearance") private var appearanceRaw: String = AppearancePreference.system.rawValue

    private var appearance: AppearancePreference {
        AppearancePreference(rawValue: appearanceRaw) ?? .system
    }

    public init(session: LuminaDesktopSession) {
        self.session = session
    }

    public var body: some View {
        ZStack {
            LuminaTheme.bgInset
            framebuffer
        }
        .preferredColorScheme(appearance.colorScheme)
        .toolbar {
            // Centered VM name. `.principal` puts the item in the title
            // bar's center slot — the macOS standard location for window
            // titles (Finder, Preview, many Apple apps). With a proper
            // title bar (not `.hiddenTitleBar`), this renders as plain
            // centered text without the capsule artifact we had before.
            ToolbarItem(placement: .principal) {
                Text(session.bundle.manifest.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(LuminaTheme.ink)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                toolbarButton("⏻ STOP", color: LuminaTheme.err) {
                    Task { await session.shutdown() }
                }
                .disabled(!session.status.isLive)

                toolbarButton("↻ RESTART") {
                    Task {
                        await session.shutdown()
                        await session.boot()
                    }
                }

                toolbarButton("⌘ SNAPSHOT") {
                    // wired in M8
                }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(!session.status.isLive)
            }
        }
        // Window title for accessibility + Expose / Dock / Window menu.
        // The on-screen toolbar shows the name via the `.principal`
        // ToolbarItem above; this call is for system services, not
        // visible chrome. With `.windowToolbarStyle(.unified(showsTitle:
        // false))` set on the scene, the toolbar no longer renders its
        // own title and the left-aligned NSWindow title is also
        // suppressed — the `.principal` text above is the sole visible
        // label.
        .navigationTitle(session.bundle.manifest.name)
        // Fullscreen auto-hide: on macOS 15+ we use the
        // SwiftUI-native `.windowToolbarFullScreenVisibility(.onHover)`
        // modifier — toolbar hides in fullscreen and reveals when
        // the cursor crosses the menu-bar reveal threshold at the
        // top edge (same gesture that unfurls the menu bar). On
        // macOS 14 we fall back to `LegacyFullscreenConfigurator`
        // below, which flips `NSApp.presentationOptions` on the
        // window's `didEnter/ExitFullScreen` notifications.
        .modifier(FullscreenToolbarAutoHide())
        .background(legacyFullscreenBackground)
    }

    @ViewBuilder
    private var legacyFullscreenBackground: some View {
        if #unavailable(macOS 15.0) {
            LegacyFullscreenConfigurator()
        }
    }

    private func toolbarButton(_ label: String, color: Color = LuminaTheme.ink, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(LuminaTheme.label)
                .tracking(1.5)
                .foregroundStyle(color)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .overlay(Rectangle().stroke(LuminaTheme.rule2, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var framebuffer: some View {
        switch session.status {
        case .booting:
            bootingScreen
        case .running, .paused:
            if let vm = session.vzMachine {
                LuminaVirtualMachineView(virtualMachine: vm, capturesSystemKeys: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
            } else {
                connectingScreen
            }
        case .crashed(let reason):
            crashedScreen(reason: reason)
        case .stopped, .shuttingDown:
            stoppedScreen
        }
    }

    private var bootingScreen: some View {
        VStack(spacing: 16) {
            Spacer()
            // ASCII brand mark, big
            VStack(alignment: .leading, spacing: 0) {
                Text("[ BOOTING ]")
                    .font(LuminaTheme.label)
                    .tracking(2.5)
                    .foregroundStyle(LuminaTheme.accent)
                Text(session.bundle.manifest.name)
                    .font(LuminaTheme.title)
                    .foregroundStyle(LuminaTheme.ink)
                Text(session.bundle.manifest.osVariant)
                    .font(LuminaTheme.caption)
                    .foregroundStyle(LuminaTheme.inkDim)
            }
            .padding(.bottom, 12)
            HStack(spacing: 10) {
                Circle().fill(LuminaTheme.accent).frame(width: 6, height: 6)
                Text("vm.boot() — initializing virtio devices, EFI variable store…")
                    .font(LuminaTheme.caption)
                    .foregroundStyle(LuminaTheme.inkDim)
            }
            // Live phase waterfall — fills in as each phase completes
            // via the session's bootPhasesMirrorTask. The view itself
            // renders nothing until the first phase lands, so no empty
            // frame appears on sessions that boot in <150ms.
            BootWaterfallView(phases: session.bootPhases)
                .frame(maxWidth: 520)
                .padding(.top, 4)
            Spacer()
            serialTailStrip
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LuminaTheme.bgInset)
    }

    /// Bottom-docked serial tail. Non-empty while the guest is writing
    /// to /dev/hvc0 (kernel, initramfs, bootloader); empty during the
    /// pre-kernel VZ window. Re-rendering is cheap — `serialDigest`
    /// updates at ~4 Hz from the session's mirror task.
    @ViewBuilder
    private var serialTailStrip: some View {
        if !session.serialDigest.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("SERIAL (tail)")
                    .font(LuminaTheme.caption.smallCaps())
                    .tracking(2)
                    .foregroundStyle(LuminaTheme.inkDim)
                ScrollView {
                    Text(session.serialDigest)
                        .font(LuminaTheme.monoSmall)
                        .foregroundStyle(LuminaTheme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 120)
                .padding(10)
                .background(LuminaTheme.bg1)
                .overlay(Rectangle().stroke(LuminaTheme.rule, lineWidth: 1))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private var connectingScreen: some View {
        VStack(spacing: 14) {
            Image(systemName: "tv.circle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(LuminaTheme.accent.opacity(0.6))
            Text("CONNECTING TO DISPLAY…")
                .font(LuminaTheme.label)
                .tracking(2.5)
                .foregroundStyle(LuminaTheme.ink)
            Text("VZ handshake in progress. If this persists, the guest may have failed to render its framebuffer.")
                .font(.system(size: 11))
                .foregroundStyle(LuminaTheme.inkDim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LuminaTheme.bgInset)
    }

    private func crashedScreen(reason: String) -> some View {
        VStack(spacing: 12) {
            Text("[ CRASHED ]")
                .font(LuminaTheme.label)
                .tracking(2.5)
                .foregroundStyle(LuminaTheme.err)
            Text("VM stopped unexpectedly")
                .font(LuminaTheme.title)
                .foregroundStyle(LuminaTheme.ink)
            ScrollView {
                Text(reason)
                    .font(LuminaTheme.monoSmall)
                    .foregroundStyle(LuminaTheme.inkDim)
                    .frame(maxWidth: 520)
                    .padding(12)
                    .background(LuminaTheme.bg1)
                    .overlay(Rectangle().stroke(LuminaTheme.rule, lineWidth: 1))
            }
            .frame(maxHeight: 200)

            if !session.serialDigest.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("LAST SERIAL OUTPUT")
                        .font(LuminaTheme.caption.smallCaps())
                        .tracking(2)
                        .foregroundStyle(LuminaTheme.inkDim)
                    ScrollView {
                        Text(session.serialDigest)
                            .font(LuminaTheme.monoSmall)
                            .foregroundStyle(LuminaTheme.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 160)
                    .padding(10)
                    .background(LuminaTheme.bg1)
                    .overlay(Rectangle().stroke(LuminaTheme.rule, lineWidth: 1))
                }
                .frame(maxWidth: 520)
            }

            // Post-mortem phase trace — shows which phase was running
            // when the crash happened. Self-gates on `.isValid` so a
            // pre-boot crash (disk flock, manifest corruption) renders
            // nothing rather than a row of zeros.
            BootWaterfallView(phases: session.bootPhases)
                .frame(maxWidth: 520)

            HStack(spacing: 12) {
                Button(action: {
                    Task { await session.shutdown(); await session.boot() }
                }) {
                    Text("↻ TRY AGAIN")
                        .font(LuminaTheme.label)
                        .tracking(1.5)
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(LuminaTheme.accent)
                }
                .buttonStyle(.plain)
                Button(action: {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(reason, forType: .string)
                }) {
                    Text("[ COPY DIAGNOSTICS ]")
                        .font(LuminaTheme.label)
                        .tracking(1.5)
                        .foregroundStyle(LuminaTheme.ink)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .overlay(Rectangle().stroke(LuminaTheme.rule2, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var stoppedScreen: some View {
        VStack(spacing: 16) {
            Text("[ STOPPED ]")
                .font(LuminaTheme.label)
                .tracking(2.5)
                .foregroundStyle(LuminaTheme.inkMute)
            Button(action: { Task { await session.boot() } }) {
                Text("▶ BOOT")
                    .font(LuminaTheme.label)
                    .tracking(2)
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(LuminaTheme.accent)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}

// ── FULLSCREEN TOOLBAR AUTO-HIDE ─────────────────────────────────
/// Applies `.windowToolbarFullScreenVisibility(.onHover)` on macOS
/// 15+, a no-op on earlier versions. The modifier tells the SwiftUI
/// runtime to treat the window's toolbar the same way as the system
/// menu bar in fullscreen: hide it while the guest has focus, and
/// reveal it briefly when the cursor crosses the top-edge reveal
/// threshold.
struct FullscreenToolbarAutoHide: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.windowToolbarFullScreenVisibility(.onHover)
        } else {
            content
        }
    }
}

// ── LEGACY FULLSCREEN CONFIG (macOS 14 fallback) ─────────────────
/// macOS 14 fallback for toolbar auto-hide in fullscreen. On macOS
/// 15+ the SwiftUI-native `.windowToolbarFullScreenVisibility(.onHover)`
/// Scene modifier handles this declaratively — this type is only
/// attached to the view on 14.x. It reaches into the underlying
/// `NSWindow` via an NSViewRepresentable and:
///
///   1. Sets `collectionBehavior` to `.fullScreenPrimary` so
///      `toggleFullScreen(nil)` enters true immersive mode.
///   2. On `didEnterFullScreen`, sets `NSApp.presentationOptions` to
///      the full immersion set (`autoHideMenuBar | autoHideDock |
///      autoHideToolbar` alongside `.fullScreen`). macOS then
///      honors mouse-to-top reveal natively for both menu bar and
///      toolbar.
///   3. On `didExitFullScreen`, clears the options.
@MainActor
struct LegacyFullscreenConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let window = v.window else { return }

            // (1) Allow true fullscreen primary mode.
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.collectionBehavior.remove(.fullScreenNone)

            // (2) Hide NSWindow's own title rendering in the title bar.
            // `.navigationTitle(...)` sets the window title for system
            // services (Window menu, Dock, Expose, accessibility) — we
            // want those to work, but NOT see a duplicate left-aligned
            // title when the principal toolbar item already renders the
            // VM name centered.
            window.titleVisibility = .hidden

            // (3) Enter-fullscreen: apply immersive presentation options.
            NotificationCenter.default.addObserver(
                forName: NSWindow.didEnterFullScreenNotification,
                object: window, queue: .main
            ) { _ in
                Task { @MainActor in
                    NSApp.presentationOptions = [
                        .fullScreen,
                        .autoHideMenuBar,
                        .autoHideDock,
                        .autoHideToolbar,
                    ]
                }
            }

            // (4) Exit-fullscreen: restore default.
            NotificationCenter.default.addObserver(
                forName: NSWindow.didExitFullScreenNotification,
                object: window, queue: .main
            ) { _ in
                Task { @MainActor in
                    NSApp.presentationOptions = []
                }
            }
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
