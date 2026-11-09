// Shared SHA-256 verifier for user-picked ISO files. Consumed by both
// Desktop (`NewVMWizard.createAndDismiss`) and CLI (`lumina desktop
// create`). Guards against corrupted downloads, wrong-mirror fetches,
// and captive-portal interception by refusing to stage an ISO whose
// digest doesn't match what `DesktopOSCatalog` promised.

import Foundation
import CryptoKit

public enum ISOVerdict: Sendable, Equatable {
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
