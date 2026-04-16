// Sources/Lumina/SessionServer.swift
import Foundation

/// Listens on a Unix domain socket and dispatches SessionRequest messages
/// to a VM actor. Each accepted connection runs in its own Task so multiple
/// clients can share the VM concurrently — the vsock dispatcher in
/// CommandRunner multiplexes execs by UUID, and `transferContinuation` in
/// CommandRunner enforces mutual exclusion of file transfers. Per-connection
/// state is local to handleConnection; there is no shared state beyond the
/// VM actor itself, which is already thread-safe.
///
/// On shutdown (one client sends `.shutdown`, or bind/accept fails), the
/// serve() task group awaits all in-flight connection tasks before returning
/// so each client gets a clean response before the process exits.
public final class SessionServer: @unchecked Sendable {
    private let socketPath: URL
    private var serverFd: Int32 = -1
    private let lock = NSLock()

    public init(socketPath: URL) {
        self.socketPath = socketPath
    }

    /// Bind and listen on the Unix domain socket.
    public func bind() throws {
        // Remove stale socket file
        try? FileManager.default.removeItem(at: socketPath)

        serverFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFd >= 0 else {
            throw LuminaError.sessionFailed("Failed to create socket: \(errno)")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = socketPath.path
        let pathBytes = path.utf8CString
        // sockaddr_un.sun_path is 104 bytes on macOS (including null terminator).
        // A path longer than 103 bytes would be silently truncated — fail early.
        guard path.utf8.count <= 103 else {
            Darwin.close(serverFd)
            serverFd = -1
            throw LuminaError.sessionFailed(
                "Socket path too long (\(path.utf8.count) bytes, max 103): \(path)"
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

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(serverFd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(serverFd)
            serverFd = -1
            throw LuminaError.sessionFailed("Failed to bind socket: \(errno)")
        }

        guard listen(serverFd, 5) == 0 else {
            Darwin.close(serverFd)
            serverFd = -1
            throw LuminaError.sessionFailed("Failed to listen on socket: \(errno)")
        }
    }

    /// Accept a client connection. Blocks until a client connects.
    /// Returns file handles for reading and writing.
    public func accept() throws -> (read: FileHandle, write: FileHandle) {
        let clientFd = Darwin.accept(serverFd, nil, nil)
        guard clientFd >= 0 else {
            throw LuminaError.sessionFailed("Failed to accept connection: \(errno)")
        }
        return (
            read: FileHandle(fileDescriptor: clientFd, closeOnDealloc: false),
            write: FileHandle(fileDescriptor: clientFd, closeOnDealloc: false)
        )
    }

    /// Read one NDJSON line from a file handle.
    /// Uses the caller-provided buffer to retain leftover bytes when multiple
    /// frames arrive in a single read (coalesced NDJSON).
    public func readMessage(from handle: FileHandle, buffer: inout Data) throws -> Data {
        while true {
            // Check if buffer already has a complete line
            if let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineEnd = buffer.index(after: newlineIndex)
                let line = Data(buffer[buffer.startIndex..<lineEnd])
                buffer.removeSubrange(buffer.startIndex..<lineEnd)
                return line
            }

            let chunk = handle.availableData
            if chunk.isEmpty {
                if buffer.isEmpty { throw LuminaError.connectionFailed }
                let remaining = buffer
                buffer = Data()
                return remaining
            }
            buffer.append(chunk)
            if buffer.count > SessionProtocol.maxMessageSize {
                buffer = Data()
                throw LuminaError.protocolError("Session message exceeds 64KB")
            }
        }
    }

    /// Write a SessionResponse to the client.
    ///
    /// Uses POSIX `write()` instead of `FileHandle.write(_:)` because
    /// NSFileHandle raises an Obj-C exception (NSFileHandleOperationException)
    /// on EPIPE, which is NOT caught by Swift's `try?`. When a client
    /// disconnects mid-stream, the broken socket triggers EPIPE on the next
    /// write. With NSFileHandle this crashes the server; with POSIX write()
    /// the error is returned as a Swift error that `try?` can suppress.
    public func writeResponse(_ response: SessionResponse, to handle: FileHandle) throws {
        let data = try SessionProtocol.encode(response)
        let fd = handle.fileDescriptor
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var remaining = buffer.count
            var offset = 0
            while remaining > 0 {
                var written: Int
                repeat { written = Darwin.write(fd, base + offset, remaining) } while written < 0 && errno == EINTR
                if written <= 0 {
                    throw LuminaError.sessionFailed("Write failed: \(errno)")
                }
                offset += written
                remaining -= written
            }
        }
    }

    /// Close the server socket.
    public func close() {
        if serverFd >= 0 {
            Darwin.close(serverFd)
            serverFd = -1
        }
        try? FileManager.default.removeItem(at: socketPath)
    }

    /// Run the server loop: accept connections, spawn a task per client,
    /// dispatch requests to the VM. Blocks until the server is closed
    /// (a client sends `.shutdown` or `close()` is called externally).
    ///
    /// The enclosing TaskGroup awaits all in-flight connection tasks on scope
    /// exit, so a shutdown on one client still lets other clients finish
    /// their pending response before the serve call returns.
    public func serve(vm: VM) async {
        await withTaskGroup(of: Void.self) { group in
            while serverFd >= 0 {
                let handles: (read: FileHandle, write: FileHandle)
                do {
                    handles = try accept()
                } catch {
                    if serverFd < 0 { break } // server was closed
                    continue
                }

                group.addTask { [weak self] in
                    await self?.handleConnection(handles: handles, vm: vm)
                }
            }
            // TaskGroup auto-awaits remaining children on scope exit.
        }
    }

    /// Handle one client connection: read framed NDJSON requests and dispatch
    /// them to the VM until the client disconnects or sends a terminal
    /// request. State (read buffer, fd) is strictly local to this call —
    /// concurrent connections do not share any mutable state beyond the VM
    /// actor (serialized by its own executor) and the CommandRunner's
    /// internal locks (per-exec AsyncStream map, transferContinuation slot).
    private func handleConnection(
        handles: (read: FileHandle, write: FileHandle),
        vm: VM
    ) async {
        let clientFd = handles.read.fileDescriptor
        defer { Darwin.close(clientFd) }

        // Read and dispatch messages until client disconnects.
        // The buffer persists across reads for this connection to
        // handle coalesced NDJSON frames.
        var readBuf = Data()
        while true {
            let msgData: Data
            do {
                msgData = try readMessage(from: handles.read, buffer: &readBuf)
            } catch {
                break // client disconnected
            }

            let request: SessionRequest
            do {
                request = try SessionProtocol.decodeRequest(msgData)
            } catch {
                try? writeResponse(.error(message: "Invalid request: \(error)"), to: handles.write)
                break
            }

            switch request {
            case .exec(let cmd, let timeout, let env, let cwd):
                // Pass the current read buffer so any bytes already buffered
                // (e.g. stdin messages that arrived in the same TCP segment as
                // the exec request) are not dropped. handleExec owns the read
                // handle and buffer for the exec's lifetime.
                let bufSnapshot = readBuf
                readBuf = Data()
                await handleExec(
                    cmd: cmd, timeout: timeout, env: env, cwd: cwd,
                    vm: vm, writeHandle: handles.write,
                    readHandle: handles.read, initialBuffer: bufSnapshot
                )

            case .upload(let localPath, let remotePath):
                await handleUpload(localPath: localPath, remotePath: remotePath, vm: vm, handle: handles.write)

            case .download(let remotePath, let localPath):
                await handleDownload(remotePath: remotePath, localPath: localPath, vm: vm, handle: handles.write)

            case .cancel(let signal, let gracePeriod):
                do {
                    try await vm.cancel(signal: signal, gracePeriod: gracePeriod)
                } catch {
                    try? writeResponse(.error(message: "Cancel failed: \(error)"), to: handles.write)
                }

            case .stdin, .stdinClose:
                // Stdin messages outside of an exec context are no-ops.
                // They should not appear here because handleExec reads them
                // directly from the socket during exec, but guard defensively.
                break

            case .shutdown:
                await vm.shutdown()
                try? writeResponse(.exit(code: 0, durationMs: 0), to: handles.write)
                close()
                return
            }
        }
    }

    // MARK: - Request Handlers

    /// Execute a command in the VM and stream output back to the client.
    ///
    /// During the exec, this method takes over reading from `readHandle` so
    /// that `stdin` and `stdinClose` messages from the client are forwarded
    /// to the VM exec. `cancel` messages are also handled inline.
    ///
    /// When the exec completes, `Darwin.shutdown(SHUT_RD)` is called on the
    /// read fd to unblock the socket-reader task (which may be blocked in
    /// `availableData`). This does NOT close the write direction — the
    /// connection remains open for subsequent requests.
    ///
    /// `initialBuffer` contains any bytes already read from the socket
    /// before the exec request was parsed (coalesced NDJSON frames). The
    /// stdin reader starts from these bytes before issuing new reads.
    private func handleExec(
        cmd: String, timeout: Int, env: [String: String], cwd: String?,
        vm: VM, writeHandle: FileHandle,
        readHandle: FileHandle, initialBuffer: Data
    ) async {
        let channel = StdinChannel()
        let stdin = Stdin.source { @Sendable [channel] in await channel.next() }

        await withTaskGroup(of: Void.self) { group in
            // Task 1: run the exec and forward output chunks to the client.
            // When the exec finishes (success, error, or timeout), signals
            // EOF to the stdin channel and shuts down the read side of the
            // socket to unblock Task 2.
            group.addTask { [weak self] in
                guard let self else { return }
                let start = ContinuousClock.now
                do {
                    let chunks = try await vm.stream(cmd, timeout: timeout, env: env, cwd: cwd, stdin: stdin)
                    for try await chunk in chunks {
                        switch chunk {
                        case .stdout(let data):
                            try? self.writeResponse(.output(stream: .stdout, data: data), to: writeHandle)
                        case .stderr(let data):
                            try? self.writeResponse(.output(stream: .stderr, data: data), to: writeHandle)
                        case .stdoutBytes(let bytes):
                            try? self.writeResponse(.outputBytes(stream: .stdout, base64: bytes.base64EncodedString()), to: writeHandle)
                        case .stderrBytes(let bytes):
                            try? self.writeResponse(.outputBytes(stream: .stderr, base64: bytes.base64EncodedString()), to: writeHandle)
                        case .exit(let code):
                            let ms = (ContinuousClock.now - start).totalMilliseconds
                            try? self.writeResponse(.exit(code: code, durationMs: ms), to: writeHandle)
                        }
                    }
                } catch {
                    try? self.writeResponse(.error(message: String(describing: error)), to: writeHandle)
                }
                // Signal EOF to the stdin pump so the pump task exits cleanly.
                channel.close()
                // Unblock Task 2's blocking availableData call by shutting
                // down the read direction of the socket. The write direction
                // remains open for subsequent responses after exec.
                Darwin.shutdown(readHandle.fileDescriptor, SHUT_RD)
            }

            // Task 2: read stdin/stdinClose/cancel messages from the client
            // socket and route them to the appropriate handler during exec.
            // Exits when the socket read side is shut down (by Task 1 on
            // exec completion) or when the client disconnects.
            group.addTask { [weak self] in
                guard let self else { return }
                var buf = initialBuffer
                while !Task.isCancelled {
                    let msgData: Data
                    do {
                        msgData = try self.readMessage(from: readHandle, buffer: &buf)
                    } catch {
                        break // socket closed or shut down
                    }
                    guard let request = try? SessionProtocol.decodeRequest(msgData) else { break }
                    switch request {
                    case .stdin(let data):
                        channel.send(Data(data.utf8))
                    case .stdinClose:
                        channel.close()
                    case .cancel(let signal, let gracePeriod):
                        try? await vm.cancel(signal: signal, gracePeriod: gracePeriod)
                    default:
                        // Other message types are not expected during exec;
                        // ignore to avoid protocol confusion.
                        break
                    }
                }
                // Ensure channel is closed even if socket closed unexpectedly.
                channel.close()
            }
        }
    }

    private func handleUpload(localPath: String, remotePath: String, vm: VM, handle: FileHandle) async {
        let upload = FileUpload(localPath: URL(fileURLWithPath: localPath), remotePath: remotePath)
        let result = await vm.uploadFilesResult([upload])
        switch result {
        case .success:
            try? writeResponse(.uploadDone(path: remotePath), to: handle)
        case .failure(let error):
            try? writeResponse(.error(message: "Upload failed: \(error)"), to: handle)
        }
    }

    private func handleDownload(remotePath: String, localPath: String, vm: VM, handle: FileHandle) async {
        let download = FileDownload(remotePath: remotePath, localPath: URL(fileURLWithPath: localPath))
        let result = await vm.downloadFilesResult([download])
        switch result {
        case .success:
            try? writeResponse(.downloadDone(path: localPath), to: handle)
        case .failure(let error):
            try? writeResponse(.error(message: "Download failed: \(error)"), to: handle)
        }
    }
}

// MARK: - StdinChannel

/// Thread-safe single-producer, single-consumer queue for stdin data.
///
/// Bridges the session IPC socket reader (Task 2 in handleExec) with the
/// VM exec's `Stdin.source` pump (which runs as a detached Task inside
/// CommandRunner.spawnStdinPump). The pump calls `next()` in a loop;
/// the socket reader calls `send(_:)` for each chunk and `close()` on EOF.
///
/// Uses NSLock + CheckedContinuation rather than an actor to avoid
/// re-entrancy issues: `send()` must resume a waiting `next()` without
/// suspending, which actors would prevent.
final class StdinChannel: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Data] = []
    private var closed = false
    private var waiter: CheckedContinuation<Data?, Never>?

    /// Enqueue a chunk of stdin data.
    /// If `next()` is currently suspended waiting for data, resumes it immediately.
    func send(_ data: Data) {
        lock.withLock {
            if let cont = waiter {
                waiter = nil
                cont.resume(returning: data)
            } else {
                queue.append(data)
            }
        }
    }

    /// Signal EOF. Subsequent calls to `next()` return nil.
    /// Safe to call multiple times (idempotent).
    func close() {
        lock.withLock {
            closed = true
            if let cont = waiter {
                waiter = nil
                cont.resume(returning: nil)
            }
        }
    }

    /// Return the next stdin chunk, suspending until one is available.
    /// Returns nil when the channel is closed (EOF).
    func next() async -> Data? {
        await withCheckedContinuation { cont in
            lock.withLock {
                if !queue.isEmpty {
                    cont.resume(returning: queue.removeFirst())
                } else if closed {
                    cont.resume(returning: nil)
                } else {
                    waiter = cont
                }
            }
        }
    }
}
