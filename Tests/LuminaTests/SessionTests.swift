// Tests/LuminaTests/SessionTests.swift
import Foundation
import Testing
@testable import Lumina

@Test func sessionOptionsDefaults() {
    let opts = SessionOptions()
    #expect(opts.cpuCount == 2)
    #expect(opts.memory == 512 * 1024 * 1024)
    #expect(opts.image == "default")
    #expect(opts.volumes.isEmpty)
}

@Test func sessionInfoSerialization() throws {
    let info = SessionInfo(
        sid: "test-uuid",
        pid: 1234,
        image: "default",
        cpuCount: 2,
        memory: 512 * 1024 * 1024,
        created: Date(timeIntervalSince1970: 1000),
        status: .running
    )
    let data = try JSONEncoder().encode(info)
    let decoded = try JSONDecoder().decode(SessionInfo.self, from: data)
    #expect(decoded.sid == "test-uuid")
    #expect(decoded.pid == 1234)
    #expect(decoded.status == .running)
}

@Test func sessionPaths() {
    let session = SessionPaths(sid: "abc-123")
    #expect(session.directory.path.hasSuffix("/.lumina/sessions/abc-123"))
    #expect(session.socket.path.hasSuffix("/control.sock"))
    #expect(session.metaFile.path.hasSuffix("/meta.json"))
}

@Test func sessionStateEquality() {
    #expect(SessionState.running == SessionState.running)
    #expect(SessionState.running != SessionState.dead)
}
