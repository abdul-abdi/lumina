// Sources/Lumina/SessionServer.swift
import Foundation

/// Listens on a Unix domain socket and dispatches SessionRequest messages
/// to a VM actor. Each accepted connection is served sequentially -- one
/// client at a time (the CLI client connects, sends a request, gets a
/// response, disconnects).
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
    public func readMessage(from handle: FileHandle) throws -> Data {
        var buffer = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty {
                if buffer.isEmpty { throw LuminaError.connectionFailed }
                return buffer
            }
            buffer.append(chunk)
            if buffer.count > SessionProtocol.maxMessageSize {
                throw LuminaError.protocolError("Session message exceeds 64KB")
            }
            if buffer.firstIndex(of: UInt8(ascii: "\n")) != nil {
                return buffer
            }
        }
    }

    /// Write a SessionResponse to the client.
    public func writeResponse(_ response: SessionResponse, to handle: FileHandle) throws {
        let data = try SessionProtocol.encode(response)
        handle.write(data)
    }

    /// Close the server socket.
    public func close() {
        if serverFd >= 0 {
            Darwin.close(serverFd)
            serverFd = -1
        }
        try? FileManager.default.removeItem(at: socketPath)
    }

    /// Run the server loop: accept connections, dispatch requests to the VM.
    /// This blocks indefinitely until the server is closed or a shutdown request arrives.
    public func serve(vm: VM) async {
        while serverFd >= 0 {
            let handles: (read: FileHandle, write: FileHandle)
            do {
                handles = try accept()
            } catch {
                if serverFd < 0 { break } // server was closed
                continue
            }

            let clientFd = handles.read.fileDescriptor
            defer { Darwin.close(clientFd) }

            // Read and dispatch messages until client disconnects
            while true {
                let msgData: Data
                do {
                    msgData = try readMessage(from: handles.read)
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
                case .exec(let cmd, let timeout, let env):
                    await handleExec(cmd: cmd, timeout: timeout, env: env, vm: vm, handle: handles.write)

                case .upload(let localPath, let remotePath):
                    await handleUpload(localPath: localPath, remotePath: remotePath, vm: vm, handle: handles.write)

                case .download(let remotePath, let localPath):
                    await handleDownload(remotePath: remotePath, localPath: localPath, vm: vm, handle: handles.write)

                case .shutdown:
                    await vm.shutdown()
                    try? writeResponse(.exit(code: 0, durationMs: 0), to: handles.write)
                    close()
                    return
                }
            }
        }
    }

    // MARK: - Request Handlers

    private func handleExec(cmd: String, timeout: Int, env: [String: String], vm: VM, handle: FileHandle) async {
        let start = ContinuousClock.now
        do {
            // Stream output in real time — each chunk is sent to the client as it arrives
            // from the guest agent, rather than buffering the entire result.
            let chunks = try await vm.stream(cmd, timeout: timeout, env: env)
            for try await chunk in chunks {
                switch chunk {
                case .stdout(let data):
                    try? writeResponse(.output(stream: .stdout, data: data), to: handle)
                case .stderr(let data):
                    try? writeResponse(.output(stream: .stderr, data: data), to: handle)
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
