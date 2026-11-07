// Sources/Lumina/Daemon.swift
//
// Unix-socket daemon wrapping Pool. `lumina daemon serve` pre-boots N VMs and
// listens on ~/.lumina/lumind.sock. `lumina run --via-daemon` dials the socket
// instead of cold-booting a fresh VM.
//
// Wire protocol (NDJSON):
//   Request:  {"op":"run","cmd":"...","timeout":30,"env":{...},"cwd":"...",
//              "uploads":[{"local":"...","remote":"...","mode":"0644"}],
//              "directory_uploads":[{"local":"...","remote":"..."}],
//              "downloads":[{"remote":"...","local":"..."}],
//              "stdin_b64":"..."}
//             {"op":"ping"}
//             {"op":"shutdown"}
//   Response: same ResultEnvelope JSON the CLI already emits from `lumina run`
//             {"poolSize":N,"warm":M,"image":"..."}   (ping)
//
// uploads/downloads carry host-side paths, not file bytes — the daemon runs
// on the same host as the client, so it reads/writes those paths directly.
// stdin has no such shortcut (only the CLI process has the real fd), so it's
// read to EOF and base64'd into the request; the daemon replays it as a
// one-shot Stdin source (see `Stdin.oneShot`).
//
// Signal handling: DispatchSource on SIGINT/SIGTERM (NOT C signal() — see
// lumina-v071-session.md: signal() callbacks cannot run Swift safely).
//
// Blocking I/O: Darwin read(2) wrapped in DispatchQueue.global().async +
// withCheckedContinuation. FileHandle.availableData is FORBIDDEN
// (cooperative-pool starvation — see swift-cooperative-pool-starvation learning).
//
// Accepted client fds get SO_RCVTIMEO so a client that connects and sends no
// newline can't hold the (deliberately serial — see #33) accept loop open
// forever.

import Foundation
import Darwin

// MARK: - Public API

/// Status of the daemon as seen from the client side.
public enum DaemonStatus: Sendable, Equatable {
    case notRunning
    case running(poolSize: Int, warm: Int, image: String)
    /// Socket file exists but the daemon didn't answer cleanly — stale socket
    /// from a crashed process, a write/read failure, or a malformed response.
    /// Kept distinct from `.notRunning` so a caller doesn't start a second
    /// daemon over a first one that's still alive: `serve()` unlinks the
    /// socket path unconditionally, so a second `daemon serve` silently
    /// orphans the first daemon's pool rather than failing to bind.
    case unreachable(reason: String)
}

/// Unix-socket daemon wrapping `Pool`. All static functions; no instance state.
public enum Daemon {

    /// SO_RCVTIMEO on each accepted client fd. Real requests are one local
    /// NDJSON line — 5s is generous for that and short enough that a silent
    /// client can't wedge the serial accept loop for long.
    private static let clientReceiveTimeoutSeconds: Double = 5.0

    // MARK: - Socket path

    /// `~/.lumina/lumind.sock`
    public static func socketPath() -> URL {
        if let path = ProcessInfo.processInfo.environment["LUMINA_DAEMON_SOCKET"] {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".lumina")
            .appendingPathComponent("lumind.sock")
    }

    // MARK: - Client: tryRun

    /// Connect to daemon; send a run request; return `RunResult` or `nil` if daemon unreachable.
    /// Never throws on connection failure — callers fall back to cold boot on `nil`.
    public static func tryRun(
        image: String = "default",
        memory: UInt64 = VMOptions.default.memory,
        cpuCount: Int = VMOptions.default.cpuCount,
        command: String,
        timeout: Int = 60,
        env: [String: String] = [:],
        cwd: String? = nil,
        uploads: [FileUpload] = [],
        directoryUploads: [DirectoryUpload] = [],
        downloads: [FileDownload] = [],
        stdinData: Data? = nil,
        socketPath: URL? = nil
    ) async throws -> RunResult? {
        let sockURL = socketPath ?? Daemon.socketPath()
        guard FileManager.default.fileExists(atPath: sockURL.path) else { return nil }
        guard let fd = unixConnect(path: sockURL.path) else { return nil }
        defer { Darwin.close(fd) }

        // Build NDJSON request. Uploads/downloads carry host paths only —
        // the daemon reads/writes them directly since it's on the same host.
        let request = DaemonRequest(
            op: "run", image: image, memory: memory, cpus: cpuCount, cmd: command, timeout: timeout,
            env: env, cwd: cwd,
            uploads: uploads.map { .init(local: $0.localPath.path, remote: $0.remotePath, mode: $0.mode) },
            directory_uploads: directoryUploads.map { .init(local: $0.localPath.path, remote: $0.remotePath) },
            downloads: downloads.map { .init(local: $0.localPath.path, remote: $0.remotePath) },
            stdin_b64: stdinData.flatMap { $0.isEmpty ? nil : $0.base64EncodedString() }
        )
        guard let line = request.line else { return nil }

        // A failed write means the request never reliably reached the daemon —
        // treat it the same as a failed connect (safe to retry cold) rather
        // than risk a half-request the daemon then hangs reading more of.
        guard writeAll(fd: fd, data: line) else { return nil }

        // Past this point the request is on the wire and the daemon may
        // already have run the command. Returning nil here would read as
        // "daemon unreachable" and the caller would re-run it cold — an
        // `apt install` or a migration executed twice, silently. Anything that
        // fails after the send must throw.
        guard let respLine = await asyncReadLine(fd: fd) else {
            throw LuminaError.sessionFailed(
                "daemon closed the connection after the request was sent; the command may have run — not retrying"
            )
        }
        if let declined = try? JSONDecoder().decode([String: String].self, from: respLine), declined["declined"] != nil {
            return nil
        }
        let envelope: RunResultEnvelope
        do {
            envelope = try JSONDecoder().decode(RunResultEnvelope.self, from: respLine)
        } catch {
            throw LuminaError.protocolError(
                "daemon sent an undecodable response after the request was sent; the command may have run — not retrying"
            )
        }
        switch envelope.error {
        case nil: return envelope.toRunResult()
        case "timeout": throw LuminaError.timeout
        case let e? where e.hasPrefix("guestCrashed"): throw LuminaError.guestCrashed(serialOutput: "")
        case let e?: throw LuminaError.sessionFailed("daemon: \(e)")
        }
    }

    // MARK: - Client: status

    /// Query daemon status. Returns `.notRunning` only when there's no socket
    /// file at all — anything that looks like a daemon once existed but
    /// didn't answer cleanly comes back as `.unreachable(reason:)` instead.
    public static func status(socketPath: URL? = nil) async -> DaemonStatus {
        let sockURL = socketPath ?? Daemon.socketPath()
        guard FileManager.default.fileExists(atPath: sockURL.path) else { return .notRunning }
        guard let fd = unixConnect(path: sockURL.path) else {
            return .unreachable(reason: "socket exists at \(sockURL.path) but connect failed (stale socket from a crashed daemon?)")
        }
        defer { Darwin.close(fd) }

        guard let line = DaemonRequest(op: "ping").line, writeAll(fd: fd, data: line) else {
            return .unreachable(reason: "write to daemon socket failed")
        }

        guard let respLine = await asyncReadLine(fd: fd) else {
            return .unreachable(reason: "no response from daemon (timed out or disconnected)")
        }
        guard let pong = try? JSONDecoder().decode(DaemonPong.self, from: respLine) else {
            return .unreachable(reason: "malformed ping response from daemon")
        }
        return .running(poolSize: pong.poolSize, warm: pong.warm, image: pong.image)
    }

    // MARK: - Client: stop

    /// Send shutdown op to daemon. Returns `true` if daemon was running, `false` otherwise.
    public static func stop(socketPath: URL? = nil) async -> Bool {
        let sockURL = socketPath ?? Daemon.socketPath()
        guard FileManager.default.fileExists(atPath: sockURL.path) else { return false }
        guard let fd = unixConnect(path: sockURL.path) else { return false }

        if let line = DaemonRequest(op: "shutdown").line {
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

        let sockPathCopy = sockURL.path
        onTerminationSignal { _ in
            FileHandle.standardError.write(Data("\nlumina daemon: shutting down\n".utf8))
            try? FileManager.default.removeItem(atPath: sockPathCopy)
            Darwin.exit(0)
        }

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
        var consecutiveAcceptFailures = 0
        while true {
            let clientFd = await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
                DispatchQueue.global().async {
                    cont.resume(returning: unixAcceptFd(listener: listenerFd))
                }
            }
            guard clientFd >= 0 else {
                // A persistent accept() error (e.g. EMFILE) would otherwise
                // spin this loop at 100% CPU instead of degrading gracefully.
                consecutiveAcceptFailures += 1
                try? await Task.sleep(for: acceptBackoffDelay(consecutiveFailures: consecutiveAcceptFailures))
                continue
            }
            consecutiveAcceptFailures = 0

            // A client that connects and never sends a newline would otherwise
            // block asyncReadLine's read(2) forever, wedging this serial loop
            // for every subsequent --via-daemon caller.
            setReceiveTimeout(fd: clientFd, seconds: Self.clientReceiveTimeoutSeconds)
            disableSigpipe(fd: clientFd)

            Task {
                await handleDaemonClient(
                    fd: clientFd, pool: pool, image: image, socketPath: sockURL
                )
            }
        }
    }
}

// MARK: - Per-connection handler

private func handleDaemonClient(fd: Int32, pool: Pool, image: String, socketPath: URL) async {
    defer { Darwin.close(fd) }

    // Read one NDJSON line
    guard let line = await asyncReadLine(fd: fd),
          let request = try? JSONDecoder().decode(DaemonRequest.self, from: line)
    else { return }

    switch request.op {
    case "ping":
        let pong = DaemonPong(poolSize: pool.size, warm: await pool.availableCount, image: image)
        if let data = try? JSONEncoder().encode(pong) {
            writeAll(fd: fd, data: data + [0x0a])
        }

    case "shutdown":
        try? FileManager.default.removeItem(at: socketPath)
        Darwin.exit(0)

    case "run":
        await runOnDaemon(request, fd: fd, pool: pool)

    default:
        if let data = try? JSONEncoder().encode(["error": "unknown op: \(request.op)"]) {
            writeAll(fd: fd, data: data + [0x0a])
        }
    }
}

private func runOnDaemon(_ request: DaemonRequest, fd: Int32, pool: Pool) async {
    let wanted = (
        request.image ?? pool.options.image,
        request.memory ?? pool.options.memory,
        request.cpus ?? pool.options.cpuCount
    )
    guard wanted == (pool.options.image, pool.options.memory, pool.options.cpuCount) else {
        writeAll(fd: fd, data: Data(#"{"declined":"pool shape differs"}"#.utf8 + [0x0a]))
        return
    }
    let start = ContinuousClock.now
    let result: RunResult
    do {
        result = try await pool.run(
            request.cmd ?? "",
            timeout: .seconds(request.timeout ?? 60),
            env: request.env ?? [:],
            workingDirectory: request.cwd,
            uploads: (request.uploads ?? []).map {
                FileUpload(localPath: URL(fileURLWithPath: $0.local), remotePath: $0.remote, mode: $0.mode ?? "0644")
            },
            directoryUploads: (request.directory_uploads ?? []).map {
                DirectoryUpload(localPath: URL(fileURLWithPath: $0.local), remotePath: $0.remote)
            },
            downloads: (request.downloads ?? []).map {
                FileDownload(remotePath: $0.remote, localPath: URL(fileURLWithPath: $0.local))
            },
            stdin: request.stdin_b64.flatMap { Data(base64Encoded: $0) }.map(Stdin.oneShot) ?? .closed
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

extension Stdin {
    /// Wraps already-read bytes as a one-shot `Stdin.source`: the exec pump
    /// gets the whole blob on its first call, then EOF. Used where the real
    /// stdin fd has already been drained upstream — the daemon's NDJSON
    /// request needs the full blob up front to base64 it in, and a CLI
    /// falling back from an unreachable daemon to cold boot must replay the
    /// same bytes rather than re-read an already-EOF'd fd.
    public static func oneShot(_ data: Data) -> Stdin {
        let channel = StdinChannel()
        channel.send(data)
        channel.close()
        return .source { @Sendable [channel] in await channel.next() }
    }
}

struct DaemonRequest: Codable {
    struct Transfer: Codable {
        var local: String
        var remote: String
        var mode: String?
    }

    var op: String
    var image: String?
    var memory: UInt64?
    var cpus: Int?
    var cmd: String?
    var timeout: Int?
    var env: [String: String]?
    var cwd: String?
    var uploads: [Transfer]?
    var directory_uploads: [Transfer]?
    var downloads: [Transfer]?
    var stdin_b64: String?

    var line: Data? { (try? JSONEncoder().encode(self)).map { $0 + [0x0a] } }
}

struct DaemonPong: Codable {
    var poolSize: Int
    var warm: Int
    var image: String
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
private func asyncReadLine(fd: Int32) async -> Data? {
    await withCheckedContinuation { cont in
        DispatchQueue.global().async {
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 65_536)
            while true {
                let n = Darwin.read(fd, &chunk, chunk.count)
                if n <= 0 {
                    // EOF or error
                    cont.resume(returning: buffer.isEmpty ? nil : buffer)
                    return
                }
                if let newline = chunk[0..<n].firstIndex(of: 0x0a) {
                    buffer.append(contentsOf: chunk[0..<newline])
                    cont.resume(returning: buffer.isEmpty ? nil : buffer)
                    return
                }
                buffer.append(contentsOf: chunk[0..<n])
            }
        }
    }
}

// MARK: - Write helper

/// Write all bytes to `fd`, retrying on EINTR. Returns `false` on a real
/// write error rather than silently leaving a partial write on the wire.
/// `internal` so tests can drive it with a socketpair.
@discardableResult
func writeAll(fd: Int32, data: Data) -> Bool {
    guard !data.isEmpty else { return true }
    return data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Bool in
        guard let base = ptr.baseAddress else { return true }
        var written = 0
        let total = ptr.count
        while written < total {
            let n = Darwin.write(fd, base.advanced(by: written), total - written)
            if n > 0 {
                written += n
                continue
            }
            if n < 0 && errno == EINTR { continue }
            return false
        }
        return true
    }
}

// MARK: - Accept-loop hardening

/// SO_RCVTIMEO on `fd` so a blocking read(2) can't hang forever. Best-effort.
@discardableResult
func setReceiveTimeout(fd: Int32, seconds: Double) -> Bool {
    var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
    return withUnsafePointer(to: &tv) { p in
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, p, socklen_t(MemoryLayout<timeval>.stride)) == 0
    }
}

/// Without this, a peer that closes mid-write sends this process SIGPIPE
/// (default action: terminate) before `writeAll` ever sees the failed
/// write(2) it's meant to report — a disconnected client would otherwise
/// take the whole daemon down. Applied to both ends of the socket (accepted
/// client fds and `unixConnect`'s client-side fd).
@discardableResult
func disableSigpipe(fd: Int32) -> Bool {
    var one: Int32 = 1
    return setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0
}

/// Linear backoff capped at 500ms for repeated accept() failures.
func acceptBackoffDelay(consecutiveFailures: Int) -> Duration {
    .milliseconds(min(max(consecutiveFailures, 0) * 10, 500))
}

// MARK: - POSIX Unix socket helpers (mirrored from lumi/Pool.swift; internal for testability)

/// Bind and listen on a Unix domain socket. Returns listener fd or nil on failure.
func unixListen(path: String, backlog: Int32 = 64) -> Int32? {
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
    if Darwin.listen(fd, backlog) != 0 { Darwin.close(fd); return nil }
    return fd
}

/// Accept one incoming connection. Returns client fd (≥0) or -1 on failure.
/// Designed to be called from a DispatchQueue.global() context.
func unixAcceptFd(listener: Int32) -> Int32 {
    var caddr = sockaddr_un()
    var clen = socklen_t(MemoryLayout<sockaddr_un>.stride)
    return withUnsafeMutablePointer(to: &caddr) { ap in
        ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(listener, $0, &clen) }
    }
}

/// Connect to a Unix domain socket. Returns connected fd or nil on failure.
func unixConnect(path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 { return nil }
    disableSigpipe(fd: fd)
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

private let terminationQueue = DispatchQueue(label: "com.lumina.signals")
nonisolated(unsafe) private var terminationSources: [DispatchSourceSignal] = []

public func onTerminationSignal(_ handler: @escaping @Sendable (Int32) -> Void) {
    let sources = [SIGINT, SIGTERM].map { sig in
        Foundation.signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: terminationQueue)
        src.setEventHandler { handler(sig) }
        src.resume()
        return src
    }
    terminationQueue.sync { terminationSources += sources }
}
