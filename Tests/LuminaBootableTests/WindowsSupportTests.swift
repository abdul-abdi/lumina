// Tests/LuminaBootableTests/WindowsSupportTests.swift
import Foundation
import Testing
@testable import LuminaBootable

@Suite struct WindowsSupportTests {
    @Test func defaultTableContainsBackslashRemap() {
        let q = WindowsInputQuirks()
        #expect(q.table[0x2A] == 0x2B)
    }

    @Test func defaultTableCoversAllFKeys() {
        let q = WindowsInputQuirks()
        for src in 0x67...0x72 {
            #expect(q.table[UInt8(src)] != nil, "F-key 0x\(String(src, radix: 16)) missing remap")
        }
    }

    @Test func remap_passesThroughUnknownCodes() {
        let q = WindowsInputQuirks()
        #expect(q.remap(0x04) == 0x04)  // 'A' — no remap
        #expect(q.remap(0xFF) == 0xFF)  // arbitrary
    }

    @Test func remap_substitutesKnownCodes() {
        let q = WindowsInputQuirks()
        #expect(q.remap(0x2A) == 0x2B)
        #expect(q.remap(0x67) == 0x3B)
    }

    @Test func customTableOverridesDefaults() {
        let q = WindowsInputQuirks(table: [0x05: 0x06])
        #expect(q.remap(0x05) == 0x06)
        #expect(q.remap(0x2A) == 0x2A)  // backslash NOT in custom table → unchanged
    }
}
