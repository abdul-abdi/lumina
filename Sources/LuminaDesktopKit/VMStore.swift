import Foundation
import LuminaBootable

public struct VMStore: Sendable {
    public let rootURL: URL

    public init(rootURL: URL = VMStore.defaultRoot) {
        self.rootURL = rootURL
    }

    public static var defaultRoot: URL { VMBundle.libraryRoot }

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
            // `.isDirectoryKey` returns false on symlinks pointing at real
            // bundle dirs (FileManager doesn't follow symlinks here). Resolve
            // first so a symlinked bundle under ~/.lumina/desktop-vms/ is
            // enumerated normally.
            let resolved = url.resolvingSymlinksInPath()
            let isDir = (try? resolved.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            guard let bundle = try? VMBundle.load(from: resolved) else { continue }
            bundles.append(bundle)
        }
        return bundles.sorted { $0.manifest.createdAt < $1.manifest.createdAt }
    }

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
