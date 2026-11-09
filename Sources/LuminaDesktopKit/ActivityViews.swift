import AppKit
import LuminaBootable
import SwiftUI

struct SectionHeader: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(LuminaTheme.label)
                .tracking(2.5)
                .foregroundStyle(LuminaTheme.accent)
            Text(detail)
                .font(LuminaTheme.caption)
                .foregroundStyle(LuminaTheme.inkDim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }
}

struct ActivityEmptyState: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(LuminaTheme.inkMute)
            Text(title)
                .font(LuminaTheme.headline)
                .foregroundStyle(LuminaTheme.ink)
            Text(detail)
                .font(LuminaTheme.caption)
                .foregroundStyle(LuminaTheme.inkDim)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

struct ActivityRow<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(LuminaTheme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(LuminaTheme.caption)
                    .foregroundStyle(LuminaTheme.inkDim)
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(LuminaTheme.bg1)
        .overlay(Rectangle().stroke(LuminaTheme.rule, lineWidth: 1))
    }
}

@MainActor
public struct DownloadsView: View {
    @Bindable var model: AppModel
    @State private var files: [URL] = []
    @State private var pendingDelete: URL?

    static let folders = ["isos", "omarchy", "ipsw", "virtio-win"]
    static var cacheRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lumina/cache")
    }

    static func cachedFiles() -> [URL] {
        folders.flatMap { folder in
            (try? FileManager.default.contentsOfDirectory(
                at: cacheRoot.appendingPathComponent(folder), includingPropertiesForKeys: [.fileSizeKey]
            )) ?? []
        }
        .filter { ["iso", "ipsw"].contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public init(model: AppModel) {
        self.model = model
    }

    private var active: [LuminaDesktopSession] {
        model.sessions.values.filter { $0.installProgress != nil }.sorted { $0.bundle.manifest.name < $1.bundle.manifest.name }
    }

    public var body: some View {
        VStack(spacing: 0) {
            SectionHeader(
                title: "DOWNLOADS",
                detail: "Installers Lumina fetched for your VMs, verified and kept so the next VM starts without downloading again. \(formatBytesHuman(UInt64(files.map(size).reduce(0, +)))) in use."
            )
            if files.isEmpty && active.isEmpty {
                ActivityEmptyState(
                    symbol: "arrow.down.circle",
                    title: "Nothing downloaded yet",
                    detail: "Create a VM and Lumina fetches its installer on first boot."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(active) { session in
                            if let progress = session.installProgress {
                                ActivityRow(title: progress.label, subtitle: "for \(session.bundle.manifest.name)") {
                                    ProgressView(value: progress.fraction).frame(width: 160).tint(LuminaTheme.accent)
                                }
                            }
                        }
                        ForEach(files, id: \.self) { file in
                            ActivityRow(title: file.lastPathComponent, subtitle: formatBytesHuman(UInt64(size(file)))) {
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                                    .buttonStyle(.borderless)
                                Button("Delete", role: .destructive) { pendingDelete = file }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { files = Self.cachedFiles() }
        .confirmationDialog(
            "Delete \(pendingDelete?.lastPathComponent ?? "")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let file = pendingDelete { try? FileManager.default.removeItem(at: file) }
                pendingDelete = nil
                files = Self.cachedFiles()
            }
        } message: {
            Text("VMs already installed keep working. A new VM of this OS downloads it again.")
        }
    }

    private func size(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}

@MainActor
public struct SnapshotsView: View {
    @Bindable var model: AppModel
    @State private var refresh = 0
    @State private var pendingRestore: (VMBundle, VMSnapshot)?
    @State private var pendingDelete: (VMBundle, VMSnapshot)?
    @State private var failure: String?

    public init(model: AppModel) {
        self.model = model
    }

    private var groups: [(bundle: VMBundle, snapshots: [VMSnapshot])] {
        _ = refresh
        return model.bundles.map { ($0, $0.snapshots) }.filter { !$0.1.isEmpty }
    }

    public var body: some View {
        VStack(spacing: 0) {
            SectionHeader(
                title: "SNAPSHOTS",
                detail: "Point-in-time copies of a VM's disks, made instantly with APFS clones. Press ⌘T in a VM window to take one."
            )
            if groups.isEmpty {
                ActivityEmptyState(
                    symbol: "camera",
                    title: "No snapshots yet",
                    detail: "Open a VM and press ⌘T before a risky change. Restoring puts its disks back exactly as they were."
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(groups, id: \.bundle.manifest.id) { group in
                            Text(group.bundle.manifest.name.uppercased())
                                .font(LuminaTheme.label)
                                .tracking(1.5)
                                .foregroundStyle(LuminaTheme.inkMute)
                                .padding(.top, 8)
                            ForEach(group.snapshots) { snapshot in
                                let live = model.sessions[group.bundle.manifest.id]?.status.isLive == true
                                ActivityRow(
                                    title: snapshot.createdAt.formatted(date: .abbreviated, time: .shortened),
                                    subtitle: live ? "Stop the VM to restore" : snapshot.createdAt.formatted(.relative(presentation: .named))
                                ) {
                                    Button("Restore") { pendingRestore = (group.bundle, snapshot) }
                                        .buttonStyle(.borderless)
                                        .disabled(live)
                                    Button("Delete", role: .destructive) { pendingDelete = (group.bundle, snapshot) }
                                        .buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .confirmationDialog(
            "Restore \(pendingRestore?.0.manifest.name ?? "")?",
            isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } })
        ) {
            Button("Restore", role: .destructive) {
                if let (bundle, snapshot) = pendingRestore {
                    do { try bundle.restore(snapshot) } catch { failure = "\(error.localizedDescription)" }
                }
                pendingRestore = nil
            }
        } message: {
            Text("Its disks go back to this snapshot. Changes made since are lost unless you snapshot them first.")
        }
        .confirmationDialog(
            "Delete this snapshot?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let (bundle, snapshot) = pendingDelete { try? bundle.deleteSnapshot(snapshot) }
                pendingDelete = nil
                refresh += 1
            }
        }
        .alert("Restore failed", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") { failure = nil }
        } message: {
            Text(failure ?? "")
        }
    }
}
