// Tests/LuminaDesktopKitTests/ISOVerifierTests.swift
//
// Unit tests for ISOVerifier — proves the wizard's SHA-256 check matches
// known-good inputs and rejects everything else. Without these, the
// catalog's hardcoded digests would be decoration.

import Foundation
import CryptoKit
import Testing
@testable import LuminaDesktopKit

@Suite struct ISOVerifierTests {
    /// SHA-256 of an empty byte sequence.
    private let emptyDigest =
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    /// SHA-256("abc") — a heavily-documented test vector.
    private let abcDigest =
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    @Test func matchesEmptyFile() async throws {
        let url = try writeTempFile(data: Data())
        defer { try? FileManager.default.removeItem(at: url) }
        let verdict = await ISOVerifier.verify(at: url, expectedSHA256: emptyDigest)
        #expect(isMatch(verdict), "empty-file digest should match; got \(verdict)")
    }

    @Test func matchesKnownAbcVector() async throws {
        let url = try writeTempFile(data: Data("abc".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let verdict = await ISOVerifier.verify(at: url, expectedSHA256: abcDigest)
        #expect(isMatch(verdict), "SHA-256('abc') should match known vector; got \(verdict)")
    }

    @Test func caseInsensitiveOnExpectedHex() async throws {
        let url = try writeTempFile(data: Data("abc".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let verdict = await ISOVerifier.verify(at: url, expectedSHA256: abcDigest.uppercased())
        #expect(isMatch(verdict), "UPPERCASE expected digest should still match; got \(verdict)")
    }

    @Test func mismatchReportsActualDigest() async throws {
        let url = try writeTempFile(data: Data("abc".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let wrong = String(repeating: "f", count: 64)
        let verdict = await ISOVerifier.verify(at: url, expectedSHA256: wrong)
        guard case .mismatch(let actual) = verdict else {
            Issue.record("expected .mismatch, got \(verdict)")
            return
        }
        #expect(actual == abcDigest, "reported digest must be the real one, not the expected one")
    }

    @Test func ioErrorWhenFileMissing() async {
        let missing = URL(fileURLWithPath: "/tmp/definitely-not-a-real-file-\(UUID().uuidString)")
        let verdict = await ISOVerifier.verify(at: missing, expectedSHA256: emptyDigest)
        if case .ioError = verdict {
            // expected
        } else {
            Issue.record("expected .ioError for missing file, got \(verdict)")
        }
    }

    @Test func largeMultiChunkInputStreamsCorrectly() async throws {
        // 12 MB spans three 4 MB chunks — proves the streaming loop
        // finalizes correctly across chunk boundaries.
        let sizeBytes = 12 * 1024 * 1024
        let data = Data(count: sizeBytes)
        let url = try writeTempFile(data: data)
        defer { try? FileManager.default.removeItem(at: url) }

        let oneShot = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        let verdict = await ISOVerifier.verify(at: url, expectedSHA256: oneShot)
        #expect(isMatch(verdict), "12 MB streamed digest must match one-shot hash; got \(verdict)")
    }

    // MARK: - helpers

    private func writeTempFile(data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("iso-verifier-test-\(UUID().uuidString)")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func isMatch(_ v: ISOVerdict) -> Bool {
        if case .match = v { return true } else { return false }
    }
}
