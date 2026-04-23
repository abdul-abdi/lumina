// Tests/LuminaDesktopKitTests/AppModelTests.swift
import Foundation
import Testing
@testable import LuminaDesktopKit
@testable import LuminaBootable

@MainActor
@Suite struct AppModelTests {
    let tmp: URL

    init() {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LuminaAppModelTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    @Test func emptyStoreYieldsEmptyBundles() {
        let model = AppModel(store: VMStore(rootURL: tmp))
        #expect(model.bundles.isEmpty)
        #expect(model.filteredBundles.isEmpty)
    }

    @Test func searchFiltersByName() throws {
        _ = try VMBundle.create(
            at: tmp.appendingPathComponent(UUID().uuidString),
            name: "Ubuntu Box",
            osFamily: .linux,
            osVariant: "ubuntu-24.04",
            memoryBytes: 1024 * 1024 * 1024,
            cpuCount: 1,
            diskBytes: 1024 * 1024 * 1024
        )
        _ = try VMBundle.create(
            at: tmp.appendingPathComponent(UUID().uuidString),
            name: "Kali Box",
            osFamily: .linux,
            osVariant: "kali-rolling",
            memoryBytes: 1024 * 1024 * 1024,
            cpuCount: 1,
            diskBytes: 1024 * 1024 * 1024
        )
        let model = AppModel(store: VMStore(rootURL: tmp))
        #expect(model.bundles.count == 2)
        model.search = "kali"
        #expect(model.filteredBundles.count == 1)
        #expect(model.filteredBundles[0].manifest.name == "Kali Box")
    }

    @Test func runningCountIsZeroWithNoSessions() throws {
        let bundle = try VMBundle.create(
            at: tmp.appendingPathComponent(UUID().uuidString),
            name: "Empty",
            osFamily: .linux,
            osVariant: "ubuntu-24.04",
            memoryBytes: 1024 * 1024 * 1024,
            cpuCount: 1,
            diskBytes: 1024 * 1024 * 1024
        )
        let model = AppModel(store: VMStore(rootURL: tmp))
        // Session exists but status is .stopped (default).
        _ = model.session(for: bundle)
        #expect(model.runningCount == 0)
    }

    @Test func liveStatsAreCachedByBundleID() throws {
        let bundle = try VMBundle.create(
            at: tmp.appendingPathComponent(UUID().uuidString),
            name: "Stats",
            osFamily: .linux,
            osVariant: "ubuntu-24.04",
            memoryBytes: 1024 * 1024 * 1024,
            cpuCount: 1,
            diskBytes: 1024 * 1024 * 1024
        )
        let model = AppModel(store: VMStore(rootURL: tmp))
        let a = model.liveStats(for: bundle)
        let b = model.liveStats(for: bundle)
        #expect(a === b)
        model.retireLiveStats(for: bundle.manifest.id)
        let c = model.liveStats(for: bundle)
        #expect(c !== a)
    }

    @Test func reaperEvictsIdleStoppedSessionsAfterThreshold() throws {
        let bundle = try VMBundle.create(
            at: tmp.appendingPathComponent(UUID().uuidString),
            name: "Reap",
            osFamily: .linux,
            osVariant: "ubuntu-24.04",
            memoryBytes: 1024 * 1024 * 1024,
            cpuCount: 1,
            diskBytes: 1024 * 1024 * 1024
        )
        let model = AppModel(store: VMStore(rootURL: tmp))
        // Session is created in .stopped state (default).
        _ = model.session(for: bundle)
        #expect(model.sessions.count == 1)

        // First reaper pass: marks the session as inactive, doesn't evict.
        let now = Date()
        model.reapIdleSessions(now: now)
        #expect(model.sessions.count == 1)

        // Jump forward past the idle threshold (300s default).
        let future = now.addingTimeInterval(400)
        model.reapIdleSessions(now: future)
        #expect(model.sessions.count == 0)
    }

    @Test func sessionIsCreatedOnceAndCached() throws {
        let bundle = try VMBundle.create(
            at: tmp.appendingPathComponent(UUID().uuidString),
            name: "Cache",
            osFamily: .linux,
            osVariant: "ubuntu-24.04",
            memoryBytes: 1024 * 1024 * 1024,
            cpuCount: 1,
            diskBytes: 1024 * 1024 * 1024
        )
        let model = AppModel(store: VMStore(rootURL: tmp))
        let s1 = model.session(for: bundle)
        let s2 = model.session(for: bundle)
        #expect(s1 === s2)
    }
}

@MainActor
@Suite struct OSCatalogTests {
    @Test func allTilesPresent() {
        let ids = Set(OSCatalog.allTiles.map { $0.id })
        #expect(ids.contains("ubuntu-24.04"))
        #expect(ids.contains("kali-rolling"))
        #expect(ids.contains("fedora-42"))
        #expect(ids.contains("debian-12"))
        #expect(ids.contains("windows-11-arm"))
        #expect(ids.contains("macos-latest"))
        #expect(ids.contains("byo-file"))
    }

    @Test func tileLookupReturnsCorrectFamily() {
        let win = OSCatalog.tile(id: "windows-11-arm")
        #expect(win?.family == .windows)
        let mac = OSCatalog.tile(id: "macos-latest")
        #expect(mac?.family == .macOS)
    }
}

@MainActor
@Suite struct ErrorCatalogTests {
    @Test func errorTitlesNonEmpty() {
        let cases: [AppError] = [
            .virtualizationEntitlementMissing,
            .appleSiliconRequired,
            .macOSHostTooOld(have: "13.0"),
            .diskFullAtCreate(needed: 1, available: 0),
            .isoNotARM64(path: "/x.iso"),
            .vmCrashed(name: "test")
        ]
        for c in cases {
            #expect(!c.title.isEmpty)
            #expect(!c.body.isEmpty)
            #expect(!c.primaryAction.isEmpty)
        }
    }
}
