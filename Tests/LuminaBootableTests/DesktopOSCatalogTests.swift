// Tests/LuminaBootableTests/DesktopOSCatalogTests.swift
import Foundation
import Testing
@testable import LuminaBootable

@Suite struct DesktopOSCatalogTests {
    @Test func ubuntuEntryPresent() throws {
        let entry = try #require(DesktopOSCatalog.entry(for: "ubuntu-24.04"))
        #expect(entry.displayName.contains("Ubuntu"))
        #expect(entry.family == .linux)
        #expect(entry.isoURL.scheme == "https")
        #expect(entry.isoURL.absoluteString.hasSuffix(".iso"))
        #expect(entry.sha256.count == 64, "SHA-256 hex digest is 64 chars")
    }

    @Test func kaliEntryPresent() throws {
        let entry = try #require(DesktopOSCatalog.entry(for: "kali-rolling"))
        #expect(entry.family == .linux)
        #expect(entry.isoURL.scheme == "https")
    }

    @Test func fedoraEntryPresent() throws {
        let entry = try #require(DesktopOSCatalog.entry(for: "fedora-42"))
        #expect(entry.family == .linux)
        #expect(entry.isoURL.scheme == "https")
    }

    @Test func debianEntryPresent() throws {
        let entry = try #require(DesktopOSCatalog.entry(for: "debian-12"))
        #expect(entry.family == .linux)
        #expect(entry.isoURL.scheme == "https")
    }

    @Test func allEntriesHaveSensibleDefaults() {
        for e in DesktopOSCatalog.all {
            #expect(e.recommendedMemoryBytes >= 2 * 1024 * 1024 * 1024, "\(e.id): bump to 2 GB+")
            #expect(e.recommendedCPUs >= 2, "\(e.id): bump to 2 CPU+")
            #expect(e.recommendedDiskBytes >= 16 * 1024 * 1024 * 1024, "\(e.id): bump to 16 GB+")
            #expect(e.sha256.count == 64, "\(e.id): SHA-256 hex digest is 64 chars")
            #expect(e.isoSizeBytes > 0, "\(e.id): iso size must be positive")
        }
    }

    /// Ship-gate: refuse any build that still carries the placeholder
    /// SHA-256. The catalog header promises this check; without it, a
    /// placeholder could ship and the wizard's ISO verification would
    /// silently accept any file.
    @Test func allEntriesHaveRealChecksums() {
        for e in DesktopOSCatalog.all {
            #expect(
                e.sha256 != DesktopOSCatalog.placeholderSHA256,
                "\(e.id): sha256 is still the placeholder sentinel"
            )
        }
    }

    @Test func catalogContainsCoreFourDistros() {
        let ids = Set(DesktopOSCatalog.all.map { $0.id })
        #expect(ids.contains("ubuntu-24.04"))
        #expect(ids.contains("kali-rolling"))
        #expect(ids.contains("fedora-42"))
        #expect(ids.contains("debian-12"))
    }

    @Test func unknownIDReturnsNil() {
        #expect(DesktopOSCatalog.entry(for: "not-a-real-os") == nil)
    }
}
