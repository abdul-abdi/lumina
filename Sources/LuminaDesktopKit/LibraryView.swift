// Sources/LuminaDesktopKit/LibraryView.swift
//
// v0.7.0 M6 — main app window: sidebar + library detail.

import SwiftUI
import LuminaBootable

@MainActor
public struct LibraryView: View {
    @Bindable public var model: AppModel
    @State private var showingWizard = false

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingWizard = true
                } label: {
                    Label("New VM", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .sheet(isPresented: $showingWizard) {
            NewVMWizard(model: model, isPresented: $showingWizard)
        }
        .frame(minWidth: 880, minHeight: 560)
    }

    private var sidebar: some View {
        List(selection: Binding(
            get: { SidebarSection.library },
            set: { _ in /* fixed for v0.7.0 */ }
        )) {
            Label("Library", systemImage: "square.grid.2x2.fill")
                .tag(SidebarSection.library)
            Label("Running", systemImage: "play.circle")
                .tag(SidebarSection.running)
                .badge(model.sessions.values.filter { $0.status.isLive }.count)
            Label("Snapshots", systemImage: "clock.arrow.circlepath")
                .tag(SidebarSection.snapshots)
            Label("Downloads", systemImage: "arrow.down.circle")
                .tag(SidebarSection.downloads)
        }
        .navigationTitle("Lumina")
        .frame(minWidth: 200)
    }

    private var detail: some View {
        Group {
            if model.bundles.isEmpty {
                EmptyStateView(showingWizard: $showingWizard)
            } else {
                VMGridView(model: model)
            }
        }
        .navigationTitle(model.bundles.isEmpty ? "Welcome" : "Library")
    }

    enum SidebarSection: Hashable { case library, running, snapshots, downloads }
}

@MainActor
public struct EmptyStateView: View {
    @Binding var showingWizard: Bool

    public var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "sparkles")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 96)
                .foregroundStyle(LuminaTheme.accent)

            Text("No virtual machines yet.")
                .font(LuminaTheme.title)

            Text("Spin up Ubuntu, Kali, Windows 11 ARM, or macOS — all from one place.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            HStack(spacing: 12) {
                Button {
                    showingWizard = true
                } label: {
                    Label("Try Ubuntu", systemImage: "circle.hexagongrid.fill")
                        .frame(minWidth: 140)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    showingWizard = true
                } label: {
                    Label("Use my own ISO/IPSW…", systemImage: "doc.badge.plus")
                        .frame(minWidth: 180)
                }
                .controlSize(.large)
            }

            Spacer()

            Text("Drop an ISO / IPSW anywhere on this window to get started.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
public struct VMGridView: View {
    @Bindable var model: AppModel

    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 320), spacing: 16)]

    public var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(model.filteredBundles, id: \.manifest.id) { bundle in
                    VMCard(model: model, bundle: bundle)
                        .onTapGesture {
                            model.selection = bundle.manifest.id
                            // The Running window is opened via a separate
                            // WindowGroup in LuminaDesktopApp via openWindow().
                            NotificationCenter.default.post(
                                name: .luminaOpenVMWindow,
                                object: bundle.manifest.id
                            )
                        }
                }
            }
            .padding(20)
        }
        .searchable(text: $model.search, prompt: "Search VMs")
        .toolbar {
            ToolbarItem {
                Picker("Sort", selection: $model.sortOrder) {
                    ForEach(AppModel.SortOrder.allCases, id: \.rawValue) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }
}

@MainActor
public struct VMCard: View {
    @Bindable var model: AppModel
    let bundle: VMBundle

    private var session: LuminaDesktopSession {
        model.session(for: bundle)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(LuminaTheme.osAccent(bundle.manifest.osFamily.rawValue).opacity(0.18))
                Image(systemName: glyphForFamily(bundle.manifest.osFamily))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 56)
                    .foregroundStyle(LuminaTheme.osAccent(bundle.manifest.osFamily.rawValue))
            }
            .aspectRatio(16.0/9.0, contentMode: .fit)

            HStack(spacing: 6) {
                statusDot
                Text(bundle.manifest.name)
                    .font(LuminaTheme.headline)
                    .lineLimit(1)
            }

            Text(bundle.manifest.osVariant)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                Text("\(formatGB(bundle.manifest.memoryBytes))")
                Text("·")
                Text("\(bundle.manifest.cpuCount) CPU")
                Text("·")
                Text(formatGB(bundle.manifest.diskBytes))
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.gray.opacity(0.3))
        )
        .contextMenu {
            Button("Open in Window") {
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

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
    }

    private var statusColor: Color {
        switch session.status {
        case .running: LuminaTheme.runningGreen
        case .booting, .shuttingDown: LuminaTheme.pausedYellow
        case .crashed: LuminaTheme.crashedRed
        default: .secondary
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
        String(format: "%.1f GB", Double(bytes) / (1024 * 1024 * 1024))
    }
}

public extension Notification.Name {
    /// Posted with the bundle UUID as the object when the user wants to
    /// open a VM in its own window. Handled by LuminaDesktopApp's main
    /// scene which spawns a RunningVMWindow for that bundle.
    static let luminaOpenVMWindow = Notification.Name("LuminaOpenVMWindow")
}
