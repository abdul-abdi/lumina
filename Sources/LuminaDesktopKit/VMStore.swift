// Sources/LuminaDesktopKit/VMStore.swift
//
// v0.7.0 M6 — enumerates `.luminaVM` bundles for the Desktop app.
// Watches `~/.lumina/desktop-vms/` for additions/removals.

import Foundation
import LuminaBootable

public struct VMStore: Sendable {
    public let rootURL: URL

    public init(rootURL: URL = VMStore.defaultRoot) {
        self.rootURL = rootURL
    }

    public static var defaultRoot: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".lumina/desktop-vms")
    }

    /// Read all `.luminaVM` bundles under `rootURL`. Bundles whose
    /// manifest fails to parse are silently dropped (they show up as
    /// errors in the app's diagnostics, not in the library).
    public func loadBundles() -> [VMBundle] {
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return [] }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        var bundles: [VMBundle] = []
        for url in entries {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            guard let bundle = try? VMBundle.load(from: url) else { continue }
            bundles.append(bundle)
        }
        return bundles.sorted { $0.manifest.createdAt < $1.manifest.createdAt }
    }

    /// Soft-delete a bundle to the user's Trash. Returns true on success.
    public func moveToTrash(_ bundle: VMBundle) -> Bool {
        var resultingURL: NSURL?
        do {
            try FileManager.default.trashItem(
                at: bundle.rootURL,
                resultingItemURL: &resultingURL
            )
            return true
        } catch {
            return false
        }
    }
}
