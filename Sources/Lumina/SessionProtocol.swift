// Sources/Lumina/SessionProtocol.swift
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

public enum SessionProtocol {
    static let maxMessageSize = 65_536

    public static func encode(_ request: SessionRequest) throws -> Data {
        let dict: [String: Any]
        switch request {
        case .exec(let cmd, let timeout, let env, let cwd):
            var d: [String: Any] = ["type": "exec", "cmd": cmd, "timeout": timeout, "env": env]
            if let cwd = cwd { d["cwd"] = cwd }
            dict = d
        case .upload(let localPath, let remotePath):
            dict = ["type": "upload", "local_path": localPath, "remote_path": remotePath]
        case .download(let remotePath, let localPath):
            dict = ["type": "download", "remote_path": remotePath, "local_path": localPath]
        case .cancel(let signal, let gracePeriod):
            dict = ["type": "cancel", "signal": Int(signal), "grace_period": gracePeriod]
        case .stdin(let data):
            dict = ["type": "stdin", "data": data]
        case .stdinClose:
            dict = ["type": "stdin_close"]
        case .shutdown:
            dict = ["type": "shutdown"]
        case .ptyExec(let cmd, let timeout, let env, let cols, let rows):
            dict = ["type": "pty_exec", "cmd": cmd, "timeout": timeout, "env": env, "cols": cols, "rows": rows]
        case .ptyInput(let data):
            dict = ["type": "pty_input", "data": data]
        case .windowResize(let cols, let rows):
            dict = ["type": "window_resize", "cols": cols, "rows": rows]
        case .status:
            dict = ["type": "status"]
        }
        var data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        data.append(contentsOf: [UInt8(ascii: "\n")])
        return data
    }

    public static func encode(_ response: SessionResponse) throws -> Data {
        let dict: [String: Any]
        switch response {
        case .output(let stream, let data):
            dict = ["type": "output", "stream": stream.rawValue, "data": data]
        case .outputBytes(let stream, let base64):
            dict = ["type": "output_bytes", "stream": stream.rawValue, "base64": base64]
        case .exit(let code, let durationMs):
            dict = ["type": "exit", "code": Int(code), "duration_ms": durationMs]
        case .error(let message):
            dict = ["type": "error", "message": message]
        case .uploadDone(let path):
            dict = ["type": "upload_done", "path": path]
        case .downloadDone(let path):
            dict = ["type": "download_done", "path": path]
        case .ptyOutput(let data):
            dict = ["type": "pty_output", "data": data]
        case .status(let uptime, let activeExecs, let image):
            dict = [
                "type": "status",
                "uptime": uptime,
                "active_execs": activeExecs,
                "image": image,
            ]
        }
        var data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        data.append(contentsOf: [UInt8(ascii: "\n")])
        return data
    }

    public static func decodeRequest(_ data: Data) throws -> SessionRequest {
        let trimmed = data.prefix(while: { $0 != UInt8(ascii: "\n") })
        guard let json = try? JSONSerialization.jsonObject(with: trimmed) as? [String: Any],
              let type = json["type"] as? String
        else {
            throw LuminaError.protocolError("Invalid JSON in session request")
        }

        switch type {
        case "exec":
            guard let cmd = json["cmd"] as? String,
                  let timeout = json["timeout"] as? Int else {
                throw LuminaError.protocolError("Malformed exec request")
            }
            let env = json["env"] as? [String: String] ?? [:]
            let cwd = json["cwd"] as? String
            return .exec(cmd: cmd, timeout: timeout, env: env, cwd: cwd)
        case "upload":
            guard let localPath = json["local_path"] as? String,
                  let remotePath = json["remote_path"] as? String else {
                throw LuminaError.protocolError("Malformed upload request")
            }
            return .upload(localPath: localPath, remotePath: remotePath)
        case "download":
            guard let remotePath = json["remote_path"] as? String,
                  let localPath = json["local_path"] as? String else {
                throw LuminaError.protocolError("Malformed download request")
            }
            return .download(remotePath: remotePath, localPath: localPath)
        case "cancel":
            let signal = (json["signal"] as? Int).map { Int32($0) } ?? Int32(SIGTERM)
            let gracePeriod = json["grace_period"] as? Int ?? 5
            return .cancel(signal: signal, gracePeriod: gracePeriod)
        case "stdin":
            guard let data = json["data"] as? String else {
                throw LuminaError.protocolError("Malformed stdin request")
            }
            return .stdin(data: data)
        case "stdin_close":
            return .stdinClose
        case "shutdown":
            return .shutdown
        case "pty_exec":
            guard let cmd = json["cmd"] as? String,
                  let timeout = json["timeout"] as? Int,
                  let cols = json["cols"] as? Int,
                  let rows = json["rows"] as? Int else {
                throw LuminaError.protocolError("Malformed pty_exec request")
            }
            let env = json["env"] as? [String: String] ?? [:]
            return .ptyExec(cmd: cmd, timeout: timeout, env: env, cols: cols, rows: rows)
        case "pty_input":
            guard let data = json["data"] as? String else {
                throw LuminaError.protocolError("Malformed pty_input request")
            }
            return .ptyInput(data: data)
        case "window_resize":
            guard let cols = json["cols"] as? Int,
                  let rows = json["rows"] as? Int else {
                throw LuminaError.protocolError("Malformed window_resize request")
            }
            return .windowResize(cols: cols, rows: rows)
        case "status":
            return .status
        default:
            throw LuminaError.protocolError("Unknown session request type: \(type)")
        }
    }

    public static func decodeResponse(_ data: Data) throws -> SessionResponse {
        let trimmed = data.prefix(while: { $0 != UInt8(ascii: "\n") })
        guard let json = try? JSONSerialization.jsonObject(with: trimmed) as? [String: Any],
              let type = json["type"] as? String
        else {
            throw LuminaError.protocolError("Invalid JSON in session response")
        }

        switch type {
        case "output":
            guard let streamStr = json["stream"] as? String,
                  let stream = OutputStream(rawValue: streamStr),
                  let data = json["data"] as? String else {
                throw LuminaError.protocolError("Malformed output response")
            }
            return .output(stream: stream, data: data)
        case "output_bytes":
            guard let streamStr = json["stream"] as? String,
                  let stream = OutputStream(rawValue: streamStr),
                  let base64 = json["base64"] as? String else {
                throw LuminaError.protocolError("Malformed output_bytes response")
            }
            return .outputBytes(stream: stream, base64: base64)
        case "exit":
            guard let code = json["code"] as? Int,
                  let durationMs = json["duration_ms"] as? Int else {
                throw LuminaError.protocolError("Malformed exit response")
            }
            return .exit(code: Int32(code), durationMs: durationMs)
        case "error":
            guard let message = json["message"] as? String else {
                throw LuminaError.protocolError("Malformed error response")
            }
            return .error(message: message)
        case "upload_done":
            guard let path = json["path"] as? String else {
                throw LuminaError.protocolError("Malformed upload_done response")
            }
            return .uploadDone(path: path)
        case "download_done":
            guard let path = json["path"] as? String else {
                throw LuminaError.protocolError("Malformed download_done response")
            }
            return .downloadDone(path: path)
        case "pty_output":
            guard let data = json["data"] as? String else {
                throw LuminaError.protocolError("Malformed pty_output response")
            }
            return .ptyOutput(data: data)
        case "status":
            // Tolerant decode — any missing field degrades to a sensible default
            // so a future server that adds fields stays parseable here.
            let uptime = (json["uptime"] as? TimeInterval)
                ?? (json["uptime"] as? Double)
                ?? Double(json["uptime"] as? Int ?? 0)
            let activeExecs = json["active_execs"] as? Int ?? 0
            let image = json["image"] as? String ?? "unknown"
            return .status(uptime: uptime, activeExecs: activeExecs, image: image)
        default:
            throw LuminaError.protocolError("Unknown session response type: \(type)")
        }
    }
}
