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
        ZStack(alignment: .top) {
            LuminaTheme.bgInset
            framebuffer
            if let notice = session.notice {
                Text(notice)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: session.notice)
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
                if let signIn = session.bundle.signIn {
                    Menu {
                        Text("User: \(signIn.user)")
                        if let password = signIn.password {
                            Button("Copy Password") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(password, forType: .string)
                            }
                        }
                    } label: {
                        Label("Sign-in Details", systemImage: "key")
                    }
                    .help("How to sign in to this VM")
                }

                Button {
                    Task { await session.takeSnapshot() }
                } label: {
                    Label("Take Snapshot", systemImage: "camera")
                }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(session.status == .booting || session.status == .shuttingDown)
                .help("Save the VM's disks so you can return to this point")

                Button {
                    Task { await session.togglePause() }
                } label: {
                    Label(session.status == .paused ? "Resume" : "Pause",
                          systemImage: session.status == .paused ? "play.fill" : "pause.fill")
                }
                .disabled(session.status != .running && session.status != .paused)
                .help(session.status == .paused ? "Resume the VM" : "Pause the VM")

                Button {
                    Task {
                        await session.shutdown()
                        await session.boot()
                    }
                } label: {
                    Label("Restart", systemImage: "arrow.clockwise")
                }
                .disabled(!session.status.isLive)
                .help("Stop and start the VM")

                Button {
                    Task {
                        if session.status.isLive { await session.shutdown() } else { await session.boot() }
                    }
                } label: {
                    Label(session.status.isLive ? "Stop" : "Start", systemImage: "power")
                }
                .help(session.status.isLive ? "Stop the VM" : "Start the VM")
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
            if let progress = session.installProgress {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(progress.label) — \(Int(progress.fraction * 100))%")
                        .font(LuminaTheme.caption)
                        .foregroundStyle(LuminaTheme.inkDim)
                    ProgressView(value: progress.fraction)
                        .tint(LuminaTheme.accent)
                }
                .frame(maxWidth: 520)
            } else {
                HStack(spacing: 10) {
                    Circle().fill(LuminaTheme.accent).frame(width: 6, height: 6)
                    Text(session.bundle.manifest.osFamily == .macOS
                         ? "vm.boot() — starting macOS…"
                         : "vm.boot() — initializing virtio devices, EFI variable store…")
                        .font(LuminaTheme.caption)
                        .foregroundStyle(LuminaTheme.inkDim)
                }
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

struct FullscreenToolbarAutoHide: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.windowToolbarFullScreenVisibility(.onHover)
        } else {
            content
        }
    }
}

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

            window.collectionBehavior.insert(.fullScreenPrimary)
            window.collectionBehavior.remove(.fullScreenNone)

            // `.navigationTitle(...)` sets the window title for system
            // services (Window menu, Dock, Expose, accessibility) — we
            // want those to work, but NOT see a duplicate left-aligned
            // title when the principal toolbar item already renders the
            // VM name centered.
            window.titleVisibility = .hidden

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
