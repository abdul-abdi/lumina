import Foundation

// MARK: - Session Request (host → session server)

public enum SessionRequest: Sendable, Equatable {
    case exec(cmd: String, timeout: Int, env: [String: String], cwd: String? = nil)
    case upload(localPath: String, remotePath: String)
    case download(remotePath: String, localPath: String)
    case cancel(signal: Int32, gracePeriod: Int)
    case stdin(data: String)
    case stdinClose
    case shutdown
    /// v0.6.0: Start an interactive PTY-backed command. `data` frames flow in
    /// `ptyInput` requests and `ptyOutput` responses (base64-encoded raw bytes).
    case ptyExec(cmd: String, timeout: Int, env: [String: String], cols: Int, rows: Int)
    /// v0.6.0: Raw base64-encoded bytes to write to the active PTY master fd.
    case ptyInput(data: String)
    /// v0.6.0: Window size change for the active PTY (triggers SIGWINCH in guest).
    case windowResize(cols: Int, rows: Int)
    /// v0.6.0: Query the server for live session status (uptime + active execs).
    /// Used by `lumina ps` for observability.
    case status
    case save(image: String)
}

// MARK: - Session Response (session server → host)

public enum SessionResponse: Sendable, Equatable {
    case output(stream: OutputStream, data: String)
    /// Binary output chunk — `base64` is the base64-encoded raw bytes.
    /// Matches the vsock binary stdout envelope so binary data survives
    /// the session IPC layer without lossy UTF-8 conversion.
    case outputBytes(stream: OutputStream, base64: String)
    case exit(code: Int32, durationMs: Int)
    case error(message: String)
    case uploadDone(path: String)
    case downloadDone(path: String)
    /// v0.6.0: Base64-encoded raw bytes from the active PTY master fd.
    /// PTY merges stdout+stderr — no stream tag.
    case ptyOutput(data: String)
    /// v0.6.0: Live session status returned in response to `.status` request.
    /// `uptime` is seconds since the session server started accepting connections.
    case status(uptime: TimeInterval, activeExecs: Int, image: String)
}

// MARK: - Codec

private struct Frame: Codable {
    var type: String
    var cmd: String?
    var timeout: Int?
    var env: [String: String]?
    var cwd: String?
    var local_path: String?
    var remote_path: String?
    var signal: Int?
    var grace_period: Int?
    var data: String?
    var cols: Int?
    var rows: Int?
    var image: String?
    var stream: OutputStream?
    var base64: String?
    var code: Int?
    var duration_ms: Int?
    var message: String?
    var path: String?
    var uptime: Double?
    var active_execs: Int?

    func need<T>(_ value: T?, _ kind: String) throws -> T {
        guard let value else { throw LuminaError.protocolError("Malformed \(type) \(kind)") }
        return value
    }
}

public enum SessionProtocol {
    static let maxMessageSize = 65_536

    public static func encode(_ request: SessionRequest) throws -> Data {
        switch request {
        case .exec(let cmd, let timeout, let env, let cwd):
            return try encode(Frame(type: "exec", cmd: cmd, timeout: timeout, env: env, cwd: cwd))
        case .upload(let localPath, let remotePath):
            return try encode(Frame(type: "upload", local_path: localPath, remote_path: remotePath))
        case .download(let remotePath, let localPath):
            return try encode(Frame(type: "download", local_path: localPath, remote_path: remotePath))
        case .cancel(let signal, let gracePeriod):
            return try encode(Frame(type: "cancel", signal: Int(signal), grace_period: gracePeriod))
        case .stdin(let data):
            return try encode(Frame(type: "stdin", data: data))
        case .stdinClose:
            return try encode(Frame(type: "stdin_close"))
        case .shutdown:
            return try encode(Frame(type: "shutdown"))
        case .ptyExec(let cmd, let timeout, let env, let cols, let rows):
            return try encode(Frame(type: "pty_exec", cmd: cmd, timeout: timeout, env: env, cols: cols, rows: rows))
        case .ptyInput(let data):
            return try encode(Frame(type: "pty_input", data: data))
        case .windowResize(let cols, let rows):
            return try encode(Frame(type: "window_resize", cols: cols, rows: rows))
        case .status:
            return try encode(Frame(type: "status"))
        case .save(let image):
            return try encode(Frame(type: "save", image: image))
        }
    }

    public static func encode(_ response: SessionResponse) throws -> Data {
        switch response {
        case .output(let stream, let data):
            return try encode(Frame(type: "output", data: data, stream: stream))
        case .outputBytes(let stream, let base64):
            return try encode(Frame(type: "output_bytes", stream: stream, base64: base64))
        case .exit(let code, let durationMs):
            return try encode(Frame(type: "exit", code: Int(code), duration_ms: durationMs))
        case .error(let message):
            return try encode(Frame(type: "error", message: message))
        case .uploadDone(let path):
            return try encode(Frame(type: "upload_done", path: path))
        case .downloadDone(let path):
            return try encode(Frame(type: "download_done", path: path))
        case .ptyOutput(let data):
            return try encode(Frame(type: "pty_output", data: data))
        case .status(let uptime, let activeExecs, let image):
            return try encode(Frame(type: "status", image: image, uptime: uptime, active_execs: activeExecs))
        }
    }

    public static func decodeRequest(_ data: Data) throws -> SessionRequest {
        let f = try decode(data, "request")
        let kind = "request"
        switch f.type {
        case "exec":
            return .exec(cmd: try f.need(f.cmd, kind), timeout: try f.need(f.timeout, kind), env: f.env ?? [:], cwd: f.cwd)
        case "upload":
            return .upload(localPath: try f.need(f.local_path, kind), remotePath: try f.need(f.remote_path, kind))
        case "download":
            return .download(remotePath: try f.need(f.remote_path, kind), localPath: try f.need(f.local_path, kind))
        case "cancel":
            return .cancel(signal: Int32(f.signal ?? Int(SIGTERM)), gracePeriod: f.grace_period ?? 5)
        case "stdin":
            return .stdin(data: try f.need(f.data, kind))
        case "stdin_close":
            return .stdinClose
        case "shutdown":
            return .shutdown
        case "pty_exec":
            return .ptyExec(
                cmd: try f.need(f.cmd, kind), timeout: try f.need(f.timeout, kind), env: f.env ?? [:],
                cols: try f.need(f.cols, kind), rows: try f.need(f.rows, kind)
            )
        case "pty_input":
            return .ptyInput(data: try f.need(f.data, kind))
        case "save":
            return .save(image: try f.need(f.image, kind))
        case "window_resize":
            return .windowResize(cols: try f.need(f.cols, kind), rows: try f.need(f.rows, kind))
        case "status":
            return .status
        default:
            throw LuminaError.protocolError("Unknown session request type: \(f.type)")
        }
    }

    public static func decodeResponse(_ data: Data) throws -> SessionResponse {
        let f = try decode(data, "response")
        let kind = "response"
        switch f.type {
        case "output":
            return .output(stream: try f.need(f.stream, kind), data: try f.need(f.data, kind))
        case "output_bytes":
            return .outputBytes(stream: try f.need(f.stream, kind), base64: try f.need(f.base64, kind))
        case "exit":
            return .exit(code: Int32(try f.need(f.code, kind)), durationMs: try f.need(f.duration_ms, kind))
        case "error":
            return .error(message: try f.need(f.message, kind))
        case "upload_done":
            return .uploadDone(path: try f.need(f.path, kind))
        case "download_done":
            return .downloadDone(path: try f.need(f.path, kind))
        case "pty_output":
            return .ptyOutput(data: try f.need(f.data, kind))
        case "status":
            return .status(uptime: f.uptime ?? 0, activeExecs: f.active_execs ?? 0, image: f.image ?? "unknown")
        default:
            throw LuminaError.protocolError("Unknown session response type: \(f.type)")
        }
    }

    private static func encode(_ frame: Frame) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(frame) + [UInt8(ascii: "\n")]
    }

    private static func decode(_ data: Data, _ kind: String) throws -> Frame {
        do {
            return try JSONDecoder().decode(Frame.self, from: data.prefix(while: { $0 != UInt8(ascii: "\n") }))
        } catch {
            throw LuminaError.protocolError("Invalid JSON in session \(kind)")
        }
    }
}
