// Sources/Lumina/Lumina.swift
import Foundation

public struct Lumina {
    /// Run a command in a disposable VM, return result when complete.
    /// The VM is created, booted, used, and destroyed automatically.
    /// Throws `LuminaError` on failure.
    public static func run(
        _ command: String,
        options: RunOptions = .default
    ) async throws -> RunResult {
        try await withVM(options: options) { vm in
            let start = ContinuousClock.now

            try await vm.bootResult().get()

            let elapsed = ContinuousClock.now - start
            guard elapsed < options.timeout else {
                throw LuminaError.timeout
            }

            let remaining = options.timeout - elapsed
            let remainingSeconds = Int(remaining.components.seconds)
            let result = try await vm.execResult(command, timeout: max(remainingSeconds, 1), env: options.env).get()

            let totalWallTime = ContinuousClock.now - start
            return RunResult(
                stdout: result.stdout,
                stderr: result.stderr,
                exitCode: result.exitCode,
                wallTime: totalWallTime
            )
        }
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
                    try await withVM(options: options) { vm in
                        let start = ContinuousClock.now
                        try await vm.bootResult().get()

                        let elapsed = ContinuousClock.now - start
                        guard elapsed < options.timeout else {
                            throw LuminaError.timeout
                        }
                        let remaining = options.timeout - elapsed
                        let remainingSeconds = max(Int(remaining.components.seconds), 1)

                        let chunks = try await vm.stream(command, timeout: remainingSeconds, env: options.env)
                        for try await chunk in chunks {
                            continuation.yield(chunk)
                        }
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Private

    /// Lifecycle scope: creates a VM, runs the body, and always shuts down.
    /// One shutdown call site, guaranteed to run on every path.
    private static func withVM<T: Sendable>(
        options: RunOptions,
        body: @Sendable (VM) async throws -> T
    ) async throws -> T {
        let vmOptions = VMOptions(from: options)
        let vm = VM(options: vmOptions)
        do {
            let result = try await body(vm)
            await vm.shutdown()
            return result
        } catch {
            await vm.shutdown()
            throw error
        }
    }
}
