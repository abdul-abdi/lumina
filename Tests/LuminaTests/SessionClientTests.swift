// Tests/LuminaTests/SessionClientTests.swift
import Foundation
import Testing
@testable import Lumina

@Test func clientConnectToMissingSid() throws {
    let client = SessionClient()
    #expect(throws: LuminaError.self) {
        try client.connect(sid: "nonexistent-sid-12345")
    }
}

@Test func clientDetectsDeadSession() throws {
    // Create a session dir with a dead PID
    let sessionsDir = FileManager.default.temporaryDirectory.appendingPathComponent("lumina-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: sessionsDir) }

    let sid = "dead-session"
    let paths = SessionPaths(sid: sid, sessionsDir: sessionsDir)
    let info = SessionInfo(
        sid: sid, pid: 99999, image: "default", cpuCount: 2,
        memory: 512 * 1024 * 1024, created: Date(), status: .running
    )
    try paths.writeMeta(info)

    let client = SessionClient(sessionsDir: sessionsDir)
    #expect(throws: LuminaError.self) {
        try client.connect(sid: sid)
    }
}

// MARK: - Buffered Read Tests

/// Verify that coalesced NDJSON frames (multiple messages in one read)
/// are correctly split and returned one at a time.
@Test func clientReceiveHandlesCoalescedFrames() throws {
    // Create a socket pair to simulate session IPC
    var fds: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
        throw LuminaError.sessionFailed("socketpair failed")
    }
    defer {
        close(fds[0])
        close(fds[1])
    }

    // Build a SessionClient with our test socket
    let client = SessionClient()
    client.injectTestSocket(readFd: fds[0], writeFd: fds[0])

    // Write two coalesced NDJSON responses in one write
    let msg1 = try SessionProtocol.encode(SessionResponse.output(stream: .stdout, data: "hello"))
    let msg2 = try SessionProtocol.encode(SessionResponse.exit(code: 0, durationMs: 100))
    var combined = Data()
    combined.append(msg1)
    combined.append(msg2)
    let writer = FileHandle(fileDescriptor: fds[1], closeOnDealloc: false)
    writer.write(combined)

    // First receive should return the output message
    let resp1 = try client.receive()
    #expect(resp1 == .output(stream: .stdout, data: "hello"))

    // Second receive should return the exit message (from leftover buffer)
    let resp2 = try client.receive()
    #expect(resp2 == .exit(code: 0, durationMs: 100))
}

/// Verify that three coalesced frames are all returned correctly.
@Test func clientReceiveHandlesThreeCoalescedFrames() throws {
    var fds: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
        throw LuminaError.sessionFailed("socketpair failed")
    }
    defer {
        close(fds[0])
        close(fds[1])
    }

    let client = SessionClient()
    client.injectTestSocket(readFd: fds[0], writeFd: fds[0])

    let msg1 = try SessionProtocol.encode(SessionResponse.output(stream: .stdout, data: "line1"))
    let msg2 = try SessionProtocol.encode(SessionResponse.output(stream: .stderr, data: "err"))
    let msg3 = try SessionProtocol.encode(SessionResponse.exit(code: 1, durationMs: 50))
    var combined = Data()
    combined.append(msg1)
    combined.append(msg2)
    combined.append(msg3)
    let writer = FileHandle(fileDescriptor: fds[1], closeOnDealloc: false)
    writer.write(combined)

    #expect(try client.receive() == .output(stream: .stdout, data: "line1"))
    #expect(try client.receive() == .output(stream: .stderr, data: "err"))
    #expect(try client.receive() == .exit(code: 1, durationMs: 50))
}
