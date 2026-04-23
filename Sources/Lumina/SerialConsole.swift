// Sources/Lumina/SerialConsole.swift
import Foundation

public final class SerialConsole: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: Data
    private let maxSize: Int
    private var _agentStarted = false
    /// Monotonic counter bumped on every `append` that actually writes
    /// bytes. Readers that poll the console (e.g. the Desktop app's
    /// serial-mirror task at ~4 Hz) capture this value and skip their
    /// full tail/strip/publish pipeline when it hasn't changed — an idle
    /// VM's mirror task ends up doing one atomic load + one equality
    /// check per tick instead of copying a megabyte of buffer. See
    /// `LuminaDesktopSession.startSerialMirror`.
    private var _version: UInt64 = 0

    private static let agentMarker = Data("lumina-agent starting".utf8)

    public init(maxSize: Int = 1_048_576) { // 1MB default
        self.buffer = Data()
        self.maxSize = maxSize
    }

    public func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }

        guard !data.isEmpty else { return }

        buffer.append(data)
        _version &+= 1

        // Check for agent marker
        if !_agentStarted && buffer.range(of: Self.agentMarker) != nil {
            _agentStarted = true
        }

        // Keep tail if over max size (per Carmack review)
        if buffer.count > maxSize {
            buffer.removeFirst(buffer.count - maxSize)
        }
    }

    public var output: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: buffer, encoding: .utf8) ?? ""
    }

    public var agentStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _agentStarted
    }

    /// Monotonic version counter — increments once per successful
    /// `append`. Starts at 0 for a freshly-constructed console.
    /// Overflow wraps via `&+=` (expected to never happen in practice;
    /// 2^64 appends at 4 Hz is ~146 billion years).
    public var version: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return _version
    }
}
