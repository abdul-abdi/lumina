// Sources/Lumina/Protocol.swift
import Foundation

// MARK: - Host Messages (sent to guest)

public enum HostMessage: Sendable {
    case exec(id: String, cmd: String, timeout: Int, env: [String: String], cwd: String? = nil)
    case upload(path: String, data: String, mode: String, seq: Int, eof: Bool)
    case downloadReq(path: String)
    /// Send a signal to a running command (by id) or all commands (id nil).
    /// The guest sends `signal` to the process group, waits `gracePeriod` seconds, then SIGKILL.
    case cancel(id: String?, signal: Int32, gracePeriod: Int)
    /// Send stdin data to a running command identified by id.
    case stdin(id: String, data: String)
    /// Close the stdin pipe for a running command.
    case stdinClose(id: String)
    /// Configure guest network (host-driven, Apple-style).
    case configureNetwork(ip: String, gateway: String, dns: String)
    /// Start a PTY-backed interactive command. Output flows back as `.ptyOutput`
    /// and the process exits via the shared `.exit(id:code:)` message.
    case ptyExec(id: String, cmd: String, timeout: Int, env: [String: String], cols: Int, rows: Int)
    /// Write base64-encoded bytes to a running PTY's master side (keyboard input).
    case ptyInput(id: String, data: String)
    /// Resize the window of a running PTY (sends TIOCSWINSZ on the guest).
    case windowResize(id: String, cols: Int, rows: Int)
}

// MARK: - Guest Messages (received from guest)

public enum GuestMessage: Sendable, Equatable {
    case ready
    /// Text output (UTF-8). `data` carries the text verbatim.
    case output(id: String, stream: OutputStream, data: String)
    /// Binary output. `bytes` carries the raw bytes that were base64-encoded
    /// on the wire. Produced when the guest detects a non-UTF-8 chunk via
    /// `utf8.Valid()` before emitting.
    case outputBinary(id: String, stream: OutputStream, bytes: Data)
    case exit(id: String, code: Int32)
    case heartbeat
    case uploadAck(seq: Int)
    case uploadDone(path: String)
    case uploadError(path: String, error: String)
    case downloadData(path: String, data: String, seq: Int, eof: Bool)
    case downloadError(path: String, error: String)
    case networkReady(ip: String)
    /// PTY-backed output (merged stdout+stderr). `data` is the base64-encoded raw bytes
    /// read from the PTY master. Exit is delivered via the shared `.exit(id:code:)` case.
    case ptyOutput(id: String, data: String)
}

public enum OutputStream: String, Sendable, Equatable, Codable {
    case stdout
    case stderr
}

// MARK: - Wire Format

enum LuminaProtocol {
    // 128KB — must accommodate 48KB raw chunks from guest agent (48*4/3 ≈ 64KB base64 + JSON envelope).
    static let maxMessageSize = 131_072

    static func encode(_ message: HostMessage) throws -> Data {
        let dict: [String: Any]
        switch message {
        case .exec(let id, let cmd, let timeout, let env, let cwd):
            var d: [String: Any] = ["type": "exec", "id": id, "cmd": cmd, "timeout": timeout, "env": env]
            if let cwd = cwd { d["cwd"] = cwd }
            dict = d
        case .upload(let path, let dataStr, let mode, let seq, let eof):
            dict = ["type": "upload", "path": path, "data": dataStr, "mode": mode, "seq": seq, "eof": eof]
        case .downloadReq(let path):
            dict = ["type": "download_req", "path": path]
        case .cancel(let id, let signal, let gracePeriod):
            var d: [String: Any] = ["type": "cancel", "signal": Int(signal), "grace_period": gracePeriod]
            if let id = id { d["id"] = id }
            dict = d
        case .stdin(let id, let data):
            dict = ["type": "stdin", "id": id, "data": data]
        case .stdinClose(let id):
            dict = ["type": "stdin_close", "id": id]
        case .configureNetwork(let ip, let gateway, let dns):
            dict = ["type": "configure_network", "ip": ip, "gateway": gateway, "dns": dns]
        case .ptyExec(let id, let cmd, let timeout, let env, let cols, let rows):
            dict = ["type": "pty_exec", "id": id, "cmd": cmd, "timeout": timeout, "env": env, "cols": cols, "rows": rows]
        case .ptyInput(let id, let data):
            dict = ["type": "pty_input", "id": id, "data": data]
        case .windowResize(let id, let cols, let rows):
            dict = ["type": "window_resize", "id": id, "cols": cols, "rows": rows]
        }
        var data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        data.append(contentsOf: [UInt8(ascii: "\n")])
        return data
    }

    static func decodeGuest(_ data: Data) throws -> GuestMessage {
        let trimmed = data.prefix(while: { $0 != UInt8(ascii: "\n") })
        guard let json = try? JSONSerialization.jsonObject(with: trimmed) as? [String: Any],
              let type = json["type"] as? String
        else {
            throw LuminaError.protocolError("Invalid JSON in guest message")
        }

        switch type {
        case "ready":
            return .ready
        case "output":
            guard let id = json["id"] as? String,
                  let streamStr = json["stream"] as? String,
                  let stream = OutputStream(rawValue: streamStr),
                  let outputData = json["data"] as? String
            else {
                throw LuminaError.protocolError("Malformed output message")
            }
            // Backward-compatible binary-output envelope. Old guests never set
            // "encoding" → treated as UTF-8 text. New guests emitting non-UTF-8
            // chunks set "encoding":"base64" and base64-encode the bytes in the
            // "data" string.
            if let encoding = json["encoding"] as? String, encoding == "base64" {
                guard let bytes = Data(base64Encoded: outputData) else {
                    throw LuminaError.protocolError("Malformed base64 output data")
                }
                return .outputBinary(id: id, stream: stream, bytes: bytes)
            }
            return .output(id: id, stream: stream, data: outputData)
        case "exit":
            guard let id = json["id"] as? String,
                  let code = json["code"] as? Int else {
                throw LuminaError.protocolError("Malformed exit message: missing id or code")
            }
            return .exit(id: id, code: Int32(code))
        case "heartbeat":
            return .heartbeat
        case "upload_ack":
            guard let seq = json["seq"] as? Int else {
                throw LuminaError.protocolError("Malformed upload_ack: missing seq")
            }
            return .uploadAck(seq: seq)
        case "upload_done":
            guard let path = json["path"] as? String else {
                throw LuminaError.protocolError("Malformed upload_done: missing path")
            }
            return .uploadDone(path: path)
        case "upload_error":
            guard let path = json["path"] as? String,
                  let errorStr = json["error"] as? String else {
                throw LuminaError.protocolError("Malformed upload_error: missing path/error")
            }
            return .uploadError(path: path, error: errorStr)
        case "download_data":
            guard let path = json["path"] as? String,
                  let dataStr = json["data"] as? String,
                  let seq = json["seq"] as? Int,
                  let eof = json["eof"] as? Bool else {
                throw LuminaError.protocolError("Malformed download_data: missing fields")
            }
            return .downloadData(path: path, data: dataStr, seq: seq, eof: eof)
        case "download_error":
            guard let path = json["path"] as? String,
                  let errorStr = json["error"] as? String else {
                throw LuminaError.protocolError("Malformed download_error: missing path/error")
            }
            return .downloadError(path: path, error: errorStr)
        case "network_ready":
            let ip = json["ip"] as? String ?? ""
            return .networkReady(ip: ip)
        case "pty_output":
            guard let id = json["id"] as? String,
                  let outputData = json["data"] as? String else {
                throw LuminaError.protocolError("Malformed pty_output: missing id or data")
            }
            return .ptyOutput(id: id, data: outputData)
        default:
            throw LuminaError.protocolError("Unknown message type: \(type)")
        }
    }
}

// MARK: - Public alias using backtick-escaped name

/// Namespace alias to allow `Protocol.encode` / `Protocol.decodeGuest` call sites.
typealias Protocol = LuminaProtocol
