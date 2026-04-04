// Sources/Lumina/SerialConsole.swift
import Foundation

public final class SerialConsole: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: Data
    private let maxSize: Int
    private var _agentStarted = false

    private static let agentMarker = Data("lumina-agent starting".utf8)

    public init(maxSize: Int = 1_048_576) { // 1MB default
        self.buffer = Data()
        self.maxSize = maxSize
    }

    public func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }

        buffer.append(data)

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
}
