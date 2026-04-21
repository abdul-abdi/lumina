// Tests/LuminaTests/ClipboardProtocolTests.swift
import Foundation
import Testing
@testable import Lumina

@Suite struct ClipboardProtocolTests {
    @Test func roundTrip_setGuestClipboard() throws {
        let original = ClipboardMessage.setGuestClipboard(data: "hello", mime: "text/plain")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ClipboardMessage.self, from: data)
        #expect(decoded == original)
    }

    @Test func roundTrip_guestClipboardIs() throws {
        let original = ClipboardMessage.guestClipboardIs(data: "world", mime: "text/plain")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ClipboardMessage.self, from: data)
        #expect(decoded == original)
    }

    @Test func roundTrip_fileDropFlow() throws {
        let messages: [ClipboardMessage] = [
            .fileDropStart(name: "report.pdf", size: 12345),
            .fileDropChunk(data: "abc123base64=="),
            .fileDropEnd,
            .fileDropDone(path: "/home/lumina/Downloads/report.pdf")
        ]
        for m in messages {
            let data = try JSONEncoder().encode(m)
            let decoded = try JSONDecoder().decode(ClipboardMessage.self, from: data)
            #expect(decoded == m)
        }
    }

    @Test func roundTrip_heartbeatAndError() throws {
        for m: ClipboardMessage in [.heartbeat, .error("temporary glitch")] {
            let data = try JSONEncoder().encode(m)
            let decoded = try JSONDecoder().decode(ClipboardMessage.self, from: data)
            #expect(decoded == m)
        }
    }

    @Test func unknownTypeFailsToDecode() {
        let json = #"{"type":"not_a_real_type"}"#
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(ClipboardMessage.self, from: Data(json.utf8))
        }
    }

    @Test func clipboardPortIs1025() {
        #expect(clipboardVsockPort == 1025)
    }
}
