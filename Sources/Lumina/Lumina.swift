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
    /// Output chunks are yielded in real time as the guest agent sends them.
    public static func stream(
        _ command: String,
        options: RunOptions = .default
    ) -> AsyncThrowingStream<OutputChunk, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let vmOptions = VMOptions(from: options)
                    let vm = VM(options: vmOptions)
                    defer { Task { await vm.shutdown() } }

                    try await vm.boot()

                    let elapsed = ContinuousClock.now
                    let remaining = options.timeout - (ContinuousClock.now - elapsed)
                    let remainingSeconds = max(Int(remaining.components.seconds), 1)

                    let chunks = try await vm.stream(command, timeout: remainingSeconds)
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
