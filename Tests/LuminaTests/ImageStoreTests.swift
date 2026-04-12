// Tests/LuminaTests/ImageStoreTests.swift
import Foundation
import Testing
@testable import Lumina

@Test func imageStoreResolveFindsLegacyImage() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("lumina-test-\(UUID().uuidString)")
    let imageDir = tempDir.appendingPathComponent("images/default")
    try FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)

    try Data("kernel".utf8).write(to: imageDir.appendingPathComponent("vmlinuz"))
    try Data("initrd".utf8).write(to: imageDir.appendingPathComponent("initrd"))
    try Data("rootfs".utf8).write(to: imageDir.appendingPathComponent("rootfs.img"))

    let store = ImageStore(baseDir: tempDir.appendingPathComponent("images"))
    let paths = try store.resolve(name: "default")

    #expect(paths.kernel.lastPathComponent == "vmlinuz")
    #expect(paths.initrd?.lastPathComponent == "initrd")
    #expect(paths.rootfs.lastPathComponent == "rootfs.img")
    #expect(!paths.isBaked)

    try FileManager.default.removeItem(at: tempDir)
}

@Test func imageStoreResolvesFindsBakedImage() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("lumina-test-\(UUID().uuidString)")
    let imageDir = tempDir.appendingPathComponent("images/default")
    try FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)

    // Baked image: only vmlinuz + rootfs.img (no initrd, no agent, no modules)
    try Data("kernel".utf8).write(to: imageDir.appendingPathComponent("vmlinuz"))
    try Data("rootfs".utf8).write(to: imageDir.appendingPathComponent("rootfs.img"))

    let store = ImageStore(baseDir: tempDir.appendingPathComponent("images"))
    let paths = try store.resolve(name: "default")

    #expect(paths.kernel.lastPathComponent == "vmlinuz")
    #expect(paths.initrd == nil)
    #expect(paths.rootfs.lastPathComponent == "rootfs.img")
    #expect(paths.agent == nil)
    #expect(paths.modulesDir == nil)
    #expect(paths.isBaked)

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
    let meta = ImageMeta(base: "default", command: "apk add python3", created: Date(), rosetta: false)
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

@Test func imageMetaBackwardCompatibleDecoding() throws {
    // Old meta.json without rosetta field — should decode with rosetta = false
    let json = """
    {"base":"default","command":"apk add python3","created":694224000}
    """
    let data = Data(json.utf8)
    let meta = try JSONDecoder().decode(ImageMeta.self, from: data)
    #expect(meta.base == "default")
    #expect(meta.command == "apk add python3")
    #expect(meta.rosetta == false)
}

@Test func imageMetaWithRosetta() throws {
    let meta = ImageMeta(base: "default", command: "apt install gcc", created: Date(), rosetta: true)
    let encoded = try JSONEncoder().encode(meta)
    let decoded = try JSONDecoder().decode(ImageMeta.self, from: encoded)
    #expect(decoded.rosetta == true)
    #expect(decoded.base == "default")
    #expect(decoded.command == "apt install gcc")
}

@Test func imageStoreReadMeta() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("lumina-imgtest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let store = ImageStore(baseDir: tmpDir)

    // No meta.json → nil
    let imageDir = tmpDir.appendingPathComponent("nometa")
    try FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)
    #expect(store.readMeta(name: "nometa") == nil)

    // With meta.json
    let metaDir = tmpDir.appendingPathComponent("withmeta")
    try FileManager.default.createDirectory(at: metaDir, withIntermediateDirectories: true)
    let meta = ImageMeta(base: "default", command: "test", created: Date(), rosetta: true)
    try JSONEncoder().encode(meta).write(to: metaDir.appendingPathComponent("meta.json"))

    let read = store.readMeta(name: "withmeta")
    #expect(read != nil)
    #expect(read?.rosetta == true)
    #expect(read?.base == "default")
}

@Test func imageCreateWithRosetta() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("lumina-imgtest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let store = ImageStore(baseDir: tmpDir)

    // Create base image
    let baseDir = tmpDir.appendingPathComponent("default")
    try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
    try Data("kernel".utf8).write(to: baseDir.appendingPathComponent("vmlinuz"))
    try Data("rootfs".utf8).write(to: baseDir.appendingPathComponent("rootfs.img"))

    let modifiedRootfs = tmpDir.appendingPathComponent("modified-rootfs.img")
    try Data("modified rootfs".utf8).write(to: modifiedRootfs)

    // Create image with rosetta = true
    try store.createImage(name: "x86dev", from: "default", rootfsSource: modifiedRootfs, command: "apt install gcc", rosetta: true)

    // Verify rosetta stored in metadata
    let meta = store.readMeta(name: "x86dev")
    #expect(meta != nil)
    #expect(meta?.rosetta == true)

    // Verify inspect shows rosetta
    let info = try store.inspect(name: "x86dev")
    #expect(info.rosetta == true)
    #expect(info.name == "x86dev")
}

@Test func imageCreateWithoutRosetta() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("lumina-imgtest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let store = ImageStore(baseDir: tmpDir)

    let baseDir = tmpDir.appendingPathComponent("default")
    try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
    try Data("kernel".utf8).write(to: baseDir.appendingPathComponent("vmlinuz"))
    try Data("rootfs".utf8).write(to: baseDir.appendingPathComponent("rootfs.img"))

    let modifiedRootfs = tmpDir.appendingPathComponent("modified-rootfs.img")
    try Data("modified".utf8).write(to: modifiedRootfs)

    // Create image with rosetta = false (default)
    try store.createImage(name: "alpine", from: "default", rootfsSource: modifiedRootfs, command: "apk add vim")

    let meta = store.readMeta(name: "alpine")
    #expect(meta != nil)
    #expect(meta?.rosetta == false)

    let info = try store.inspect(name: "alpine")
    #expect(info.rosetta == false)
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
