// Sources/LuminaDesktopKit/HostStatusRibbon.swift
//
// Top-of-detail metric strip. Surfaces the host/guest contract:
// hardware, available memory, free disk under ~/.lumina, total VMs,
// disk used across bundles, running count. Victor's "make the
// invisible visible" applied to the library chrome.

import SwiftUI

@MainActor
public struct HostStatusRibbon: View {
    @Bindable var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        let host = HostInfo.current
        let freeDisk = HostInfo.freeDiskBytes(at: model.store.rootURL) ?? 0
        let running = model.sessions.values.filter { $0.status.isLive }.count
        let totalUsed = model.bundles.reduce(0) { $0 + $1.actualDiskBytes }

        HStack(spacing: 16) {
            metric(label: "HOST", value: host.modelName.uppercased())
            divider
            metric(label: "RAM", value: formatBytesHuman(host.physicalMemoryBytes))
            metric(label: "CORES", value: "\(host.processorCount)")
            metric(label: "LIBRARY FREE", value: formatBytesHuman(freeDisk),
                   warn: freeDisk < 16 * 1024 * 1024 * 1024)
            divider
            metric(label: "VMS", value: "\(model.bundles.count)")
            metric(label: "USED", value: formatBytesHuman(totalUsed))
            metric(label: "RUNNING", value: "\(running)",
                   accent: running > 0 ? LuminaTheme.ok : LuminaTheme.inkDim)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(
            Rectangle().fill(LuminaTheme.bg2.opacity(0.5))
        )
        .overlay(
            Rectangle().fill(LuminaTheme.rule).frame(height: 1),
            alignment: .bottom
        )
    }

    @ViewBuilder
    private func metric(label: String, value: String,
                        accent: Color = LuminaTheme.ink,
                        warn: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(LuminaTheme.inkMute)
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(warn ? LuminaTheme.warn : accent)
                .monospacedDigit()
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(LuminaTheme.rule2)
            .frame(width: 1, height: 14)
    }
}
