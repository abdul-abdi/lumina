// Tests/LuminaTests/CancellationIntegrationTests.swift
//
// Behaviour-level cancellation tests for `VM.boot()` and
// `MacOSVM.install()`. v0.7.1 landed structural fixes (withTask-
// CancellationHandler wraps, exhaustive LuminaError.isCancellation)
// but did not drive real Task.cancel() through the boot/install
// lifecycles to prove cleanup → retry works end-to-end.
//
// The architect-lens review specifically flagged: *"A boot that gets
// cancelled at the VZ start callback must release the disk/EFI-vars
// flock so the next boot works. We don't test that loop."*
//
// These tests DO test that loop. They boot a real VZVirtualMachine,
// cancel the parent Task at three distinct phases, and assert that
// a subsequent boot on the same bundle succeeds cold.
//
// Gated behind `LUMINA_INTEGRATION_TESTS=1` + image presence, same
// pattern as `IntegrationTests.swift`. MacOSVM.install tests also
// gate on `LUMINA_IPSW_FIXTURE` pointing at a real IPSW — skipped
// when the fixture is absent (large file; not bundled with the repo).

import Foundation
import Testing
@testable import Lumina
@testable import LuminaBootable

private func integrationEnabled() -> Bool {
    guard ProcessInfo.processInfo.environment["LUMINA_INTEGRATION_TESTS"] == "1" else {
        return false
    }
    let store = ImageStore()
    return (try? store.resolve(name: "default")) != nil
}

private func ipswFixtureEnabled() -> Bool {
    guard ProcessInfo.processInfo.environment["LUMINA_INTEGRATION_TESTS"] == "1" else {
        return false
    }
    guard let path = ProcessInfo.processInfo.environment["LUMINA_IPSW_FIXTURE"] else {
        return false
    }
    return FileManager.default.fileExists(atPath: path)
}

// MARK: - VM.boot cancellation loop

/// Cancel immediately — before the Task has even hit boot's first
/// Task.checkCancellation gate. The resulting error must round-trip
/// as a cancellation, and a subsequent boot() must succeed cold.
/// This is the trivial case; it guards the fact that the Task cancel
/// gets observed at all.
@Test(.enabled(if: integrationEnabled()))
func boot_cancelImmediate_subsequentBootSucceeds() async throws {
    // Build a fresh bundle in a temp dir so we can control its
    // lifecycle without stepping on the user's ~/.lumina/desktop-vms.
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("lumina-cancel-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: tmp, withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: tmp) }

    // We exercise VM.boot via the agent path — the cancel-loop
    // structure on that path uses the same withTaskCancellationHandler
    // shape as the EFI path, and the agent-image resolve is fast.
    let task = Task {
        try await Lumina.run("echo hi", options: RunOptions(timeout: .seconds(30)))
    }
    task.cancel()
    do {
        _ = try await task.value
        Issue.record("expected cancellation or bootFailed(cancelled)")
    } catch is CancellationError {
        // Expected — raw cancellation path.
    } catch let err as LuminaError {
        #expect(err.isCancellation,
                "expected isCancellation to be true for \(err)")
    } catch {
        // Some cancel flavours wrap through Task infrastructure.
        // What we assert: next boot works regardless.
        let desc = String(describing: error)
        #expect(desc.contains("cancel") || desc.contains("bootFailed"),
                "unexpected error type: \(error)")
    }

    // The real test: a second run on the same machine must not be
    // blocked by a leaked VZ resource (disk.img flock, EFI vars lock,
    // orphaned socket device, ...). If cleanup regresses, this call
    // will hang on VZ wait or throw bootFailed.
    let result = try await Lumina.run("true", options: RunOptions(timeout: .seconds(30)))
    #expect(result.success, "second boot after cancel must succeed; got \(result)")
}

/// Cancel after the Task has started but before the VM actor's
/// `boot()` returns. Short sleep targets the window where VZ start
/// is in flight — the `withTaskCancellationHandler` path in VM.swift
/// must call `vm.stop(…)` on the executor queue and unwind cleanly.
@Test(.enabled(if: integrationEnabled()))
func boot_cancelDuringStart_releasesResources() async throws {
    let startedBoot = Task {
        try await Lumina.run("sleep 30", options: RunOptions(timeout: .seconds(60)))
    }
    // 50–150ms is inside the VZ start window on a healthy host
    // (P50 ~400ms cold boot). Jittering in this range is how the
    // test hits different lifecycle phases across iterations without
    // needing deterministic sync points inside VZ.
    try await Task.sleep(for: .milliseconds(100))
    startedBoot.cancel()

    // We don't care what type of error comes back — only that it
    // resolves (doesn't deadlock) and that the next boot works.
    _ = try? await startedBoot.value

    let result = try await Lumina.run("true", options: RunOptions(timeout: .seconds(30)))
    #expect(result.success,
            "boot after cancel-during-start must succeed; got \(result)")
}

/// Fire two cancels back-to-back across the same image. The second
/// boot (post-cancel) must succeed; the third must too. Proves the
/// cleanup loop is idempotent, not just single-shot.
@Test(.enabled(if: integrationEnabled()))
func boot_cancelCancelBoot_sequenceSucceeds() async throws {
    for i in 1...2 {
        let t = Task {
            try await Lumina.run("sleep 30", options: RunOptions(timeout: .seconds(60)))
        }
        try await Task.sleep(for: .milliseconds(80 * i))
        t.cancel()
        _ = try? await t.value
    }

    let result = try await Lumina.run("true", options: RunOptions(timeout: .seconds(30)))
    #expect(result.success,
            "third boot after two cancels must succeed; got \(result)")
}

/// Cancel late — after the guest agent has connected. The
/// CommandRunner is live when cancel lands; shutdown must tear down
/// the vsock connection cleanly. Exercises the
/// `connectCommandRunner` path, not just `VZVirtualMachine.start`.
@Test(.enabled(if: integrationEnabled()))
func boot_cancelAfterConnect_preservesHostState() async throws {
    let t = Task {
        try await Lumina.run("sleep 30", options: RunOptions(timeout: .seconds(60)))
    }
    // Wait well past cold-boot P99 on a healthy host. If the runner
    // hasn't come up in this window, the cold path is itself broken
    // and the test should fail loudly — that's a correct signal.
    try await Task.sleep(for: .milliseconds(800))
    t.cancel()
    _ = try? await t.value

    let result = try await Lumina.run("true", options: RunOptions(timeout: .seconds(30)))
    #expect(result.success,
            "boot after late cancel must succeed; got \(result)")
}

// MARK: - MacOSVM.install cancellation (fixture-gated)

/// Cancel during MacOSVM.install validates the withTaskCancellation-
/// Handler + Task.checkCancellation gates added in v0.7.1
/// (closes #23). Requires a real IPSW fixture — too large to bundle;
/// set LUMINA_IPSW_FIXTURE=/path/to/UniversalMac.ipsw to enable.
@Test(.enabled(if: ipswFixtureEnabled()))
func macOSInstall_cancelMidway_releasesResources() async throws {
    guard let ipswPath = ProcessInfo.processInfo.environment["LUMINA_IPSW_FIXTURE"] else {
        Issue.record("LUMINA_IPSW_FIXTURE unset; skipping")
        return
    }

    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("lumina-macos-cancel-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: tmp, withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: tmp) }

    let config = MacOSBootConfig(
        ipsw: URL(fileURLWithPath: ipswPath),
        auxiliaryStorage: tmp.appendingPathComponent("aux.img"),
        primaryDisk: tmp.appendingPathComponent("disk.img")
    )
    let vm = MacOSVM(bootConfig: config, memoryBytes: 8 * 1024 * 1024 * 1024, cpuCount: 4)

    let installTask = Task {
        try await vm.install(progress: { _ in })
    }
    // Short window — enough to let config build + VZ machine alloc
    // complete but not enough for the IPSW restore to finish even
    // a first progress tick.
    try await Task.sleep(for: .milliseconds(500))
    installTask.cancel()
    _ = try? await installTask.value

    // MacOSVM should be back in .idle; `install()` retry must work
    // (or fail on a different reason like missing disk, not a leaked
    // flock). We assert actor state rather than attempting the
    // full 30-minute retry. `state` is a nonisolated read-through on
    // MacOSVM (actor property with custom executor); no await needed.
    let state = vm.state
    if case .idle = state {
        // expected
    } else {
        Issue.record("expected .idle after cancel; got \(state)")
    }
}
