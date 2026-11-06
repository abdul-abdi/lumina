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
                } else if images.isEmpty {
                    emptyState
                } else {
                    installedList
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

    /// Same column spec as VMGridView for visual parity with the main
    /// library. Adaptive so agent images tile symmetrically with VMs
    /// when the window is resized.
    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 300, maximum: 380), spacing: 14)]
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

// MARK: - Shared row/card helpers

/// Bytes-on-disk display for installed images. Shared by ImageRow and ImageCard.
private func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}

/// Copies the disposable-run command to the pasteboard and flashes
/// `copiedFlash` true then false. Shared by ImageRow and ImageCard.
private func copyRunCommand(imageName: String, copiedFlash: Binding<Bool>) {
    let cmd = "lumina run --image \(imageName) 'uname -a'"
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(cmd, forType: .string)
    copiedFlash.wrappedValue = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
        copiedFlash.wrappedValue = false
    }
}

/// Opens `lumina session start --image <name>` via TerminalLauncher and
/// surfaces the outcome through the caller's alert callback. Shared by
/// ImageRow and ImageCard.
private func openInTerminal(imageName: String, onLaunchOutcome: (TerminalLaunchOutcome) -> Void) {
    let cmd = "lumina session start --image \(imageName)"
    let outcome = TerminalLauncher().launch(command: cmd)
    onLaunchOutcome(outcome)
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
        .onTapGesture { openInTerminal(imageName: entry.name, onLaunchOutcome: onLaunchOutcome) }
        .help("Click to open `lumina session start --image \(entry.name)` in Terminal")
        .contextMenu {
            Button("Open in Terminal") { openInTerminal(imageName: entry.name, onLaunchOutcome: onLaunchOutcome) }
            Button("Copy `lumina run` command") { copyRunCommand(imageName: entry.name, copiedFlash: $copiedFlash) }
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
                copyRunCommand(imageName: entry.name, copiedFlash: $copiedFlash)
            } label: {
                Label(copiedFlash ? "Copied" : "Copy `run`",
                      systemImage: copiedFlash ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                openInTerminal(imageName: entry.name, onLaunchOutcome: onLaunchOutcome)
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
        .onTapGesture { openInTerminal(imageName: entry.name, onLaunchOutcome: onLaunchOutcome) }
        .help("Click to open `lumina session start --image \(entry.name)` in Terminal")
        .contextMenu {
            Button("Open in Terminal") { openInTerminal(imageName: entry.name, onLaunchOutcome: onLaunchOutcome) }
            Button("Copy `lumina run` command") { copyRunCommand(imageName: entry.name, copiedFlash: $copiedFlash) }
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
            openInTerminal(imageName: entry.name, onLaunchOutcome: onLaunchOutcome)
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
