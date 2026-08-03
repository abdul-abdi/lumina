import Foundation

public struct DiskClone: Sendable {
    public let directory: URL
    public let rootfs: URL
    public let pidFile: URL

    /// How long a run directory with no PID file is assumed to be a clone in
    /// flight rather than an orphan.
    static let newCloneGracePeriod: TimeInterval = 60

    public static let defaultRunsDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".lumina/runs")
    }()

    public static func create(
        from sourceImage: URL,
        runsDir: URL = DiskClone.defaultRunsDir
    ) throws(LuminaError) -> DiskClone {
        let id = UUID().uuidString
        let dir = runsDir.appendingPathComponent(id)
        let rootfs = dir.appendingPathComponent("rootfs.img")
        let pidFile = dir.appendingPathComponent(".pid")

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw .cloneFailed(underlying: error)
        }

        // Claim the directory BEFORE cloning into it. `cleanOrphans` deletes
        // any run dir lacking a live PID, and runs from every `lumina run`
        // start and atexit — writing this afterwards left the entire ~1GB copy
        // as a window for a concurrent run to delete the directory underneath
        // us. Cost: ~1 in 15 concurrent boots died with "rootfs.img doesn't
        // exist" or ".pid doesn't exist".
        let pid = "\(ProcessInfo.processInfo.processIdentifier)"
        do {
            try Data(pid.utf8).write(to: pidFile)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw .cloneFailed(underlying: error)
        }

        // APFS COW clone via copyItem (uses cloneFile internally on APFS)
        do {
            try FileManager.default.copyItem(at: sourceImage, to: rootfs)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw .cloneFailed(underlying: error)
        }

        return DiskClone(directory: dir, rootfs: rootfs, pidFile: pidFile)
    }

    /// Resize the rootfs to the given size in bytes.
    /// Uses POSIX truncate to extend the file, then resize2fs (from Homebrew e2fsprogs)
    /// to grow the ext4 filesystem to fill the new space.
    public func resize(to newSize: UInt64) throws(LuminaError) {
        // Get current size
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: rootfs.path),
              let currentSize = attrs[.size] as? UInt64 else {
            throw .cloneFailed(underlying: ResizeError.cannotReadSize)
        }
        guard newSize > currentSize else { return }

        // Extend file with POSIX truncate (preserves existing content, extends with zeros)
        guard Darwin.truncate(rootfs.path, off_t(newSize)) == 0 else {
            throw .cloneFailed(underlying: ResizeError.truncateFailed)
        }

        // Find resize2fs from Homebrew e2fsprogs
        let resize2fs = Self.findE2fsTool("resize2fs")
        guard let resize2fs else {
            throw .cloneFailed(underlying: ResizeError.resize2fsNotFound)
        }

        // Grow the ext4 filesystem to fill the new space
        let process = Process()
        process.executableURL = URL(fileURLWithPath: resize2fs)
        process.arguments = [rootfs.path]
        let stderrPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw .cloneFailed(underlying: error)
        }
        guard process.terminationStatus == 0 else {
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw .cloneFailed(underlying: ResizeError.resize2fsFailed(stderr))
        }
    }

    public func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Find an e2fsprogs tool by name (checks PATH then Homebrew locations).
    private static func findE2fsTool(_ name: String) -> String? {
        // Check PATH first
        let whichProcess = Process()
        whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichProcess.arguments = [name]
        let pipe = Pipe()
        whichProcess.standardOutput = pipe
        whichProcess.standardError = FileHandle.nullDevice
        if (try? whichProcess.run()) != nil {
            whichProcess.waitUntilExit()
            if whichProcess.terminationStatus == 0 {
                let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let path, !path.isEmpty { return path }
            }
        }
        // Check Homebrew locations
        for prefix in ["/opt/homebrew", "/usr/local"] {
            let path = "\(prefix)/opt/e2fsprogs/sbin/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    @discardableResult
    public static func cleanOrphans(runsDir: URL = DiskClone.defaultRunsDir) -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: runsDir,
            includingPropertiesForKeys: nil
        ) else {
            return 0
        }

        var removed = 0
        for entry in entries {
            let pidFile = entry.appendingPathComponent(".pid")
            guard let pidStr = try? String(contentsOf: pidFile, encoding: .utf8),
                  let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines))
            else {
                // A directory created moments ago with no PID yet is a clone
                // in flight, not an orphan — another process is between
                // mkdir and its first write. Deleting it corrupts a live boot.
                if let created = try? fm.attributesOfItem(atPath: entry.path)[.creationDate] as? Date,
                   Date().timeIntervalSince(created) < newCloneGracePeriod {
                    continue
                }
                try? fm.removeItem(at: entry)
                removed += 1
                continue
            }

            // Check if process is alive (kill with signal 0 checks existence)
            if kill(pid, 0) != 0 {
                // Process doesn't exist — orphaned clone
                try? fm.removeItem(at: entry)
                removed += 1
            }
        }
        return removed
    }
}

enum ResizeError: Error, LocalizedError, Sendable {
    case cannotReadSize
    case truncateFailed
    case resize2fsNotFound
    case resize2fsFailed(String)

    var errorDescription: String? {
        switch self {
        case .cannotReadSize: "cannot read current disk size"
        case .truncateFailed: "failed to truncate disk image"
        case .resize2fsNotFound: "resize2fs not found — install e2fsprogs"
        case .resize2fsFailed(let stderr): "resize2fs failed: \(stderr)"
        }
    }
}
