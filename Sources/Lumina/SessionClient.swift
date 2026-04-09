// Sources/Lumina/SessionClient.swift
import Foundation

/// Connects to a session's Unix domain socket and sends/receives
/// SessionProtocol messages. Used by the CLI `exec` and `session stop` commands.
public final class SessionClient: @unchecked Sendable {
    private let sessionsDir: URL
    private var clientFd: Int32 = -1
    private var readHandle: FileHandle?
    private var writeHandle: FileHandle?

    public init(sessionsDir: URL = SessionPaths.defaultSessionsDir) {
        self.sessionsDir = sessionsDir
    }

    /// Connect to a session by ID. Validates the session exists and is alive.
    public func connect(sid: String) throws {
        let paths = SessionPaths(sid: sid, sessionsDir: sessionsDir)

        // Check if session directory exists
        guard FileManager.default.fileExists(atPath: paths.directory.path) else {
            throw LuminaError.sessionNotFound(sid)
        }

        // Check if session process is alive
        if let info = paths.readMeta(), kill(info.pid, 0) != 0 {
            paths.cleanup()
            throw LuminaError.sessionDead(sid)
        }

        // Connect to Unix socket
        clientFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard clientFd >= 0 else {
            throw LuminaError.sessionFailed("Failed to create socket: \(errno)")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathStr = paths.socket.path
        let pathBytes = pathStr.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
                pathBytes.withUnsafeBufferPointer { src in
                    let count = min(src.count, 104)
                    dest.update(from: src.baseAddress!, count: count)
                }
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(clientFd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            Darwin.close(clientFd)
            clientFd = -1
            // Socket exists but can't connect -- session may be dead
            if !paths.isAlive() {
                paths.cleanup()
                throw LuminaError.sessionDead(sid)
            }
            throw LuminaError.sessionFailed("Failed to connect to session \(sid): \(errno)")
        }

        readHandle = FileHandle(fileDescriptor: clientFd, closeOnDealloc: false)
        writeHandle = FileHandle(fileDescriptor: clientFd, closeOnDealloc: false)
    }

    /// Send a request to the session server.
    public func send(_ request: SessionRequest) throws {
        guard let handle = writeHandle else {
            throw LuminaError.connectionFailed
        }
        let data = try SessionProtocol.encode(request)
        handle.write(data)
    }

    /// Read one response from the session server.
    public func receive() throws -> SessionResponse {
        guard let handle = readHandle else {
            throw LuminaError.connectionFailed
        }
        var buffer = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty {
                throw LuminaError.connectionFailed
            }
            buffer.append(chunk)
            if buffer.count > SessionProtocol.maxMessageSize {
                throw LuminaError.protocolError("Session response exceeds 64KB")
            }
            if buffer.firstIndex(of: UInt8(ascii: "\n")) != nil {
                return try SessionProtocol.decodeResponse(buffer)
            }
        }
    }

    /// Execute a command and yield all responses until exit or error.
    public func exec(
        cmd: String,
        timeout: Int = 60,
        env: [String: String] = [:]
    ) throws -> [SessionResponse] {
        try send(.exec(cmd: cmd, timeout: timeout, env: env))
        var responses: [SessionResponse] = []
        while true {
            let response = try receive()
            responses.append(response)
            switch response {
            case .exit, .error:
                return responses
            default:
                continue
            }
        }
    }

    /// Disconnect from the session.
    public func disconnect() {
        if clientFd >= 0 {
            Darwin.close(clientFd)
            clientFd = -1
        }
        readHandle = nil
        writeHandle = nil
    }

    deinit {
        disconnect()
    }
}
