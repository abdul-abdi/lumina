// Sources/Lumina/Session.swift
import Foundation

public struct SessionPaths: Sendable {
    public let sid: String
    public let directory: URL
    public let socket: URL
    public let metaFile: URL
    public let runDir: URL

    public static let defaultSessionsDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".lumina/sessions")
    }()

    public init(sid: String, sessionsDir: URL = SessionPaths.defaultSessionsDir) {
        self.sid = sid
        self.directory = sessionsDir.appendingPathComponent(sid)
        self.socket = self.directory.appendingPathComponent("control.sock")
        self.metaFile = self.directory.appendingPathComponent("meta.json")
        self.runDir = self.directory.appendingPathComponent("run")
    }

    /// Write session metadata to disk.
    ///
    /// Creates the session directory with mode 0700 so the control
    /// socket + meta.json inside are shielded from other users on the
    /// host even if umask widens file perms. The enclosing
    /// `~/.lumina/sessions` parent inherits whatever mode the user set
    /// on their home layout — we only own the per-session directory's
    /// mode. See v0.7.1 isolation probe findings for the full
    /// rationale; paired with the chmod-0600 on control.sock in
    /// `SessionServer.bind`.
    public func writeMeta(_ info: SessionInfo) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // If the directory already existed (e.g. same-SID reuse, unlikely
        // but possible across crashes), re-chmod it. createDirectory does
        // NOT alter existing permissions.
        _ = chmod(directory.path, 0o700)
        let data = try JSONEncoder().encode(info)
        try data.write(to: metaFile)
        // Meta file too — no session secrets in it today, but pid + image
        // name should not be a readable signal for other users.
        _ = chmod(metaFile.path, 0o600)
    }

    /// Read session metadata from disk. Returns nil if file doesn't exist.
    public func readMeta() -> SessionInfo? {
        guard let data = try? Data(contentsOf: metaFile) else { return nil }
        return try? JSONDecoder().decode(SessionInfo.self, from: data)
    }

    /// Check if the session's process is alive.
    public func isAlive() -> Bool {
        guard let info = readMeta() else { return false }
        return kill(info.pid, 0) == 0
    }

    /// Remove the session directory and all contents.
    public func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// List all sessions, checking liveness.
    public static func listAll(sessionsDir: URL = SessionPaths.defaultSessionsDir) -> [SessionInfo] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: sessionsDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        return entries.compactMap { entry -> SessionInfo? in
            let sid = entry.lastPathComponent
            let paths = SessionPaths(sid: sid, sessionsDir: sessionsDir)
            guard var info = paths.readMeta() else { return nil }
            if kill(info.pid, 0) != 0 {
                info.status = .dead
            }
            return info
        }.sorted { $0.created < $1.created }
    }
}
