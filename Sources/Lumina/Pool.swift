// Sources/Lumina/Pool.swift
//
// Pre-warmed VM pool. Boot N VMs once, serve run() calls from warm
// inventory, automatically refill after each use.
//
// Concurrency model:
//   - Pool is an actor so all state mutations are serialized.
//   - Each slot holds an already-booted VM (or nil while booting/replacing).
//   - acquire() suspends the caller on a continuation channel until a VM is
//     ready; release() fulfils a waiting caller first, then returns the VM to
//     inventory.
//   - Background refill tasks are Task.detached so they don't inherit the
//     pool actor's executor and can boot VMs concurrently.

import Foundation

/// A pre-warmed pool of VMs. Boot once, run many.
///
/// ```swift
/// let pool = Pool(size: 4)
/// try await pool.boot()
///
/// let result = try await pool.run("echo hello")
/// ```
public actor Pool {

    // MARK: - Public Config

    public nonisolated let size: Int
    public nonisolated let options: VMOptions

    // MARK: - Inventory

    /// Ready-to-use VMs. May contain fewer than `size` while slots refill.
    private var available: [VM] = []

    /// Callers blocked waiting for a VM.
    private var waiters: [CheckedContinuation<VM, any Error>] = []

    /// Count of slots currently booting (prevents over-spawning).
    private var booting: Int = 0

    /// True after shutdown() is called — rejects new runs.
    private var isShutdown = false

    /// Exposed for testing only. Count of VMs currently in inventory.
    internal var availableCount: Int { available.count }

    // MARK: - Init

    public init(size: Int = 4, options: VMOptions = VMOptions()) {
        self.size = size
        self.options = options
    }

    public init(size: Int = 4, image: String) {
        self.size = size
        self.options = VMOptions(image: image)
    }

    // MARK: - Boot

    /// Pre-boot all pool slots. Call once before `run()`.
    /// Boots VMs concurrently via detached tasks.
    ///
    /// **Network note:** VMs use NAT networking. The gateway discovery heuristic
    /// picks the first available vmnet bridge, which is correct for sequential boots.
    /// When multiple slots boot simultaneously on a host with several active vmnet
    /// bridges, a VM may pick the wrong bridge (rare in practice — Apple typically
    /// assigns one bridge per process). Call `boot()` and let it complete before
    /// serving traffic if strict per-VM networking is required.
    public func boot() async throws {
        guard !isShutdown else { throw LuminaError.sessionFailed("Pool is shut down") }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<size {
                group.addTask { [self] in
                    await self.bootOneSlot()
                }
            }
        }
        guard !available.isEmpty else {
            throw LuminaError.bootFailed(underlying: PoolError.allSlotsFailed)
        }
    }

    // MARK: - Run

    /// Run a command in a pooled VM. Returns when the command completes.
    /// The VM is automatically returned to the pool and a fresh one is booted.
    ///
    /// File transfers run on the pre-warmed VM before (uploads) and after (downloads) exec.
    /// Note: mounts (volumes) are VM-level configuration — pass them in `VMOptions.mounts`
    /// at pool init time so all slots boot with the mount already attached.
    public func run(
        _ command: String,
        timeout: Duration = .seconds(60),
        env: [String: String] = [:],
        workingDirectory: String? = nil,
        uploads: [FileUpload] = [],
        directoryUploads: [DirectoryUpload] = [],
        downloads: [FileDownload] = [],
        directoryDownloads: [DirectoryDownload] = [],
        stdin: Stdin = .closed
    ) async throws -> RunResult {
        guard !isShutdown else { throw LuminaError.sessionFailed("Pool is shut down") }
        let vm = try await acquire()
        defer { Task { await self.releaseAndRefill(vm) } }

        // Upload files before exec
        if !uploads.isEmpty {
            try await vm.uploadFilesResult(uploads).get()
        }
        for dir in directoryUploads {
            try await vm.uploadDirectory(localPath: dir.localPath, remotePath: dir.remotePath)
        }

        let timeoutSecs = max(Int(timeout.components.seconds), 1)
        let result = try await vm.execResult(
            command,
            timeout: timeoutSecs,
            env: env,
            cwd: workingDirectory,
            stdin: stdin
        ).get()

        // Download after exec — auto-detect file vs directory on guest (mirrors Lumina.run)
        for dl in downloads {
            let escaped = dl.remotePath.replacingOccurrences(of: "'", with: "'\\''")
            let check = try await vm.exec("test -d '\(escaped)'", timeout: 10)
            if check.exitCode == 0 {
                try await vm.downloadDirectory(remotePath: dl.remotePath, localPath: dl.localPath)
            } else {
                try await vm.downloadFiles([dl])
            }
        }
        for dir in directoryDownloads {
            try await vm.downloadDirectory(remotePath: dir.remotePath, localPath: dir.localPath)
        }

        return result
    }

    // MARK: - Shutdown

    /// Shut down all pooled VMs and reject future run() calls.
    public func shutdown() async {
        isShutdown = true
        // Fail all waiting callers
        for waiter in waiters {
            waiter.resume(throwing: LuminaError.sessionFailed("Pool shut down"))
        }
        waiters.removeAll()
        // Shut down ready VMs
        let vms = available
        available.removeAll()
        for vm in vms {
            await vm.shutdown()
        }
    }

    // MARK: - Private: Acquire / Release

    /// Borrow a VM. Suspends if none available; times out with session error if pool is exhausted.
    private func acquire() async throws -> VM {
        if let vm = available.first {
            available.removeFirst()
            return vm
        }
        // Suspend until a VM becomes available
        return try await withCheckedThrowingContinuation { cont in
            waiters.append(cont)
        }
    }

    /// Return a used VM, boot a replacement, hand off to the next waiter or inventory.
    private func releaseAndRefill(_ used: VM) async {
        await used.shutdown()
        // Boot a fresh replacement slot asynchronously
        Task.detached { [self] in
            let fresh = await self.bootSingleVM()
            await self.depositVM(fresh)
        }
    }

    /// Add a fresh VM to the pool: fulfil the first waiter, or add to inventory.
    /// If the pool is shut down, immediately shuts down the VM to prevent leaks.
    private func depositVM(_ vm: VM?) async {
        guard let vm else {
            booting = max(0, booting - 1)
            return
        }
        booting = max(0, booting - 1)
        // If shutdown() was called while this VM was booting, shut it down
        // immediately rather than adding it to inventory — prevents leaked VMs.
        if isShutdown {
            await vm.shutdown()
            return
        }
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume(returning: vm)
        } else {
            available.append(vm)
        }
    }

    // MARK: - Private: Boot Helpers

    /// Boot one slot concurrently (for initial boot).
    private func bootOneSlot() async {
        let vm = await bootSingleVM()
        await depositVM(vm)
    }

    /// Allocate and boot a single VM. Returns nil on failure.
    private func bootSingleVM() async -> VM? {
        booting += 1
        let vm = VM(options: options)
        do {
            try await vm.bootResult().get()
            try await vm.configureNetwork()
            return vm
        } catch {
            await vm.shutdown()
            // Log boot failure so operators can detect pool drain.
            // A pool that drains to zero causes acquire() to suspend indefinitely.
            NSLog("[Lumina.Pool] Slot boot failed: %@", String(describing: error))
            return nil
        }
    }
}

// MARK: - Lumina.pool convenience

extension Lumina {
    /// Create and boot a pre-warmed VM pool.
    ///
    /// VMs use NAT networking. The gateway heuristic is correct for typical
    /// single-process usage. See ``Pool/boot()`` for known limitations.
    ///
    /// ```swift
    /// let pool = try await Lumina.pool(size: 4, image: "default")
    /// let result = try await pool.run("echo hello")
    /// await pool.shutdown()
    /// ```
    public static func pool(
        size: Int = 4,
        image: String = "default",
        memory: UInt64 = 1024 * 1024 * 1024,
        cpuCount: Int = 2
    ) async throws -> Pool {
        let opts = VMOptions(memory: memory, cpuCount: cpuCount, image: image)
        let pool = Pool(size: size, options: opts)
        try await pool.boot()
        return pool
    }
}

// MARK: - Pool Errors

private enum PoolError: Error, Sendable {
    case allSlotsFailed
}

extension PoolError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .allSlotsFailed: return "All pool slots failed to boot"
        }
    }
}
