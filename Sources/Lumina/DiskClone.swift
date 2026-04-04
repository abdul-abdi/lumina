import Foundation

public struct DiskClone: Sendable {
    public let directory: URL
    public let rootfs: URL
    public let pidFile: URL

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

        // APFS COW clone via copyItem (uses cloneFile internally on APFS)
        do {
            try FileManager.default.copyItem(at: sourceImage, to: rootfs)
        } catch {
            // Cleanup the directory if clone fails
            try? FileManager.default.removeItem(at: dir)
            throw .cloneFailed(underlying: error)
        }

        // Write PID file for orphan detection
        let pid = "\(ProcessInfo.processInfo.processIdentifier)"
        do {
            try Data(pid.utf8).write(to: pidFile)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw .cloneFailed(underlying: error)
        }

        return DiskClone(directory: dir, rootfs: rootfs, pidFile: pidFile)
    }

    public func remove() {
        try? FileManager.default.removeItem(at: directory)
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
                // No valid PID file — remove it
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
