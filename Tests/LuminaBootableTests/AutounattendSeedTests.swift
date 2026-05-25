// Tests/LuminaBootableTests/AutounattendSeedTests.swift
//
// AutounattendSeed wraps `hdiutil makehybrid`, which refuses to
// overwrite an existing output file ("autounattend.iso already exists
// / Bad file descriptor"). This silently broke the GUI first-boot
// path: a bundle with a pre-existing autounattend.iso (e.g. left by
// an earlier CLI run) would re-fire AutounattendSeed.generate() on
// next boot, hdiutil would refuse, the orchestrator would emit
// `.autounattendFailed`, and the extra disk would never be attached
// — Win11 Setup then hit the compat check on a black framebuffer.

import Foundation
import Testing
@testable import LuminaBootable

@Suite struct AutounattendSeedTests {
    /// Make a temp bundle root and clean up after each test.
    private func makeBundleRoot() throws -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lumina-autounattend-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    @Test func generate_writesISOAtExpectedPath() throws {
        let root = try makeBundleRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let seed = AutounattendSeed(bundleRootURL: root)
        let iso = try seed.generate()

        #expect(iso.lastPathComponent == "autounattend.iso")
        #expect(FileManager.default.fileExists(atPath: iso.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: iso.path)
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        // hdiutil makehybrid produces ~1MB ISOs for a single small file.
        // Just sanity-check it's not empty and not absurdly huge.
        #expect(size > 8 * 1024)
        #expect(size < 4 * 1024 * 1024)
    }

    @Test func generate_overwritesExistingISO() throws {
        // hdiutil makehybrid refuses to overwrite by default — calling
        // generate() twice on the same bundle must succeed (the second
        // call replaces the first ISO with a fresh one).
        let root = try makeBundleRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let seed = AutounattendSeed(bundleRootURL: root)
        let first = try seed.generate()
        let firstSize = (try FileManager.default.attributesOfItem(atPath: first.path)[.size] as? NSNumber)?.uint64Value
        // Second call MUST NOT throw; it must replace the prior file.
        let second = try seed.generate()
        #expect(second == first, "path is deterministic so the URL should be identical")
        let secondSize = (try FileManager.default.attributesOfItem(atPath: second.path)[.size] as? NSNumber)?.uint64Value
        // Either size is fine — we mostly care that it's still a valid file.
        #expect(secondSize != nil)
        #expect(firstSize != nil)
    }
}
