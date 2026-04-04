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
