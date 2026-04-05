// Sources/Lumina/Protocol.swift
import Foundation

// MARK: - Host Messages (sent to guest)

public enum HostMessage: Sendable {
    case exec(cmd: String, timeout: Int, env: [String: String])
}

// MARK: - Guest Messages (received from guest)

public enum GuestMessage: Sendable, Equatable {
    case ready
    case output(stream: OutputStream, data: String)
    case exit(code: Int32)
    case heartbeat
}

public enum OutputStream: String, Sendable, Equatable, Codable {
    case stdout
    case stderr
}

// MARK: - Wire Format

enum LuminaProtocol {
    static let maxMessageSize = 65_536 // 64KB

    static func encode(_ message: HostMessage) throws -> Data {
        let dict: [String: Any]
        switch message {
        case .exec(let cmd, let timeout, let env):
            dict = ["type": "exec", "cmd": cmd, "timeout": timeout, "env": env]
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
            guard let streamStr = json["stream"] as? String,
                  let stream = OutputStream(rawValue: streamStr),
                  let outputData = json["data"] as? String
            else {
                throw LuminaError.protocolError("Malformed output message")
            }
            return .output(stream: stream, data: outputData)
        case "exit":
            guard let code = json["code"] as? Int else {
                throw LuminaError.protocolError("Malformed exit message: missing code")
            }
            return .exit(code: Int32(code))
        case "heartbeat":
            return .heartbeat
        default:
            throw LuminaError.protocolError("Unknown message type: \(type)")
        }
    }
}

// MARK: - Public alias using backtick-escaped name

/// Namespace alias to allow `Protocol.encode` / `Protocol.decodeGuest` call sites.
typealias Protocol = LuminaProtocol
