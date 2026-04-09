// Tests/LuminaTests/VolumeStoreTests.swift
import Foundation
import Testing
@testable import Lumina

@Test func volumeCreateAndResolve() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("lumina-voltest-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let store = VolumeStore(baseDir: tmpDir)
    try store.create(name: "pycache")

    let resolved = store.resolve(name: "pycache")
    #expect(resolved != nil)
    #expect(resolved!.path.hasSuffix("/pycache/data"))

    var isDir: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: resolved!.path, isDirectory: &isDir))
    #expect(isDir.boolValue)
}

@Test func volumeList() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("lumina-voltest-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let store = VolumeStore(baseDir: tmpDir)
    try store.create(name: "cache")
    try store.create(name: "data")

    let names = store.list()
    #expect(names.contains("cache"))
    #expect(names.contains("data"))
}

@Test func volumeRemove() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("lumina-voltest-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let store = VolumeStore(baseDir: tmpDir)
    try store.create(name: "temp")
    try store.remove(name: "temp")

    #expect(store.resolve(name: "temp") == nil)
    #expect(!store.list().contains("temp"))
}

@Test func volumeInspect() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("lumina-voltest-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let store = VolumeStore(baseDir: tmpDir)
    try store.create(name: "test")

    let info = try store.inspect(name: "test")
    #expect(info.name == "test")
    #expect(info.sizeBytes == 0)
}

@Test func volumeResolveMissing() {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("lumina-voltest-\(UUID().uuidString)")
    let store = VolumeStore(baseDir: tmpDir)
    #expect(store.resolve(name: "nonexistent") == nil)
}
