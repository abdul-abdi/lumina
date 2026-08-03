// Sources/Lumina/Daemon.swift
//
// Unix-socket daemon wrapping Pool. `lumina daemon serve` pre-boots N VMs and
// listens on ~/.lumina/lumind.sock. `lumina run --via-daemon` dials the socket
// instead of cold-booting a fresh VM.
//
// Wire protocol (NDJSON):
//   Request:  {"op":"run","cmd":"...","timeout":30,"env":{...},"cwd":"..."}
//             {"op":"ping"}
//             {"op":"shutdown"}
//   Response: same ResultEnvelope JSON the CLI already emits from `lumina run`
//             {"poolSize":N,"warm":M,"image":"..."}   (ping)
//
// Signal handling: DispatchSource on SIGINT/SIGTERM (NOT C signal() — see
// lumina-v071-session.md: signal() callbacks cannot run Swift safely).
//
// Blocking I/O: Darwin read(2) wrapped in DispatchQueue.global().async +
// withCheckedContinuation. FileHandle.availableData is FORBIDDEN
// (cooperative-pool starvation — see swift-cooperative-pool-starvation learning).

import Foundation
import Darwin

// MARK: - Public API

/// Status of the daemon as seen from the client side.
public enum DaemonStatus: Sendable, Equatable {
    case notRunning
    case running(poolSize: Int, warm: Int, image: String)
}

/// Unix-socket daemon wrapping `Pool`. All static functions; no instance state.
public enum Daemon {

    // MARK: - Socket path

    /// `~/.lumina/lumind.sock`
    public static func socketPath() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".lumina")
            .appendingPathComponent("lumind.sock")
    }

    // MARK: - Client: tryRun

    /// Connect to daemon; send a run request; return `RunResult` or `nil` if daemon unreachable.
    /// Never throws on connection failure — callers fall back to cold boot on `nil`.
    public static func tryRun(
        image: String = "default",
        command: String,
        timeout: Int = 60,
        env: [String: String] = [:],
        cwd: String? = nil,
        socketPath: URL? = nil
    ) async throws -> RunResult? {
        let sockURL = socketPath ?? Daemon.socketPath()
        guard FileManager.default.fileExists(atPath: sockURL.path) else { return nil }
        guard let fd = unixConnect(path: sockURL.path) else { return nil }
        defer { Darwin.close(fd) }

        // Build NDJSON request
        var req: [String: Any] = [
            "op": "run",
            "cmd": command,
            "timeout": timeout,
            "env": env,
        ]
        if let c = cwd { req["cwd"] = c }
        guard let reqData = try? JSONSerialization.data(withJSONObject: req) else { return nil }
        var line = reqData
        line.append(0x0a) // newline
        writeAll(fd: fd, data: line)

        // Past this point the request is on the wire and the daemon may
        // already have run the command. Returning nil here would read as
        // "daemon unreachable" and the caller would re-run it cold — an
        // `apt install` or a migration executed twice, silently. Anything that
        // fails after the send must throw.
        guard let respLine = try await asyncReadLine(fd: fd) else {
            throw LuminaError.sessionFailed(
                "daemon closed the connection after the request was sent; the command may have run — not retrying"
            )
        }
        let dec = JSONDecoder()
        do {
            return try dec.decode(RunResultEnvelope.self, from: respLine).toRunResult()
        } catch {
            throw LuminaError.protocolError(
                "daemon sent an undecodable response after the request was sent; the command may have run — not retrying"
            )
        }
    }

    // MARK: - Client: status

    /// Query daemon status. Returns `.notRunning` if socket absent or unreachable.
    public static func status(socketPath: URL? = nil) async -> DaemonStatus {
        let sockURL = socketPath ?? Daemon.socketPath()
        guard FileManager.default.fileExists(atPath: sockURL.path) else { return .notRunning }
        guard let fd = unixConnect(path: sockURL.path) else { return .notRunning }
        defer { Darwin.close(fd) }

        let req: [String: Any] = ["op": "ping"]
        guard let reqData = try? JSONSerialization.data(withJSONObject: req) else { return .notRunning }
        var line = reqData
        line.append(0x0a)
        writeAll(fd: fd, data: line)

        guard let respLine = try? await asyncReadLine(fd: fd),
              let json = try? JSONSerialization.jsonObject(with: respLine) as? [String: Any],
              let poolSize = json["poolSize"] as? Int,
              let warm = json["warm"] as? Int,
              let image = json["image"] as? String
        else { return .notRunning }

        return .running(poolSize: poolSize, warm: warm, image: image)
    }

    // MARK: - Client: stop

    /// Send shutdown op to daemon. Returns `true` if daemon was running, `false` otherwise.
    public static func stop(socketPath: URL? = nil) async -> Bool {
        let sockURL = socketPath ?? Daemon.socketPath()
        guard FileManager.default.fileExists(atPath: sockURL.path) else { return false }
        guard let fd = unixConnect(path: sockURL.path) else { return false }

        let req: [String: Any] = ["op": "shutdown"]
        if let reqData = try? JSONSerialization.data(withJSONObject: req) {
            var line = reqData
            line.append(0x0a)
            writeAll(fd: fd, data: line)
        }
        Darwin.close(fd)
        try? FileManager.default.removeItem(at: sockURL)
        return true
    }

    // MARK: - Server: serve

    /// Main daemon entry point. Binds the socket, boots the pool, accepts forever.
    /// Never returns (the process exits on SIGINT/SIGTERM or shutdown op).
    public static func serve(
        size: Int = 4,
        image: String = "default",
        socketPath: URL? = nil
    ) async throws -> Never {
        let sockURL = socketPath ?? Daemon.socketPath()

        // Mkdir ~/.lumina defensively
        let luminaDir = sockURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: luminaDir, withIntermediateDirectories: true
        )

        // Remove stale socket
        try? FileManager.default.removeItem(at: sockURL)

        guard let listenerFd = unixListen(path: sockURL.path) else {
            throw LuminaError.sessionFailed("daemon: bind \(sockURL.path) failed")
        }

        // Restrict socket to owner: rw------- (0600)
        if chmod(sockURL.path, S_IRUSR | S_IWUSR) != 0 {
            let reason = String(cString: strerror(errno))
            FileHandle.standardError.write(Data(
                "lumina daemon: warning: chmod 0600 on \(sockURL.path) failed: \(reason)\n".utf8
            ))
        }

        // Install SIGINT/SIGTERM via DispatchSource (NOT C signal() — see learning)
        Foundation.signal(SIGINT, SIG_IGN)
        Foundation.signal(SIGTERM, SIG_IGN)
        let sockPathCopy = sockURL.path
        let signalQueue = DispatchQueue(label: "com.lumina.daemon.signals")
        let sigSources: [DispatchSourceSignal] = [SIGINT, SIGTERM].map { sig in
            let src = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
            src.setEventHandler {
                FileHandle.standardError.write(Data("\nlumina daemon: shutting down\n".utf8))
                try? FileManager.default.removeItem(atPath: sockPathCopy)
                Darwin.exit(0)
            }
            src.resume()
            return src
        }
        _ = sigSources // retain

        // Boot pool
        let pool = Pool(size: size, image: image)
        FileHandle.standardError.write(Data(
            "lumina daemon: booting \(size) VM(s) (image: \(image))...\n".utf8
        ))
        do {
            try await pool.boot()
        } catch {
            FileHandle.standardError.write(Data(
                "lumina daemon: pool boot failed: \(error)\n".utf8
            ))
            try? FileManager.default.removeItem(at: sockURL)
            throw error
        }
        FileHandle.standardError.write(Data(
            "lumina daemon: ready on \(sockURL.path)\n".utf8
        ))

        // Accept loop — serial handler dispatch.
        //
        // Each accepted client is handled to completion before the next is
        // accepted. This costs concurrency (clients queue) but avoids the
        // N≥pool concurrent-exec race (CommandRunner vsock dispatcher trips
        // `connectionFailed` when N exec()s hit N VMs simultaneously, see
        // GitHub #33). Pool.run still uses the warm pool — first response
        // is ~1 ms; subsequent queued clients pay queueing latency rather
        // than wedge. For agent workloads with think-time between calls
        // this is invisible; for synthetic burst (xargs -P N) clients are
        // effectively serialized.
        //
        // Lifting this to detached Tasks (Task.detached { ... }) requires
        // fixing the underlying CommandRunner race first.
        while true {
            let clientFd = await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
                DispatchQueue.global().async {
                    cont.resume(returning: unixAcceptFd(listener: listenerFd))
                }
            }
            guard clientFd >= 0 else { continue }
            await handleDaemonClient(
                fd: clientFd, pool: pool, image: image, socketPath: sockURL
            )
        }
    }
}

// MARK: - Per-connection handler

private func handleDaemonClient(fd: Int32, pool: Pool, image: String, socketPath: URL) async {
    defer { Darwin.close(fd) }

    // Read one NDJSON line
    guard let line = try? await asyncReadLine(fd: fd),
          let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
          let op = json["op"] as? String
    else { return }

    switch op {
    case "ping":
        let poolSize = pool.size // nonisolated
        let warm = await pool.availableCount
        let resp: [String: Any] = ["poolSize": poolSize, "warm": warm, "image": image]
        if let data = try? JSONSerialization.data(withJSONObject: resp) {
            var out = data; out.append(0x0a)
            writeAll(fd: fd, data: out)
        }

    case "shutdown":
        try? FileManager.default.removeItem(at: socketPath)
        Darwin.exit(0)

    case "run":
        await runOnDaemon(json: json, fd: fd, pool: pool)

    default:
        let err: [String: Any] = ["error": "unknown op: \(op)"]
        if let data = try? JSONSerialization.data(withJSONObject: err) {
            var out = data; out.append(0x0a)
            writeAll(fd: fd, data: out)
        }
    }
}

private func runOnDaemon(json: [String: Any], fd: Int32, pool: Pool) async {
    let cmd = (json["cmd"] as? String) ?? ""
    let env = (json["env"] as? [String: String]) ?? [:]
    let cwd = json["cwd"] as? String
    let timeoutSec = (json["timeout"] as? Int) ?? 60

    let start = ContinuousClock.now
    let result: RunResult
    do {
        result = try await pool.run(
            cmd,
            timeout: .seconds(timeoutSec),
            env: env,
            workingDirectory: cwd
        )
    } catch {
        let ms = Int((ContinuousClock.now - start).totalMilliseconds)
        let envelope = RunResultEnvelope(error: String(describing: error), duration_ms: ms)
        if let data = try? JSONEncoder().encode(envelope) {
            var out = data; out.append(0x0a)
            writeAll(fd: fd, data: out)
        }
        return
    }

    let ms = Int((ContinuousClock.now - start).totalMilliseconds)
    let envelope = RunResultEnvelope(from: result, durationMs: ms)
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    if let data = try? enc.encode(envelope) {
        var out = data; out.append(0x0a)
        writeAll(fd: fd, data: out)
    }
}

// MARK: - Wire envelope (mirrors CLI's private ResultJSON shape exactly)

/// Codable envelope matching the JSON shape lumina-cli emits from `lumina run`.
/// Field names are snake_case to match the wire protocol.
struct RunResultEnvelope: Codable, Sendable {
    var stdout: String?
    var stderr: String?
    var stdout_bytes: String?
    var stderr_bytes: String?
    var exit_code: Int?
    var error: String?
    var duration_ms: Int
    var partial_stdout: String?
    var partial_stderr: String?
    var network_metrics: NetworkMetricsSummary?

    /// Build from a successful `RunResult`.
    init(from result: RunResult, durationMs: Int) {
        self.stdout = result.stdout
        self.stderr = result.stderr
        self.stdout_bytes = result.stdoutBytes.map { $0.base64EncodedString() }
        self.stderr_bytes = result.stderrBytes.map { $0.base64EncodedString() }
        self.exit_code = Int(result.exitCode)
        self.duration_ms = durationMs
        self.network_metrics = result.networkMetrics
    }

    /// Build for an error response.
    init(error: String, duration_ms: Int) {
        self.duration_ms = duration_ms
        self.error = error
    }

    /// Decode back to `RunResult` on the client side.
    func toRunResult() -> RunResult {
        let stdoutData = stdout_bytes.flatMap { Data(base64Encoded: $0) }
        let stderrData = stderr_bytes.flatMap { Data(base64Encoded: $0) }
        return RunResult(
            stdout: stdout ?? "",
            stderr: stderr ?? "",
            exitCode: Int32(exit_code ?? 0),
            wallTime: .milliseconds(duration_ms),
            stdoutBytes: stdoutData,
            stderrBytes: stderrData,
            networkMetrics: network_metrics
        )
    }
}

// MARK: - Async line reader (non-blocking cooperative thread hand-off)

/// Read bytes from `fd` until `\n`, returning the data (without the newline).
/// Uses `read(2)` on a global DispatchQueue so the cooperative pool is not blocked.
/// Returns `nil` on EOF or connection close.
private func asyncReadLine(fd: Int32) async throws -> Data? {
    return try await withCheckedThrowingContinuation { cont in
        DispatchQueue.global().async {
            var buffer = Data()
            var byte = UInt8(0)
            while true {
                let n = Darwin.read(fd, &byte, 1)
                if n <= 0 {
                    // EOF or error
                    cont.resume(returning: buffer.isEmpty ? nil : buffer)
                    return
                }
                if byte == 0x0a { // newline
                    cont.resume(returning: buffer.isEmpty ? nil : buffer)
                    return
                }
                buffer.append(byte)
            }
        }
    }
}

// MARK: - Write helper

/// Write all bytes to `fd`, retrying on EINTR.
private func writeAll(fd: Int32, data: Data) {
    data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
        guard let base = ptr.baseAddress else { return }
        var written = 0
        let total = ptr.count
        while written < total {
            let n = Darwin.write(fd, base.advanced(by: written), total - written)
            if n <= 0 { return }
            written += n
        }
    }
}

// MARK: - POSIX Unix socket helpers (private — mirrored from lumi/Pool.swift)

/// Bind and listen on a Unix domain socket. Returns listener fd or nil on failure.
private func unixListen(path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 { return nil }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = path.utf8CString
    // sockaddr_un.sun_path is 104 bytes on macOS (including null terminator)
    guard pathBytes.count <= 104 else { Darwin.close(fd); return nil }
    withUnsafeMutablePointer(to: &addr.sun_path) { p in
        p.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
            for (i, b) in pathBytes.enumerated() { dst[i] = b }
        }
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.stride)
    let bindRc = withUnsafePointer(to: &addr) { ap in
        ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) }
    }
    if bindRc != 0 { Darwin.close(fd); return nil }
    if Darwin.listen(fd, 64) != 0 { Darwin.close(fd); return nil }
    return fd
}

/// Accept one incoming connection. Returns client fd (≥0) or -1 on failure.
/// Designed to be called from a DispatchQueue.global() context.
private func unixAcceptFd(listener: Int32) -> Int32 {
    var caddr = sockaddr_un()
    var clen = socklen_t(MemoryLayout<sockaddr_un>.stride)
    return withUnsafeMutablePointer(to: &caddr) { ap in
        ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(listener, $0, &clen) }
    }
}

/// Connect to a Unix domain socket. Returns connected fd or nil on failure.
private func unixConnect(path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 { return nil }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = path.utf8CString
    guard pathBytes.count <= 104 else { Darwin.close(fd); return nil }
    withUnsafeMutablePointer(to: &addr.sun_path) { p in
        p.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
            for (i, b) in pathBytes.enumerated() { dst[i] = b }
        }
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.stride)
    let rc = withUnsafePointer(to: &addr) { ap in
        ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) }
    }
    if rc != 0 { Darwin.close(fd); return nil }
    return fd
}
