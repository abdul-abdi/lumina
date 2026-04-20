// Sources/LuminaDesktopKit/LibraryView.swift
//
// v0.7.0 M6 — main app window matching lumina.run's phosphor-amber aesthetic.
// Sharp corners, hairline rules, mono type, dashed sub-dividers.

import SwiftUI
import LuminaBootable

@MainActor
public struct LibraryView: View {
    @Bindable public var model: AppModel
    @State private var showingWizard = false
    @State private var hoverID: UUID?

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        ZStack {
            LuminaTheme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                metaStrip
                Divider().background(LuminaTheme.rule).frame(height: 1)
                content
            }
        }
        .preferredColorScheme(.dark)
        .frame(minWidth: 980, minHeight: 600)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                BrandMark()
            }
            ToolbarItem(placement: .principal) {
                LuminaSearchField(text: $model.search)
            }
            ToolbarItem(placement: .primaryAction) {
                LuminaPrimaryButton(label: "+ NEW VM", systemImage: nil) {
                    showingWizard = true
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .sheet(isPresented: $showingWizard) {
            NewVMWizard(model: model, isPresented: $showingWizard)
        }
    }

    private var metaStrip: some View {
        HStack(spacing: 24) {
            metaItem(label: "LUMINA", value: "DESKTOP")
            metaItem(label: "VMS", value: "\(model.bundles.count)")
            metaItem(label: "RUNNING", value: "\(model.sessions.values.filter { $0.status.isLive }.count)")
            Spacer()
            statusDotView
            Text("v0.7.0 · stable")
                .font(LuminaTheme.label)
                .tracking(1)
                .textCase(.uppercase)
                .foregroundStyle(LuminaTheme.inkDim)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(LuminaTheme.bg)
    }

    private func metaItem(label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(LuminaTheme.inkMute)
            Text(value).foregroundStyle(LuminaTheme.inkDim).fontWeight(.medium)
        }
        .font(LuminaTheme.label)
        .tracking(1.5)
        .textCase(.uppercase)
    }

    private var statusDotView: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(LuminaTheme.ok)
                .frame(width: 6, height: 6)
            Text("LIVE")
                .font(LuminaTheme.label)
                .tracking(1.5)
                .foregroundStyle(LuminaTheme.inkDim)
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.bundles.isEmpty {
            EmptyStateView(showingWizard: $showingWizard)
        } else {
            VMGridView(model: model, hoverID: $hoverID)
        }
    }
}

@MainActor
public struct BrandMark: View {
    public init() {}
    public var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Rectangle()
                    .stroke(LuminaTheme.accent, lineWidth: 1)
                    .frame(width: 14, height: 14)
                Rectangle()
                    .stroke(LuminaTheme.ink.opacity(0.5), lineWidth: 1)
                    .frame(width: 14, height: 14)
                    .offset(x: 3, y: 3)
            }
            .frame(width: 18, height: 18)
            HStack(spacing: 0) {
                Text("lumina")
                    .foregroundStyle(LuminaTheme.ink)
                Text(".run")
                    .foregroundStyle(LuminaTheme.inkMute)
            }
            .font(LuminaTheme.headline)
        }
    }
}

@MainActor
public struct LuminaSearchField: View {
    @Binding var text: String
    public init(text: Binding<String>) { _text = text }
    public var body: some View {
        HStack(spacing: 6) {
            Text("$")
                .font(LuminaTheme.body)
                .foregroundStyle(LuminaTheme.accent)
            TextField("filter --name", text: $text)
                .textFieldStyle(.plain)
                .font(LuminaTheme.body)
                .foregroundStyle(LuminaTheme.ink)
                .frame(minWidth: 240)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(LuminaTheme.bg1)
        .overlay(Rectangle().stroke(LuminaTheme.rule2, lineWidth: 1))
    }
}

@MainActor
public struct LuminaPrimaryButton: View {
    let label: String
    let systemImage: String?
    let action: () -> Void
    @State private var hovering = false

    public init(label: String, systemImage: String? = nil, action: @escaping () -> Void) {
        self.label = label
        self.systemImage = systemImage
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let s = systemImage { Image(systemName: s) }
                Text(label)
                    .font(LuminaTheme.label)
                    .tracking(1.5)
            }
            .foregroundStyle(hovering ? LuminaTheme.bg : Color.black)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(hovering ? LuminaTheme.ink : LuminaTheme.accent)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

@MainActor
public struct EmptyStateView: View {
    @Binding var showingWizard: Bool

    public var body: some View {
        ZStack {
            LuminaTheme.bg
            VStack(alignment: .leading, spacing: 0) {
                kicker
                Text("subprocess.run()")
                    .font(LuminaTheme.hero)
                    .foregroundStyle(LuminaTheme.accent)
                    .tracking(-2)
                HStack(spacing: 8) {
                    Text("for")
                        .font(LuminaTheme.hero)
                        .foregroundStyle(LuminaTheme.ink)
                        .tracking(-2)
                    Text("virtual machines.")
                        .font(LuminaTheme.serifLargeItalic)
                        .foregroundStyle(LuminaTheme.inkDim)
                }
                .padding(.bottom, 24)

                Text("Boot any OS. Run it. Throw it away. v0.7.0 ships full-OS guests with a SwiftUI face — Linux, Windows 11 ARM, macOS, all from one Library.")
                    .font(.system(size: 14))
                    .foregroundStyle(LuminaTheme.inkDim)
                    .frame(maxWidth: 560, alignment: .leading)
                    .padding(.bottom, 32)

                actionRow

                Spacer().frame(height: 40)

                installLine
            }
            .frame(maxWidth: 740, alignment: .leading)
            .padding(.horizontal, 56)
            .padding(.vertical, 80)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var kicker: some View {
        HStack(spacing: 8) {
            Circle().fill(LuminaTheme.accent).frame(width: 6, height: 6)
            Text("§ 01 — WELCOME")
                .font(LuminaTheme.label)
                .tracking(2)
                .textCase(.uppercase)
        }
        .foregroundStyle(LuminaTheme.accent)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .overlay(Rectangle().stroke(LuminaTheme.accent, lineWidth: 1))
        .background(LuminaTheme.accent.opacity(0.06))
        .padding(.bottom, 28)
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            LuminaPrimaryButton(label: "TRY UBUNTU →") { showingWizard = true }
            QuickTileButton(label: "INSTALL WINDOWS 11", glyph: "macwindow") { showingWizard = true }
            QuickTileButton(label: "INSTALL macOS", glyph: "apple.logo") { showingWizard = true }
            QuickTileButton(label: "USE MY OWN ISO/IPSW…", glyph: "doc.badge.plus") { showingWizard = true }
        }
    }

    private var installLine: some View {
        HStack(spacing: 14) {
            Text("$").foregroundStyle(LuminaTheme.accent)
            Text("brew install lumina-run/tap/lumina")
                .foregroundStyle(LuminaTheme.ink)
            Spacer()
            Text("[ copy ]")
                .foregroundStyle(LuminaTheme.inkMute)
        }
        .font(LuminaTheme.body)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(LuminaTheme.bg1)
        .overlay(
            Rectangle()
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .foregroundStyle(LuminaTheme.rule2)
        )
        .frame(maxWidth: 560, alignment: .leading)
    }
}

@MainActor
public struct QuickTileButton: View {
    let label: String
    let glyph: String
    let action: () -> Void
    @State private var hovering = false

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: glyph)
                    .font(.system(size: 12))
                Text(label)
                    .font(LuminaTheme.label)
                    .tracking(1.5)
            }
            .foregroundStyle(hovering ? LuminaTheme.accent : LuminaTheme.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(LuminaTheme.bg1)
            .overlay(
                Rectangle()
                    .stroke(hovering ? LuminaTheme.accent : LuminaTheme.rule2, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

@MainActor
public struct VMGridView: View {
    @Bindable var model: AppModel
    @Binding var hoverID: UUID?

    private let columns = [GridItem(.adaptive(minimum: 260, maximum: 320), spacing: 0)]

    public var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 0) {
                ForEach(model.filteredBundles, id: \.manifest.id) { bundle in
                    VMCard(model: model, bundle: bundle, isHovering: hoverID == bundle.manifest.id)
                        .onHover { hovering in
                            hoverID = hovering ? bundle.manifest.id : nil
                        }
                        .onTapGesture {
                            model.selection = bundle.manifest.id
                            NotificationCenter.default.post(
                                name: .luminaOpenVMWindow,
                                object: bundle.manifest.id
                            )
                        }
                }
            }
            .background(LuminaTheme.rule)  // grid lines via parent bg + cell margins
        }
        .background(LuminaTheme.bg)
    }
}

@MainActor
public struct VMCard: View {
    @Bindable var model: AppModel
    let bundle: VMBundle
    let isHovering: Bool

    private var session: LuminaDesktopSession {
        model.session(for: bundle)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header strip with state + sid prefix
            HStack(spacing: 8) {
                statusDot
                Text(stateLabel)
                    .font(LuminaTheme.label)
                    .tracking(1.5)
                    .foregroundStyle(stateColor)
                Spacer()
                Text(bundle.manifest.id.uuidString.prefix(8).lowercased())
                    .font(LuminaTheme.monoTiny)
                    .foregroundStyle(LuminaTheme.inkMute)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(LuminaTheme.bg2)
            .overlay(Rectangle().fill(LuminaTheme.rule).frame(height: 1), alignment: .bottom)

            // Body
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: glyphForFamily(bundle.manifest.osFamily))
                        .font(.system(size: 14))
                        .foregroundStyle(LuminaTheme.osAccent(bundle.manifest.osFamily.rawValue))
                    Text(bundle.manifest.name)
                        .font(LuminaTheme.headline)
                        .foregroundStyle(LuminaTheme.ink)
                        .lineLimit(1)
                }
                .padding(.bottom, 2)

                Text(bundle.manifest.osVariant)
                    .font(LuminaTheme.caption)
                    .foregroundStyle(LuminaTheme.inkDim)

                Spacer().frame(height: 12)

                statRow("MEMORY", formatGB(bundle.manifest.memoryBytes))
                statRow("CPUS", "\(bundle.manifest.cpuCount)")
                statRow("DISK", formatGB(bundle.manifest.diskBytes))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 16)
        }
        .background(isHovering ? LuminaTheme.bg1 : LuminaTheme.bg)
        .overlay(
            Rectangle()
                .stroke(isHovering ? LuminaTheme.accent.opacity(0.6) : LuminaTheme.rule, lineWidth: 1)
        )
        .padding(.trailing, 1)
        .padding(.bottom, 1)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Open") {
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
            .fill(stateColor)
            .frame(width: 6, height: 6)
            .shadow(color: session.status == .running ? stateColor.opacity(0.6) : .clear, radius: 4)
    }

    private var stateColor: Color {
        switch session.status {
        case .running: LuminaTheme.ok
        case .booting, .shuttingDown: LuminaTheme.warn
        case .crashed: LuminaTheme.err
        case .paused: LuminaTheme.warn
        case .stopped: LuminaTheme.inkMute
        }
    }

    private var stateLabel: String {
        switch session.status {
        case .running: "RUNNING"
        case .booting: "BOOTING"
        case .paused: "PAUSED"
        case .crashed: "CRASHED"
        case .shuttingDown: "STOPPING"
        case .stopped: "IDLE"
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(LuminaTheme.label)
                .tracking(1.5)
                .foregroundStyle(LuminaTheme.inkMute)
            Spacer()
            Text(value)
                .font(LuminaTheme.caption)
                .foregroundStyle(LuminaTheme.inkDim)
                .monospacedDigit()
        }
        .padding(.vertical, 3)
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
    static let luminaOpenVMWindow = Notification.Name("LuminaOpenVMWindow")
}
