// Sources/LuminaDesktopKit/VMListView.swift
//
// Dense-row library layout — Activity Monitor / `lumina ps` feel.
// Columns: name + OS variant, state chip, last boot, disk usage,
// snapshot count, action. The working view when you have many VMs
// and need to scan them at once. Extracted from LibraryView.swift.

import SwiftUI
import LuminaBootable

@MainActor
public struct VMListView: View {
    @Bindable var model: AppModel
    let bundles: [VMBundle]
    @Environment(\.openWindow) private var openWindow

    public init(model: AppModel, bundles: [VMBundle]) {
        self.model = model
        self.bundles = bundles
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 4) {
                // Column header — dense like Activity Monitor / Linear / `lumina ps`
                HStack(spacing: 12) {
                    columnHeader("NAME", width: nil, align: .leading)
                    columnHeader("STATE", width: 80)
                    columnHeader("LAST BOOT", width: 100)
                    columnHeader("DISK", width: 120)
                    columnHeader("SNAPS", width: 50)
                    columnHeader("", width: 72)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    Rectangle().fill(LuminaTheme.bg2.opacity(0.5))
                )
                .overlay(
                    Rectangle().fill(LuminaTheme.rule).frame(height: 1),
                    alignment: .bottom
                )

                LazyVStack(spacing: 1) {
                    ForEach(bundles, id: \.manifest.id) { bundle in
                        VMRow(model: model, bundle: bundle)
                            .onTapGesture {
                                openWindow(id: "vm-window", value: bundle.manifest.id)
                            }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
    }

    private func columnHeader(_ label: String, width: CGFloat?, align: Alignment = .leading) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .tracking(1.2)
            .foregroundStyle(LuminaTheme.inkMute)
            .frame(width: width, alignment: align)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: align)
    }
}

@MainActor
public struct VMRow: View {
    @Bindable var model: AppModel
    let bundle: VMBundle
    @Environment(\.openWindow) private var openWindow
    @State private var isHovering = false
    @State private var stats: VMLiveStats

    public init(model: AppModel, bundle: VMBundle) {
        self.model = model
        self.bundle = bundle
        _stats = State(initialValue: VMLiveStats(bundle: bundle))
    }

    private var session: LuminaDesktopSession {
        model.session(for: bundle)
    }

    public var body: some View {
        let brand = OSBranding.brand(for: bundle.manifest.osVariant,
                                     family: bundle.manifest.osFamily)
        HStack(spacing: 0) {
            Rectangle()
                .fill(brand.accent)
                .frame(width: 3)
                .frame(maxHeight: 44)
            HStack(spacing: 12) {
                // NAME + live heartbeat when running + distro glyph
                HStack(spacing: 10) {
                    Image(systemName: brand.glyph)
                        .font(.system(size: 14))
                        .foregroundStyle(brand.accent)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            if session.status == .running {
                                Heartbeat(color: LuminaTheme.ok)
                            }
                            Text(bundle.manifest.name)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(LuminaTheme.ink)
                                .lineLimit(1)
                        }
                        Text(bundle.manifest.osVariant)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(LuminaTheme.inkMute)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // STATE
                HStack {
                    StateChip(status: session.status)
                    Spacer()
                }
                .frame(width: 80)

                // LAST BOOT
                Text(bundle.lastBootedRelative)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(LuminaTheme.inkDim)
                    .frame(width: 100, alignment: .leading)

                // DISK — text + live sparkline (per-OS brand accent).
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(bundle.diskUsedFormatted) / \(bundle.diskCapFormatted)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(LuminaTheme.inkDim)
                        .monospacedDigit()
                    DiskSparkline(stats: stats,
                                  tint: brand.accent,
                                  running: session.status == .running)
                        .frame(height: 12)
                }
                .frame(width: 120, alignment: .leading)

                // SNAPS
                Text("\(bundle.snapshotCount)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(LuminaTheme.inkDim)
                    .frame(width: 50, alignment: .leading)
                    .monospacedDigit()

                // ACTION (always visible in list — this is the working view)
                VMActionButton(session: session, compact: true)
                    .frame(width: 72, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .background(
            Rectangle()
                .fill(isHovering ? LuminaTheme.bg1.opacity(0.75) : Color.clear)
        )
        .overlay(
            Rectangle()
                .fill(LuminaTheme.rule2.opacity(0.5))
                .frame(height: 1),
            alignment: .bottom
        )
        .animation(.easeOut(duration: 0.08), value: isHovering)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Open") {
                openWindow(id: "vm-window", value: bundle.manifest.id)
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
}
