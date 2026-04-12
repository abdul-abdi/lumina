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
            // Upload directories before exec
            for dir in options.directoryUploads {
                try await vm.uploadDirectory(localPath: dir.localPath, remotePath: dir.remotePath)
            }

            let remaining = options.timeout - elapsed
            let remainingSeconds = Int(remaining.components.seconds)
            let result = try await vm.execResult(command, timeout: max(remainingSeconds, 1), env: options.env, cwd: options.workingDirectory).get()

            // Download files after exec
            if !options.downloads.isEmpty {
                try await vm.downloadFilesResult(options.downloads).get()
            }
            // Download directories after exec
            for dir in options.directoryDownloads {
                try await vm.downloadDirectory(remotePath: dir.remotePath, localPath: dir.localPath)
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
                        for dir in options.directoryUploads {
                            try await vm.uploadDirectory(localPath: dir.localPath, remotePath: dir.remotePath)
                        }

                        let remaining = options.timeout - elapsed
                        let remainingSeconds = max(Int(remaining.components.seconds), 1)

                        let chunks = try await vm.stream(command, timeout: remainingSeconds, env: options.env, cwd: options.workingDirectory)
                        for try await chunk in chunks {
                            continuation.yield(chunk)
                        }

                        // Download files after stream completes
                        if !options.downloads.isEmpty {
                            try await vm.downloadFilesResult(options.downloads).get()
                        }
                        for dir in options.directoryDownloads {
                            try await vm.downloadDirectory(remotePath: dir.remotePath, localPath: dir.localPath)
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
    /// Set `options.timeout` to control how long the build command can run (default 60s).
    ///
    /// Unlike `run`, this manages the VM lifecycle manually: after the build
    /// command completes, the clone is detached, the VM is shut down cleanly
    /// (flushing the ext4 journal), and then the rootfs is copied to the image store.
    public static func createImage(
        name: String,
        from base: String = "default",
        command: String,
        options: RunOptions = .default
    ) async throws {
        var opts = options
        opts.image = base
        let vmOptions = VMOptions(from: opts)
        let vm = VM(options: vmOptions)

        // Phase 1: Run command (VM owns everything — shutdown handles cleanup on failure)
        do {
            try await vm.bootResult().get()
        } catch {
            await vm.shutdown()
            throw error
        }
        let result = try await vm.execResult(command, timeout: max(Int(opts.timeout.components.seconds), 1), env: opts.env).get()
        guard result.success else {
            await vm.shutdown()
            throw LuminaError.sessionFailed("Image build command failed with exit code \(result.exitCode): \(result.stderr)")
        }

        // Phase 2: Transfer ownership — clone detached, VM shut down cleanly.
        // After this point, WE own the clone and must clean it up.
        guard let clone = await vm.detachClone() else {
            await vm.shutdown()
            throw LuminaError.sessionFailed("No disk clone available")
        }
        // Clean shutdown flushes the Virtualization framework's disk cache
        // and the guest kernel's ext4 journal, producing a consistent rootfs.
        await vm.shutdown()

        // Phase 3: Copy rootfs into image store (caller owns clone)
        defer { clone.remove() }
        let store = ImageStore()
        try store.createImage(name: name, from: base, rootfsSource: clone.rootfs, command: command)
    }

    /// Create a custom image by running multiple commands sequentially.
    /// Aborts on first non-zero exit. Staging dir is NOT promoted on failure.
    public static func createImage(
        name: String,
        from base: String = "default",
        commands: [String],
        options: RunOptions = .default
    ) async throws {
        guard !commands.isEmpty else {
            throw LuminaError.sessionFailed("No build commands provided")
        }

        var opts = options
        opts.image = base
        let vmOptions = VMOptions(from: opts)
        let vm = VM(options: vmOptions)

        do {
            try await vm.bootResult().get()
        } catch {
            await vm.shutdown()
            throw error
        }

        let timeoutSecs = max(Int(opts.timeout.components.seconds), 1)
        for (index, cmd) in commands.enumerated() {
            let result = try await vm.execResult(cmd, timeout: timeoutSecs, env: opts.env).get()
            guard result.success else {
                await vm.shutdown()
                throw LuminaError.sessionFailed(
                    "Image build step \(index + 1)/\(commands.count) failed (exit \(result.exitCode)): \(result.stderr)"
                )
            }
        }

        guard let clone = await vm.detachClone() else {
            await vm.shutdown()
            throw LuminaError.sessionFailed("No disk clone available")
        }
        await vm.shutdown()

        defer { clone.remove() }
        let store = ImageStore()
        try store.createImage(name: name, from: base, rootfsSource: clone.rootfs, command: commands.joined(separator: " && "))
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
