// Sources/Lumina/ImageStore.swift
import Foundation

public struct ImagePaths: Sendable {
    public let kernel: URL
    public let initrd: URL
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
        let initrd = dir.appendingPathComponent("initrd")
        let rootfs = dir.appendingPathComponent("rootfs.img")

        guard FileManager.default.fileExists(atPath: kernel.path),
              FileManager.default.fileExists(atPath: initrd.path),
              FileManager.default.fileExists(atPath: rootfs.path)
        else {
            throw .imageNotFound(name)
        }

        return ImagePaths(kernel: kernel, initrd: initrd, rootfs: rootfs)
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
            .sorted()
    }

    public func clean(name: String) {
        let dir = baseDir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dir)
    }
}
