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

        let baseImageDir = baseDir.appendingPathComponent(base)
        guard fm.fileExists(atPath: baseImageDir.appendingPathComponent("rootfs.img").path) else {
            throw LuminaError.imageNotFound(base)
        }

        let stagingId = UUID().uuidString
        let stagingDir = baseDir.appendingPathComponent(".tmp-\(stagingId)")

        do {
            try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)

            try fm.copyItem(at: rootfsSource, to: stagingDir.appendingPathComponent("rootfs.img"))

            try fm.createSymbolicLink(
                at: stagingDir.appendingPathComponent("vmlinuz"),
                withDestinationURL: baseImageDir.appendingPathComponent("vmlinuz")
            )

            let meta = ImageMeta(base: base, command: command, created: Date(), rosetta: rosetta)
            let metaData = try JSONEncoder().encode(meta)
            try metaData.write(to: stagingDir.appendingPathComponent("meta.json"))

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
        for other in list() where other != name && readMeta(name: other)?.base == name {
            throw LuminaError.sessionFailed("Cannot remove '\(name)': image '\(other)' depends on it")
        }
        let dir = baseDir.appendingPathComponent(name)
        try FileManager.default.removeItem(at: dir)
    }

    public func inspect(name: String) throws -> ImageInfo {
        let rootfs = baseDir.appendingPathComponent(name).appendingPathComponent("rootfs.img")

        guard FileManager.default.fileExists(atPath: rootfs.path) else {
            throw LuminaError.imageNotFound(name)
        }

        let meta = readMeta(name: name)
        let attrs = try? FileManager.default.attributesOfItem(atPath: rootfs.path)
        let size = attrs?[.size] as? UInt64 ?? 0

        return ImageInfo(
            name: name,
            base: meta?.base,
            command: meta?.command,
            rosetta: meta?.rosetta ?? false,
            created: meta?.created ?? Date(),
            sizeBytes: size
        )
    }
}
