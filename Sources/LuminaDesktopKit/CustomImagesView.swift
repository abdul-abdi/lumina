// Sources/LuminaDesktopKit/CustomImagesView.swift
//
// Agent-path image library. Custom images are built via `lumina images
// create <name> --from default --run "apk add python3"` and live at
// ~/.lumina/images/<name>/. The Desktop library wasn't surfacing them
// before v0.7.1 because they don't boot through the EFI path — they run
// under the headless agent runtime (`lumina run`, `lumina session start`).
//
// This view makes them visible and provides one-click ergonomics for
// launching an interactive session in Terminal.app. Booting in-window
// (i.e. a SwiftUI terminal emulator pane) is a larger feature deferred
// to v0.7.1+.

import SwiftUI
import Lumina
import LuminaBootable

@MainActor
public struct CustomImagesView: View {
    private let layout: LibraryLayout
    @State private var images: [CustomImageEntry] = []
    @State private var error: String?
    @State private var launchNotice: LaunchNotice?
    @State private var catalogPullingID: String?

    public init(layout: LibraryLayout = .list) {
        self.layout = layout
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if let error {
                    Text(error)
                        .font(LuminaTheme.caption)
                        .foregroundStyle(LuminaTheme.err)
                        .padding(16)
                } else if images.isEmpty && uninstalledCatalog.isEmpty {
                    emptyState
                } else {
                    if !images.isEmpty { installedList }
                    if !uninstalledCatalog.isEmpty { catalogSection }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MaterialBackground(material: .contentBackground))
        .onAppear { refresh() }
        .alert(
            launchNotice?.title ?? "",
            isPresented: Binding(
                get: { launchNotice != nil },
                set: { if !$0 { launchNotice = nil } }
            )
        ) {
            Button("OK") { launchNotice = nil }
        } message: {
            Text(launchNotice?.message ?? "")
        }
    }

    /// Catalog entries whose id isn't already installed locally.
    /// Installed entries would just duplicate rows from the main list,
    /// so we hide them.
    private var uninstalledCatalog: [AgentImageEntry] {
        let installed = Set(images.map { $0.name })
        return AgentImageCatalog.all.filter { !installed.contains($0.id) }
    }

    /// Alert payload surfaced after a launch attempt. `.info` is a
    /// success-ish case (pasteboard fallback used); `.error` is a hard
    /// failure the user must fix.
    struct LaunchNotice: Equatable {
        let title: String
        let message: String
        let isError: Bool
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("AGENT IMAGES")
                    .font(LuminaTheme.label)
                    .tracking(2.5)
                    .foregroundStyle(LuminaTheme.accent)
                Spacer()
                Button { refresh() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }
            Text("Headless VM images built via `lumina images create`. Boot with `lumina run --image <name>` or open a persistent session in Terminal.")
                .font(LuminaTheme.caption)
                .foregroundStyle(LuminaTheme.inkDim)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "shippingbox")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(LuminaTheme.inkMute)
            Text("No agent images found.")
                .font(LuminaTheme.title)
                .foregroundStyle(LuminaTheme.ink)
            Text("Create one: `lumina images create mypy --from default --run \"apk add python3\"`")
                .font(LuminaTheme.monoSmall)
                .foregroundStyle(LuminaTheme.inkDim)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var installedList: some View {
        Group {
            switch layout {
            case .grid:
                LazyVGrid(columns: gridColumns, spacing: 14) {
                    ForEach(images, id: \.name) { img in
                        ImageCard(
                            entry: img,
                            onRemove: { remove(img.name) },
                            onLaunchOutcome: { outcome in
                                launchNotice = noticeFor(outcome: outcome)
                            }
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            case .list:
                LazyVStack(spacing: 8) {
                    ForEach(images, id: \.name) { img in
                        ImageRow(
                            entry: img,
                            onRemove: { remove(img.name) },
                            onLaunchOutcome: { outcome in
                                launchNotice = noticeFor(outcome: outcome)
                            }
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }
        }
    }

    private var catalogSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("CATALOG")
                        .font(LuminaTheme.label)
                        .tracking(2.5)
                        .foregroundStyle(LuminaTheme.accent)
                    Spacer()
                }
                Text("Curated images from github.com/abdul-abdi/lumina/releases. Pull verifies SHA-256 before extraction.")
                    .font(LuminaTheme.caption)
                    .foregroundStyle(LuminaTheme.inkDim)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 10)

            switch layout {
            case .grid:
                LazyVGrid(columns: gridColumns, spacing: 14) {
                    ForEach(uninstalledCatalog, id: \.id) { entry in
                        CatalogCard(
                            entry: entry,
                            isPulling: catalogPullingID == entry.id,
                            disabled: catalogPullingID != nil && catalogPullingID != entry.id,
                            onPull: { pull(entry) }
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            case .list:
                LazyVStack(spacing: 8) {
                    ForEach(uninstalledCatalog, id: \.id) { entry in
                        CatalogRow(
                            entry: entry,
                            isPulling: catalogPullingID == entry.id,
                            disabled: catalogPullingID != nil && catalogPullingID != entry.id,
                            onPull: { pull(entry) }
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
    }

    /// Same column spec as VMGridView for visual parity with the main
    /// library. Adaptive so agent images tile symmetrically with VMs
    /// when the window is resized.
    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 300, maximum: 380), spacing: 14)]
    }

    private func pull(_ entry: AgentImageEntry) {
        // Refuse placeholder sha256 — mirrors the CLI behaviour.
        let placeholder = String(repeating: "0", count: 64)
        if entry.sha256.lowercased() == placeholder {
            launchNotice = LaunchNotice(
                title: "Not yet published",
                message: "\(entry.displayName) hasn't been released yet. The build-baked-image.yml workflow will publish the tarball to GitHub Releases on the next tag. Try again after v0.7.1 ships.",
                isError: false
            )
            return
        }
        catalogPullingID = entry.id
        Task {
            do {
                let puller = ImagePuller(
                    repo: "abdul-abdi/lumina",
                    tag: "catalog-\(entry.id)",
                    assetName: entry.url.lastPathComponent,
                    directURL: entry.url,
                    expectedSHA256: entry.sha256,
                    imageName: entry.id
                )
                try await puller.pull { _ in }
                await MainActor.run {
                    catalogPullingID = nil
                    refresh()
                    launchNotice = LaunchNotice(
                        title: "Pulled \(entry.displayName)",
                        message: "Installed at ~/.lumina/images/\(entry.id)/. Try: `lumina run --image \(entry.id) 'uname -a'`",
                        isError: false
                    )
                }
            } catch {
                await MainActor.run {
                    catalogPullingID = nil
                    launchNotice = LaunchNotice(
                        title: "Pull failed",
                        message: "\(entry.displayName): \(error)",
                        isError: true
                    )
                }
            }
        }
    }

    /// Translate a launch outcome into a user-facing alert payload.
    /// Silent on `.executed` (the terminal window itself is the
    /// feedback); surfaces a helpful hint on the pasteboard-fallback
    /// path; surfaces an error on hard failure.
    private func noticeFor(outcome: TerminalLaunchOutcome) -> LaunchNotice? {
        switch outcome {
        case .executed:
            return nil
        case .copiedAndOpened(let terminal):
            return LaunchNotice(
                title: "Opened in \(terminal.displayName)",
                message: "The `lumina session start` command was copied to your clipboard. Paste with ⌘V in the new window to run it.",
                isError: false
            )
        case .failed(let reason):
            return LaunchNotice(
                title: "Couldn't open terminal",
                message: reason,
                isError: true
            )
        }
    }

    private func refresh() {
        error = nil
        let store = ImageStore()
        let names = store.list()
        images = names.map { name in
            CustomImageEntry(
                name: name,
                meta: store.readMeta(name: name),
                directory: store.baseDir.appendingPathComponent(name)
            )
        }
    }

    private func remove(_ name: String) {
        ImageStore().clean(name: name)
        refresh()
    }
}

/// Value type for a single image row. Derived from ImageStore + meta.json;
/// safe to hold on the MainActor.
struct CustomImageEntry: Sendable {
    let name: String
    let meta: ImageMeta?
    let directory: URL

    var isBaseline: Bool {
        // Heuristic: anything without a meta.json is either the pristine
        // base image (`default`) or a developer-built sibling (`default-legacy`,
        // `minimal` with its own meta). Hide the pristine base behind a
        // clearer label so users know which one they built themselves.
        meta == nil
    }

    var sizeOnDisk: Int64 {
        (try? FileManager.default.allocatedSizeOfDirectory(at: directory)) ?? 0
    }
}

@MainActor
private struct ImageRow: View {
    let entry: CustomImageEntry
    let onRemove: () -> Void
    let onLaunchOutcome: (TerminalLaunchOutcome) -> Void

    @State private var copiedFlash: Bool = false
    @State private var hovering: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            glyph
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(entry.name)
                        .font(LuminaTheme.title)
                        .foregroundStyle(LuminaTheme.ink)
                    if entry.isBaseline {
                        Text("BASELINE")
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(1.5)
                            .foregroundStyle(LuminaTheme.inkDim)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .overlay(Rectangle().stroke(LuminaTheme.rule2, lineWidth: 1))
                    } else if entry.meta?.rosetta == true {
                        Text("ROSETTA")
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(1.5)
                            .foregroundStyle(LuminaTheme.accent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .overlay(Rectangle().stroke(LuminaTheme.accent, lineWidth: 1))
                    }
                }
                if let meta = entry.meta {
                    Text("from \(meta.base ?? "unknown") · \(meta.created.formatted(date: .abbreviated, time: .omitted))")
                        .font(LuminaTheme.caption)
                        .foregroundStyle(LuminaTheme.inkDim)
                    if let cmd = meta.command, !cmd.isEmpty {
                        Text(cmd)
                            .font(LuminaTheme.monoSmall)
                            .foregroundStyle(LuminaTheme.ink)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
                Text(formatBytes(entry.sizeOnDisk))
                    .font(LuminaTheme.caption)
                    .foregroundStyle(LuminaTheme.inkMute)
            }
            Spacer()
            actions
        }
        .padding(14)
        .background(hovering ? LuminaTheme.bg1.opacity(0.85) : LuminaTheme.bg1)
        .overlay(Rectangle().stroke(
            hovering ? LuminaTheme.accent.opacity(0.5) : LuminaTheme.rule,
            lineWidth: 1
        ))
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .onTapGesture { openInTerminal() }
        .help("Click to open `lumina session start --image \(entry.name)` in Terminal")
        .contextMenu {
            Button("Open in Terminal") { openInTerminal() }
            Button("Copy `lumina run` command") { copyRunCommand() }
            if !entry.isBaseline {
                Divider()
                Button("Remove", role: .destructive) { onRemove() }
            }
        }
    }

    private var glyph: some View {
        Image(systemName: entry.isBaseline ? "cube" : "shippingbox.fill")
            .font(.system(size: 26, weight: .light))
            .foregroundStyle(LuminaTheme.accent.opacity(entry.isBaseline ? 0.5 : 1.0))
            .frame(width: 40, height: 40)
            .background(LuminaTheme.bg2)
            .overlay(Rectangle().stroke(LuminaTheme.rule, lineWidth: 1))
    }

    private var actions: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Button {
                copyRunCommand()
            } label: {
                Label(copiedFlash ? "Copied" : "Copy `run`",
                      systemImage: copiedFlash ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                openInTerminal()
            } label: {
                Label("Open in Terminal", systemImage: "terminal")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if !entry.isBaseline {
                Button(role: .destructive) {
                    onRemove()
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
                .foregroundStyle(LuminaTheme.err)
            }
        }
    }

    private func copyRunCommand() {
        let cmd = "lumina run --image \(entry.name) 'uname -a'"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
        copiedFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            copiedFlash = false
        }
    }

    private func openInTerminal() {
        // Route through TerminalLauncher — detects iTerm2/Ghostty/Warp
        // from the user's pref or install order, falls back to
        // Terminal.app, and surfaces a visible error instead of the
        // previous `try?`-swallowed failure. ImageStore names are
        // filesystem-safe by construction (no spaces, no quotes), so
        // the command doesn't need shell-escaping beyond what the
        // launcher already does.
        let cmd = "lumina session start --image \(entry.name)"
        let outcome = TerminalLauncher().launch(command: cmd)
        onLaunchOutcome(outcome)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Catalog row (uninstalled entries from AgentImageCatalog)

@MainActor
private struct CatalogRow: View {
    let entry: AgentImageEntry
    let isPulling: Bool
    let disabled: Bool
    let onPull: () -> Void

    @State private var hovering: Bool = false

    /// True when the row should respond to taps. Pending (placeholder
    /// SHA) rows still fire onPull, which surfaces the "not yet
    /// published" alert — clicking a COMING SOON entry should give
    /// feedback, not silently do nothing. Rows are inert when another
    /// pull is in flight (disabled) or this row is already pulling.
    private var tappable: Bool { !isPulling && !disabled }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            glyph
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(entry.id)
                        .font(LuminaTheme.title)
                        .foregroundStyle(LuminaTheme.ink)
                    if hasPlaceholderSHA {
                        Text("COMING SOON")
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(1.5)
                            .foregroundStyle(LuminaTheme.inkDim)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .overlay(Rectangle().stroke(LuminaTheme.rule2, lineWidth: 1))
                    } else {
                        Text("CATALOG")
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(1.5)
                            .foregroundStyle(LuminaTheme.accent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .overlay(Rectangle().stroke(LuminaTheme.accent, lineWidth: 1))
                    }
                }
                Text(entry.displayName)
                    .font(LuminaTheme.caption)
                    .foregroundStyle(LuminaTheme.inkDim)
                Text(entry.summary)
                    .font(LuminaTheme.caption)
                    .foregroundStyle(LuminaTheme.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text("~\(formatMB(entry.approximateSize))")
                        .font(LuminaTheme.caption)
                        .foregroundStyle(LuminaTheme.inkMute)
                    if !entry.tags.isEmpty {
                        Text("·")
                            .font(LuminaTheme.caption)
                            .foregroundStyle(LuminaTheme.inkMute)
                        Text(entry.tags.joined(separator: ", "))
                            .font(LuminaTheme.caption)
                            .foregroundStyle(LuminaTheme.inkMute)
                    }
                }
            }
            Spacer()
            pullButton
        }
        .padding(14)
        .background(hovering && tappable ? LuminaTheme.bg1.opacity(0.85) : LuminaTheme.bg1)
        .overlay(Rectangle().stroke(
            hovering && tappable ? LuminaTheme.accent.opacity(0.5) : LuminaTheme.rule,
            lineWidth: 1
        ))
        .opacity(disabled ? 0.5 : 1.0)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .onTapGesture {
            if tappable { onPull() }
        }
        .help(tappable
              ? (hasPlaceholderSHA ? "Click — placeholder build, will surface publish status"
                                   : "Click to pull \(entry.displayName)")
              : "")
    }

    private var hasPlaceholderSHA: Bool {
        entry.sha256.lowercased() == String(repeating: "0", count: 64)
    }

    private var glyph: some View {
        Image(systemName: hasPlaceholderSHA ? "cloud" : "cloud.fill")
            .font(.system(size: 26, weight: .light))
            .foregroundStyle(LuminaTheme.accent.opacity(hasPlaceholderSHA ? 0.4 : 1.0))
            .frame(width: 40, height: 40)
            .background(LuminaTheme.bg2)
            .overlay(Rectangle().stroke(LuminaTheme.rule, lineWidth: 1))
    }

    private var pullButton: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if isPulling {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Pulling…")
                        .font(LuminaTheme.caption)
                        .foregroundStyle(LuminaTheme.inkDim)
                }
            } else {
                Button {
                    onPull()
                } label: {
                    Label(hasPlaceholderSHA ? "Pending" : "Pull",
                          systemImage: hasPlaceholderSHA ? "clock" : "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(disabled)
            }
        }
    }

    private func formatMB(_ bytes: Int64) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024)
        }
        return String(format: "%.0f MB", mb)
    }
}

// MARK: - Grid cards (parity with VMCard/VMGridView)

/// Grid-layout card for an installed agent image. Visual weight
/// matches VMCard so the agent-images grid reads as a peer of the
/// VM library grid, not a second-class list. Primary action = open
/// in terminal; hover reveals the action button alongside the
/// always-visible badge + size footer.
@MainActor
private struct ImageCard: View {
    let entry: CustomImageEntry
    let onRemove: () -> Void
    let onLaunchOutcome: (TerminalLaunchOutcome) -> Void

    @State private var hovering: Bool = false
    @State private var copiedFlash: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            // Accent stripe — parity with VMCard's OS brand stripe.
            Rectangle()
                .fill(LuminaTheme.accent)
                .frame(width: 4)
                .shadow(color: hovering ? LuminaTheme.accent.opacity(0.4) : .clear,
                        radius: hovering ? 4 : 0)
            VStack(alignment: .leading, spacing: 10) {
                // Header: name + badge
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LuminaTheme.ink)
                        .lineLimit(1)
                    Spacer()
                    badge
                }
                // Kind chip — distinguishes installed agent image from
                // the VM library's OS brand. Not distro-specific (agent
                // images are all Alpine-derived today) so a generic
                // "AGENT IMAGE" pill with the shippingbox glyph.
                HStack(spacing: 6) {
                    Image(systemName: entry.isBaseline ? "cube" : "shippingbox.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.black)
                    Text("AGENT IMAGE")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(1.5)
                        .foregroundStyle(Color.black)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(LuminaTheme.accent))
                // Metadata block — same density as VMStatePreview so
                // the grid rows align vertically across sections.
                VStack(alignment: .leading, spacing: 4) {
                    if let meta = entry.meta {
                        Text("› from   \(meta.base ?? "unknown")")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(LuminaTheme.inkDim)
                            .lineLimit(1)
                        Text("› built  \(meta.created.formatted(date: .abbreviated, time: .omitted))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(LuminaTheme.inkDim)
                            .lineLimit(1)
                        if let cmd = meta.command, !cmd.isEmpty {
                            Text("› run    \(cmd)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(LuminaTheme.inkDim)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    } else if entry.isBaseline {
                        Text("› pristine baseline image")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(LuminaTheme.inkDim)
                    }
                    Text("› disk   \(formatBytes(entry.sizeOnDisk))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(LuminaTheme.inkDim)
                        .lineLimit(1)
                }
                HStack {
                    Text("alpine-arm64")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .tracking(0.4)
                        .textCase(.uppercase)
                        .foregroundStyle(LuminaTheme.inkMute)
                    Spacer()
                    if hovering {
                        terminalButton
                            .transition(.opacity.combined(with: .move(edge: .trailing)))
                    }
                }
                .animation(.easeOut(duration: 0.15), value: hovering)
            }
            .padding(14)
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(LuminaTheme.bg1.opacity(hovering ? 0.82 : 0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(hovering ? LuminaTheme.accent.opacity(0.7) : LuminaTheme.rule,
                        lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .animation(.easeOut(duration: 0.14), value: hovering)
        .onHover { hovering = $0 }
        .onTapGesture { openInTerminal() }
        .help("Click to open `lumina session start --image \(entry.name)` in Terminal")
        .contextMenu {
            Button("Open in Terminal") { openInTerminal() }
            Button("Copy `lumina run` command") { copyRunCommand() }
            if !entry.isBaseline {
                Divider()
                Button("Remove", role: .destructive) { onRemove() }
            }
        }
    }

    @ViewBuilder
    private var badge: some View {
        if entry.isBaseline {
            Text("BASELINE")
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(LuminaTheme.inkDim)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .overlay(Rectangle().stroke(LuminaTheme.rule2, lineWidth: 1))
        } else if entry.meta?.rosetta == true {
            Text("ROSETTA")
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(LuminaTheme.accent)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .overlay(Rectangle().stroke(LuminaTheme.accent, lineWidth: 1))
        }
    }

    private var terminalButton: some View {
        Button {
            openInTerminal()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "terminal")
                    .font(.system(size: 11, weight: .semibold))
                Text("OPEN")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(0.5)
            }
            .foregroundStyle(LuminaTheme.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(LuminaTheme.accent.opacity(0.1)))
            .overlay(Capsule().stroke(LuminaTheme.accent.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Open `lumina session start --image \(entry.name)` in Terminal")
    }

    private func copyRunCommand() {
        let cmd = "lumina run --image \(entry.name) 'uname -a'"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
        copiedFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copiedFlash = false }
    }

    private func openInTerminal() {
        let cmd = "lumina session start --image \(entry.name)"
        let outcome = TerminalLauncher().launch(command: cmd)
        onLaunchOutcome(outcome)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

/// Grid-layout card for an uninstalled catalog entry. Visual parity
/// with ImageCard — same dimensions, same hover + tap-to-primary-
/// action pattern. Primary action = pull (or surface the "not yet
/// published" alert for placeholder-SHA rows).
@MainActor
private struct CatalogCard: View {
    let entry: AgentImageEntry
    let isPulling: Bool
    let disabled: Bool
    let onPull: () -> Void

    @State private var hovering: Bool = false

    private var tappable: Bool { !isPulling && !disabled }

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(hasPlaceholderSHA ? LuminaTheme.inkMute : LuminaTheme.accent)
                .frame(width: 4)
                .shadow(color: hovering && tappable ? LuminaTheme.accent.opacity(0.4) : .clear,
                        radius: hovering && tappable ? 4 : 0)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.id)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LuminaTheme.ink)
                        .lineLimit(1)
                    Spacer()
                    badge
                }
                HStack(spacing: 6) {
                    Image(systemName: hasPlaceholderSHA ? "cloud" : "cloud.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.black)
                    Text("CATALOG")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(1.5)
                        .foregroundStyle(Color.black)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(LuminaTheme.accent.opacity(hasPlaceholderSHA ? 0.4 : 1.0)))
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.displayName)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(LuminaTheme.inkDim)
                        .lineLimit(1)
                    Text(entry.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(LuminaTheme.ink)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("› size   ~\(formatMB(entry.approximateSize))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(LuminaTheme.inkDim)
                }
                HStack {
                    if !entry.tags.isEmpty {
                        Text(entry.tags.joined(separator: " · "))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .tracking(0.4)
                            .textCase(.uppercase)
                            .foregroundStyle(LuminaTheme.inkMute)
                            .lineLimit(1)
                    }
                    Spacer()
                    pullFooter
                }
            }
            .padding(14)
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(LuminaTheme.bg1.opacity(hovering && tappable ? 0.82 : 0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(hovering && tappable ? LuminaTheme.accent.opacity(0.7) : LuminaTheme.rule,
                        lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .opacity(disabled ? 0.5 : 1.0)
        .animation(.easeOut(duration: 0.14), value: hovering)
        .onHover { hovering = $0 }
        .onTapGesture {
            if tappable { onPull() }
        }
        .help(tappable
              ? (hasPlaceholderSHA ? "Click — placeholder build, will surface publish status"
                                   : "Click to pull \(entry.displayName)")
              : "")
    }

    @ViewBuilder
    private var badge: some View {
        if hasPlaceholderSHA {
            Text("COMING SOON")
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(LuminaTheme.inkDim)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .overlay(Rectangle().stroke(LuminaTheme.rule2, lineWidth: 1))
        }
    }

    @ViewBuilder
    private var pullFooter: some View {
        if isPulling {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Pulling…")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .tracking(0.5)
                    .foregroundStyle(LuminaTheme.inkDim)
            }
        } else if hovering && tappable {
            HStack(spacing: 5) {
                Image(systemName: hasPlaceholderSHA ? "clock" : "arrow.down.circle")
                    .font(.system(size: 11, weight: .semibold))
                Text(hasPlaceholderSHA ? "PENDING" : "PULL")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(0.5)
            }
            .foregroundStyle(LuminaTheme.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(LuminaTheme.accent.opacity(0.1)))
            .overlay(Capsule().stroke(LuminaTheme.accent.opacity(0.5), lineWidth: 1))
            .transition(.opacity)
        }
    }

    private var hasPlaceholderSHA: Bool {
        entry.sha256.lowercased() == String(repeating: "0", count: 64)
    }

    private func formatMB(_ bytes: Int64) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        return String(format: "%.0f MB", mb)
    }
}

// MARK: - FileManager helper

extension FileManager {
    /// Recursive allocated size of a directory. Uses resourceValues
    /// so we count actual disk usage (after APFS COW dedup), not
    /// logical file sizes — `default-legacy` et al. are mostly
    /// symlinks back into `default` and should read as ~0.
    func allocatedSizeOfDirectory(at url: URL) throws -> Int64 {
        var total: Int64 = 0
        guard let enumerator = enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey, .isSymbolicLinkKey]
            )
            if values.isSymbolicLink == true { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
