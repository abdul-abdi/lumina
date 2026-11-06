// Sources/Lumina/ImageStore.swift
import Foundation

public struct ImagePaths: Sendable {
    public let kernel: URL
    public let rootfs: URL
}

public struct ImageStore: Sendable {
    public let baseDir: URL

    public static let defaultBaseDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".lumina/images")
    }()

    public init(baseDir: URL = ImageStore.defaultBaseDir) {
        self.baseDir = baseDir
    }

    public func resolve(name: String) throws(LuminaError) -> ImagePaths {
        let dir = baseDir.appendingPathComponent(name)
        let kernel = dir.appendingPathComponent("vmlinuz")
        let rootfs = dir.appendingPathComponent("rootfs.img")
        guard FileManager.default.fileExists(atPath: kernel.path),
              FileManager.default.fileExists(atPath: rootfs.path)
        else {
            throw .imageNotFound(name)
        }
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("initrd").path) {
            throw .bootFailed(underlying: VMError.invalidState(
                "image '\(name)' uses the pre-v0.5 initrd layout; run `lumina pull --force` or rebuild it"
            ))
        }
        return ImagePaths(kernel: kernel, rootfs: rootfs)
    }

    public func list() -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: baseDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return []
        }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { $0.lastPathComponent }
            .filter { !$0.hasPrefix(".tmp-") }
            .sorted()
    }

    /// Read image metadata. Returns nil if the image has no meta.json.
    public func readMeta(name: String) -> ImageMeta? {
        let metaFile = baseDir.appendingPathComponent(name).appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: metaFile),
              let meta = try? JSONDecoder().decode(ImageMeta.self, from: data) else {
            return nil
        }
        return meta
    }

    public func clean(name: String) {
        let dir = baseDir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dir)
    }

    /// Create a new named image from a base image and a modified rootfs.
    /// Uses staging-dir + atomic rename for crash safety.
    public func createImage(
        name: String,
        from base: String,
        rootfsSource: URL,
        command: String,
        rosetta: Bool = false
    ) throws {
        let fm = FileManager.default

        // Validate base exists
        let baseImageDir = baseDir.appendingPathComponent(base)
        guard fm.fileExists(atPath: baseImageDir.appendingPathComponent("rootfs.img").path) else {
            throw LuminaError.imageNotFound(base)
        }

        // Staging dir for atomic creation
        let stagingId = UUID().uuidString
        let stagingDir = baseDir.appendingPathComponent(".tmp-\(stagingId)")

        do {
            try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)

            // Copy modified rootfs
            try fm.copyItem(at: rootfsSource, to: stagingDir.appendingPathComponent("rootfs.img"))

            try fm.createSymbolicLink(
                at: stagingDir.appendingPathComponent("vmlinuz"),
                withDestinationURL: baseImageDir.appendingPathComponent("vmlinuz")
            )

            // Write meta.json
            let meta = ImageMeta(base: base, command: command, created: Date(), rosetta: rosetta)
            let metaData = try JSONEncoder().encode(meta)
            try metaData.write(to: stagingDir.appendingPathComponent("meta.json"))

            // Atomic rename to final location
            let finalDir = self.baseDir.appendingPathComponent(name)
            try fm.moveItem(at: stagingDir, to: finalDir)
        } catch let error as LuminaError {
            try? fm.removeItem(at: stagingDir)
            throw error
        } catch {
            try? fm.removeItem(at: stagingDir)
            throw LuminaError.cloneFailed(underlying: error)
        }
    }

    /// Remove a named image. Refuses if other images depend on it.
    public func removeImage(name: String) throws {
        let allNames = list()
        for other in allNames where other != name {
            let metaFile = baseDir.appendingPathComponent(other).appendingPathComponent("meta.json")
            if let data = try? Data(contentsOf: metaFile),
               let meta = try? JSONDecoder().decode(ImageMeta.self, from: data),
               meta.base == name {
                throw LuminaError.sessionFailed("Cannot remove '\(name)': image '\(other)' depends on it")
            }
        }
        let dir = baseDir.appendingPathComponent(name)
        try FileManager.default.removeItem(at: dir)
    }

    /// Inspect an image -- returns metadata and size.
    public func inspect(name: String) throws -> ImageInfo {
        let dir = baseDir.appendingPathComponent(name)
        let metaFile = dir.appendingPathComponent("meta.json")
        let rootfs = dir.appendingPathComponent("rootfs.img")

        guard FileManager.default.fileExists(atPath: rootfs.path) else {
            throw LuminaError.imageNotFound(name)
        }

        var base: String? = nil
        var command: String? = nil
        var rosetta = false
        var created = Date()

        if let data = try? Data(contentsOf: metaFile),
           let meta = try? JSONDecoder().decode(ImageMeta.self, from: data) {
            base = meta.base
            command = meta.command
            rosetta = meta.rosetta
            created = meta.created
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: rootfs.path)
        let size = attrs?[.size] as? UInt64 ?? 0

        return ImageInfo(name: name, base: base, command: command, rosetta: rosetta, created: created, sizeBytes: size)
    }

    /// Clean up staging directories left by crashed image creation attempts.
    public func cleanStagingDirs() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(".tmp-") {
            try? fm.removeItem(at: entry)
        }
    }
}
