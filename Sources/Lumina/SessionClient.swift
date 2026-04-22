// Sources/Lumina/SessionClient.swift
import Foundation
import Darwin

/// Connects to a session's Unix domain socket and sends/receives
/// SessionProtocol messages. Used by the CLI `exec` and `session stop` commands.
public final class SessionClient: @unchecked Sendable {
    private let sessionsDir: URL
    private var clientFd: Int32 = -1
    private var readHandle: FileHandle?
    private var writeHandle: FileHandle?
    /// Persistent read buffer that retains leftover bytes between `receive()` calls.
    /// Prevents data loss when multiple NDJSON frames arrive in a single read.
    private var readBuffer = Data()

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
        guard pathStr.utf8.count <= 103 else {
            Darwin.close(clientFd)
            clientFd = -1
            throw LuminaError.sessionFailed(
                "Socket path too long (\(pathStr.utf8.count) bytes, max 103): \(pathStr)"
            )
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
                pathBytes.withUnsafeBufferPointer { src in
                    // Guard above ensures src.count <= 104; min is a safety backstop.
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
    ///
    /// Uses POSIX `write()` instead of `FileHandle.write()` — NSFileHandle raises
    /// an Obj-C NSFileHandleOperationException on EPIPE that Swift's `try` cannot catch.
    public func send(_ request: SessionRequest) throws {
        guard clientFd >= 0 else {
            throw LuminaError.connectionFailed
        }
        let data = try SessionProtocol.encode(request)
        var remaining = data.count
        var offset = 0
        while remaining > 0 {
            let written: Int = data.withUnsafeBytes { buf -> Int in
                guard let base = buf.baseAddress else { return -1 }
                var n: Int
                repeat { n = Darwin.write(clientFd, base + offset, remaining) } while n < 0 && errno == EINTR
                return n
            }
            if written <= 0 { throw LuminaError.connectionFailed }
            offset += written
            remaining -= written
        }
    }

    /// Read one response from the session server.
    /// Uses a persistent buffer to handle coalesced NDJSON frames — if a
    /// single read returns multiple newline-delimited messages, the leftover
    /// bytes are retained for the next call.
    ///
    /// `availableData` is intentionally synchronous here. SessionClient runs
    /// inside the `lumina` CLI process — one process per invocation, its
    /// own cooperative pool, one connection open at a time. Unlike
    /// `SessionServer.readMessage` (where N parked per-connection tasks
    /// starved the server's shared pool), a single blocked read here cannot
    /// starve anything the same process also needs — the CLI has nothing
    /// else to do. Making this async would add await/resume overhead with
    /// zero concurrency gain. See `CommandRunner.readLine` for the same
    /// reasoning on the dispatcher singleton.
    public func receive() throws -> SessionResponse {
        guard let handle = readHandle else {
            throw LuminaError.connectionFailed
        }
        while true {
            // Check if there's already a complete line in the buffer
            if let newlineIndex = readBuffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineEnd = readBuffer.index(after: newlineIndex)
                let lineData = Data(readBuffer[readBuffer.startIndex..<lineEnd])
                readBuffer.removeSubrange(readBuffer.startIndex..<lineEnd)
                return try SessionProtocol.decodeResponse(lineData)
            }

            let chunk = handle.availableData
            if chunk.isEmpty {
                throw LuminaError.connectionFailed
            }
            readBuffer.append(chunk)
            if readBuffer.count > SessionProtocol.maxMessageSize {
                readBuffer = Data()
                throw LuminaError.protocolError("Session response exceeds 64KB")
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

    /// Inject pre-connected file descriptors for testing.
    /// Bypasses the Unix socket connect flow.
    internal func injectTestSocket(readFd: Int32, writeFd: Int32) {
        clientFd = readFd
        readHandle = FileHandle(fileDescriptor: readFd, closeOnDealloc: false)
        writeHandle = FileHandle(fileDescriptor: writeFd, closeOnDealloc: false)
        readBuffer = Data()
    }

    /// Disconnect from the session.
    public func disconnect() {
        if clientFd >= 0 {
            Darwin.close(clientFd)
            clientFd = -1
        }
        readHandle = nil
        writeHandle = nil
        readBuffer = Data()
    }

    deinit {
        disconnect()
    }
}
