// Tests/LuminaTests/PoolTests.swift
import Foundation
import Testing
@testable import Lumina

// MARK: - Unit tests (no VM required)

@Test func poolDefaultSize() {
    let pool = Pool()
    #expect(pool.size == 4)
}

@Test func poolCustomSize() {
    let pool = Pool(size: 8)
    #expect(pool.size == 8)
}

@Test func poolImageConvenience() {
    let pool = Pool(size: 2, image: "myimage")
    #expect(pool.size == 2)
    #expect(pool.options.image == "myimage")
}

@Test func poolOptionsDefaults() {
    let pool = Pool()
    #expect(pool.options.memory == VMOptions().memory)
    #expect(pool.options.cpuCount == VMOptions().cpuCount)
    #expect(pool.options.image == "default")
}

@Test func poolCustomOptions() {
    let opts = VMOptions(memory: 512 * 1024 * 1024, cpuCount: 1, image: "alpine")
    let pool = Pool(size: 3, options: opts)
    #expect(pool.size == 3)
    #expect(pool.options.memory == 512 * 1024 * 1024)
    #expect(pool.options.cpuCount == 1)
    #expect(pool.options.image == "alpine")
}

// MARK: - Integration tests (require Apple Silicon + VM image)

private func integrationEnabled() -> Bool {
    ProcessInfo.processInfo.environment["LUMINA_INTEGRATION_TESTS"] == "1"
}

@Test(.enabled(if: integrationEnabled()))
func poolBootAndSingleRun() async throws {
    let pool = Pool(size: 2, options: VMOptions(memory: 512 * 1024 * 1024, cpuCount: 2))
    try await pool.boot()
    defer { Task { await pool.shutdown() } }

    let result = try await pool.run("echo hello-pool", timeout: .seconds(30))
    #expect(result.stdout.contains("hello-pool"))
    #expect(result.exitCode == 0)
}

@Test(.enabled(if: integrationEnabled()))
func poolConcurrentRuns() async throws {
    let n = 4
    let pool = Pool(size: n, options: VMOptions(memory: 512 * 1024 * 1024, cpuCount: 2))
    try await pool.boot()
    defer { Task { await pool.shutdown() } }

    var results: [RunResult] = []
    await withTaskGroup(of: RunResult.self) { group in
        for i in 0..<n {
            group.addTask { [pool] in
                (try? await pool.run("echo run-\(i)", timeout: .seconds(30)))
                ?? RunResult(stdout: "", stderr: "failed", exitCode: 1, wallTime: .zero)
            }
        }
        for await r in group {
            results.append(r)
        }
    }

    #expect(results.count == n)
    #expect(results.allSatisfy { $0.success })
}

@Test(.enabled(if: integrationEnabled()))
func poolRefillsAfterUse() async throws {
    // Pool of 1: run twice, verifying that the second run gets a freshly booted VM
    let pool = Pool(size: 1, options: VMOptions(memory: 512 * 1024 * 1024, cpuCount: 2))
    try await pool.boot()
    defer { Task { await pool.shutdown() } }

    let r1 = try await pool.run("echo run1", timeout: .seconds(30))
    // Give refill task time to complete
    try await Task.sleep(for: .milliseconds(500))
    let r2 = try await pool.run("echo run2", timeout: .seconds(30))

    #expect(r1.stdout.contains("run1"))
    #expect(r2.stdout.contains("run2"))
}

@Test(.enabled(if: integrationEnabled()))
func poolShutdownRejectsNewRuns() async throws {
    let pool = Pool(size: 1, options: VMOptions(memory: 512 * 1024 * 1024, cpuCount: 2))
    try await pool.boot()
    await pool.shutdown()

    do {
        _ = try await pool.run("echo hi", timeout: .seconds(10))
        Issue.record("Expected error after shutdown")
    } catch let error as LuminaError {
        if case .sessionFailed = error { /* expected */ } else {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
