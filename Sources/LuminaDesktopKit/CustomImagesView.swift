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
// to v0.7.2+.

import SwiftUI
import Lumina

@MainActor
public struct CustomImagesView: View {
    @State private var images: [CustomImageEntry] = []
    @State private var error: String?

    public init() {}

    public var body: some View {
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
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MaterialBackground(material: .contentBackground))
        .onAppear { refresh() }
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

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(images, id: \.name) { img in
                    ImageRow(entry: img, onRemove: {
                        remove(img.name)
                    })
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
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

    @State private var copiedFlash: Bool = false

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
        .background(LuminaTheme.bg1)
        .overlay(Rectangle().stroke(LuminaTheme.rule, lineWidth: 1))
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
        // Open Terminal.app with `lumina session start --image <name>`
        // pre-filled. AppleScript is the least-fragile way — it handles
        // new-window-or-reuse, focus-front, and typing with proper
        // keyboard events. The command itself doesn't escape the image
        // name because ImageStore names are filesystem-safe by construction
        // (no spaces, no quotes).
        let cmd = "lumina session start --image \(entry.name)"
        let script = """
            tell application "Terminal"
                activate
                do script "\(cmd)"
            end tell
        """
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        try? task.run()
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
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
