// Tests/LuminaBootableTests/IPSWCatalogTests.swift
import Foundation
import Testing
@testable import LuminaBootable

@Suite struct IPSWCatalogTests {
    let tmp: URL

    init() {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LuminaIPSWCatalogTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    @Test func parsePlist_acceptsMinimalAssetList() throws {
        let plistXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Assets</key>
            <array>
                <dict>
                    <key>__BaseURL</key><string>https://updates-http.cdn-apple.com/2024/macos/</string>
                    <key>__RelativePath</key><string>UniversalMac_14.5_23F79_Restore.ipsw</string>
                    <key>OSVersion</key><string>14.5</string>
                    <key>Build</key><string>23F79</string>
                    <key>PostingDate</key><string>2024-05-13</string>
                    <key>_DownloadSize</key><integer>15728640000</integer>
                </dict>
                <dict>
                    <key>__BaseURL</key><string>https://updates-http.cdn-apple.com/2024/macos/</string>
                    <key>__RelativePath</key><string>UniversalMac_14.4_23E214_Restore.ipsw</string>
                    <key>OSVersion</key><string>14.4</string>
                    <key>Build</key><string>23E214</string>
                    <key>PostingDate</key><string>2024-03-07</string>
                </dict>
            </array>
        </dict>
        </plist>
        """
        let entries = try MesuIPSWCatalogScraper.parse(plist: Data(plistXML.utf8))
        #expect(entries.count == 2)
        #expect(entries[0].version == "14.5")
        #expect(entries[0].build == "23F79")
        #expect(entries[0].url.absoluteString.hasSuffix("23F79_Restore.ipsw"))
        #expect(entries[0].size == 15_728_640_000)
        #expect(entries[1].build == "23E214")
    }

    @Test func parsePlist_skipsMalformedEntries() throws {
        let plistXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
            <key>Assets</key>
            <array>
                <dict><key>OSVersion</key><string>14.5</string></dict>
                <dict>
                    <key>__BaseURL</key><string>https://example.com/</string>
                    <key>__RelativePath</key><string>good.ipsw</string>
                    <key>OSVersion</key><string>14.6</string>
                    <key>Build</key><string>23G93</string>
                </dict>
            </array>
        </dict>
        </plist>
        """
        let entries = try MesuIPSWCatalogScraper.parse(plist: Data(plistXML.utf8))
        #expect(entries.count == 1)
        #expect(entries[0].version == "14.6")
    }

    @Test func parsePlist_throwsOnNonPlist() {
        #expect(throws: (any Error).self) {
            _ = try MesuIPSWCatalogScraper.parse(plist: Data("not a plist".utf8))
        }
    }

    @Test func cache_firstFetchHitsScraper() async throws {
        let cacheURL = tmp.appendingPathComponent("ipsw.json")
        let scraper = StubScraper(entries: [
            IPSWCatalogEntry(url: URL(string: "https://example.com/a.ipsw")!, version: "14.5", build: "23F79", postingDate: Date())
        ])
        let cache = IPSWCatalogCache(scraper: scraper, cacheURL: cacheURL, refreshInterval: 3600)
        let entries = await cache.entries()
        #expect(entries.count == 1)
        #expect(scraper.callCount == 1)
        // Cache file exists after first fetch.
        #expect(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    @Test func cache_secondFetchUsesCache() async throws {
        let cacheURL = tmp.appendingPathComponent("ipsw.json")
        let scraper = StubScraper(entries: [
            IPSWCatalogEntry(url: URL(string: "https://example.com/a.ipsw")!, version: "14.5", build: "23F79", postingDate: Date())
        ])
        let cache = IPSWCatalogCache(scraper: scraper, cacheURL: cacheURL, refreshInterval: 3600)
        _ = await cache.entries()
        _ = await cache.entries()
        #expect(scraper.callCount == 1, "cache should serve second call without scraper")
    }

    @Test func cache_forceRefreshHitsScraper() async throws {
        let cacheURL = tmp.appendingPathComponent("ipsw.json")
        let scraper = StubScraper(entries: [
            IPSWCatalogEntry(url: URL(string: "https://example.com/a.ipsw")!, version: "14.5", build: "23F79", postingDate: Date())
        ])
        let cache = IPSWCatalogCache(scraper: scraper, cacheURL: cacheURL, refreshInterval: 3600)
        _ = await cache.entries()
        _ = await cache.entries(forceRefresh: true)
        #expect(scraper.callCount == 2)
    }

    @Test func cache_scraperFailureFallsBackToCache() async throws {
        let cacheURL = tmp.appendingPathComponent("ipsw.json")
        // Pre-seed the cache with one entry.
        let seedEntry = IPSWCatalogEntry(
            url: URL(string: "https://seed.example.com/a.ipsw")!,
            version: "14.0",
            build: "23A344",
            postingDate: Date()
        )
        let envelopeJSON = """
        { "entries": [ { "url": "https://seed.example.com/a.ipsw", "version": "14.0", "build": "23A344", "postingDate": "\(ISO8601DateFormatter().string(from: Date()))" } ], "fetchedAt": "1970-01-01T00:00:00Z" }
        """
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(envelopeJSON.utf8).write(to: cacheURL)

        // Scraper that always fails — cache must still serve the seed.
        struct FailingScraper: IPSWCatalogScraper {
            func fetch() async throws -> [IPSWCatalogEntry] {
                throw IPSWCatalogError.endpointUnreachable
            }
        }
        let cache = IPSWCatalogCache(scraper: FailingScraper(), cacheURL: cacheURL, refreshInterval: 0)
        let entries = await cache.entries(forceRefresh: true)
        #expect(entries.count == 1)
        #expect(entries[0].build == seedEntry.build)
    }
}

/// Test scraper that returns a fixed list and counts calls.
final class StubScraper: IPSWCatalogScraper, @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0
    let entries: [IPSWCatalogEntry]

    var callCount: Int {
        lock.withLock { _callCount }
    }

    init(entries: [IPSWCatalogEntry]) {
        self.entries = entries
    }

    func fetch() async throws -> [IPSWCatalogEntry] {
        lock.withLock { _callCount += 1 }
        return entries
    }
}
