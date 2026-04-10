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
        // Typed-throws may box the error across actor boundaries.
        // Check string representation as fallback.
        let desc = String(describing: error)
        #expect(desc.contains("timeout"), "Expected timeout, got: \(error)")
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

    // After stream finishes, state must be .ready (not stuck in .executing)
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
