// Tests/LuminaBootableTests/SeedISOTests.swift
import Foundation
import Testing
@testable import LuminaBootable

@Suite struct SeedISOTests {
    let tmp: URL

    init() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LuminaSeedISOTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    /// ISO9660 keeps the volume id at byte 40 of the descriptor in sector 16.
    private func volumeID(of iso: URL) throws -> String {
        let data = try Data(contentsOf: iso)
        let field = data[(16 * 2048 + 40)..<(16 * 2048 + 72)]
        return String(decoding: field, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
    }

    @Test func make_writesFilesUnderVolumeLabel() throws {
        let iso = tmp.appendingPathComponent("cidata.iso")
        try SeedISO.make(
            files: ["user_configuration.json": Data("{}".utf8)],
            volumeName: "cidata",
            at: iso
        )
        #expect(try volumeID(of: iso) == "CIDATA")
        // Joliet keeps the long, lower-case name the guest looks for.
        let bytes = try Data(contentsOf: iso)
        #expect(bytes.range(of: Data("user_configuration.json".utf16BigEndian)) != nil)
    }

    @Test func make_replacesExistingImage() throws {
        let iso = tmp.appendingPathComponent("seed.iso")
        try Data("stale".utf8).write(to: iso)
        try SeedISO.make(files: ["a": Data("1".utf8)], volumeName: "WIN", at: iso)
        #expect(try volumeID(of: iso) == "WIN")
    }

    @Test func make_packsDirectory() throws {
        let dir = tmp.appendingPathComponent("seed")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("instance-id: x\n".utf8).write(to: dir.appendingPathComponent("meta-data"))
        let iso = try SeedISO.make(directory: dir, volumeName: "cidata", at: tmp.appendingPathComponent("d.iso"))
        #expect(try volumeID(of: iso) == "CIDATA")
    }
}

private extension String {
    var utf16BigEndian: [UInt8] { utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] } }
}
