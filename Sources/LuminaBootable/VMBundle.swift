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

/// Per-bundle network attachment mode. Persisted on `VMBundleManifest`
/// so the host and the app agree on behaviour across invocations.
///
/// - `.nat`: default. Uses `VZNATNetworkDeviceAttachment` — vmnet's
///   embedded DHCP server, no external network dependency. The path
///   that fails with "Network autoconfiguration failed" on a fresh
///   Debian/Kali install and that Apple's vmnet degrades after ~5 VM
///   lifecycles per session.
/// - `.bridged`: `VZBridgedNetworkDeviceAttachment`. Guest joins the
///   host's LAN directly; DHCP served by the user's real router. Fixes
///   every known vmnet issue (degradation, first-boot DHCP race,
///   unreliable UDP/ICMP-to-external), at the cost of requiring an
///   active bridgeable interface and the `com.apple.vm.networking`
///   entitlement. `interface` is the `VZBridgedNetworkInterface.identifier`
///   to bridge against (e.g. `"en0"`); nil means "first available,"
///   usually `en0`.
public enum NetworkMode: Sendable, Equatable {
    case nat
    case bridged(interface: String?)
}

extension NetworkMode: Codable {
    private enum CodingKeys: String, CodingKey { case mode, interface }
    private enum Tag: String, Codable { case nat, bridged }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(Tag.self, forKey: .mode)
        switch tag {
        case .nat:
            self = .nat
        case .bridged:
            let iface = try c.decodeIfPresent(String.self, forKey: .interface)
            self = .bridged(interface: iface)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .nat:
            try c.encode(Tag.nat, forKey: .mode)
        case .bridged(let iface):
            try c.encode(Tag.bridged, forKey: .mode)
            try c.encodeIfPresent(iface, forKey: .interface)
        }
    }
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
    /// Stable MAC address in `xx:xx:xx:xx:xx:xx` hex form. Persisted so
    /// every boot of the same bundle presents the same L2 identity to
    /// vmnet's DHCP server, eliminating lease-table churn and making the
    /// guest's IP stable across boots. Optional for backward compatibility
    /// with pre-v0.7.1 bundles; a nil value is lazily filled on first boot
    /// via `ensureMACAddress()`.
    public var macAddress: String?
    /// Network attachment mode. See `NetworkMode` for the tradeoffs.
    /// Nil means "use the library default" (`.nat`); the boot layer
    /// maps nil → `.nat` so older bundles continue to work unchanged.
    public var networkMode: NetworkMode?

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
        lastBootedAt: Date?,
        macAddress: String? = nil,
        networkMode: NetworkMode? = nil
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
        self.macAddress = macAddress
        self.networkMode = networkMode
    }

    /// Generate a MAC address in the locally-administered unicast range —
    /// byte 0 bit 1 set (locally administered), bit 0 cleared (unicast).
    /// No dependency on `Virtualization.framework`; the returned string is
    /// directly parseable by `VZMACAddress(string:)`.
    public static func generateLocallyAdministeredMAC() -> String {
        var bytes = [UInt8](repeating: 0, count: 6)
        for i in 0..<6 { bytes[i] = UInt8.random(in: 0...255) }
        bytes[0] = (bytes[0] & 0xFE) | 0x02
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
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
        networkMode: NetworkMode? = nil,
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
        // Opt the bundle out of Spotlight. A multi-GB `disk.img` that's
        // being actively written by a running guest triggers constant
        // re-indexing on every flush — the indexer briefly holds a
        // read lock on the file, which races with VZ's attempt to take
        // an exclusive lock on boot and produces
        // `VZErrorDomain Code 2 — invalid storage device attachment`.
        // `.metadata_never_index` at the directory root is Apple's
        // documented opt-out; it applies to every file in the directory.
        // Creating it is idempotent — if the flag already exists or the
        // creation fails for any reason, we continue. Non-fatal.
        try? Data().write(
            to: rootURL.appendingPathComponent(".metadata_never_index"),
            options: .atomic
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
            lastBootedAt: nil,
            macAddress: VMBundleManifest.generateLocallyAdministeredMAC(),
            networkMode: networkMode
        )
        try writeManifest(manifest, into: rootURL)
        return VMBundle(rootURL: rootURL, manifest: manifest)
    }

    /// Populate `manifest.macAddress` if missing (pre-v0.7.1 bundle),
    /// persist the change, and return the effective MAC. Safe to call on
    /// every boot — idempotent when the manifest already has a MAC. Write
    /// failure doesn't fail the boot (caller still gets a usable MAC this
    /// run) but is surfaced on stderr so the user can see that the next
    /// cold boot will regenerate — the exact failure mode this method
    /// exists to prevent.
    ///
    /// **Concurrent-open race (accepted, not guarded):** two processes
    /// that open the same pre-v0.7.1 bundle in the same sub-second window
    /// each generate a distinct in-memory MAC; whichever writes
    /// `manifest.json` last wins. Both boots that run under this race
    /// use their own in-memory MAC for the current session (so
    /// correctness holds — the DHCP lease just won't be stable between
    /// them), and every subsequent cold boot sees a populated manifest
    /// and skips generation entirely. Single-process-per-bundle is the
    /// Lumina design norm (Desktop holds the bundle; CLI `desktop boot`
    /// is invoked interactively). A scripted double-open is the only
    /// way to hit this, and the first migration boot is the only boot
    /// that matters — every boot after that is deterministic. If a use
    /// case emerges that needs strict first-boot MAC stability across
    /// concurrent callers, wrap the read-modify-write in an `flock(2)`
    /// on `manifest.json`.
    @discardableResult
    public mutating func ensureMACAddress() -> String {
        if let existing = manifest.macAddress, !existing.isEmpty {
            return existing
        }
        let generated = VMBundleManifest.generateLocallyAdministeredMAC()
        manifest.macAddress = generated
        do {
            try save()
        } catch {
            let msg = "lumina: warning: failed to persist MAC for \(rootURL.lastPathComponent): \(error). "
                + "This boot uses \(generated); the next cold boot will regenerate.\n"
            FileHandle.standardError.write(Data(msg.utf8))
        }
        return generated
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
