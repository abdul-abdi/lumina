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
        default:
            throw LuminaError.protocolError("Unknown session response type: \(type)")
        }
    }
}
