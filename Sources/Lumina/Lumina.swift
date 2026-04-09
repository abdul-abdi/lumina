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

            // Upload files before exec
            if !options.uploads.isEmpty {
                try await vm.uploadFilesResult(options.uploads).get()
            }

            let remaining = options.timeout - elapsed
            let remainingSeconds = Int(remaining.components.seconds)
            let result = try await vm.execResult(command, timeout: max(remainingSeconds, 1), env: options.env).get()

            // Download files after exec
            if !options.downloads.isEmpty {
                try await vm.downloadFilesResult(options.downloads).get()
            }

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

                        // Upload files before exec
                        if !options.uploads.isEmpty {
                            try await vm.uploadFilesResult(options.uploads).get()
                        }

                        let remaining = options.timeout - elapsed
                        let remainingSeconds = max(Int(remaining.components.seconds), 1)

                        let chunks = try await vm.stream(command, timeout: remainingSeconds, env: options.env)
                        for try await chunk in chunks {
                            continuation.yield(chunk)
                        }

                        // Download files after stream completes
                        if !options.downloads.isEmpty {
                            try await vm.downloadFilesResult(options.downloads).get()
                        }

                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Create a custom image by running a command in a disposable VM.
    public static func createImage(
        name: String,
        from base: String = "default",
        command: String,
        options: RunOptions = .default
    ) async throws {
        var opts = options
        opts.image = base
        let resolvedOpts = opts
        try await withVM(options: resolvedOpts) { vm in
            try await vm.bootResult().get()
            let result = try await vm.execResult(command, timeout: Int(resolvedOpts.timeout.components.seconds), env: resolvedOpts.env).get()
            guard result.success else {
                throw LuminaError.sessionFailed("Image build command failed with exit code \(result.exitCode): \(result.stderr)")
            }
            guard let clone = await vm.diskClone else {
                throw LuminaError.sessionFailed("No disk clone available")
            }
            let store = ImageStore()
            try store.createImage(name: name, from: base, rootfsSource: clone.rootfs, command: command)
        }
    }

    /// Run a closure with a private network of VMs.
    /// All VMs share a virtual switch for VM-to-VM communication.
    public static func withNetwork<T: Sendable>(
        _ name: String = "default",
        body: @Sendable (Network) async throws -> T
    ) async throws -> T {
        let network = Network(name: name)
        do {
            let result = try await body(network)
            await network.shutdown()
            return result
        } catch {
            await network.shutdown()
            throw error
        }
    }

    // MARK: - Internal

    /// Lifecycle scope: creates a VM, runs the body, and always shuts down.
    /// One shutdown call site, guaranteed to run on every path.
    static func withVM<T: Sendable>(
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
