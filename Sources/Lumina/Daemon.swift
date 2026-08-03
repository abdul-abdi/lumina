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
        var req: [String: Any] = [
            "op": "run",
            "cmd": command,
            "timeout": timeout,
            "env": env,
        ]
        if let c = cwd { req["cwd"] = c }
        if !uploads.isEmpty {
            req["uploads"] = uploads.map { ["local": $0.localPath.path, "remote": $0.remotePath, "mode": $0.mode] }
        }
        if !directoryUploads.isEmpty {
            req["directory_uploads"] = directoryUploads.map { ["local": $0.localPath.path, "remote": $0.remotePath] }
        }
        if !downloads.isEmpty {
            req["downloads"] = downloads.map { ["remote": $0.remotePath, "local": $0.localPath.path] }
        }
        if let stdinData, !stdinData.isEmpty {
            req["stdin_b64"] = stdinData.base64EncodedString()
        }
        guard let reqData = try? JSONSerialization.data(withJSONObject: req) else { return nil }
        var line = reqData
        line.append(0x0a) // newline

        // A failed write means the request never reliably reached the daemon —
        // treat it the same as a failed connect (safe to retry cold) rather
        // than risk a half-request the daemon then hangs reading more of.
        guard writeAll(fd: fd, data: line) else { return nil }

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

        let req: [String: Any] = ["op": "ping"]
        guard let reqData = try? JSONSerialization.data(withJSONObject: req) else {
            return .unreachable(reason: "failed to encode ping request")
        }
        var line = reqData
        line.append(0x0a)
        guard writeAll(fd: fd, data: line) else {
            return .unreachable(reason: "write to daemon socket failed")
        }

        guard let respLine = try? await asyncReadLine(fd: fd) else {
            return .unreachable(reason: "no response from daemon (timed out or disconnected)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: respLine) as? [String: Any] else {
            return .unreachable(reason: "malformed (non-JSON) response from daemon")
        }
        guard let poolSize = json["poolSize"] as? Int,
              let warm = json["warm"] as? Int,
              let image = json["image"] as? String
        else {
            return .unreachable(reason: "ping response missing poolSize/warm/image fields")
        }

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
            workingDirectory: cwd,
            uploads: decodeFileUploads(json["uploads"]),
            directoryUploads: decodeDirectoryUploads(json["directory_uploads"]),
            downloads: decodeFileDownloads(json["downloads"]),
            stdin: decodeStdin(json["stdin_b64"])
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

// MARK: - Request-side transfer / stdin decoding
//
// uploads/downloads carry host paths (see wire protocol note at the top of
// this file) — decode straight into the same types Pool.run already accepts.

private func decodeFileUploads(_ raw: Any?) -> [FileUpload] {
    guard let specs = raw as? [[String: String]] else { return [] }
    return specs.compactMap { spec in
        guard let local = spec["local"], let remote = spec["remote"] else { return nil }
        return FileUpload(localPath: URL(fileURLWithPath: local), remotePath: remote, mode: spec["mode"] ?? "0644")
    }
}

private func decodeDirectoryUploads(_ raw: Any?) -> [DirectoryUpload] {
    guard let specs = raw as? [[String: String]] else { return [] }
    return specs.compactMap { spec in
        guard let local = spec["local"], let remote = spec["remote"] else { return nil }
        return DirectoryUpload(localPath: URL(fileURLWithPath: local), remotePath: remote)
    }
}

private func decodeFileDownloads(_ raw: Any?) -> [FileDownload] {
    guard let specs = raw as? [[String: String]] else { return [] }
    return specs.compactMap { spec in
        guard let remote = spec["remote"], let local = spec["local"] else { return nil }
        return FileDownload(remotePath: remote, localPath: URL(fileURLWithPath: local))
    }
}

/// Rehydrates the base64 stdin blob as a one-shot source — the request
/// already carries the whole thing, so there's nothing left to stream.
private func decodeStdin(_ raw: Any?) -> Stdin {
    guard let b64 = raw as? String, let data = Data(base64Encoded: b64), !data.isEmpty else {
        return .closed
    }
    return .oneShot(data)
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
func unixListen(path: String) -> Int32? {
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
