// Sources/Lumina/Lumina.swift
import Foundation

public struct Lumina {
    /// Run a command in a disposable VM, return result when complete.
    /// The VM is created, booted, used, and destroyed automatically.
    public static func run(
        _ command: String,
        options: RunOptions = .default
    ) async throws(LuminaError) -> RunResult {
        let vmOptions = VMOptions(from: options)
        let vm = VM(options: vmOptions)

        let start = ContinuousClock.now

        // Ensure shutdown on all paths
        defer { Task { await vm.shutdown() } }

        // Boot with timeout awareness
        try await vm.boot()

        // Check if we've already exceeded total timeout during boot
        let elapsed = ContinuousClock.now - start
        guard elapsed < options.timeout else {
            throw .timeout
        }

        // Execute with remaining time budget
        let remaining = options.timeout - elapsed
        let remainingSeconds = Int(remaining.components.seconds)
        let result = try await vm.exec(command, timeout: max(remainingSeconds, 1))

        let totalWallTime = ContinuousClock.now - start
        return RunResult(
            stdout: result.stdout,
            stderr: result.stderr,
            exitCode: result.exitCode,
            wallTime: totalWallTime
        )
    }

    /// Stream output from a command in a disposable VM.
    /// Note: v0.1 buffers then emits (not true real-time streaming). True line-by-line streaming in v0.2.
    public static func stream(
        _ command: String,
        options: RunOptions = .default
    ) -> AsyncThrowingStream<OutputChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let vmOptions = VMOptions(from: options)
                    let vm = VM(options: vmOptions)
                    defer { Task { await vm.shutdown() } }

                    try await vm.boot()

                    // Delegate to VM.stream() which handles exec + chunking
                    let chunks = await vm.stream(command)
                    for try await chunk in chunks {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
