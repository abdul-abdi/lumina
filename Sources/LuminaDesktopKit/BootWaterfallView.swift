// Design constraints:
//   - Dependency-free (no Charts, no SwiftUI-charts-import). The
//     whole view is GeometryReader + Rectangle + Text. Keeps the
//     module buildable on every macOS version the rest of
//     LuminaDesktopKit targets.
//   - Gate on `BootPhases.isValid` so we never render a row of 0 ms
//     phases for a freshly-stopped VM.
//   - Phases render in boot order, matching `formatTrace()`. EFI-
//     path zeros are elided — an EFI guest's waterfall is 3 bars,
//     not 7 with half of them empty.

import SwiftUI
import Lumina

public struct BootWaterfallView: View {
    private let phases: BootPhases

    public init(phases: BootPhases) {
        self.phases = phases
    }

    public var body: some View {
        if phases.isValid {
            VStack(alignment: .leading, spacing: 4) {
                header
                ForEach(rows, id: \.label) { row in
                    BootPhaseRow(
                        label: row.label,
                        ms: row.ms,
                        fraction: phases.totalMs > 0 ? row.ms / max(phases.totalMs, 1) : 0,
                        accent: row.accent
                    )
                }
                if !phases.networkStage.isEmpty {
                    Text("network stage: \(phases.networkStage)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospaced()
                        .padding(.top, 2)
                }
            }
            .padding(10)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        } else {
            EmptyView()
        }
    }

    private var header: some View {
        HStack {
            Text("Boot trace")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            Spacer()
            Text(formatMs(phases.totalMs))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
    }

    /// `internal` (not `private`) so tests can assert filtering +
    /// ordering without going through SwiftUI rendering.
    var rows: [BootPhaseRow.Row] {
        let all: [BootPhaseRow.Row] = [
            .init(label: "image resolve", ms: phases.imageResolveMs, accent: .blue),
            .init(label: "disk clone", ms: phases.cloneMs, accent: .purple),
            .init(label: "config build", ms: phases.configMs, accent: .pink),
            .init(label: "vz start", ms: phases.vzStartMs, accent: .orange),
            .init(label: "vsock connect", ms: phases.vsockConnectMs, accent: .yellow),
            .init(label: "guest agent ready", ms: phases.runnerReadyMs, accent: .green),
            .init(label: "guest network", ms: phases.networkConfigMs, accent: .mint),
        ]
        return all.filter { $0.ms > 0 }
    }
}

struct BootPhaseRow: View {
    struct Row: Equatable {
        let label: String
        let ms: Double
        let accent: Color
    }

    let label: String
    let ms: Double
    let fraction: Double
    let accent: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .monospaced()
                .frame(width: 130, alignment: .leading)
                .foregroundStyle(.primary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(accent.opacity(0.15))
                        .frame(height: 10)
                    Rectangle()
                        .fill(accent)
                        .frame(
                            width: max(2, geo.size.width * min(max(fraction, 0), 1)),
                            height: 10
                        )
                }
                .clipShape(RoundedRectangle(cornerRadius: 2))
            }
            .frame(height: 10)
            Text(formatMs(ms))
                .font(.caption)
                .monospacedDigit()
                .frame(width: 60, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
    }
}

private func formatMs(_ ms: Double) -> String {
    String(format: "%.1f ms", ms)
}
