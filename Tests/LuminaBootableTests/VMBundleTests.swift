// Tests/LuminaBootableTests/VMBundleTests.swift
import Foundation
import Testing
@testable import LuminaBootable

@Suite struct VMBundleTests {
    let root: URL

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LuminaVMBundleTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    @Test func manifestRoundTripsThroughJSON() throws {
        let manifest = VMBundleManifest(
            schemaVersion: 1,
            id: UUID(),
            name: "Ubuntu 24.04",
            osFamily: .linux,
            osVariant: "ubuntu-24.04",
            memoryBytes: 4 * 1024 * 1024 * 1024,
            cpuCount: 2,
            diskBytes: 32 * 1024 * 1024 * 1024,
            createdAt: Date(timeIntervalSince1970: 1_713_600_000),
            lastBootedAt: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoded = try encoder.encode(manifest)
        let decoded = try decoder.decode(VMBundleManifest.self, from: encoded)
        #expect(decoded == manifest)
    }

    @Test func bundle_createsDirectoriesAndManifest() throws {
        let bundle = try VMBundle.create(
            at: root.appendingPathComponent(UUID().uuidString),
            name: "Test",
            osFamily: .linux,
            osVariant: "ubuntu-24.04",
            memoryBytes: 2 * 1024 * 1024 * 1024,
            cpuCount: 2,
            diskBytes: 4 * 1024 * 1024 * 1024
        )
        #expect(FileManager.default.fileExists(atPath: bundle.manifestURL.path))
        #expect(FileManager.default.fileExists(atPath: bundle.logsDirectory.path))
        #expect(FileManager.default.fileExists(atPath: bundle.snapshotsDirectory.path))
    }

    @Test func bundle_loadsExistingManifest() throws {
        let path = root.appendingPathComponent(UUID().uuidString)
        let created = try VMBundle.create(
            at: path,
            name: "Roundtrip",
            osFamily: .linux,
            osVariant: "debian-12",
            memoryBytes: 1 * 1024 * 1024 * 1024,
            cpuCount: 1,
            diskBytes: 1 * 1024 * 1024 * 1024
        )
        let loaded = try VMBundle.load(from: path)
        #expect(loaded.manifest.name == "Roundtrip")
        #expect(loaded.manifest.osVariant == "debian-12")
        #expect(loaded.manifest.id == created.manifest.id)
    }

    @Test func bundle_rejectsExistingRoot() throws {
        let path = root.appendingPathComponent(UUID().uuidString)
        _ = try VMBundle.create(
            at: path,
            name: "First",
            osFamily: .linux,
            osVariant: "ubuntu-24.04",
            memoryBytes: 1024 * 1024 * 1024,
            cpuCount: 1,
            diskBytes: 1024 * 1024 * 1024
        )
        #expect(throws: VMBundle.Error.self) {
            _ = try VMBundle.create(
                at: path,
                name: "Second",
                osFamily: .linux,
                osVariant: "ubuntu-24.04",
                memoryBytes: 1024 * 1024 * 1024,
                cpuCount: 1,
                diskBytes: 1024 * 1024 * 1024
            )
        }
    }

    @Test func bundle_loadRejectsMissingManifest() throws {
        let path = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        #expect(throws: VMBundle.Error.self) {
            _ = try VMBundle.load(from: path)
        }
    }

    @Test func bundle_save_writesUpdatedManifest() throws {
        let path = root.appendingPathComponent(UUID().uuidString)
        var bundle = try VMBundle.create(
            at: path,
            name: "Original",
            osFamily: .linux,
            osVariant: "ubuntu-24.04",
            memoryBytes: 1024 * 1024 * 1024,
            cpuCount: 1,
            diskBytes: 1024 * 1024 * 1024
        )
        let now = Date()
        bundle.manifest.lastBootedAt = now
        try bundle.save()
        let reloaded = try VMBundle.load(from: path)
        #expect(reloaded.manifest.lastBootedAt != nil)
    }
}
