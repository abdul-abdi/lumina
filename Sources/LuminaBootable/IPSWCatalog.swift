// Sources/LuminaBootable/IPSWCatalog.swift
//
// v0.7.0 M5 — fetch + cache the catalog of macOS IPSWs Apple serves over
// `mesu.apple.com`.
//
// IMPORTANT: this catalog endpoint is unofficial. Apple ships it for the
// macOS Software Update mechanism; we read it for the same purpose
// (selecting an IPSW to restore). If Apple changes the format or moves
// the endpoint, the wizard falls back to BYO-IPSW (file picker).
//
// Endpoint: https://mesu.apple.com/assets/macho/com_apple_MobileAsset_MacSoftwareUpdate/com_apple_MobileAsset_MacSoftwareUpdate.xml
//
// Cache: ~/.lumina/cache/ipsw-catalog.json (plain JSON, not the upstream
// plist). Refreshed at most every 24 hours. Stale-but-present beats no
// data on offline runs.

import Foundation

public struct IPSWCatalogEntry: Sendable, Codable, Equatable {
    public var url: URL
    public var version: String       // "14.5"
    public var build: String         // "23F79"
    public var postingDate: Date
    public var size: UInt64?
    public var sha256: String?       // upstream rarely publishes; nil is OK

    public init(url: URL, version: String, build: String, postingDate: Date, size: UInt64? = nil, sha256: String? = nil) {
        self.url = url
        self.version = version
        self.build = build
        self.postingDate = postingDate
        self.size = size
        self.sha256 = sha256
    }
}

public protocol IPSWCatalogScraper: Sendable {
    func fetch() async throws -> [IPSWCatalogEntry]
}

/// Concrete scraper that reads the mesu.apple.com plist asset.
public struct MesuIPSWCatalogScraper: IPSWCatalogScraper {
    public static let endpointURL = URL(string: "https://mesu.apple.com/assets/macho/com_apple_MobileAsset_MacSoftwareUpdate/com_apple_MobileAsset_MacSoftwareUpdate.xml")!

    public init() {}

    public func fetch() async throws -> [IPSWCatalogEntry] {
        let (data, response) = try await URLSession.shared.data(from: Self.endpointURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw IPSWCatalogError.endpointUnreachable
        }
        return try Self.parse(plist: data)
    }

    /// Parse a `MobileAsset` plist payload into `IPSWCatalogEntry` rows.
    /// Public + static so tests can call it with a fixture without hitting
    /// the network.
    public static func parse(plist data: Data) throws -> [IPSWCatalogEntry] {
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dict = object as? [String: Any],
              let assets = dict["Assets"] as? [[String: Any]] else {
            throw IPSWCatalogError.parseFailed
        }

        var out: [IPSWCatalogEntry] = []
        for asset in assets {
            guard
                let baseURLString = asset["__BaseURL"] as? String,
                let pathString = asset["__RelativePath"] as? String,
                let version = (asset["OSVersion"] as? String) ?? (asset["OSVersionMarketing"] as? String),
                let build = asset["Build"] as? String,
                let baseURL = URL(string: baseURLString),
                let url = URL(string: pathString, relativeTo: baseURL)?.absoluteURL
            else { continue }

            let postingDate: Date
            if let raw = asset["PostingDate"] as? String, let d = Self.parseDate(raw) {
                postingDate = d
            } else {
                postingDate = Date()
            }
            let size = (asset["_DownloadSize"] as? Int).map(UInt64.init)

            out.append(IPSWCatalogEntry(
                url: url,
                version: version,
                build: build,
                postingDate: postingDate,
                size: size,
                sha256: nil
            ))
        }
        return out
    }

    private static func parseDate(_ raw: String) -> Date? {
        // Apple uses "yyyy-MM-dd" in posting dates.
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: raw)
    }
}

public enum IPSWCatalogError: Swift.Error, Equatable {
    case endpointUnreachable
    case parseFailed
    case cacheCorrupt
}

/// Disk-backed cache wrapping any `IPSWCatalogScraper`.
public actor IPSWCatalogCache {
    public let scraper: any IPSWCatalogScraper
    public let cacheURL: URL
    public let refreshInterval: TimeInterval

    private struct Envelope: Codable {
        let entries: [IPSWCatalogEntry]
        let fetchedAt: Date
    }

    public init(
        scraper: any IPSWCatalogScraper = MesuIPSWCatalogScraper(),
        cacheURL: URL = IPSWCatalogCache.defaultCacheURL,
        refreshInterval: TimeInterval = 24 * 3600
    ) {
        self.scraper = scraper
        self.cacheURL = cacheURL
        self.refreshInterval = refreshInterval
    }

    public static var defaultCacheURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".lumina/cache/ipsw-catalog.json")
    }

    public func entries(forceRefresh: Bool = false) async -> [IPSWCatalogEntry] {
        // Try cache first if not forcing refresh.
        if !forceRefresh, let cached = readCache(), !isStale(cached) {
            return cached.entries
        }
        // Try scraper. On failure, fall back to whatever cache exists
        // (even stale) so offline users aren't blocked.
        do {
            let fresh = try await scraper.fetch()
            try? writeCache(Envelope(entries: fresh, fetchedAt: Date()))
            return fresh
        } catch {
            return readCache()?.entries ?? []
        }
    }

    private func isStale(_ env: Envelope) -> Bool {
        Date().timeIntervalSince(env.fetchedAt) > refreshInterval
    }

    private func readCache() -> Envelope? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Envelope.self, from: data)
    }

    private func writeCache(_ env: Envelope) throws {
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(env)
        try data.write(to: cacheURL, options: .atomic)
    }
}
