// Tests/LuminaTests/ImageStoreTests.swift
import Foundation
import Testing
@testable import Lumina

@Test func imageStoreResolveFindsImage() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("lumina-test-\(UUID().uuidString)")
    let imageDir = tempDir.appendingPathComponent("images/default")
    try FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)

    try Data("kernel".utf8).write(to: imageDir.appendingPathComponent("vmlinuz"))
    try Data("initrd".utf8).write(to: imageDir.appendingPathComponent("initrd"))
    try Data("rootfs".utf8).write(to: imageDir.appendingPathComponent("rootfs.img"))

    let store = ImageStore(baseDir: tempDir.appendingPathComponent("images"))
    let paths = try store.resolve(name: "default")

    #expect(paths.kernel.lastPathComponent == "vmlinuz")
    #expect(paths.initrd.lastPathComponent == "initrd")
    #expect(paths.rootfs.lastPathComponent == "rootfs.img")

    try FileManager.default.removeItem(at: tempDir)
}

@Test func imageStoreResolveThrowsWhenMissing() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("lumina-test-\(UUID().uuidString)")
    let store = ImageStore(baseDir: tempDir.appendingPathComponent("images"))

    #expect(throws: LuminaError.self) {
        try store.resolve(name: "nonexistent")
    }

    try? FileManager.default.removeItem(at: tempDir)
}

@Test func imageStoreListReturnsNames() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("lumina-test-\(UUID().uuidString)")
    let imagesDir = tempDir.appendingPathComponent("images")
    try FileManager.default.createDirectory(
        at: imagesDir.appendingPathComponent("default"),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: imagesDir.appendingPathComponent("ubuntu"),
        withIntermediateDirectories: true
    )

    let store = ImageStore(baseDir: imagesDir)
    let names = store.list()

    #expect(names.contains("default"))
    #expect(names.contains("ubuntu"))

    try FileManager.default.removeItem(at: tempDir)
}

@Test func imageStoreListReturnsEmptyWhenNoDir() {
    let store = ImageStore(baseDir: URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)"))
    let names = store.list()
    #expect(names.isEmpty)
}

@Test func imageCreateAndInspect() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("lumina-imgtest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let store = ImageStore(baseDir: tmpDir)

    // Create a fake base image
    let baseDir = tmpDir.appendingPathComponent("default")
    try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
    try Data("kernel".utf8).write(to: baseDir.appendingPathComponent("vmlinuz"))
    try Data("initrd".utf8).write(to: baseDir.appendingPathComponent("initrd"))
    try Data("rootfs".utf8).write(to: baseDir.appendingPathComponent("rootfs.img"))
    try Data("agent".utf8).write(to: baseDir.appendingPathComponent("lumina-agent"))
    let modulesDir = baseDir.appendingPathComponent("modules")
    try FileManager.default.createDirectory(at: modulesDir, withIntermediateDirectories: true)

    // Create a modified rootfs (simulates what DiskClone.rootfs would contain)
    let modifiedRootfs = tmpDir.appendingPathComponent("modified-rootfs.img")
    try Data("modified rootfs".utf8).write(to: modifiedRootfs)

    // Create image
    try store.createImage(
        name: "python",
        from: "default",
        rootfsSource: modifiedRootfs,
        command: "apk add python3"
    )

    // Verify image exists
    let names = store.list()
    #expect(names.contains("python"))

    // Verify inspect
    let info = try store.inspect(name: "python")
    #expect(info.name == "python")
    #expect(info.base == "default")
    #expect(info.command == "apk add python3")

    // Verify rootfs is a copy, not a symlink
    let pythonRootfs = tmpDir.appendingPathComponent("python/rootfs.img")
    let rootfsContent = try String(contentsOf: pythonRootfs, encoding: .utf8)
    #expect(rootfsContent == "modified rootfs")
}

@Test func imageRemoveWithDependents() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("lumina-imgtest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let store = ImageStore(baseDir: tmpDir)

    // Create base + derived images manually
    let baseDir = tmpDir.appendingPathComponent("default")
    try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
    try Data("k".utf8).write(to: baseDir.appendingPathComponent("vmlinuz"))
    try Data("i".utf8).write(to: baseDir.appendingPathComponent("initrd"))
    try Data("r".utf8).write(to: baseDir.appendingPathComponent("rootfs.img"))

    let pythonDir = tmpDir.appendingPathComponent("python")
    try FileManager.default.createDirectory(at: pythonDir, withIntermediateDirectories: true)
    try Data("r2".utf8).write(to: pythonDir.appendingPathComponent("rootfs.img"))
    let meta = ImageMeta(base: "default", command: "apk add python3", created: Date())
    try JSONEncoder().encode(meta).write(to: pythonDir.appendingPathComponent("meta.json"))

    // Should refuse to remove default (python depends on it)
    #expect(throws: LuminaError.self) {
        try store.removeImage(name: "default")
    }

    // Should allow removing python (no dependents)
    try store.removeImage(name: "python")
    #expect(!store.list().contains("python"))
}

@Test func imageStoreListExcludesStagingDirs() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("lumina-imgtest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let store = ImageStore(baseDir: tmpDir)

    // Create a real image dir and a staging dir
    try FileManager.default.createDirectory(
        at: tmpDir.appendingPathComponent("default"),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: tmpDir.appendingPathComponent(".tmp-staging123"),
        withIntermediateDirectories: true
    )

    let names = store.list()
    #expect(names.contains("default"))
    #expect(!names.contains(".tmp-staging123"))
}

@Test func imageStoreCleanStagingDirs() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("lumina-imgtest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let store = ImageStore(baseDir: tmpDir)

    // Create staging dirs
    let staging1 = tmpDir.appendingPathComponent(".tmp-aaa")
    let staging2 = tmpDir.appendingPathComponent(".tmp-bbb")
    try FileManager.default.createDirectory(at: staging1, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: staging2, withIntermediateDirectories: true)

    #expect(FileManager.default.fileExists(atPath: staging1.path))
    store.cleanStagingDirs()
    #expect(!FileManager.default.fileExists(atPath: staging1.path))
    #expect(!FileManager.default.fileExists(atPath: staging2.path))
}
