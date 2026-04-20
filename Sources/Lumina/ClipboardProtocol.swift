// Sources/Lumina/ClipboardProtocol.swift
//
// v0.7.0 M7 — vsock protocol over port 1025 for host↔guest clipboard
// sync and file drag-drop. Distinct from the agent protocol on port 1024
// so a misbehaving clipboard handler can't break agent execs.
//
// Wire format: NDJSON (newline-delimited JSON), same as the agent
// protocol. Each message is one line of UTF-8 JSON terminated by `\n`.

import Foundation

public enum ClipboardMessage: Sendable, Codable, Equatable {
    /// Host → guest: replace the guest clipboard with `data`.
    case setGuestClipboard(data: String, mime: String)
    /// Host → guest: ask the guest to send its current clipboard back.
    case getGuestClipboard
    /// Guest → host: this is the current guest clipboard.
    case guestClipboardIs(data: String, mime: String)
    /// Host → guest: a file is being dropped; here are bytes.
    case fileDropStart(name: String, size: UInt64)
    case fileDropChunk(data: String)  // base64
    case fileDropEnd
    /// Guest → host: file drop completed; landed at `path`.
    case fileDropDone(path: String)
    /// Either direction: heartbeat to keep the connection alive.
    case heartbeat
    /// Either direction: report a non-fatal error.
    case error(String)

    private enum CodingKeys: String, CodingKey {
        case type, data, mime, name, size, path, message
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .setGuestClipboard(let d, let m):
            try c.encode("set_guest_clipboard", forKey: .type)
            try c.encode(d, forKey: .data)
            try c.encode(m, forKey: .mime)
        case .getGuestClipboard:
            try c.encode("get_guest_clipboard", forKey: .type)
        case .guestClipboardIs(let d, let m):
            try c.encode("guest_clipboard_is", forKey: .type)
            try c.encode(d, forKey: .data)
            try c.encode(m, forKey: .mime)
        case .fileDropStart(let n, let s):
            try c.encode("file_drop_start", forKey: .type)
            try c.encode(n, forKey: .name)
            try c.encode(s, forKey: .size)
        case .fileDropChunk(let d):
            try c.encode("file_drop_chunk", forKey: .type)
            try c.encode(d, forKey: .data)
        case .fileDropEnd:
            try c.encode("file_drop_end", forKey: .type)
        case .fileDropDone(let p):
            try c.encode("file_drop_done", forKey: .type)
            try c.encode(p, forKey: .path)
        case .heartbeat:
            try c.encode("heartbeat", forKey: .type)
        case .error(let m):
            try c.encode("error", forKey: .type)
            try c.encode(m, forKey: .message)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "set_guest_clipboard":
            self = .setGuestClipboard(
                data: try c.decode(String.self, forKey: .data),
                mime: try c.decode(String.self, forKey: .mime)
            )
        case "get_guest_clipboard":
            self = .getGuestClipboard
        case "guest_clipboard_is":
            self = .guestClipboardIs(
                data: try c.decode(String.self, forKey: .data),
                mime: try c.decode(String.self, forKey: .mime)
            )
        case "file_drop_start":
            self = .fileDropStart(
                name: try c.decode(String.self, forKey: .name),
                size: try c.decode(UInt64.self, forKey: .size)
            )
        case "file_drop_chunk":
            self = .fileDropChunk(data: try c.decode(String.self, forKey: .data))
        case "file_drop_end":
            self = .fileDropEnd
        case "file_drop_done":
            self = .fileDropDone(path: try c.decode(String.self, forKey: .path))
        case "heartbeat":
            self = .heartbeat
        case "error":
            self = .error(try c.decode(String.self, forKey: .message))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c,
                debugDescription: "Unknown clipboard message type: \(type)"
            )
        }
    }
}

/// Vsock port used by the clipboard / drag-drop protocol. Distinct from
/// the agent protocol's port 1024.
public let clipboardVsockPort: UInt32 = 1025
