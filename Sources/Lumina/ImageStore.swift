// Sources/Lumina/ImageStore.swift
import Foundation

public struct ImagePaths: Sendable {
    public let kernel: URL
    public let initrd: URL
    public let rootfs: URL
    /// Path to the guest agent binary (linux/arm64 ELF).
    /// Present when the image directory contains a `lumina-agent` file.
    public let agent: URL?
    /// Directory containing vsock kernel modules (.ko.gz).
    /// Present when the image directory contains a `modules/` subdirectory.
    public let modulesDir: URL?
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
        let agent = dir.appendingPathComponent("lumina-agent")

        guard FileManager.default.fileExists(atPath: kernel.path),
              FileManager.default.fileExists(atPath: initrd.path),
              FileManager.default.fileExists(atPath: rootfs.path)
        else {
            throw .imageNotFound(name)
        }

        let agentURL: URL? = FileManager.default.fileExists(atPath: agent.path) ? agent : nil
        let modulesURL: URL? = {
            let dir = dir.appendingPathComponent("modules")
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir)
                && isDir.boolValue ? dir : nil
        }()
        return ImagePaths(kernel: kernel, initrd: initrd, rootfs: rootfs, agent: agentURL, modulesDir: modulesURL)
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
