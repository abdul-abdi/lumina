// Tests/LuminaTests/IntegrationTests.swift
import Foundation
import Testing
@testable import Lumina

// Integration tests — require:
// 1. Alpine image at ~/.lumina/images/default/
// 2. Test binary signed with com.apple.security.virtualization entitlement
// Gate: set LUMINA_INTEGRATION_TESTS=1 after codesigning the test binary.
// Example: swift build --build-tests && codesign --entitlements lumina.entitlements --force -s - .build/debug/LuminaPackageTests.xctest && LUMINA_INTEGRATION_TESTS=1 swift test

private func integrationEnabled() -> Bool {
    guard ProcessInfo.processInfo.environment["LUMINA_INTEGRATION_TESTS"] == "1" else { return false }
    let store = ImageStore()
    return (try? store.resolve(name: "default")) != nil
}

@Test(.enabled(if: integrationEnabled()))
func integrationRunEcho() async throws {
    let result = try await Lumina.run("echo hello", options: RunOptions(timeout: .seconds(30)))
    #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
    #expect(result.success)
}

@Test(.enabled(if: integrationEnabled()))
func integrationRunExitCode() async throws {
    let result = try await Lumina.run("exit 42", options: RunOptions(timeout: .seconds(30)))
    #expect(result.exitCode == 42)
    #expect(!result.success)
}

@Test(.enabled(if: integrationEnabled()))
func integrationRunStderr() async throws {
    let result = try await Lumina.run("echo err >&2", options: RunOptions(timeout: .seconds(30)))
    #expect(result.stderr.contains("err"))
}

@Test(.enabled(if: integrationEnabled()))
func integrationRunTimeout() async {
    do {
        _ = try await Lumina.run("sleep 60", options: RunOptions(timeout: .seconds(3)))
        Issue.record("Expected timeout error")
    } catch let error as LuminaError {
        if case .timeout = error {
            // Expected — timeout fired correctly
        } else {
            Issue.record("Expected .timeout, got: \(error)")
        }
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
}

@Test(.enabled(if: integrationEnabled()))
func integrationVMLifecycle() async throws {
    let vm = VM(options: VMOptions(memory: 512 * 1024 * 1024, cpuCount: 2))
    #expect(await vm.state == .idle)

    try await vm.boot()
    #expect(await vm.state == .ready)

    let result = try await vm.exec("echo lifecycle")
    #expect(result.stdout.contains("lifecycle"))

    await vm.shutdown()
    #expect(await vm.state == .shutdown)
}

@Test(.enabled(if: integrationEnabled()))
func integrationBootTime() async throws {
    let start = ContinuousClock.now
    let result = try await Lumina.run("echo fast", options: RunOptions(timeout: .seconds(10)))
    let elapsed = ContinuousClock.now - start

    #expect(result.success)
    // Target: under 3 seconds (relaxed for CI, aim for <2s locally)
    #expect(elapsed < .seconds(3), "Boot + exec took \(elapsed), target is <3s")
}
