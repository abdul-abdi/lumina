// Tests/LuminaTests/DaemonTests.swift
import Testing
import Foundation
import Darwin
@testable import Lumina

@Test func daemonSocketPathIsUnderLuminaHome() {
    let path = Daemon.socketPath().path
    #expect(path.contains("/.lumina/"))
}

@Test func tryRunReturnsNilWhenNoSocket() async throws {
    let missing = URL(fileURLWithPath: "/tmp/lumina-daemon-definitely-absent-\(UUID().uuidString).sock")
    let result = try await Daemon.tryRun(command: "echo hi", socketPath: missing)
    #expect(result == nil)
}

@Test func statusReportsNotRunningWhenNoSocket() async {
    let missing = URL(fileURLWithPath: "/tmp/lumina-daemon-definitely-absent-\(UUID().uuidString).sock")
    let s = await Daemon.status(socketPath: missing)
    #expect(s == .notRunning)
}

@Test func stopReturnsFalseWhenNotRunning() async {
    let missing = URL(fileURLWithPath: "/tmp/lumina-daemon-definitely-absent-\(UUID().uuidString).sock")
    let stopped = await Daemon.stop(socketPath: missing)
    #expect(stopped == false)
}

@Test(.disabled("requires real VM — Phase 4 integration bench"))
func serveBoot() async throws {
    try await Daemon.serve(size: 1, image: "default")
}

// MARK: - writeAll (fix #3: loop-or-surface-error, not silent partial write)

@Test func writeAllWritesLargePayloadCompletely() async throws {
    var fds: [Int32] = [0, 0]
    let rc = fds.withUnsafeMutableBufferPointer { socketpair(AF_UNIX, SOCK_STREAM, 0, $0.baseAddress) }
    #expect(rc == 0)
    let writeFd = fds[0]
    let readFd = fds[1]
    defer { Darwin.close(writeFd); Darwin.close(readFd) }

    // Larger than the default socket send/receive buffers so writeAll must
    // loop over multiple write(2) calls to land the whole thing.
    let payload = Data(repeating: 0x42, count: 4 * 1024 * 1024)

    async let received: Data = withCheckedContinuation { (cont: CheckedContinuation<Data, Never>) in
        DispatchQueue.global().async {
            var buf = [UInt8](repeating: 0, count: 65536)
            var total = Data()
            while total.count < payload.count {
                let n = Darwin.read(readFd, &buf, buf.count)
                if n <= 0 { break }
                total.append(contentsOf: buf[0..<n])
            }
            cont.resume(returning: total)
        }
    }

    #expect(writeAll(fd: writeFd, data: payload))
    let got = await received
    #expect(got == payload)
}

@Test func writeAllReturnsFalseAfterPeerCloses() {
    var fds: [Int32] = [0, 0]
    let rc = fds.withUnsafeMutableBufferPointer { socketpair(AF_UNIX, SOCK_STREAM, 0, $0.baseAddress) }
    #expect(rc == 0)
    let writeFd = fds[0]
    disableSigpipe(fd: writeFd) // otherwise the broken pipe kills the test process
    Darwin.close(fds[1])

    var sawFailure = false
    for _ in 0..<50 {
        if !writeAll(fd: writeFd, data: Data(repeating: 0x1, count: 4096)) {
            sawFailure = true
            break
        }
    }
    #expect(sawFailure)
    Darwin.close(writeFd)
}

// MARK: - Accept-loop hardening (fix #1: SO_RCVTIMEO, fix #2: backoff)

@Test func setReceiveTimeoutBoundsABlockingRead() {
    var fds: [Int32] = [0, 0]
    let rc = fds.withUnsafeMutableBufferPointer { socketpair(AF_UNIX, SOCK_STREAM, 0, $0.baseAddress) }
    #expect(rc == 0)
    let readFd = fds[0]
    defer { Darwin.close(fds[0]); Darwin.close(fds[1]) }

    #expect(setReceiveTimeout(fd: readFd, seconds: 0.2))

    let start = ContinuousClock.now
    var byte = UInt8(0)
    let n = Darwin.read(readFd, &byte, 1) // nothing written on the other end
    let elapsedMs = (ContinuousClock.now - start).totalMilliseconds

    #expect(n == -1)
    #expect(errno == EAGAIN || errno == EWOULDBLOCK)
    #expect(elapsedMs < 2000)
}

@Test func acceptBackoffDelayIsLinearAndCapped() {
    #expect(acceptBackoffDelay(consecutiveFailures: 0) == .milliseconds(0))
    #expect(acceptBackoffDelay(consecutiveFailures: 1) == .milliseconds(10))
    #expect(acceptBackoffDelay(consecutiveFailures: 5) == .milliseconds(50))
    #expect(acceptBackoffDelay(consecutiveFailures: 1000) == .milliseconds(500))
}

// MARK: - Stdin.oneShot (fix #5: stdin plumbed through the daemon protocol)

@Test func stdinOneShotYieldsDataOnceThenNil() async throws {
    let payload = Data("hello".utf8)
    guard case .source(let source) = Stdin.oneShot(payload) else {
        Issue.record("expected .source")
        return
    }
    let first = try await source()
    let second = try await source()
    #expect(first == payload)
    #expect(second == nil)
}

// MARK: - DaemonStatus (fix #4: distinguishable .unreachable)

@Test func statusReportsUnreachableForStaleSocket() async {
    let path = "/tmp/lumina-daemon-stale-\(UUID().uuidString).sock"
    guard let fd = unixListen(path: path) else {
        Issue.record("failed to bind test socket")
        return
    }
    Darwin.close(fd) // file stays put; nothing is listening anymore
    defer { try? FileManager.default.removeItem(atPath: path) }

    let s = await Daemon.status(socketPath: URL(fileURLWithPath: path))
    guard case .unreachable = s else {
        Issue.record("expected .unreachable, got \(s)")
        return
    }
}

@Test func statusReportsUnreachableForMalformedResponse() async {
    let path = "/tmp/lumina-daemon-malformed-\(UUID().uuidString).sock"
    guard let server = FakeDaemonServer(path: path) else {
        Issue.record("failed to bind test socket")
        return
    }
    server.acceptAndRespond { _ in Data("not json\n".utf8) }

    let s = await Daemon.status(socketPath: URL(fileURLWithPath: path))
    await server.close()
    try? FileManager.default.removeItem(atPath: path)

    guard case .unreachable = s else {
        Issue.record("expected .unreachable, got \(s)")
        return
    }
}

@Test func statusReportsUnreachableForMissingFields() async {
    let path = "/tmp/lumina-daemon-missingfield-\(UUID().uuidString).sock"
    guard let server = FakeDaemonServer(path: path) else {
        Issue.record("failed to bind test socket")
        return
    }
    server.acceptAndRespond { _ in
        var line = try! JSONSerialization.data(withJSONObject: ["poolSize": 4, "image": "default"])
        line.append(0x0a)
        return line
    }

    let s = await Daemon.status(socketPath: URL(fileURLWithPath: path))
    await server.close()
    try? FileManager.default.removeItem(atPath: path)

    guard case .unreachable = s else {
        Issue.record("expected .unreachable, got \(s)")
        return
    }
}

@Test func statusReportsRunningForValidPing() async {
    let path = "/tmp/lumina-daemon-valid-\(UUID().uuidString).sock"
    guard let server = FakeDaemonServer(path: path) else {
        Issue.record("failed to bind test socket")
        return
    }
    server.acceptAndRespond { _ in
        var line = try! JSONSerialization.data(withJSONObject: ["poolSize": 4, "warm": 2, "image": "default"])
        line.append(0x0a)
        return line
    }

    let s = await Daemon.status(socketPath: URL(fileURLWithPath: path))
    await server.close()
    try? FileManager.default.removeItem(atPath: path)

    #expect(s == .running(poolSize: 4, warm: 2, image: "default"))
}

// MARK: - tryRun request shape (fix #5: uploads/downloads/stdin on the wire)

@Test func tryRunEmbedsUploadsDownloadsAndStdinInRequest() async throws {
    let path = "/tmp/lumina-daemon-shape-\(UUID().uuidString).sock"
    guard let server = FakeDaemonServer(path: path) else {
        Issue.record("failed to bind test socket")
        return
    }

    let captured = CapturedRequest()
    server.acceptAndRespond { line in
        captured.set(line)
        let envelope = RunResultEnvelope(
            from: RunResult(stdout: "ok", stderr: "", exitCode: 0, wallTime: .milliseconds(1)),
            durationMs: 1
        )
        var resp = try! JSONEncoder().encode(envelope)
        resp.append(0x0a)
        return resp
    }

    let upload = FileUpload(localPath: URL(fileURLWithPath: "/tmp/in.txt"), remotePath: "/work/in.txt")
    let download = FileDownload(remotePath: "/work/out.txt", localPath: URL(fileURLWithPath: "/tmp/out.txt"))
    let stdinBytes = Data("piped input".utf8)

    let result = try await Daemon.tryRun(
        command: "cat",
        uploads: [upload],
        downloads: [download],
        stdinData: stdinBytes,
        socketPath: URL(fileURLWithPath: path)
    )
    await server.close()
    try? FileManager.default.removeItem(atPath: path)

    #expect(result?.stdout == "ok")

    guard let raw = captured.data,
          let json = try JSONSerialization.jsonObject(with: raw) as? [String: Any]
    else {
        Issue.record("no request captured")
        return
    }
    let uploads = json["uploads"] as? [[String: String]]
    #expect(uploads?.first?["local"] == "/tmp/in.txt")
    #expect(uploads?.first?["remote"] == "/work/in.txt")
    let downloads = json["downloads"] as? [[String: String]]
    #expect(downloads?.first?["remote"] == "/work/out.txt")
    #expect(downloads?.first?["local"] == "/tmp/out.txt")
    #expect(json["stdin_b64"] as? String == stdinBytes.base64EncodedString())
}

// MARK: - Test doubles

/// One-shot fake daemon: binds a real Unix socket, accepts a single
/// connection on a background queue, and drives `respond` off the raw
/// request line. `unixListen` runs synchronously in `init`, so callers that
/// invoke the client-side API right after construction don't race accept().
///
/// `close()` awaits the accept task before closing the listener fd. Closing
/// while another thread is still blocked inside accept(2) on that same fd
/// number is a real race under a large parallel test run — the number can
/// be reused by an unrelated test before the blocked syscall notices.
private final class FakeDaemonServer: @unchecked Sendable {
    private let listenerFd: Int32
    private let lock = NSLock()
    private var acceptTask: Task<Void, Never>?

    init?(path: String) {
        guard let fd = unixListen(path: path) else { return nil }
        listenerFd = fd
    }

    func acceptAndRespond(_ respond: @escaping @Sendable (Data) -> Data?) {
        let listenerFd = self.listenerFd
        let task = Task.detached {
            let clientFd = await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
                DispatchQueue.global().async {
                    cont.resume(returning: unixAcceptFd(listener: listenerFd))
                }
            }
            guard clientFd >= 0 else { return }
            defer { Darwin.close(clientFd) }
            guard let line = Self.blockingReadLine(fd: clientFd) else { return }
            if let resp = respond(line) {
                writeAll(fd: clientFd, data: resp)
            }
        }
        lock.withLock { acceptTask = task }
    }

    private static func blockingReadLine(fd: Int32) -> Data? {
        var buffer = Data()
        var byte = UInt8(0)
        while true {
            let n = Darwin.read(fd, &byte, 1)
            if n <= 0 { return buffer.isEmpty ? nil : buffer }
            if byte == 0x0a { return buffer }
            buffer.append(byte)
        }
    }

    /// Waits for the in-flight accept (bounded — a client that never
    /// connects would otherwise block this forever) before closing.
    func close() async {
        if let task = lock.withLock({ acceptTask }) {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await task.value }
                group.addTask { try? await Task.sleep(for: .seconds(2)) }
                await group.next()
                group.cancelAll()
            }
        }
        Darwin.close(listenerFd)
    }
}

/// Cross-thread capture box for a fake server's view of what the client sent.
private final class CapturedRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var _data: Data?
    func set(_ d: Data) { lock.withLock { _data = d } }
    var data: Data? { lock.withLock { _data } }
}
