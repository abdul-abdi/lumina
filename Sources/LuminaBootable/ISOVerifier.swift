// Sources/LuminaBootable/ISOVerifier.swift
//
// Shared SHA-256 verifier for user-picked ISO files. Consumed by both
// Desktop (`NewVMWizard.createAndDismiss`) and CLI (`lumina desktop
// create`). Guards against corrupted downloads, wrong-mirror fetches,
// and captive-portal interception by refusing to stage an ISO whose
// digest doesn't match what `DesktopOSCatalog` promised.
//
// Two entry points for the two call-site ergonomics:
//   - `verify(at:expectedSHA256:)` — async; the wizard's on-main-actor
//      staging closure wants an awaitable primitive that detaches to
//      userInitiated while hashing.
//   - `sha256Hex(ofFileAt:)` — sync throwing; the CLI runs inside an
//      `AsyncParsableCommand.run()` and prefers plain throws to the
//      `ISOVerdict` envelope.
//
// Both share the same 4 MB streaming chunk to keep the hash window
// predictable; a 2 GB Ubuntu ISO hashes in ~512 chunks.

import Foundation
import CryptoKit

public enum ISOVerdict: Sendable, Equatable {
    /// File matched the expected digest.
    case match
    /// File hashed cleanly but didn't match. Attached string is the
    /// actual lowercase hex digest for diagnostics.
    case mismatch(String)
    /// Read failed mid-hash (permissions, disappeared file, I/O).
    /// Attached string is `error.localizedDescription`.
    case ioError(String)
}

public enum ISOVerifier {
    /// Streams the file through SHA-256 in 4 MB chunks off the main
    /// actor. Case-insensitive hex comparison against the expected
    /// digest. Safe to call from MainActor closures — the hashing
    /// itself runs on a detached userInitiated Task.
    public static func verify(
        at url: URL,
        expectedSHA256: String
    ) async -> ISOVerdict {
        await Task.detached(priority: .userInitiated) {
            do {
                let hex = try sha256Hex(ofFileAt: url)
                return hex == expectedSHA256.lowercased() ? .match : .mismatch(hex)
            } catch {
                return .ioError(error.localizedDescription)
            }
        }.value
    }

    /// Stream-hash a file with SHA-256 in 4 MB chunks. Returns a
    /// lowercase hex digest string. Throws any FileHandle error
    /// encountered during reading.
    public static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// If the given ISO's filename matches the tail component of any
    /// `DesktopOSCatalog` entry's URL, return that entry — the "you
    /// picked a known catalog ISO" signal. No network I/O; pure
    /// filename comparison. Returns nil for BYO ISOs (no catalog
    /// digest to check against).
    public static func catalogEntry(matching isoURL: URL) -> DesktopOSEntry? {
        let name = isoURL.lastPathComponent.lowercased()
        return DesktopOSCatalog.all.first {
            $0.isoURL.lastPathComponent.lowercased() == name
        }
    }
}
