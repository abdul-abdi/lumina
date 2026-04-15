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
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
                pathBytes.withUnsafeBufferPointer { src in
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
                let written = Darwin.write(fd, base + offset, remaining)
                if written < 0 {
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
                await handleExec(cmd: cmd, timeout: timeout, env: env, cwd: cwd, vm: vm, handle: handles.write)

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

            case .stdin:
                // Stdin forwarding via sessions requires exec ID tracking.
                // The library API (VM.sendStdin) is the current path for
                // session stdin. SessionProtocol.stdin(data:) does not carry
                // an exec ID and cannot target the right in-flight exec on
                // a shared VM, so it is intentionally a no-op here.
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

    private func handleExec(cmd: String, timeout: Int, env: [String: String], cwd: String?, vm: VM, handle: FileHandle) async {
        let start = ContinuousClock.now
        do {
            // Stream output in real time — each chunk is sent to the client as it arrives
            // from the guest agent, rather than buffering the entire result.
            let chunks = try await vm.stream(cmd, timeout: timeout, env: env, cwd: cwd)
            for try await chunk in chunks {
                switch chunk {
                case .stdout(let data):
                    try? writeResponse(.output(stream: .stdout, data: data), to: handle)
                case .stderr(let data):
                    try? writeResponse(.output(stream: .stderr, data: data), to: handle)
                case .stdoutBytes(let bytes):
                    // Binary chunk: lossy-convert for session text protocol (binary session transfers not yet supported)
                    try? writeResponse(.output(stream: .stdout, data: String(decoding: bytes, as: UTF8.self)), to: handle)
                case .stderrBytes(let bytes):
                    try? writeResponse(.output(stream: .stderr, data: String(decoding: bytes, as: UTF8.self)), to: handle)
                case .exit(let code):
                    let ms = (ContinuousClock.now - start).totalMilliseconds
                    try? writeResponse(.exit(code: code, durationMs: ms), to: handle)
                }
            }
        } catch {
            try? writeResponse(.error(message: String(describing: error)), to: handle)
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
