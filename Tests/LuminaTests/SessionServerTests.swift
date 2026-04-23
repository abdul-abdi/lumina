// Tests/LuminaTests/SessionServerTests.swift
import Foundation
import Testing
@testable import Lumina

@Test func serverSocketCreation() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let socketPath = tmpDir.appendingPathComponent("control.sock")
    let server = SessionServer(socketPath: socketPath)
    try server.bind()
    defer { server.close() }

    #expect(FileManager.default.fileExists(atPath: socketPath.path))
}

@Test func serverAcceptsConnection() async throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let socketPath = tmpDir.appendingPathComponent("control.sock")
    let server = SessionServer(socketPath: socketPath)
    try server.bind()
    defer { server.close() }

    // Connect a client socket
    let clientFd = socket(AF_UNIX, SOCK_STREAM, 0)
    #expect(clientFd >= 0)
    defer { close(clientFd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = socketPath.path.utf8CString
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        let bound = ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
            pathBytes.withUnsafeBufferPointer { src in
                let count = min(src.count, 104)
                dest.update(from: src.baseAddress!, count: count)
                return count
            }
        }
        _ = bound
    }
    let connectResult = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            Darwin.connect(clientFd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    #expect(connectResult == 0)
}

// MARK: - Buffered Read Tests

/// Verify that readMessage correctly handles coalesced NDJSON frames
/// by splitting on newlines and retaining leftover bytes in the buffer.
@Test func serverReadMessageHandlesCoalescedFrames() async throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let socketPath = tmpDir.appendingPathComponent("control.sock")
    let server = SessionServer(socketPath: socketPath)

    // Use a pipe to simulate the read side
    var fds: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
        throw LuminaError.sessionFailed("socketpair failed")
    }
    defer {
        close(fds[0])
        close(fds[1])
    }

    // Write two coalesced NDJSON requests in one write
    let req1 = try SessionProtocol.encode(SessionRequest.exec(cmd: "echo hello", timeout: 30, env: [:]))
    let req2 = try SessionProtocol.encode(SessionRequest.shutdown)
    var combined = Data()
    combined.append(req1)
    combined.append(req2)
    let writer = FileHandle(fileDescriptor: fds[1], closeOnDealloc: false)
    writer.write(combined)

    let reader = FileHandle(fileDescriptor: fds[0], closeOnDealloc: false)
    var buffer = Data()

    // First read should return the exec request
    let msg1Data = try await server.readMessage(from: reader, buffer: &buffer)
    let decoded1 = try SessionProtocol.decodeRequest(msg1Data)
    #expect(decoded1 == .exec(cmd: "echo hello", timeout: 30, env: [:]))

    // Second read should return the shutdown request (from leftover buffer)
    let msg2Data = try await server.readMessage(from: reader, buffer: &buffer)
    let decoded2 = try SessionProtocol.decodeRequest(msg2Data)
    #expect(decoded2 == .shutdown)

    _ = server // keep server alive
}

/// Regression test for the cooperative-pool starvation bug fixed in
/// commit edd1410 ("async readMessage to stop starving the cooperative
/// pool"). Before that fix, `readMessage` used `FileHandle.availableData`
/// — a synchronous blocking `read(2)`. Running inside an async Task on
/// Swift's cooperative thread pool, each parked connection held one pool
/// thread in `read(2)` indefinitely. Around CPU-count connections (~8-11
/// on an M-series) the pool saturated and the session wedged: accept
/// loop, dispatch, and response writes all stalled.
///
/// The fix moves the blocking read to a dedicated GCD concurrent queue
/// via `withCheckedContinuation`, freeing cooperative threads for
/// dispatch work while the kernel read blocks.
///
/// This test locks in the invariant: 64 concurrent `readMessage` calls
/// (≈8× typical CPU-count) must all complete, not hang. A regression
/// to the synchronous path would park every reader on the pool and the
/// final `group.waitForAll()` would never return, blowing the wall-clock
/// budget below.
@Test func readMessageDoesNotStarveCooperativePool() async throws {
    let pairCount = 64

    var allFds: [Int32] = []
    var readers: [FileHandle] = []
    var writers: [FileHandle] = []
    for _ in 0..<pairCount {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw LuminaError.sessionFailed("socketpair failed: errno=\(errno)")
        }
        allFds.append(fds[0])
        allFds.append(fds[1])
        readers.append(FileHandle(fileDescriptor: fds[0], closeOnDealloc: false))
        writers.append(FileHandle(fileDescriptor: fds[1], closeOnDealloc: false))
    }
    defer { allFds.forEach { close($0) } }

    let frame = try SessionProtocol.encode(
        SessionRequest.exec(cmd: "echo probe", timeout: 10, env: [:])
    )

    // `readMessage` does not touch `self.serverFd`, so an un-bound server
    // instance is fine. We only need the method.
    let tmpSocket = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString + ".sock")
    let server = SessionServer(socketPath: tmpSocket)

    let start = ContinuousClock.now
    try await withThrowingTaskGroup(of: Void.self) { group in
        for reader in readers {
            group.addTask {
                var buffer = Data()
                _ = try await server.readMessage(from: reader, buffer: &buffer)
            }
        }
        // Give readers a moment to suspend in the await boundary.
        try await Task.sleep(for: .milliseconds(100))
        for writer in writers {
            writer.write(frame)
        }
        try await group.waitForAll()
    }
    let elapsed = ContinuousClock.now - start

    // Empirical: ~300-500ms for 64 readers on an M3 Pro. 10s is a
    // generous ceiling chosen to catch a regression, not fine-grained
    // performance. A blocking-read regression hangs well past this.
    #expect(elapsed < .seconds(10),
        "64 concurrent readMessage calls took \(elapsed) — possible cooperative-pool regression (see commit edd1410)")
}

@Test func bindRejectsPathExceeding103Bytes() throws {
    // sockaddr_un.sun_path is 104 bytes on macOS (including null terminator).
    // Paths > 103 bytes must be rejected before silent truncation occurs.
    let tmpDir = FileManager.default.temporaryDirectory
    // Build a path that uses all of the available 103 bytes.
    // tmpDir.path is typically ~40 chars; pad with 'a's to reach exactly 104.
    let padding = String(repeating: "a", count: max(1, 104 - tmpDir.path.count - 1))
    let longName = padding + ".sock"
    let longPath = tmpDir.appendingPathComponent(longName)
    // Verify our constructed path is actually over 103 bytes.
    guard longPath.path.utf8.count > 103 else {
        Issue.record("Path construction did not exceed 103 bytes — test cannot verify guard. tmpDir: \(tmpDir.path)")
        return
    }
    let server = SessionServer(socketPath: longPath)
    #expect(throws: (any Error).self) {
        try server.bind()
    }
}
