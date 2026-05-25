// Tests/LuminaTests/DaemonTests.swift
import Testing
import Foundation
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
