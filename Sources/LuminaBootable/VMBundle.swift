// Sources/LuminaBootable/VMBundle.swift
//
// Filesystem-backed model for a `.luminaVM` bundle.
//
// Layout:
//   <root>/manifest.json      — VMBundleManifest (JSON)
//   <root>/disk.img           — primary disk (sparse)
//   <root>/efi.vars           — EFI variable store (EFI guests)
//   <root>/aux.img            — macOS auxiliary storage (macOS guests)
//   <root>/snapshots/<id>/    — snapshot subtree
//   <root>/logs/serial.log    — current serial console capture
//
// The bundle is self-describing: loading only needs `manifest.json`; all
// other files are resolved relative to the bundle root.

import Foundation

public enum OSFamily: String, Codable, Sendable, Equatable {
    case linux
    case windows
    case macOS
}

public struct VMBundleManifest: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var id: UUID
    public var name: String
    public var osFamily: OSFamily
    public var osVariant: String
    public var memoryBytes: UInt64
    public var cpuCount: Int
    public var diskBytes: UInt64
    public var createdAt: Date
    public var lastBootedAt: Date?

    public init(
        schemaVersion: Int = 1,
        id: UUID,
        name: String,
        osFamily: OSFamily,
        osVariant: String,
        memoryBytes: UInt64,
        cpuCount: Int,
        diskBytes: UInt64,
        createdAt: Date,
        lastBootedAt: Date?
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.osFamily = osFamily
        self.osVariant = osVariant
        self.memoryBytes = memoryBytes
        self.cpuCount = cpuCount
        self.diskBytes = diskBytes
        self.createdAt = createdAt
        self.lastBootedAt = lastBootedAt
    }
}

public struct VMBundle: Sendable, Equatable {
    public let rootURL: URL
    public var manifest: VMBundleManifest

    public var manifestURL: URL { rootURL.appendingPathComponent("manifest.json") }
    public var primaryDiskURL: URL { rootURL.appendingPathComponent("disk.img") }
    public var efiVarsURL: URL { rootURL.appendingPathComponent("efi.vars") }
    public var auxiliaryStorageURL: URL { rootURL.appendingPathComponent("aux.img") }
    public var snapshotsDirectory: URL { rootURL.appendingPathComponent("snapshots") }
    public var logsDirectory: URL { rootURL.appendingPathComponent("logs") }

    public enum Error: Swift.Error, Equatable {
        case alreadyExists(URL)
        case notABundle(URL)
        case invalidManifest(URL)
    }

    public static func create(
        at rootURL: URL,
        name: String,
        osFamily: OSFamily,
        osVariant: String,
        memoryBytes: UInt64,
        cpuCount: Int,
        diskBytes: UInt64,
        id: UUID = UUID(),
        now: Date = Date()
    ) throws -> VMBundle {
        if FileManager.default.fileExists(atPath: rootURL.path) {
            throw Error.alreadyExists(rootURL)
        }
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("logs"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("snapshots"),
            withIntermediateDirectories: true
        )
        let manifest = VMBundleManifest(
            id: id,
            name: name,
            osFamily: osFamily,
            osVariant: osVariant,
            memoryBytes: memoryBytes,
            cpuCount: cpuCount,
            diskBytes: diskBytes,
            createdAt: now,
            lastBootedAt: nil
        )
        try writeManifest(manifest, into: rootURL)
        return VMBundle(rootURL: rootURL, manifest: manifest)
    }

    public static func load(from rootURL: URL) throws -> VMBundle {
        let manifestURL = rootURL.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw Error.notABundle(rootURL)
        }
        let data = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let decoded = try decoder.decode(VMBundleManifest.self, from: data)
            return VMBundle(rootURL: rootURL, manifest: decoded)
        } catch {
            throw Error.invalidManifest(manifestURL)
        }
    }

    public func save() throws {
        try Self.writeManifest(manifest, into: rootURL)
    }

    private static func writeManifest(_ manifest: VMBundleManifest, into rootURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(
            to: rootURL.appendingPathComponent("manifest.json"),
            options: .atomic
        )
    }
}
