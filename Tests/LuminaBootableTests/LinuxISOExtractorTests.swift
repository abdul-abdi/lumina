// Tests/LuminaBootableTests/LinuxISOExtractorTests.swift
//
// Covers the pure logic of the LinuxISOExtractor: path matching
// against known distro layouts + zboot header detection. Full ISO
// extraction is exercised in the e2e path (lumina desktop boot
// --capture-serial on a real Alpine ISO); this file keeps the
// deterministic parts locked down.

import Foundation
import Testing
@testable import LuminaBootable

@Suite struct LinuxISOExtractorTests {
    @Test func matchesPath_exact() {
        #expect(LinuxISOExtractor.matchesPath("casper/vmlinuz", "casper/vmlinuz"))
        #expect(LinuxISOExtractor.matchesPath("boot/vmlinuz-lts", "boot/vmlinuz-lts"))
    }

    @Test func matchesPath_leadingDotSlash() {
        // bsdtar sometimes lists ISO members with "./" prefix.
        #expect(LinuxISOExtractor.matchesPath("./casper/vmlinuz", "casper/vmlinuz"))
        #expect(LinuxISOExtractor.matchesPath("./boot/initramfs-lts", "boot/initramfs-lts"))
    }

    @Test func matchesPath_caseInsensitive() {
        // Joliet extension can surface upper-case entries.
        #expect(LinuxISOExtractor.matchesPath("CASPER/VMLINUZ", "casper/vmlinuz"))
        #expect(LinuxISOExtractor.matchesPath("./BOOT/VMLINUZ-LTS", "boot/vmlinuz-lts"))
    }

    @Test func matchesPath_rejectsDirectoryEntries() {
        // Tar member paths ending in "/" are directory entries — never
        // the file we want.
        #expect(!LinuxISOExtractor.matchesPath("casper/", "casper/vmlinuz"))
        #expect(!LinuxISOExtractor.matchesPath("boot/", "boot/vmlinuz-lts"))
    }

    @Test func matchesPath_rejectsUnrelated() {
        #expect(!LinuxISOExtractor.matchesPath("casper/filesystem.squashfs", "casper/vmlinuz"))
        #expect(!LinuxISOExtractor.matchesPath("EFI/boot/BOOTAA64.EFI", "boot/vmlinuz-lts"))
    }

    @Test func knownLayoutsCoverExpectedDistros() {
        // Lock down the distro coverage contract — if someone drops a
        // row, this test tells them to update the expectation with
        // intent.
        let names = LinuxISOExtractor.knownLayouts.map { $0.name }
        #expect(names.contains("Ubuntu live/server"))
        #expect(names.contains("Debian arm64 netinst"))
        #expect(names.contains("Alpine standard (LTS)"))
        #expect(names.contains("Fedora Live / netinst"))
    }

    @Test func unwrapEFIZBoot_passesThroughNonZbootKernels() throws {
        // Any file whose bytes at offset 4 aren't "zimg" is returned
        // unchanged. We fake a raw arm64 Image by writing the right
        // magic at 0x38 and random bytes elsewhere.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let raw = dir.appendingPathComponent("vmlinuz-raw")
        // 64 bytes — enough to cover the magic-at-0x38 slot. Content
        // doesn't actually matter for the zboot check, just that the
        // bytes at offset 4-8 are NOT "zimg".
        var bytes = [UInt8](repeating: 0, count: 64)
        bytes[0] = 0x4d; bytes[1] = 0x5a // "MZ" (DOS/PE)
        // offset 4..8 is all-zeros — clearly not "zimg"
        try Data(bytes).write(to: raw)

        let result = try LinuxISOExtractor.unwrapEFIZBootIfNeeded(
            kernel: raw, destination: dir
        )
        // Pass-through — same URL.
        #expect(result == raw)
    }

    @Test func unwrapEFIZBoot_detectsZbootSignatureAndBails() throws {
        // Zboot detection path: offset 4..8 is "zimg". With zero
        // payload offset/size (corrupt), the function must throw
        // extractFailed rather than crash.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fake = dir.appendingPathComponent("vmlinuz-fake-zboot")
        var bytes = [UInt8](repeating: 0, count: 32)
        bytes[0] = 0x4d; bytes[1] = 0x5a          // "MZ"
        bytes[4] = 0x7a; bytes[5] = 0x69          // "zi"
        bytes[6] = 0x6d; bytes[7] = 0x67          // "mg"
        // payload offset/size remain 0 — invalid, should throw.
        try Data(bytes).write(to: fake)

        do {
            _ = try LinuxISOExtractor.unwrapEFIZBootIfNeeded(
                kernel: fake, destination: dir
            )
            Issue.record("expected extractFailed for zero payload")
        } catch LinuxISOExtractor.Error.extractFailed {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
