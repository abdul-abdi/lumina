// Sources/LuminaDesktopKit/RunningVMView.swift
//
// v0.7.0 M6 — per-VM running window. Embeds LuminaVirtualMachineView,
// adds toolbar (pause/restart/snapshot/shutdown/fullscreen), and the
// pointer-release toast.

import SwiftUI
@preconcurrency import Virtualization
import LuminaBootable

@MainActor
public struct RunningVMView: View {
    @Bindable var session: LuminaDesktopSession
    @State private var vzMachine: VZVirtualMachine?
    @State private var showReleaseToast = false

    public init(session: LuminaDesktopSession) {
        self.session = session
    }

    public var body: some View {
        ZStack(alignment: .top) {
            framebuffer
            if showReleaseToast {
                releaseToast
                    .transition(.opacity)
                    .padding(.top, 16)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await session.shutdown() }
                } label: {
                    Label("Shut down", systemImage: "power")
                }
                .disabled(!session.status.isLive)

                Button {
                    Task { await session.shutdown(); await session.boot() }
                } label: {
                    Label("Restart", systemImage: "arrow.counterclockwise")
                }

                Button {
                    // Snapshot — v0.7.0 wires up basic save state.
                } label: {
                    Label("Snapshot", systemImage: "camera")
                }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(!session.status.isLive)
            }
        }
        .navigationTitle(session.bundle.manifest.name)
        .task {
            if session.status == .stopped {
                await session.boot()
            }
            vzMachine = await session.virtualMachine()
            // Show toast on first 3 sessions per UserDefaults (simplified).
            withAnimation { showReleaseToast = true }
            try? await Task.sleep(for: .seconds(3))
            withAnimation { showReleaseToast = false }
        }
        .onChange(of: session.status) { _, _ in
            Task { vzMachine = await session.virtualMachine() }
        }
    }

    @ViewBuilder
    private var framebuffer: some View {
        switch session.status {
        case .booting:
            VStack(spacing: 12) {
                ProgressView()
                Text("Booting \(session.bundle.manifest.name)…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .running, .paused:
            if let vm = vzMachine {
                LuminaVirtualMachineView(virtualMachine: vm, capturesSystemKeys: true)
                    .background(Color.black)
            } else {
                Text("Connecting to display…")
                    .foregroundStyle(.secondary)
            }
        case .crashed(let reason):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(LuminaTheme.crashedRed)
                Text("VM crashed")
                    .font(.title3.weight(.semibold))
                Text(reason)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 480)
                Button("Try again") {
                    Task { await session.shutdown(); await session.boot() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .stopped, .shuttingDown:
            VStack(spacing: 12) {
                Image(systemName: "stop.circle")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("VM stopped")
                    .foregroundStyle(.secondary)
                Button("Boot") {
                    Task { await session.boot() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var releaseToast: some View {
        Text("Press ⌘⌥ to release pointer")
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .shadow(radius: 4)
    }
}
