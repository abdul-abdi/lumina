// Tests/LuminaBootableTests/ISOInspectorTests.swift
import Foundation
import Testing
@testable import LuminaBootable

@Suite struct ISOInspectorTests {
    let tmp: URL

    init() {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LuminaISOInspectorTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    private func makeISO(_ name: String, containing marker: String) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        // Pad the front with zeros so the marker doesn't end up in the
        // ISO9660 header range (offsets 0-32768) — that's where path-table
        // strings actually live in real ISOs.
        var data = Data(count: 64 * 1024)
        let suffix = Data(marker.utf8)
        data.append(suffix)
        try data.write(to: url)
        return url
    }

    @Test func detect_arm64ViaBootaa64() throws {
        let iso = try makeISO("arm.iso", containing: "BOOTAA64.EFI")
        #expect(try ISOInspector.detectArchitecture(at: iso) == .arm64)
    }

    @Test func detect_x86_64ViaBootx64() throws {
        let iso = try makeISO("x86.iso", containing: "BOOTX64.EFI")
        #expect(try ISOInspector.detectArchitecture(at: iso) == .x86_64)
    }

    @Test func detect_caseInsensitive() throws {
        let iso = try makeISO("arm-lower.iso", containing: "bootaa64.efi")
        #expect(try ISOInspector.detectArchitecture(at: iso) == .arm64)
    }

    @Test func detect_unknownWhenAbsent() throws {
        let iso = try makeISO("blank.iso", containing: "no boot loader markers here")
        #expect(try ISOInspector.detectArchitecture(at: iso) == .unknown)
    }

    @Test func detect_throwsOnMissingFile() {
        let url = tmp.appendingPathComponent("does-not-exist.iso")
        #expect(throws: ISOInspector.Error.self) {
            _ = try ISOInspector.detectArchitecture(at: url)
        }
    }

    @Test func detect_riscv64Surfaced() throws {
        let iso = try makeISO("rv.iso", containing: "BOOTRISCV64.EFI")
        #expect(try ISOInspector.detectArchitecture(at: iso) == .riscv64)
    }
}
