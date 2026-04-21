// Sources/LuminaDesktopKit/CommandLauncher.swift
//
// v0.7.0 M6 — ⌘K fuzzy launcher. Type a VM name or a command, hit Enter,
// it runs. This is what makes Lumina feel faster than anything else in
// the VM space: no clicks, no navigation, no wizard for existing VMs.
// You think "ubuntu", you press Enter, the VM boots.

import SwiftUI
import AppKit
import LuminaBootable

@MainActor
public struct CommandLauncher: View {
    @Bindable var model: AppModel
    @Binding var isPresented: Bool
    @Environment(\.openWindow) private var openWindow
    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @FocusState private var searchFocused: Bool

    public init(model: AppModel, isPresented: Binding<Bool>) {
        self.model = model
        self._isPresented = isPresented
    }

    public var body: some View {
        VStack(spacing: 0) {
            queryField
            if !matches.isEmpty {
                Rectangle().fill(LuminaTheme.rule).frame(height: 1)
                resultList
            }
            Rectangle().fill(LuminaTheme.rule).frame(height: 1)
            footer
        }
        .frame(width: 540)
        .frame(maxHeight: 480)
        .background(LuminaTheme.bg1)
        .overlay(Rectangle().stroke(LuminaTheme.rule, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.35), radius: 30, y: 10)
        .onAppear { searchFocused = true }
        .onKeyPress(.escape) {
            isPresented = false
            return .handled
        }
        .onKeyPress(.upArrow) {
            selectedIndex = max(0, selectedIndex - 1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            selectedIndex = min(matches.count - 1, selectedIndex + 1)
            return .handled
        }
        .onKeyPress(.return) {
            runSelected()
            return .handled
        }
    }

    // ── ROWS ──────────────────────────────────────────────────────

    private var queryField: some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(LuminaTheme.accent)
            TextField("Type a VM name, or “new”, or a command…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(LuminaTheme.ink)
                .focused($searchFocused)
                .onChange(of: query) { _, _ in selectedIndex = 0 }

            Text("⌘K")
                .font(LuminaTheme.label).tracking(1.5)
                .foregroundStyle(LuminaTheme.inkMute)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .overlay(Rectangle().stroke(LuminaTheme.rule2, lineWidth: 1))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var resultList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(matches.enumerated()), id: \.offset) { index, match in
                    CommandRow(match: match, selected: index == selectedIndex)
                        .contentShape(Rectangle())
                        .onTapGesture { runMatch(match) }
                        .onHover { h in if h { selectedIndex = index } }
                }
            }
        }
        .frame(maxHeight: 360)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            footerKey("↑ ↓", "navigate")
            footerKey("↵", "run")
            footerKey("esc", "dismiss")
            Spacer()
            Text("\(matches.count) result\(matches.count == 1 ? "" : "s")")
                .font(LuminaTheme.label).tracking(1.2)
                .foregroundStyle(LuminaTheme.inkMute)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(LuminaTheme.bg2.opacity(0.5))
    }

    private func footerKey(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(LuminaTheme.inkDim)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .overlay(Rectangle().stroke(LuminaTheme.rule2, lineWidth: 1))
            Text(label)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(LuminaTheme.inkMute)
        }
    }

    // ── MATCH / ACTION ────────────────────────────────────────────

    /// Canonical match — either a known VM, a verb action, or a tile.
    enum Match: Identifiable, Equatable {
        case vm(VMBundle, VMVerb)
        case newVM(tileID: String, label: String)
        case reveal(VMBundle)
        case delete(VMBundle)

        enum VMVerb: Equatable { case boot, stop, open }

        var id: String {
            switch self {
            case .vm(let b, let v): "vm:\(b.manifest.id):\(v)"
            case .newVM(let t, _): "new:\(t)"
            case .reveal(let b): "reveal:\(b.manifest.id)"
            case .delete(let b): "del:\(b.manifest.id)"
            }
        }

        var glyph: String {
            switch self {
            case .vm(_, .boot): "play.fill"
            case .vm(_, .stop): "stop.fill"
            case .vm(_, .open): "arrow.up.right.square"
            case .newVM: "plus.rectangle"
            case .reveal: "folder"
            case .delete: "trash"
            }
        }

        var iconTint: Color {
            switch self {
            case .vm(_, .boot), .newVM: LuminaTheme.accent
            case .vm(_, .stop), .delete: LuminaTheme.err
            default: LuminaTheme.inkDim
            }
        }

        var primary: String {
            switch self {
            case .vm(let b, .boot): "Boot \(b.manifest.name)"
            case .vm(let b, .stop): "Stop \(b.manifest.name)"
            case .vm(let b, .open): "Open \(b.manifest.name)"
            case .newVM(_, let label): "New: \(label)"
            case .reveal(let b): "Reveal \(b.manifest.name) in Finder"
            case .delete(let b): "Move \(b.manifest.name) to Trash"
            }
        }

        var secondary: String {
            switch self {
            case .vm(let b, _): "\(b.manifest.osVariant) · \(b.lastBootedRelative)"
            case .newVM: "launch the New VM wizard"
            case .reveal: "open the bundle in Finder"
            case .delete: "move to Trash (recover in Finder)"
            }
        }
    }

    private var matches: [Match] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let verbHit = q.split(separator: " ").first.map(String.init) ?? ""

        // Base match set
        var out: [Match] = []

        // VM matches (always show if query matches name/variant)
        for bundle in model.bundles {
            if q.isEmpty || bundle.manifest.name.lowercased().contains(q)
                || bundle.manifest.osVariant.lowercased().contains(q) {
                let session = model.session(for: bundle)
                if session.status.isLive {
                    out.append(.vm(bundle, .stop))
                    out.append(.vm(bundle, .open))
                } else {
                    out.append(.vm(bundle, .boot))
                    out.append(.vm(bundle, .open))
                }
            }
        }

        // "new" / "create" → wizard entries
        if q.isEmpty || "new".hasPrefix(verbHit) || "create".hasPrefix(verbHit)
            || q.contains("ubuntu") || q.contains("kali") || q.contains("fedora")
            || q.contains("debian") || q.contains("windows") || q.contains("mac") {
            out.append(.newVM(tileID: "ubuntu-24.04", label: "Ubuntu 24.04 LTS"))
            out.append(.newVM(tileID: "kali-rolling", label: "Kali (rolling)"))
            out.append(.newVM(tileID: "fedora-42", label: "Fedora 42"))
            out.append(.newVM(tileID: "debian-12", label: "Debian 12"))
            out.append(.newVM(tileID: "windows-11-arm", label: "Windows 11 on ARM"))
            out.append(.newVM(tileID: "macos-latest", label: "macOS"))
            out.append(.newVM(tileID: "byo-file", label: "From ISO / IPSW file…"))
        }

        // Admin actions — show if user types "reveal" / "delete"
        if q.hasPrefix("reveal") || q.hasPrefix("show") {
            for b in model.bundles { out.append(.reveal(b)) }
        }
        if q.hasPrefix("delete") || q.hasPrefix("trash") {
            for b in model.bundles { out.append(.delete(b)) }
        }

        // Dedupe + cap
        var seen = Set<String>()
        return out.filter { seen.insert($0.id).inserted }.prefix(12).map { $0 }
    }

    private func runSelected() {
        guard selectedIndex < matches.count else { return }
        runMatch(matches[selectedIndex])
    }

    private func runMatch(_ match: Match) {
        isPresented = false
        switch match {
        case .vm(let bundle, .boot):
            Task { await model.session(for: bundle).boot() }
            openWindow(id: "vm-window", value: bundle.manifest.id)
        case .vm(let bundle, .stop):
            Task { await model.session(for: bundle).shutdown() }
        case .vm(let bundle, .open):
            openWindow(id: "vm-window", value: bundle.manifest.id)
        case .newVM(let tileID, _):
            // Signal to LibraryView to open wizard with this tile preselected.
            NotificationCenter.default.post(
                name: .luminaLauncherOpenWizard,
                object: tileID
            )
        case .reveal(let bundle):
            NSWorkspace.shared.activateFileViewerSelecting([bundle.rootURL])
        case .delete(let bundle):
            model.deleteBundle(bundle)
        }
    }
}

@MainActor
struct CommandRow: View {
    let match: CommandLauncher.Match
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: match.glyph)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(match.iconTint)
                .frame(width: 22, height: 22)
                .background(
                    Rectangle()
                        .fill(match.iconTint.opacity(selected ? 0.15 : 0.08))
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(match.primary)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(LuminaTheme.ink)
                Text(match.secondary)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(LuminaTheme.inkMute)
            }
            Spacer()
            if selected {
                Text("↵")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(LuminaTheme.accent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(selected ? LuminaTheme.accent.opacity(0.1) : Color.clear)
    }
}

public extension Notification.Name {
    static let luminaLauncherOpenWizard = Notification.Name("LuminaLauncherOpenWizard")
}
