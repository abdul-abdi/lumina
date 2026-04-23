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

            // Host-driven network config. Default: await network_ready
            // before exec — the guarantee users depend on for commands
            // that send a packet in the first ~20 ms (curl, ping, apt,
            // dns lookups). v0.7.2 perf work moved the cost from ~2.5s
            // to ~50-150 ms by shrinking the guest's carrier-wait
            // timeout, batching the `ip` setup, and using a netlink
            // subscription for instant notification when eth0 comes up
            // (see Guest/lumina-agent/internal/network/network.go).
            //
            // Opt-out for speed-first workloads that know they don't
            // need network: set `options.awaitNetworkReady = false` or
            // pass `--no-wait-network` on the CLI. The guest agent
            // still configures the network in a goroutine concurrently
            // — the opt-out just drops the host-side barrier.
            if options.awaitNetworkReady {
                try await vm.configureNetwork()
            } else {
                // Fire-and-forget: start the config, don't await.
                Task.detached { try? await vm.configureNetwork() }
            }

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
            let result = try await vm.execResult(command, timeout: max(remainingSeconds, 1), env: options.env, cwd: options.workingDirectory, stdin: options.stdin).get()

            // Download after exec — auto-detect file vs directory on guest
            for dl in options.downloads {
                let escaped = dl.remotePath.replacingOccurrences(of: "'", with: "'\\''")
                let check = try await vm.exec("test -d '\(escaped)'", timeout: 10)
                if check.exitCode == 0 {
                    try await vm.downloadDirectory(remotePath: dl.remotePath, localPath: dl.localPath)
                } else {
                    try await vm.downloadFiles([dl])
                }
            }
            // Explicit directory downloads (library API)
            for dir in options.directoryDownloads {
                try await vm.downloadDirectory(remotePath: dir.remotePath, localPath: dir.localPath)
            }

            let totalWallTime = ContinuousClock.now - start
            return RunResult(
                stdout: result.stdout,
                stderr: result.stderr,
                exitCode: result.exitCode,
                wallTime: totalWallTime,
                stdoutBytes: result.stdoutBytes,
                stderrBytes: result.stderrBytes
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
                        let bootDone = ContinuousClock.now

                        // v0.7.2 perf: default awaits network_ready so
                        // commands that need DNS/TCP in the first ~20ms
                        // of exec work. Opt-out via
                        // options.awaitNetworkReady = false.
                        if options.awaitNetworkReady {
                            try await vm.configureNetwork()
                        } else {
                            Task.detached { try? await vm.configureNetwork() }
                        }
                        let netDone = ContinuousClock.now

                        if ProcessInfo.processInfo.environment["LUMINA_BOOT_TRACE"] == "1" {
                            let bootMs = (bootDone - start).totalMilliseconds
                            let netMs = (netDone - bootDone).totalMilliseconds
                            FileHandle.standardError.write(Data(
                                "  boot total:         \(String(format: "%7d", bootMs)) ms\n  configure network:  \(String(format: "%7d", netMs)) ms\n".utf8
                            ))
                        }

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

                        let chunks = try await vm.stream(command, timeout: remainingSeconds, env: options.env, cwd: options.workingDirectory, stdin: options.stdin)
                        for try await chunk in chunks {
                            continuation.yield(chunk)
                        }

                        // Download after stream — auto-detect file vs directory on guest
                        for dl in options.downloads {
                            let escaped = dl.remotePath.replacingOccurrences(of: "'", with: "'\\''")
                            let check = try await vm.exec("test -d '\(escaped)'", timeout: 10)
                            if check.exitCode == 0 {
                                try await vm.downloadDirectory(remotePath: dl.remotePath, localPath: dl.localPath)
                            } else {
                                try await vm.downloadFiles([dl])
                            }
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
    /// Delegates to the multi-command overload with a single-element array.
    public static func createImage(
        name: String,
        from base: String = "default",
        command: String,
        options: RunOptions = .default,
        rosetta: Bool = false
    ) async throws {
        try await createImage(name: name, from: base, commands: [command], options: options, rosetta: rosetta)
    }

    /// Create a custom image by running multiple commands sequentially.
    /// Aborts on first non-zero exit. Staging dir is NOT promoted on failure.
    public static func createImage(
        name: String,
        from base: String = "default",
        commands: [String],
        options: RunOptions = .default,
        rosetta: Bool = false
    ) async throws {
        guard !commands.isEmpty else {
            throw LuminaError.sessionFailed("No build commands provided")
        }

        var opts = options
        opts.image = base
        var vmOptions = VMOptions(from: opts)
        if rosetta { vmOptions.rosetta = true }
        let vm = VM(options: vmOptions)

        do {
            try await vm.bootResult().get()
            try await vm.configureNetwork()
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

        // Flush dirty pages before clone capture (same rationale as single-command path).
        _ = await vm.execResult("sync", timeout: 10)

        guard let clone = await vm.detachClone() else {
            await vm.shutdown()
            throw LuminaError.sessionFailed("No disk clone available")
        }
        await vm.shutdown()

        defer { clone.remove() }
        let store = ImageStore()
        try store.createImage(name: name, from: base, rootfsSource: clone.rootfs, command: commands.joined(separator: " && "), rosetta: rosetta)
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
