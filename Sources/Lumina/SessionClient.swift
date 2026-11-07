import Foundation

/// Connects to a session's Unix domain socket and sends/receives
/// SessionProtocol messages. Used by the CLI `exec` and `session stop` commands.
public final class SessionClient: @unchecked Sendable {
    private let sessionsDir: URL
    private var clientFd: Int32 = -1
    /// Persistent read buffer that retains leftover bytes between `receive()` calls.
    /// Prevents data loss when multiple NDJSON frames arrive in a single read.
    private var readBuffer = Data()

    public init(sessionsDir: URL = SessionPaths.defaultSessionsDir) {
        self.sessionsDir = sessionsDir
    }

    /// Connect to a session by ID. Validates the session exists and is alive.
    public func connect(sid: String) throws {
        let paths = SessionPaths(sid: sid, sessionsDir: sessionsDir)

        guard FileManager.default.fileExists(atPath: paths.directory.path) else {
            throw LuminaError.sessionNotFound(sid)
        }

        if let info = paths.readMeta(), kill(info.pid, 0) != 0 {
            paths.cleanup()
            throw LuminaError.sessionDead(sid)
        }

        guard let fd = unixConnect(path: paths.socket.path) else {
            if !paths.isAlive() {
                paths.cleanup()
                throw LuminaError.sessionDead(sid)
            }
            throw LuminaError.sessionFailed("Failed to connect to session \(sid): \(errno)")
        }
        clientFd = fd
    }

    public func send(_ request: SessionRequest) throws {
        guard clientFd >= 0 else {
            throw LuminaError.connectionFailed
        }
        guard writeAll(fd: clientFd, data: try SessionProtocol.encode(request)) else {
            throw LuminaError.connectionFailed
        }
    }

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
        guard clientFd >= 0 else {
            throw LuminaError.connectionFailed
        }
        let handle = FileHandle(fileDescriptor: clientFd, closeOnDealloc: false)
        while true {
            if let line = takeLine(from: &readBuffer) {
                return try SessionProtocol.decodeResponse(line)
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

    /// Inject pre-connected file descriptors for testing.
    /// Bypasses the Unix socket connect flow.
    internal func injectTestSocket(fd: Int32) {
        clientFd = fd
        readBuffer = Data()
    }

    public func disconnect() {
        if clientFd >= 0 {
            Darwin.close(clientFd)
            clientFd = -1
        }
        readBuffer = Data()
    }

    deinit {
        disconnect()
    }
}
