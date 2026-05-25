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

    // MARK: - suggestArm64Equivalent (for x86_64 ISO rejection messages)

    @Test func suggestArm64Equivalent_matchesUbuntuFromAmd64Filename() throws {
        let entry = try #require(DesktopOSCatalog.suggestArm64Equivalent(
            forFilename: "ubuntu-24.04.3-desktop-amd64.iso"
        ))
        #expect(entry.id == "ubuntu-24.04")
    }

    @Test func suggestArm64Equivalent_matchesFedoraFromX86_64Filename() throws {
        let entry = try #require(DesktopOSCatalog.suggestArm64Equivalent(
            forFilename: "Fedora-Workstation-Live-42-1.1.x86_64.iso"
        ))
        #expect(entry.id == "fedora-42")
    }

    @Test func suggestArm64Equivalent_matchesDebianFromAmd64Filename() throws {
        let entry = try #require(DesktopOSCatalog.suggestArm64Equivalent(
            forFilename: "debian-12.12.0-amd64-netinst.iso"
        ))
        #expect(entry.id == "debian-12")
    }

    @Test func suggestArm64Equivalent_returnsNilForUnknownDistro() {
        // Windows has no catalog entry; rejection message should not
        // hallucinate an ARM64 alternative.
        #expect(DesktopOSCatalog.suggestArm64Equivalent(
            forFilename: "Win11_24H2_English_x64.iso"
        ) == nil)
    }

    @Test func suggestArm64Equivalent_returnsNilForArbitraryName() {
        #expect(DesktopOSCatalog.suggestArm64Equivalent(
            forFilename: "some-random-distro.iso"
        ) == nil)
    }

    @Test func suggestArm64Equivalent_isCaseInsensitive() throws {
        let entry = try #require(DesktopOSCatalog.suggestArm64Equivalent(
            forFilename: "UBUNTU-24.04-SERVER-AMD64.ISO"
        ))
        #expect(entry.id == "ubuntu-24.04")
    }

    @Test func suggestArm64Equivalent_prefersLongestIdMatch() throws {
        // If the catalog grows to have both "ubuntu" and "ubuntu-24.04",
        // longer wins. Today we only ship "ubuntu-24.04" — the test
        // future-proofs the most-tokens-first contract.
        let entry = try #require(DesktopOSCatalog.suggestArm64Equivalent(
            forFilename: "ubuntu-24.04-server.iso"
        ))
        #expect(entry.id == "ubuntu-24.04")
    }

    @Test func suggestArm64Equivalent_returnsNilWhenKaliFilenameLacksRollingToken() {
        // Kali's catalog id is `kali-rolling`, but vendor filenames are
        // `kali-linux-2026.1-installer-amd64.iso` — the "rolling" token
        // never appears. Strict matching declines to suggest rather than
        // mis-suggest. Wrong suggestions are worse than none.
        #expect(DesktopOSCatalog.suggestArm64Equivalent(
            forFilename: "kali-linux-2026.1-installer-amd64.iso"
        ) == nil)
    }
}
