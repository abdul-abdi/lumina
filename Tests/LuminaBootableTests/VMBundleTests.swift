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

    @Test func macAddressIsPopulatedOnCreate() throws {
        let path = root.appendingPathComponent(UUID().uuidString)
        let bundle = try VMBundle.create(
            at: path,
            name: "MACTest",
            osFamily: .linux,
            osVariant: "kali-rolling",
            memoryBytes: 1024 * 1024 * 1024,
            cpuCount: 1,
            diskBytes: 1024 * 1024 * 1024
        )
        guard let mac = bundle.manifest.macAddress else {
            Issue.record("Expected macAddress to be populated on create")
            return
        }
        // xx:xx:xx:xx:xx:xx form, 17 chars, 6 hex octets.
        #expect(mac.count == 17)
        let octets = mac.split(separator: ":")
        #expect(octets.count == 6)
        for octet in octets { #expect(octet.count == 2) }
        // First octet must be locally-administered (bit 1 set) and
        // unicast (bit 0 cleared). That's the whole point of the
        // randomLocallyAdministered contract.
        guard let firstByte = UInt8(octets[0], radix: 16) else {
            Issue.record("First octet \(octets[0]) is not a valid hex byte")
            return
        }
        #expect((firstByte & 0x02) == 0x02)
        #expect((firstByte & 0x01) == 0x00)
    }

    @Test func ensureMACAddressIsIdempotentAcrossBootAndReload() throws {
        let path = root.appendingPathComponent(UUID().uuidString)
        var bundle = try VMBundle.create(
            at: path,
            name: "Stable",
            osFamily: .linux,
            osVariant: "ubuntu-24.04",
            memoryBytes: 1024 * 1024 * 1024,
            cpuCount: 1,
            diskBytes: 1024 * 1024 * 1024
        )
        let first = bundle.ensureMACAddress()
        let second = bundle.ensureMACAddress()
        #expect(first == second)
        // Survives a reload from disk.
        let reloaded = try VMBundle.load(from: path)
        #expect(reloaded.manifest.macAddress == first)
    }

    @Test func ensureMACAddressBackfillsLegacyManifest() throws {
        // Simulate a pre-v0.7.1 bundle that predates macAddress persistence
        // by building one with macAddress: nil directly on disk.
        let path = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let legacy = VMBundleManifest(
            id: UUID(),
            name: "Legacy",
            osFamily: .linux,
            osVariant: "ubuntu-22.04",
            memoryBytes: 1024 * 1024 * 1024,
            cpuCount: 1,
            diskBytes: 1024 * 1024 * 1024,
            createdAt: Date(),
            lastBootedAt: nil,
            macAddress: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(legacy)
        try data.write(to: path.appendingPathComponent("manifest.json"))

        var bundle = try VMBundle.load(from: path)
        #expect(bundle.manifest.macAddress == nil)
        let backfilled = bundle.ensureMACAddress()
        #expect(!backfilled.isEmpty)
        #expect(bundle.manifest.macAddress == backfilled)
        // Re-loaded manifest has the persisted backfill.
        let reloaded = try VMBundle.load(from: path)
        #expect(reloaded.manifest.macAddress == backfilled)
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
