import Foundation
import Lumina

public enum InstallerSource {
    static let cacheRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lumina/cache")
    static let omarchyManifest = URL(string: "https://nightly.omarchy.org/edge-aarch64/latest.json")!

    public static func displayName(for variant: String) -> String? {
        variant == "omarchy" ? "Omarchy" : DesktopOSCatalog.entry(for: variant)?.displayName
    }

    public static func fetch(variant: String, progress: @escaping @Sendable (Double) -> Void) async throws -> URL? {
        if variant == "omarchy" {
            let cached = (try? FileManager.default.contentsOfDirectory(
                at: cacheRoot.appendingPathComponent("omarchy"), includingPropertiesForKeys: nil
            )) ?? []
            if let newest = cached.filter({ $0.pathExtension == "iso" }).max(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                return newest
            }
            struct Latest: Decodable { let url: URL; let sha256: String }
            let (data, _) = try await URLSession.shared.data(from: omarchyManifest)
            let latest = try JSONDecoder().decode(Latest.self, from: data)
            return try await verifiedDownload(latest.url, sha256: latest.sha256, into: "omarchy", progress: progress)
        }
        guard let entry = DesktopOSCatalog.entry(for: variant) else { return nil }
        return try await verifiedDownload(entry.isoURL, sha256: entry.sha256, into: "isos", progress: progress)
    }

    static func verifiedDownload(
        _ remote: URL, sha256: String, into folder: String, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let destination = cacheRoot.appendingPathComponent(folder).appendingPathComponent(remote.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let staged = destination.appendingPathExtension("download")
        try await MacOSRestore.download(remote, to: staged, progress: progress)
        guard try ISOVerifier.sha256Hex(ofFileAt: staged).lowercased() == sha256.lowercased() else {
            try? FileManager.default.removeItem(at: staged)
            throw MacOSRestore.Error(description: "\(remote.lastPathComponent) failed its SHA-256 check; the download was discarded")
        }
        try FileManager.default.moveItem(at: staged, to: destination)
        return destination
    }
}

extension VMBundle {
    public func fetchInstaller(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL? {
        if let pendingISO { return pendingISO }
        guard manifest.lastBootedAt == nil,
              let iso = try await InstallerSource.fetch(variant: manifest.osVariant, progress: progress)
        else { return nil }
        try Data(iso.path.utf8).write(to: rootURL.appendingPathComponent("pending-iso.path"), options: .atomic)
        return iso
    }
}
