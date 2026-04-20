// Sources/LuminaDesktopKit/HostInfo.swift
//
// v0.7.0 M6 — inspect the host Mac's memory, CPU, and free disk so the
// wizard can suggest sane VM resources and warn before the user configures
// a VM that won't fit. The constraint is invisible otherwise — Victor's
// principle: make it visible.

import Foundation
import Darwin

public struct HostInfo: Sendable {
    public let physicalMemoryBytes: UInt64
    public let processorCount: Int
    public let modelName: String

    public static let current: HostInfo = {
        HostInfo(
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            processorCount: ProcessInfo.processInfo.activeProcessorCount,
            modelName: Self.readSysctlString("hw.model") ?? "Mac"
        )
    }()

    /// Free disk space "important-usage" aware — the same number Finder
    /// shows. Excludes purgeable + system-reserved.
    public static func freeDiskBytes(at url: URL) -> UInt64? {
        guard let values = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ) else { return nil }
        return UInt64(values.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    /// Capacity of the volume containing `url`. Non-important-usage-aware.
    public static func totalDiskBytes(at url: URL) -> UInt64? {
        guard let values = try? url.resourceValues(
            forKeys: [.volumeTotalCapacityKey]
        ) else { return nil }
        return UInt64(values.volumeTotalCapacity ?? 0)
    }

    /// Apple's recommendation: guests should consume at most ~2/3 of host
    /// RAM to leave headroom for macOS itself. Used for the "warn" ceiling.
    public var safeMemoryCeilingBytes: UInt64 {
        UInt64(Double(physicalMemoryBytes) * 0.66)
    }

    /// Hard ceiling — anything above this is guaranteed to make macOS
    /// struggle. VZ also hard-rejects allocations > host RAM.
    public var hardMemoryCeilingBytes: UInt64 {
        UInt64(Double(physicalMemoryBytes) * 0.85)
    }

    private static func readSysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

public func formatBytesHuman(_ n: UInt64) -> String {
    let gb = Double(n) / (1024 * 1024 * 1024)
    if gb >= 1.0 { return String(format: "%.1f GB", gb) }
    let mb = Double(n) / (1024 * 1024)
    if mb >= 1.0 { return String(format: "%.0f MB", mb) }
    return "\(n) B"
}
