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

/// EFI integration gate — same env flag, no image-store requirement since
/// EFI boot bypasses the agent image cache. The test still needs the
/// Virtualization entitlement on the signed test binary.
private func efiIntegrationEnabled() -> Bool {
    ProcessInfo.processInfo.environment["LUMINA_INTEGRATION_TESTS"] == "1"
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
        // Typed-throws may box the error across actor boundaries.
        // Check string representation as fallback.
        let desc = String(describing: error)
        #expect(desc.contains("timeout"), "Expected timeout, got: \(error)")
    }
}

/// Audit-fix regression guard (v0.7.2): a command that finishes a hair
/// after the timeout watchdog fires SIGTERM should land its real exit
/// code via the soft/hard deadline grace window, not synthesize
/// `.timeout`. Without this fix, agents retrying non-idempotent ops
/// repeated work that actually succeeded.
///
/// Test shape: timeout 1s on a `sleep 0.95 && exit 7`. The `sleep`
/// returns naturally just before the 1s soft deadline most of the
/// time, but on a loaded host the schedule can overshoot. Either way:
///   - Natural-exit case: exit code 7, no error.
///   - Late-exit-in-grace-window case: also exit code 7 (the fix
///     guarantees this — pre-fix it would surface as `.timeout`).
///   - Hard-overshoot (>1.25s on a *very* loaded host): `.timeout`.
///     Treated as inconclusive rather than a failure.
@Test(.enabled(if: integrationEnabled()))
func integrationTimeoutGraceWindow() async {
    do {
        let result = try await Lumina.run(
            "sleep 0.95 && exit 7",
            options: RunOptions(timeout: .seconds(1))
        )
        // The contract: if the command was within the natural-exit
        // window OR the post-watchdog grace window, the host MUST
        // surface the real exit code (7) instead of a synthetic
        // timeout.
        #expect(result.exitCode == 7,
                "Expected exit 7 (natural exit or grace-window reclaim); got \(result.exitCode)")
    } catch let error as LuminaError {
        if case .timeout = error {
            // Hard overshoot — only acceptable on a heavily loaded
            // host where the command genuinely took >1.25s. Don't
            // fail the suite on that, but record the slip so it
            // shows up if it becomes a regression pattern.
            Issue.record("Grace-window test fell off the cliff to .timeout — host likely loaded; expected exit 7")
        } else {
            Issue.record("Expected exit 7 or .timeout, got: \(error)")
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

// MARK: - Streaming Tests

@Test(.enabled(if: integrationEnabled()))
func integrationStreamEcho() async throws {
    let stream = Lumina.stream("echo hello", options: RunOptions(timeout: .seconds(30)))
    var chunks: [OutputChunk] = []
    for try await chunk in stream {
        chunks.append(chunk)
    }
    // Should have at least one stdout chunk and an exit chunk
    let stdoutChunks = chunks.filter { if case .stdout = $0 { return true }; return false }
    let exitChunks = chunks.compactMap { if case .exit(let code) = $0 { return code }; return nil }
    #expect(!stdoutChunks.isEmpty, "Expected at least one stdout chunk")
    let combined = stdoutChunks.map { if case .stdout(let s) = $0 { return s }; return "" }.joined()
    #expect(combined.contains("hello"))
    #expect(exitChunks == [0], "Expected exit code 0")
}

@Test(.enabled(if: integrationEnabled()))
func integrationStreamMultiLine() async throws {
    let stream = Lumina.stream(
        "for i in 1 2 3; do echo line_$i; done",
        options: RunOptions(timeout: .seconds(30))
    )
    var chunks: [OutputChunk] = []
    for try await chunk in stream {
        chunks.append(chunk)
    }
    let combined = chunks.compactMap { if case .stdout(let s) = $0 { return s }; return nil }.joined()
    #expect(combined.contains("line_1"))
    #expect(combined.contains("line_2"))
    #expect(combined.contains("line_3"))
}

@Test(.enabled(if: integrationEnabled()))
func integrationStreamStderr() async throws {
    let stream = Lumina.stream(
        "echo out; echo err >&2",
        options: RunOptions(timeout: .seconds(30))
    )
    var stdoutData = ""
    var stderrData = ""
    var exitCode: Int32?
    for try await chunk in stream {
        switch chunk {
        case .stdout(let s): stdoutData += s
        case .stderr(let s): stderrData += s
        case .exit(let code): exitCode = code
        default: break
        }
    }
    #expect(stdoutData.contains("out"))
    #expect(stderrData.contains("err"))
    #expect(exitCode == 0)
}

// MARK: - Session (VM Actor) Tests

@Test(.enabled(if: integrationEnabled()))
func integrationVMMultipleExecs() async throws {
    let vm = VM(options: VMOptions(memory: 512 * 1024 * 1024, cpuCount: 2))
    defer { Task { await vm.shutdown() } }

    try await vm.boot()
    #expect(await vm.state == .ready)

    let r1 = try await vm.exec("echo first", timeout: 30)
    #expect(r1.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "first")
    #expect(await vm.state == .ready)

    let r2 = try await vm.exec("echo second", timeout: 30)
    #expect(r2.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "second")
    #expect(await vm.state == .ready)

    let r3 = try await vm.exec("echo third", timeout: 30)
    #expect(r3.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "third")
    #expect(await vm.state == .ready)
}

@Test(.enabled(if: integrationEnabled()))
func integrationVMStreamThenExec() async throws {
    // THE test for the P1 fix: VM stuck in executing state after stream.
    // After streaming completes, VM state must reset to .ready so exec() works.
    let vm = VM(options: VMOptions(memory: 512 * 1024 * 1024, cpuCount: 2))
    defer { Task { await vm.shutdown() } }

    try await vm.boot()
    #expect(await vm.state == .ready)

    // Stream a command and fully consume the stream
    let stream = try await vm.stream("echo streamed", timeout: 30)
    var streamOutput = ""
    for try await chunk in stream {
        if case .stdout(let s) = chunk { streamOutput += s }
    }
    #expect(streamOutput.contains("streamed"))

    // After stream finishes, state must be .ready
    #expect(await vm.state == .ready)

    // Now exec should work without error
    let result = try await vm.exec("echo after_stream", timeout: 30)
    #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "after_stream")
    #expect(result.success)
}

@Test(.enabled(if: integrationEnabled()))
func integrationVMStreamThenDownload() async throws {
    // Stream an exec that creates a file, then download it.
    let vm = VM(options: VMOptions(memory: 512 * 1024 * 1024, cpuCount: 2))
    defer { Task { await vm.shutdown() } }

    try await vm.boot()

    // Stream a command that creates a file
    let stream = try await vm.stream("echo 'stream-content' > /tmp/stream-test.txt && echo done", timeout: 30)
    for try await _ in stream { /* consume all chunks */ }

    // State must be ready after stream
    #expect(await vm.state == .ready)

    // Download the file created during stream
    let localPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("lumina-test-stream-dl-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: localPath) }

    try await vm.downloadFiles([
        FileDownload(remotePath: "/tmp/stream-test.txt", localPath: localPath)
    ])

    let contents = try String(contentsOf: localPath, encoding: .utf8)
    #expect(contents.trimmingCharacters(in: .whitespacesAndNewlines) == "stream-content")
}

// MARK: - File Transfer Tests

@Test(.enabled(if: integrationEnabled()))
func integrationFileUploadDownload() async throws {
    // Create a temp file to upload
    let uploadContent = "hello-from-host-\(UUID().uuidString)"
    let uploadLocal = FileManager.default.temporaryDirectory
        .appendingPathComponent("lumina-test-upload-\(UUID().uuidString).txt")
    let downloadLocal = FileManager.default.temporaryDirectory
        .appendingPathComponent("lumina-test-download-\(UUID().uuidString).txt")
    defer {
        try? FileManager.default.removeItem(at: uploadLocal)
        try? FileManager.default.removeItem(at: downloadLocal)
    }
    try uploadContent.write(to: uploadLocal, atomically: true, encoding: .utf8)

    let result = try await Lumina.run(
        "cat /tmp/uploaded.txt",
        options: RunOptions(
            timeout: .seconds(30),
            uploads: [FileUpload(localPath: uploadLocal, remotePath: "/tmp/uploaded.txt")],
            downloads: [FileDownload(remotePath: "/tmp/uploaded.txt", localPath: downloadLocal)]
        )
    )

    // Verify exec saw the uploaded file
    #expect(result.stdout.contains(uploadContent))
    #expect(result.success)

    // Verify downloaded file matches
    let downloaded = try String(contentsOf: downloadLocal, encoding: .utf8)
    #expect(downloaded.contains(uploadContent))
}

@Test(.enabled(if: integrationEnabled()))
func integrationDirectoryUpload() async throws {
    // Create a temp directory with files
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("lumina-test-dirupload-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    try "file-a".write(to: tempDir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try "file-b".write(to: tempDir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

    // Create a subdirectory
    let subDir = tempDir.appendingPathComponent("sub")
    try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
    try "file-c".write(to: subDir.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)

    let result = try await Lumina.run(
        "find /tmp/uploaded-dir -type f | sort",
        options: RunOptions(
            timeout: .seconds(30),
            directoryUploads: [DirectoryUpload(localPath: tempDir, remotePath: "/tmp/uploaded-dir")]
        )
    )

    #expect(result.success)
    #expect(result.stdout.contains("a.txt"))
    #expect(result.stdout.contains("b.txt"))
    #expect(result.stdout.contains("c.txt"))
}

@Test(.enabled(if: integrationEnabled()))
func integrationDirectoryDownload() async throws {
    // Create files on guest, then download the directory
    let downloadDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("lumina-test-dirdownload-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: downloadDir) }

    let result = try await Lumina.run(
        "mkdir -p /tmp/dl-test/nested && echo aaa > /tmp/dl-test/x.txt && echo bbb > /tmp/dl-test/nested/y.txt && echo ok",
        options: RunOptions(
            timeout: .seconds(30),
            directoryDownloads: [DirectoryDownload(remotePath: "/tmp/dl-test", localPath: downloadDir)]
        )
    )

    #expect(result.success)

    // Verify local files exist
    let xPath = downloadDir.appendingPathComponent("x.txt")
    let yPath = downloadDir.appendingPathComponent("nested/y.txt")
    #expect(FileManager.default.fileExists(atPath: xPath.path))
    #expect(FileManager.default.fileExists(atPath: yPath.path))
    let xContent = try String(contentsOf: xPath, encoding: .utf8)
    let yContent = try String(contentsOf: yPath, encoding: .utf8)
    #expect(xContent.trimmingCharacters(in: .whitespacesAndNewlines) == "aaa")
    #expect(yContent.trimmingCharacters(in: .whitespacesAndNewlines) == "bbb")
}

// MARK: - Environment and Image Tests

@Test(.enabled(if: integrationEnabled()))
func integrationEnvVars() async throws {
    let result = try await Lumina.run(
        "echo $LUMINA_TEST_VAR",
        options: RunOptions(
            timeout: .seconds(30),
            env: ["LUMINA_TEST_VAR": "hello_from_env"]
        )
    )
    #expect(result.success)
    #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hello_from_env")
}

@Test(.enabled(if: integrationEnabled()))
func integrationCustomImage() async throws {
    // Only run if a "minimal" image exists — skip gracefully otherwise
    let store = ImageStore()
    guard (try? store.resolve(name: "minimal")) != nil else {
        return // No "minimal" image, skip
    }

    let result = try await Lumina.run(
        "echo custom-image-ok",
        options: RunOptions(timeout: .seconds(30), image: "minimal")
    )
    #expect(result.success)
    #expect(result.stdout.contains("custom-image-ok"))
}

// MARK: - Signal/Cancel Test

@Test(.enabled(if: integrationEnabled()))
func integrationVMCancel() async throws {
    let vm = VM(options: VMOptions(memory: 512 * 1024 * 1024, cpuCount: 2))
    defer { Task { await vm.shutdown() } }

    try await vm.boot()

    // Start a long-running stream
    let stream = try await vm.stream("sleep 60", timeout: 60)

    // Cancel after a brief moment
    try await Task.sleep(for: .milliseconds(500))
    try await vm.cancel()

    // The stream should terminate (with an exit chunk or error)
    var chunks: [OutputChunk] = []
    for try await chunk in stream {
        chunks.append(chunk)
    }

    // After cancel, VM state should return to ready
    #expect(await vm.state == .ready)
}

// MARK: - Concurrent Exec Tests (P3 — multiple commands on same VM)

@Test(.enabled(if: integrationEnabled()))
func integrationConcurrentExecTwoCommands() async throws {
    // THE core concurrent exec test: two execs on the same VM at the same time,
    // output correctly demultiplexed — no mixing of stdout between commands.
    let vm = VM(options: VMOptions(memory: 512 * 1024 * 1024, cpuCount: 2))
    defer { Task { await vm.shutdown() } }

    try await vm.boot()
    #expect(await vm.state == .ready)

    // Fire two execs concurrently using a task group
    try await withThrowingTaskGroup(of: (String, RunResult).self) { group in
        group.addTask {
            let r = try await vm.exec("echo ALPHA && sleep 0.5 && echo ALPHA_DONE", timeout: 30)
            return ("alpha", r)
        }
        group.addTask {
            let r = try await vm.exec("echo BRAVO && sleep 0.5 && echo BRAVO_DONE", timeout: 30)
            return ("bravo", r)
        }

        var results: [String: RunResult] = [:]
        for try await (tag, result) in group {
            results[tag] = result
        }

        // Both must succeed
        #expect(results["alpha"]!.success, "alpha failed: \(results["alpha"]!.stderr)")
        #expect(results["bravo"]!.success, "bravo failed: \(results["bravo"]!.stderr)")

        // Output must not be crossed — alpha's stdout contains ALPHA, not BRAVO
        #expect(results["alpha"]!.stdout.contains("ALPHA"))
        #expect(results["alpha"]!.stdout.contains("ALPHA_DONE"))
        #expect(!results["alpha"]!.stdout.contains("BRAVO"), "alpha stdout contaminated with bravo output")

        #expect(results["bravo"]!.stdout.contains("BRAVO"))
        #expect(results["bravo"]!.stdout.contains("BRAVO_DONE"))
        #expect(!results["bravo"]!.stdout.contains("ALPHA"), "bravo stdout contaminated with alpha output")
    }

    // VM must still be ready after concurrent execs
    #expect(await vm.state == .ready)
}

@Test(.enabled(if: integrationEnabled()))
func integrationConcurrentExecFiveWay() async throws {
    // Push harder: 5 concurrent execs on the same VM.
    // Each produces unique output — verify no cross-contamination.
    let vm = VM(options: VMOptions(memory: 512 * 1024 * 1024, cpuCount: 2))
    defer { Task { await vm.shutdown() } }

    try await vm.boot()

    let tags = ["one", "two", "three", "four", "five"]

    try await withThrowingTaskGroup(of: (String, RunResult).self) { group in
        for tag in tags {
            group.addTask {
                let r = try await vm.exec("echo TAG_\(tag)_START && sleep 0.3 && echo TAG_\(tag)_END", timeout: 30)
                return (tag, r)
            }
        }

        var results: [String: RunResult] = [:]
        for try await (tag, result) in group {
            results[tag] = result
        }

        for tag in tags {
            let r = results[tag]!
            #expect(r.success, "\(tag) failed: \(r.stderr)")
            #expect(r.stdout.contains("TAG_\(tag)_START"), "\(tag) missing START marker")
            #expect(r.stdout.contains("TAG_\(tag)_END"), "\(tag) missing END marker")

            // Verify no other tag's output leaked into this result
            for other in tags where other != tag {
                #expect(!r.stdout.contains("TAG_\(other)_"), "\(tag) stdout contains \(other) output")
            }
        }
    }
}

@Test(.enabled(if: integrationEnabled()))
func integrationConcurrentStreams() async throws {
    // Two concurrent streams on the same VM — verify interleaved output is correctly routed.
    let vm = VM(options: VMOptions(memory: 512 * 1024 * 1024, cpuCount: 2))
    defer { Task { await vm.shutdown() } }

    try await vm.boot()

    try await withThrowingTaskGroup(of: (String, String).self) { group in
        group.addTask {
            let stream = try await vm.stream("for i in 1 2 3 4 5; do echo STREAM_A_$i; sleep 0.1; done", timeout: 30)
            var output = ""
            for try await chunk in stream {
                if case .stdout(let s) = chunk { output += s }
            }
            return ("A", output)
        }
        group.addTask {
            let stream = try await vm.stream("for i in 1 2 3 4 5; do echo STREAM_B_$i; sleep 0.1; done", timeout: 30)
            var output = ""
            for try await chunk in stream {
                if case .stdout(let s) = chunk { output += s }
            }
            return ("B", output)
        }

        var outputs: [String: String] = [:]
        for try await (tag, output) in group {
            outputs[tag] = output
        }

        // Verify each stream got its own output
        for i in 1...5 {
            #expect(outputs["A"]!.contains("STREAM_A_\(i)"), "Stream A missing line \(i)")
            #expect(outputs["B"]!.contains("STREAM_B_\(i)"), "Stream B missing line \(i)")
        }
        // Verify no cross-contamination
        #expect(!outputs["A"]!.contains("STREAM_B_"), "Stream A contains B output")
        #expect(!outputs["B"]!.contains("STREAM_A_"), "Stream B contains A output")
    }
}

@Test(.enabled(if: integrationEnabled()))
func integrationConcurrentExecWithDifferentExitCodes() async throws {
    // Concurrent execs with different exit codes — verify each gets the right code.
    let vm = VM(options: VMOptions(memory: 512 * 1024 * 1024, cpuCount: 2))
    defer { Task { await vm.shutdown() } }

    try await vm.boot()

    try await withThrowingTaskGroup(of: (Int, RunResult).self) { group in
        for code in [0, 1, 2, 42, 127] {
            group.addTask {
                let r = try await vm.exec("exit \(code)", timeout: 30)
                return (code, r)
            }
        }

        var results: [Int: RunResult] = [:]
        for try await (code, result) in group {
            results[code] = result
        }

        for code in [0, 1, 2, 42, 127] {
            #expect(results[code]!.exitCode == Int32(code),
                    "Expected exit code \(code), got \(results[code]!.exitCode)")
        }
    }
}

@Test(.enabled(if: integrationEnabled()))
func integrationConcurrentExecWithLargeOutput() async throws {
    // Two concurrent execs each producing 5K lines — tests dispatcher under volume.
    let vm = VM(options: VMOptions(memory: 512 * 1024 * 1024, cpuCount: 2))
    defer { Task { await vm.shutdown() } }

    try await vm.boot()

    try await withThrowingTaskGroup(of: (String, RunResult).self) { group in
        group.addTask {
            let r = try await vm.exec("seq 1 5000 | sed 's/^/A_/'", timeout: 60)
            return ("A", r)
        }
        group.addTask {
            let r = try await vm.exec("seq 1 5000 | sed 's/^/B_/'", timeout: 60)
            return ("B", r)
        }

        var results: [String: RunResult] = [:]
        for try await (tag, result) in group {
            results[tag] = result
        }

        let aLines = results["A"]!.stdout.split(separator: "\n")
        let bLines = results["B"]!.stdout.split(separator: "\n")

        #expect(aLines.count == 5000, "A expected 5000 lines, got \(aLines.count)")
        #expect(bLines.count == 5000, "B expected 5000 lines, got \(bLines.count)")

        // Verify no cross-contamination
        #expect(aLines.allSatisfy { $0.hasPrefix("A_") }, "A output contains non-A lines")
        #expect(bLines.allSatisfy { $0.hasPrefix("B_") }, "B output contains non-B lines")

        // Verify first and last lines
        #expect(aLines.first == "A_1")
        #expect(aLines.last == "A_5000")
        #expect(bLines.first == "B_1")
        #expect(bLines.last == "B_5000")
    }
}

@Test(.enabled(if: integrationEnabled()))
func integrationConcurrentExecThenSequential() async throws {
    // Run concurrent execs, then sequential — verify no state corruption.
    let vm = VM(options: VMOptions(memory: 512 * 1024 * 1024, cpuCount: 2))
    defer { Task { await vm.shutdown() } }

    try await vm.boot()

    // Phase 1: Concurrent
    try await withThrowingTaskGroup(of: RunResult.self) { group in
        group.addTask { try await vm.exec("echo concurrent_1", timeout: 30) }
        group.addTask { try await vm.exec("echo concurrent_2", timeout: 30) }
        for try await r in group {
            #expect(r.success)
        }
    }

    // Phase 2: Sequential — must still work after concurrent phase
    for i in 1...5 {
        let r = try await vm.exec("echo sequential_\(i)", timeout: 30)
        #expect(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "sequential_\(i)")
    }

    // Phase 3: Concurrent again
    try await withThrowingTaskGroup(of: RunResult.self) { group in
        group.addTask { try await vm.exec("echo final_1", timeout: 30) }
        group.addTask { try await vm.exec("echo final_2", timeout: 30) }
        group.addTask { try await vm.exec("echo final_3", timeout: 30) }
        for try await r in group {
            #expect(r.success)
        }
    }
}

@Test(.enabled(if: integrationEnabled()))
func integrationConcurrentExecStderrRouting() async throws {
    // Concurrent execs producing stderr — verify stderr is also correctly demuxed.
    let vm = VM(options: VMOptions(memory: 512 * 1024 * 1024, cpuCount: 2))
    defer { Task { await vm.shutdown() } }

    try await vm.boot()

    try await withThrowingTaskGroup(of: (String, RunResult).self) { group in
        group.addTask {
            let r = try await vm.exec("echo ERR_X >&2 && echo OUT_X", timeout: 30)
            return ("X", r)
        }
        group.addTask {
            let r = try await vm.exec("echo ERR_Y >&2 && echo OUT_Y", timeout: 30)
            return ("Y", r)
        }

        var results: [String: RunResult] = [:]
        for try await (tag, result) in group {
            results[tag] = result
        }

        #expect(results["X"]!.stdout.contains("OUT_X"))
        #expect(results["X"]!.stderr.contains("ERR_X"))
        #expect(!results["X"]!.stderr.contains("ERR_Y"), "X stderr contaminated with Y")

        #expect(results["Y"]!.stdout.contains("OUT_Y"))
        #expect(results["Y"]!.stderr.contains("ERR_Y"))
        #expect(!results["Y"]!.stderr.contains("ERR_X"), "Y stderr contaminated with X")
    }
}

@Test(.enabled(if: integrationEnabled()))
func integrationConcurrentExecOneTimeout() async throws {
    // One exec times out while another succeeds — verify the successful one isn't disrupted.
    let vm = VM(options: VMOptions(memory: 512 * 1024 * 1024, cpuCount: 2))
    defer { Task { await vm.shutdown() } }

    try await vm.boot()

    try await withThrowingTaskGroup(of: (String, Result<RunResult, any Error>).self) { group in
        group.addTask {
            do {
                let r = try await vm.exec("sleep 60", timeout: 3)
                return ("slow", .success(r))
            } catch {
                return ("slow", .failure(error))
            }
        }
        group.addTask {
            do {
                let r = try await vm.exec("echo fast_result", timeout: 30)
                return ("fast", .success(r))
            } catch {
                return ("fast", .failure(error))
            }
        }

        var results: [String: Result<RunResult, any Error>] = [:]
        for try await (tag, result) in group {
            results[tag] = result
        }

        // Fast should succeed
        if case .success(let r) = results["fast"]! {
            #expect(r.success)
            #expect(r.stdout.contains("fast_result"))
        } else {
            Issue.record("Fast exec should have succeeded")
        }

        // Slow should have timed out
        if case .failure = results["slow"]! {
            // Expected — timeout
        } else {
            Issue.record("Slow exec should have timed out")
        }
    }

    // VM should recover — next exec should work
    // Reconnect may be needed since timeout sends cancel which may disrupt
    try await Task.sleep(for: .seconds(8))
    let recovery = try await vm.exec("echo post_timeout_ok", timeout: 30)
    #expect(recovery.success)
    #expect(recovery.stdout.contains("post_timeout_ok"))
}

// MARK: - Stdin Tests (P3 — pipe data to running commands)

@Test(.enabled(if: integrationEnabled()))
func integrationStdinBasic() async throws {
    // Use the VM actor directly with a known exec ID to test stdin.
    let vm = VM(options: VMOptions(memory: 512 * 1024 * 1024, cpuCount: 2))
    defer { Task { await vm.shutdown() } }

    try await vm.boot()

    // Use a caller-supplied exec ID so we can target sendStdin at this specific exec.
    let id = UUID().uuidString
    let stream = try await vm.execStream(id: id, "head -1", timeout: 30)

    // Give the command a moment to start
    try await Task.sleep(for: .milliseconds(500))

    // Send stdin data
    try await vm.sendStdin("hello from stdin\n", execId: id)

    // Collect output
    var output = ""
    var exitCode: Int32?
    for try await chunk in stream {
        switch chunk {
        case .stdout(let s): output += s
        case .exit(let code): exitCode = code
        default: break
        }
    }

    #expect(output.contains("hello from stdin"), "Expected stdin data in output, got: \(output)")
    #expect(exitCode == 0, "Expected exit 0, got: \(String(describing: exitCode))")
}

@Test(.enabled(if: integrationEnabled()))
func integrationStdinMultiLine() async throws {
    // Pipe multiple lines of stdin to `wc -l`
    let vm = VM(options: VMOptions(memory: 512 * 1024 * 1024, cpuCount: 2))
    defer { Task { await vm.shutdown() } }

    try await vm.boot()

    let id = UUID().uuidString
    let stream = try await vm.execStream(id: id, "wc -l", timeout: 30)

    try await Task.sleep(for: .milliseconds(500))

    // Send 5 lines then close stdin
    for i in 1...5 {
        try await vm.sendStdin("line \(i)\n", execId: id)
    }
    try await vm.closeStdin(execId: id)

    var output = ""
    for try await chunk in stream {
        if case .stdout(let s) = chunk { output += s }
    }

    let count = output.trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(count == "5", "Expected wc -l to return 5, got: \(count)")
}

@Test(.enabled(if: integrationEnabled()))
func integrationStdinCloseTriggersEOF() async throws {
    // `cat` with no args reads stdin until EOF. Close stdin, cat should exit.
    let vm = VM(options: VMOptions(memory: 512 * 1024 * 1024, cpuCount: 2))
    defer { Task { await vm.shutdown() } }

    try await vm.boot()

    let id = UUID().uuidString
    let stream = try await vm.execStream(id: id, "cat", timeout: 30)

    try await Task.sleep(for: .milliseconds(500))

    // Send some data
    try await vm.sendStdin("payload\n", execId: id)

    // Close stdin — cat should see EOF and exit
    try await vm.closeStdin(execId: id)

    var output = ""
    var exitCode: Int32?
    for try await chunk in stream {
        switch chunk {
        case .stdout(let s): output += s
        case .exit(let code): exitCode = code
        default: break
        }
    }

    #expect(output.contains("payload"), "cat should echo stdin: got \(output)")
    #expect(exitCode == 0, "cat should exit 0 after EOF, got: \(String(describing: exitCode))")
}

@Test(.enabled(if: integrationEnabled()))
func integrationStdinConcurrentWithExec() async throws {
    // Run a stdin-consuming command concurrently with a normal exec.
    // Verify they don't interfere.
    let vm = VM(options: VMOptions(memory: 512 * 1024 * 1024, cpuCount: 2))
    defer { Task { await vm.shutdown() } }

    try await vm.boot()

    try await withThrowingTaskGroup(of: (String, String).self) { group in
        // Task 1: stdin-consuming command
        group.addTask {
            let id = UUID().uuidString
            let stream = try await vm.execStream(id: id, "cat", timeout: 30)

            try await Task.sleep(for: .milliseconds(300))
            try await vm.sendStdin("STDIN_DATA\n", execId: id)
            try await vm.closeStdin(execId: id)

            var output = ""
            for try await chunk in stream {
                if case .stdout(let s) = chunk { output += s }
            }
            return ("stdin", output)
        }

        // Task 2: normal exec running concurrently
        group.addTask {
            let r = try await vm.exec("echo NORMAL_EXEC", timeout: 30)
            return ("exec", r.stdout)
        }

        var results: [String: String] = [:]
        for try await (tag, output) in group {
            results[tag] = output
        }

        #expect(results["stdin"]!.contains("STDIN_DATA"), "stdin task got: \(results["stdin"]!)")
        #expect(results["exec"]!.contains("NORMAL_EXEC"), "exec task got: \(results["exec"]!)")
    }
}

// MARK: - Error Handling Tests

@Test(.enabled(if: integrationEnabled()))
func integrationCommandNotFound() async throws {
    let result = try await Lumina.run(
        "nonexistent_command_xyz_12345",
        options: RunOptions(timeout: .seconds(30))
    )
    #expect(!result.success)
    #expect(result.exitCode != 0)
}

@Test(.enabled(if: integrationEnabled()))
func integrationLargeOutput() async throws {
    let result = try await Lumina.run(
        "seq 1 10000",
        options: RunOptions(timeout: .seconds(30))
    )
    #expect(result.success)
    let lines = result.stdout
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: "\n")
    #expect(lines.count == 10000, "Expected 10000 lines, got \(lines.count)")
    #expect(lines.first == "1")
    #expect(lines.last == "10000")
}

// MARK: - Reconnect / Recovery Tests

@Test(.enabled(if: integrationEnabled()))
func integrationExecRecoveryAfterTimeout() async throws {
    // Verify that after a command times out (CommandRunner enters .failed),
    // the next exec auto-reconnects and succeeds.
    let vm = VM(options: VMOptions(memory: 512 * 1024 * 1024, cpuCount: 2))
    defer { Task { await vm.shutdown() } }

    try await vm.boot()
    #expect(await vm.state == .ready)

    // Run a command that will exceed the host timeout — this puts
    // CommandRunner into .failed state when the deadline fires.
    do {
        _ = try await vm.exec("sleep 30", timeout: 2)
        Issue.record("Expected timeout error")
    } catch {
        // Timeout expected — CommandRunner is now .failed
    }

    // VM state should be .ready (exec resets it on error)
    #expect(await vm.state == .ready)

    // The next exec should auto-reconnect and succeed.
    // With the guest heartbeat fix, the guest detects the closed connection
    // within 5s and returns to Accept(), making reconnect fast.
    let result = try await vm.exec("echo recovered", timeout: 30)
    #expect(result.success)
    #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "recovered")
}

@Test(.enabled(if: integrationEnabled()))
func integrationStreamRecoveryAfterTimeout() async throws {
    // Verify that after a stream times out, the next stream auto-reconnects.
    let vm = VM(options: VMOptions(memory: 512 * 1024 * 1024, cpuCount: 2))
    defer { Task { await vm.shutdown() } }

    try await vm.boot()
    #expect(await vm.state == .ready)

    // Stream a command that exceeds the host timeout
    do {
        let stream = try await vm.stream("sleep 30", timeout: 2)
        for try await _ in stream { /* drain */ }
        Issue.record("Expected timeout error")
    } catch {
        // Timeout expected
    }

    // streamDidFinish should have proactively reconnected.
    // Wait briefly for async reconnect to settle.
    try await Task.sleep(for: .seconds(8))
    #expect(await vm.state == .ready)

    // Next stream should work
    let stream = try await vm.stream("echo stream_recovered", timeout: 30)
    var output = ""
    for try await chunk in stream {
        if case .stdout(let s) = chunk { output += s }
    }
    #expect(output.contains("stream_recovered"))
}

@Test(.enabled(if: integrationEnabled()))
func integrationStreamCancelThenExec() async throws {
    // Verify that cancelling a stream (dropping it mid-flight) puts
    // CommandRunner into .failed (not .ready), and the next exec
    // reconnects successfully.
    let vm = VM(options: VMOptions(memory: 512 * 1024 * 1024, cpuCount: 2))
    defer { Task { await vm.shutdown() } }

    try await vm.boot()
    #expect(await vm.state == .ready)

    // Start a long stream and cancel it by dropping the iterator
    let stream = try await vm.stream("sleep 60 && echo done", timeout: 60)
    // Read a couple of chunks (heartbeats) then drop the stream
    var count = 0
    for try await _ in stream {
        count += 1
        if count >= 1 { break }
    }
    // Stream is dropped — cancelled flag set, CommandRunner → .failed

    // Wait for cancellation + proactive reconnect to settle
    try await Task.sleep(for: .seconds(8))
    #expect(await vm.state == .ready)

    // Exec should work via reconnect
    let result = try await vm.exec("echo after_cancel", timeout: 30)
    #expect(result.success)
    #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "after_cancel")
}

// MARK: - Session IPC Stdin Tests

@Test(.enabled(if: integrationEnabled()))
func integrationSessionExecStdinViaIPC() async throws {
    // Exercise the SessionServer/SessionClient IPC path for stdin piping.
    // Existing stdin tests use the VM actor directly (execStream + sendStdin).
    // This test goes through: SessionClient → Unix socket → SessionServer.handleExec
    //   → StdinChannel → CommandRunner → vsock → guest.

    let vm = VM(options: VMOptions(memory: 512 * 1024 * 1024, cpuCount: 2))
    defer { Task { await vm.shutdown() } }
    try await vm.boot()

    // Create a temporary Unix socket for the server.
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    let socketPath = tmpDir.appendingPathComponent("ipc-test.sock")

    let server = SessionServer(socketPath: socketPath)
    try server.bind()
    defer { server.close() }

    // Serve in a background task — exits when server.close() is called.
    let serveTask = Task { await server.serve(vm: vm) }
    defer { serveTask.cancel() }

    // Give the server a moment to enter accept().
    try await Task.sleep(for: .milliseconds(50))

    // Connect a raw socket and inject into SessionClient.
    let clientFd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard clientFd >= 0 else {
        Issue.record("Failed to create client socket: \(errno)")
        return
    }
    // clientFd will be closed by SessionClient.disconnect() via Darwin.close.

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = socketPath.path.utf8CString
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
            pathBytes.withUnsafeBufferPointer { src in
                dest.update(from: src.baseAddress!, count: min(src.count, 104))
            }
        }
    }
    let connected = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            Darwin.connect(clientFd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else {
        Darwin.close(clientFd)
        Issue.record("Failed to connect to session socket: \(errno)")
        return
    }

    // Set a 10s read timeout so receive() can't block CI indefinitely if the
    // guest never responds (e.g. boot failure, agent crash).
    var tv = timeval(tv_sec: 10, tv_usec: 0)
    setsockopt(clientFd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    let client = SessionClient()
    client.injectTestSocket(readFd: clientFd, writeFd: clientFd)
    defer { client.disconnect() }

    // Send exec for `cat` (echoes stdin until EOF).
    try client.send(.exec(cmd: "cat", timeout: 30, env: [:]))

    // Give the guest a moment to start `cat`.
    try await Task.sleep(for: .milliseconds(300))

    // Send stdin data then close.
    try client.send(.stdin(data: "hello from IPC\n"))
    try client.send(.stdinClose)

    // Collect responses until exit or error.
    var output = ""
    var exitCode: Int32?
    for _ in 0..<200 {
        let response = try client.receive()
        switch response {
        case .output(_, let data):
            output += data
        case .outputBytes(_, let base64):
            if let raw = Data(base64Encoded: base64) {
                output += String(decoding: raw, as: UTF8.self)
            }
        case .exit(let code, _):
            exitCode = code
        case .error(let msg):
            Issue.record("Unexpected session error: \(msg)")
            return
        default:
            break
        }
        if exitCode != nil { break }
    }

    #expect(output.contains("hello from IPC"), "Expected stdin echoed by cat, got: \(output)")
    #expect(exitCode == 0, "Expected cat to exit 0 after stdinClose, got: \(String(describing: exitCode))")
}

// MARK: - v0.7.0 M3 — EFI boot routing

/// Smoke test that `.efi` profiles dispatch to the EFI path in VM.boot().
///
/// Evidence: the EFI variable store file gets created on disk. We don't
/// expect the VM to actually boot — the primary disk is empty, so the VM
/// will fail to start or fail post-start, but the variable-store side-effect
/// proves the branch was taken and EFIBootable.apply() ran.
///
/// Requires the integration gate + VZ entitlement on the signed test binary.
@Test(.enabled(if: efiIntegrationEnabled()))
func bootWithEFIProfile_createsVariableStore() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("efi-routing-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let varsURL = tmp.appendingPathComponent("efi.vars")
    let diskURL = tmp.appendingPathComponent("disk.img")
    // 64 MB empty sparse disk — no bootable content.
    let fd = open(diskURL.path, O_CREAT | O_EXCL | O_RDWR, 0o644)
    #expect(fd >= 0)
    _ = ftruncate(fd, 64 * 1024 * 1024)
    close(fd)

    var opts = VMOptions.default
    opts.bootable = .efi(EFIBootConfig(
        variableStoreURL: varsURL,
        primaryDisk: diskURL
    ))
    opts.memory = 1024 * 1024 * 1024
    opts.cpuCount = 2

    let vm = VM(options: opts)
    // Boot may fail (no bootable medium) but must take the EFI branch first.
    do {
        try await vm.boot()
    } catch {
        // Expected: boot fails because disk is empty. We just want the side effect.
    }
    #expect(
        FileManager.default.fileExists(atPath: varsURL.path),
        "EFIBootable should have created the variable store; branch was not taken"
    )
    await vm.shutdown()
}
