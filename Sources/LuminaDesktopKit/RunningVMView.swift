// Sources/LuminaDesktopKit/RunningVMView.swift
//
// v0.7.0 M6 — per-VM running window. Embeds LuminaVirtualMachineView,
// adds toolbar (pause/restart/snapshot/shutdown/fullscreen), and the
// pointer-release toast. Aligned to lumina.run phosphor-amber theme.

import SwiftUI
@preconcurrency import Virtualization
import LuminaBootable

@MainActor
public struct RunningVMView: View {
    @Bindable var session: LuminaDesktopSession
    @State private var vzMachine: VZVirtualMachine?
    @State private var showReleaseToast = false
    @State private var bootingDots = 0
    @State private var isFullscreen = false
    @State private var showFullscreenChrome = true
    @AppStorage("lumina.appearance") private var appearanceRaw: String = AppearancePreference.system.rawValue

    private var appearance: AppearancePreference {
        AppearancePreference(rawValue: appearanceRaw) ?? .system
    }

    public init(session: LuminaDesktopSession) {
        self.session = session
    }

    public var body: some View {
        ZStack(alignment: .top) {
            LuminaTheme.bgInset.ignoresSafeArea()
            framebuffer
                .ignoresSafeArea(.all, edges: isFullscreen ? .all : [])
            if showReleaseToast {
                releaseToast
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .padding(.top, 16)
            }
            if isFullscreen {
                FullscreenChrome(
                    visible: $showFullscreenChrome,
                    sessionName: session.bundle.manifest.name,
                    onExit: { toggleFullscreen() },
                    onShutdown: { Task { await session.shutdown() } }
                )
            }
        }
        .preferredColorScheme(appearance.colorScheme)
        .background(
            FullscreenObserver(isFullscreen: $isFullscreen)
        )
        .toolbar(isFullscreen ? .hidden : .automatic, for: .windowToolbar)
        .toolbar {
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

                toolbarButton("⛶ FULLSCREEN") {
                    toggleFullscreen()
                }
                .keyboardShortcut("f", modifiers: [.command, .control])
                .help("Enter full screen (⌘⌃F). The VM takes over your display.")
            }
        }
        .navigationTitle(session.bundle.manifest.name)
        .task {
            if session.status == .stopped {
                await session.boot()
            }
            vzMachine = await session.virtualMachine()
            withAnimation(.easeIn(duration: 0.2)) { showReleaseToast = true }
            try? await Task.sleep(for: .seconds(3))
            withAnimation(.easeOut(duration: 0.3)) { showReleaseToast = false }
        }
        .onChange(of: session.status) { _, newStatus in
            // Clear the stale VZVirtualMachine reference when the VM is no
            // longer running — prevents the framebuffer branch from
            // rendering a dead connection on state transitions.
            Task {
                switch newStatus {
                case .stopped, .crashed, .shuttingDown:
                    vzMachine = nil
                default:
                    vzMachine = await session.virtualMachine()
                }
            }
        }
    }

    private func toggleFullscreen() {
        if let window = NSApp.keyWindow {
            window.toggleFullScreen(nil)
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
            if let vm = vzMachine {
                LuminaVirtualMachineView(virtualMachine: vm, capturesSystemKeys: true)
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LuminaTheme.bgInset)
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

    private var releaseToast: some View {
        HStack(spacing: 8) {
            Text("⌘⌥")
                .font(LuminaTheme.label)
                .tracking(2)
                .foregroundStyle(LuminaTheme.accent)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .overlay(Rectangle().stroke(LuminaTheme.accent, lineWidth: 1))
            Text("RELEASE POINTER")
                .font(LuminaTheme.label)
                .tracking(2)
                .foregroundStyle(LuminaTheme.ink)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(LuminaTheme.bg2.opacity(0.95))
        .overlay(Rectangle().stroke(LuminaTheme.rule, lineWidth: 1))
    }
}

// ── FULLSCREEN — immersive, auto-hiding chrome ────────────────────

/// Observes NSWindow fullscreen transitions and mirrors them into a
/// SwiftUI @State. Required because SwiftUI doesn't expose fullscreen
/// state directly — we need the AppKit notification.
@MainActor
struct FullscreenObserver: NSViewRepresentable {
    @Binding var isFullscreen: Bool

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let window = v.window else { return }
            NotificationCenter.default.addObserver(
                forName: NSWindow.didEnterFullScreenNotification,
                object: window, queue: .main
            ) { _ in
                self.isFullscreen = true
            }
            NotificationCenter.default.addObserver(
                forName: NSWindow.didExitFullScreenNotification,
                object: window, queue: .main
            ) { _ in
                self.isFullscreen = false
            }
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Fullscreen chrome — auto-hiding overlay with VM name + exit button.
/// Appears when the mouse moves near the top of the screen, fades out
/// after 2 seconds of inactivity. ESC or ⌘⌃F also exits.
@MainActor
struct FullscreenChrome: View {
    @Binding var visible: Bool
    let sessionName: String
    let onExit: () -> Void
    let onShutdown: () -> Void
    @State private var hideTimer: Task<Void, Never>?

    var body: some View {
        VStack {
            if visible {
                chrome
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            Spacer()
        }
        .onAppear { scheduleHide() }
        // Track mouse moves to re-reveal the chrome near the top edge.
        .background(
            MouseHoverDetector { point in
                if point.y < 60 {
                    showChrome()
                }
            }
        )
        .animation(.easeInOut(duration: 0.25), value: visible)
    }

    private var chrome: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Circle().fill(LuminaTheme.ok).frame(width: 6, height: 6)
                Text(sessionName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(LuminaTheme.ink)
            }
            Spacer()
            Button {
                onShutdown()
            } label: {
                Label("STOP", systemImage: "power")
                    .font(LuminaTheme.label).tracking(1.5)
                    .foregroundStyle(LuminaTheme.err)
            }
            .buttonStyle(.plain)
            Button {
                onExit()
            } label: {
                Label("EXIT FULL SCREEN", systemImage: "arrow.down.right.and.arrow.up.left")
                    .font(LuminaTheme.label).tracking(1.5)
                    .foregroundStyle(LuminaTheme.ink)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(
            Capsule().fill(LuminaTheme.bg2.opacity(0.92))
        )
        .overlay(
            Capsule().stroke(LuminaTheme.rule2, lineWidth: 0.5)
        )
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
    }

    private func showChrome() {
        withAnimation(.easeInOut(duration: 0.2)) { visible = true }
        scheduleHide()
    }

    private func scheduleHide() {
        hideTimer?.cancel()
        hideTimer = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) { visible = false }
        }
    }
}

/// Track mouse position (global coords relative to this view) and fire
/// a callback. Used by FullscreenChrome to reveal when cursor nears top.
@MainActor
struct MouseHoverDetector: NSViewRepresentable {
    let onMove: (CGPoint) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = HoverNSView()
        v.onMove = onMove
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private class HoverNSView: NSView {
        var onMove: ((CGPoint) -> Void)?
        override func updateTrackingAreas() {
            trackingAreas.forEach { removeTrackingArea($0) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseMoved, .activeAlways, .inVisibleRect],
                owner: self, userInfo: nil
            )
            addTrackingArea(area)
        }
        override func mouseMoved(with event: NSEvent) {
            let p = convert(event.locationInWindow, from: nil)
            onMove?(CGPoint(x: p.x, y: bounds.height - p.y))  // flip Y
        }
    }
}
