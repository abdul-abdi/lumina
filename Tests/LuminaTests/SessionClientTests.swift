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
