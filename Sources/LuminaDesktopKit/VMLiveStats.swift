// Sources/LuminaDesktopKit/VMLiveStats.swift
//
// v0.7.0 M6 — cards display live stats (disk growth, running heartbeat)
// instead of static configuration labels. Per Victor's critique:
// representations should show behavior, not labels for behavior.
//
// We poll VMBundle.actualDiskBytes every 2s into a 60-sample ring buffer,
// then draw a path through the samples. The sparkline shows whether the
// guest is writing — a flat line means "asleep," a rising line means
// "actively installing or working," a spike means "snapshot just landed."
// This is information the static text can't convey.

import SwiftUI
import Combine
import LuminaBootable

@MainActor
@Observable
public final class VMLiveStats {
    public private(set) var samples: [UInt64] = []
    public private(set) var lastSampleAt: Date = .distantPast
    public private(set) var growthRate: Double = 0  // bytes per second, rolling 10s

    private let bundle: VMBundle
    private var timer: Timer?
    private let windowSize = 60  // 60 samples × 2s = 2min visible

    public init(bundle: VMBundle) {
        self.bundle = bundle
        start()
    }

    /// Start sampling. Idempotent.
    public func start() {
        guard timer == nil else { return }
        // Prime with a single sample so the view has something to draw.
        pushSample()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pushSample() }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }
    // `deinit { timer?.invalidate() }` would be belt-and-suspenders, but
    // reading main-actor-isolated `timer` from a nonisolated deinit needs
    // Swift 6.1's `isolated deinit` (SE-0371) which is still experimental on
    // GitHub macos-15 runners. Every call site already uses
    // `.onDisappear { stop() }`; the structural fix (move ownership to
    // AppModel, keyed by bundle.id, so timers never leak) is tracked by #11.

    private func pushSample() {
        let now = Date()
        let bytes = bundle.actualDiskBytes
        samples.append(bytes)
        if samples.count > windowSize { samples.removeFirst() }

        // Rolling 10-sample growth rate = (last - earliest in window) / elapsed.
        if samples.count >= 2 {
            let span = Double(min(5, samples.count - 1)) * 2.0  // samples are 2s apart
            let delta = Double(bytes) - Double(samples[max(0, samples.count - 1 - 5)])
            growthRate = span > 0 ? delta / span : 0
        }
        lastSampleAt = now
    }

    /// Normalised 0–1 samples scaled to the rolling max. Empty when
    /// fewer than 2 samples are present.
    public var normalised: [Double] {
        guard samples.count >= 2 else { return [] }
        let maxVal = max(samples.max() ?? 1, 1)
        let minVal = samples.min() ?? 0
        let range = max(1, maxVal - minVal)
        return samples.map { Double($0 - minVal) / Double(range) }
    }
}

// ── SPARKLINE VIEW ────────────────────────────────────────────────

/// Tiny line chart of the VM's disk usage over time. When the VM is
/// running and writing, the line rises — you SEE the guest working.
/// When idle, the line is flat. The representation carries the state.
@MainActor
public struct DiskSparkline: View {
    @Bindable var stats: VMLiveStats
    let tint: Color
    let running: Bool

    public init(stats: VMLiveStats, tint: Color = LuminaTheme.accent, running: Bool) {
        self.stats = stats
        self.tint = tint
        self.running = running
    }

    public var body: some View {
        Canvas { context, size in
            let samples = stats.normalised
            guard samples.count >= 2 else { return }
            let step = size.width / CGFloat(samples.count - 1)
            var path = Path()
            for (i, v) in samples.enumerated() {
                let x = CGFloat(i) * step
                let y = size.height - CGFloat(v) * size.height
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            // Line
            context.stroke(path, with: .color(tint), lineWidth: 1.2)

            // Area fill under the line
            var fillPath = path
            fillPath.addLine(to: CGPoint(x: size.width, y: size.height))
            fillPath.addLine(to: CGPoint(x: 0, y: size.height))
            fillPath.closeSubpath()
            context.fill(fillPath, with: .color(tint.opacity(0.12)))

            // Terminal cursor at the latest point
            if let last = samples.last {
                let x = size.width
                let y = size.height - CGFloat(last) * size.height
                context.fill(
                    Path(ellipseIn: CGRect(x: x - 2, y: y - 2, width: 4, height: 4)),
                    with: .color(tint)
                )
            }
        }
        .overlay(alignment: .topTrailing) {
            // Growth rate indicator — breathes when writing, still when idle.
            if running && abs(stats.growthRate) > 1024 {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8, weight: .semibold))
                    Text(formatRate(stats.growthRate))
                        .font(.system(size: 9, design: .monospaced))
                }
                .foregroundStyle(tint)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    Capsule().fill(Color.black.opacity(0.35))
                )
                .padding(4)
            }
        }
    }

    private func formatRate(_ bps: Double) -> String {
        let abs = Swift.abs(bps)
        if abs > 1024 * 1024 { return String(format: "%.1f MB/s", abs / (1024 * 1024)) }
        if abs > 1024 { return String(format: "%.0f KB/s", abs / 1024) }
        return String(format: "%.0f B/s", abs)
    }
}

// ── HEARTBEAT INDICATOR ───────────────────────────────────────────
/// Tiny amber dot that pulses when the VM is running. Visual proof
/// the machine is alive — no text label needed.
@MainActor
public struct Heartbeat: View {
    let color: Color
    @State private var pulse = false

    public init(color: Color = LuminaTheme.ok) {
        self.color = color
    }

    public var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .shadow(color: color.opacity(pulse ? 0.75 : 0.0),
                    radius: pulse ? 6 : 0)
            .scaleEffect(pulse ? 1.1 : 0.95)
            .animation(
                .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                value: pulse
            )
            .onAppear { pulse = true }
    }
}
