// Sources/LuminaDesktopKit/ISOVerifier.swift
//
// Streaming SHA-256 verifier for user-picked ISO files. Called from
// NewVMWizard.createAndDismiss before staging a catalog-ISO pick — we
// refuse to create a VM if the file doesn't match the digest the catalog
// promised. Guards against corrupted downloads, wrong-mirror fetches, and
// captive-portal interception.

import Foundation
import CryptoKit

enum ISOVerdict: Sendable {
    case match
    case mismatch(String)       // actual hex digest
    case ioError(String)
}

enum ISOVerifier {
    /// Streams the file through SHA-256 in 4 MB chunks off the main actor.
    /// Case-insensitive hex comparison against `expectedSHA256`.
    static func verify(at url: URL, expectedSHA256: String) async -> ISOVerdict {
        await Task.detached(priority: .userInitiated) {
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                var hasher = SHA256()
                while true {
                    let chunk = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
                    if chunk.isEmpty { break }
                    hasher.update(data: chunk)
                }
                let hex = hasher.finalize()
                    .map { String(format: "%02x", $0) }
                    .joined()
                    .lowercased()
                return hex == expectedSHA256.lowercased() ? .match : .mismatch(hex)
            } catch {
                return .ioError(error.localizedDescription)
            }
        }.value
    }
}
