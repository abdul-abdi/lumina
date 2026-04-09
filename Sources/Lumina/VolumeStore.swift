// Sources/Lumina/VolumeStore.swift
import Foundation

public struct VolumeInfo: Sendable {
    public let name: String
    public let created: Date
    public let lastUsed: Date
    public let sizeBytes: UInt64
}

struct VolumeMeta: Codable {
    var created: Date
    var lastUsed: Date
}

public struct VolumeStore: Sendable {
    public let baseDir: URL

    public static let defaultBaseDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".lumina/volumes")
    }()

    public init(baseDir: URL = VolumeStore.defaultBaseDir) {
        self.baseDir = baseDir
    }

    public func create(name: String) throws {
        let dir = baseDir.appendingPathComponent(name)
        let dataDir = dir.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        let meta = VolumeMeta(created: Date(), lastUsed: Date())
        let data = try JSONEncoder().encode(meta)
        try data.write(to: dir.appendingPathComponent("meta.json"))
    }

    public func resolve(name: String) -> URL? {
        let dataDir = baseDir.appendingPathComponent(name).appendingPathComponent("data")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dataDir.path, isDirectory: &isDir),
              isDir.boolValue else {
            return nil
        }
        return dataDir
    }

    public func remove(name: String) throws {
        let dir = baseDir.appendingPathComponent(name)
        try FileManager.default.removeItem(at: dir)
    }

    public func list() -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: baseDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { $0.lastPathComponent }
            .sorted()
    }

    public func inspect(name: String) throws -> VolumeInfo {
        let dir = baseDir.appendingPathComponent(name)
        let metaFile = dir.appendingPathComponent("meta.json")

        guard FileManager.default.fileExists(atPath: dir.path) else {
            throw LuminaError.sessionFailed("Volume '\(name)' not found")
        }

        var created = Date()
        var lastUsed = Date()
        if let data = try? Data(contentsOf: metaFile),
           let meta = try? JSONDecoder().decode(VolumeMeta.self, from: data) {
            created = meta.created
            lastUsed = meta.lastUsed
        }

        let dataDir = dir.appendingPathComponent("data")
        let size = directorySize(dataDir)

        return VolumeInfo(name: name, created: created, lastUsed: lastUsed, sizeBytes: size)
    }

    /// Update last_used timestamp when a volume is mounted.
    public func touch(name: String) {
        let metaFile = baseDir.appendingPathComponent(name).appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: metaFile),
              var meta = try? JSONDecoder().decode(VolumeMeta.self, from: data) else { return }
        meta.lastUsed = Date()
        if let updated = try? JSONEncoder().encode(meta) {
            try? updated.write(to: metaFile)
        }
    }

    private func directorySize(_ url: URL) -> UInt64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += UInt64(size)
            }
        }
        return total
    }
}
