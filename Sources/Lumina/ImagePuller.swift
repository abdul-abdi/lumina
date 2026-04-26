// Sources/Lumina/ImagePuller.swift
import Foundation
import CryptoKit

/// Downloads pre-built VM images from GitHub Releases.
///
/// Tag selection order at pull time (first non-nil wins):
///   1. explicit `tag:` passed to init()
///   2. `LUMINA_IMAGE_TAG` environment variable
///   3. latest GitHub release whose assets include `assetName`
///   4. `fallbackTag` (hard-coded, bumped per host release)
///
/// This auto-resolution means a host built from recent `main` pulls
/// the most recent image automatically — no more host-v0.7.x running
/// against a v0.5.0 guest agent. Resolution is bounded to a 3-second
/// API call; if GitHub is unreachable we fall back to the pinned tag
/// so offline / air-gapped builds still work.
public struct ImagePuller: Sendable {
    public static let defaultRepo = "abdul-abdi/lumina"
    /// Last-resort tag when env override is absent and the GitHub
    /// API can't be reached (offline, rate-limited, 5xx). Bump in
    /// lockstep with the host release so the fallback never points
    /// at a more-than-one-minor-version-older image.
    public static let fallbackTag = "lumina-v0.7.0"
    public static let defaultAssetName = "lumina-image-default.tar.gz"

    /// Back-compat alias — older code reads `ImagePuller.defaultTag`.
    /// Reports the fallback, not the resolved tag.
    public static var defaultTag: String { fallbackTag }

    private let repo: String
    /// nil means "resolve at pull time" (env → API latest → fallback).
    /// Non-nil means the caller pinned a specific tag explicitly.
    private let tag: String?
    private let assetName: String
    private let imageStore: ImageStore
    /// When set, download this URL directly instead of constructing
    /// one from repo/tag/assetName. Used by `lumina images pull <id>`
    /// against the catalog.
    private let directURL: URL?
    /// When set, verify the downloaded tarball matches this digest
    /// before extraction. Refuses to install a mismatched tarball
    /// even if --force is set.
    private let expectedSHA256: String?
    /// When set, install into ~/.lumina/images/<imageName>/ instead
    /// of the default `default/`.
    private let imageName: String?

    public init(
        repo: String = ImagePuller.defaultRepo,
        tag: String? = nil,
        assetName: String = ImagePuller.defaultAssetName,
        imageStore: ImageStore = ImageStore(),
        directURL: URL? = nil,
        expectedSHA256: String? = nil,
        imageName: String? = nil
    ) {
        self.repo = repo
        self.tag = tag
        self.assetName = assetName
        self.imageStore = imageStore
        self.directURL = directURL
        self.expectedSHA256 = expectedSHA256
        self.imageName = imageName
    }

    /// Check if the default image is already available.
    public func imageExists(name: String = "default") -> Bool {
        (try? imageStore.resolve(name: name)) != nil
    }

    /// Pull the default image from GitHub Releases.
    /// Downloads the tarball, verifies integrity, extracts vmlinuz + initrd + rootfs.img.
    public func pull(
        name requestedName: String = "default",
        progress: @Sendable (_ message: String) -> Void = { _ in }
    ) async throws(LuminaError) {
        // Resolve destination name and download URL. Catalog pulls
        // override both via init; defaults preserve v0.5.0 behaviour.
        let name = imageName ?? requestedName
        let releaseURL: String
        let resolvedTag: String
        if let directURL {
            releaseURL = directURL.absoluteString
            resolvedTag = tag ?? Self.fallbackTag  // display-only for errors
            progress("Downloading \(directURL.lastPathComponent) → image '\(name)'...")
        } else {
            resolvedTag = await resolveTag(progress: progress)
            releaseURL = "https://github.com/\(repo)/releases/download/\(resolvedTag)/\(assetName)"
            progress("Downloading \(assetName) from \(repo) (\(resolvedTag))...")
        }

        // 1. Download the tarball
        let downloadedFile: URL
        do {
            downloadedFile = try await download(from: releaseURL)
        } catch let error as PullError {
            throw .imageNotFound(error.message)
        } catch {
            throw .imageNotFound("Network error: \(error.localizedDescription)")
        }

        // 2. Verify download is not empty / corrupted
        let fileSize: Int
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: downloadedFile.path)
            fileSize = (attrs[.size] as? Int) ?? 0
        } catch {
            throw .imageNotFound("Cannot read downloaded file: \(error.localizedDescription)")
        }

        guard fileSize > 1024 else {
            throw .imageNotFound(
                "Downloaded file is too small (\(fileSize) bytes) — likely corrupted or empty."
            )
        }

        // 3. Compute SHA256 and verify against expected when set
        //    (catalog pulls). Mismatch = refuse to install even if
        //    the caller passed --force.
        let sha256 = hashFile(at: downloadedFile)
        progress("Downloaded \(formatBytes(fileSize)) (SHA256: \(sha256.prefix(12))...)")
        if let expected = expectedSHA256 {
            if sha256.lowercased() != expected.lowercased() {
                throw .imageNotFound(
                    "SHA-256 mismatch for downloaded tarball. expected=\(expected), actual=\(sha256). Refusing to install."
                )
            }
            progress("SHA-256 verified against catalog entry.")
        }

        // 4. Prepare image directory (clean if partial previous attempt)
        let imageDir = imageStore.baseDir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: imageDir.path) {
            try? FileManager.default.removeItem(at: imageDir)
        }
        do {
            try FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)
        } catch {
            throw .imageNotFound("Cannot create image directory: \(error.localizedDescription)")
        }

        // 5. Pre-scan tarball for path-traversal attempts before extraction.
        //    BSD tar on macOS rejects `..` members by default, but relying on
        //    the default is defence-in-depth-zero. List the archive first
        //    and refuse any member whose normalised path escapes imageDir.
        //    Cheap: `tar -tzf` reads the member list without extracting;
        //    bounded by the number of members (a few for an image tarball).
        progress("Verifying tarball members...")
        let listResult = runProcess(
            "/usr/bin/tar", arguments: ["-tzf", downloadedFile.path]
        )
        guard listResult.exitCode == 0 else {
            try? FileManager.default.removeItem(at: imageDir)
            throw .imageNotFound(
                "Tarball listing failed (exit \(listResult.exitCode)): \(listResult.stderr)"
            )
        }
        for member in listResult.stdout.split(separator: "\n") {
            // Reject absolute paths and any member containing `..` segments.
            let path = String(member).trimmingCharacters(in: .whitespaces)
            if path.isEmpty { continue }
            if path.hasPrefix("/") {
                try? FileManager.default.removeItem(at: imageDir)
                throw .imageNotFound(
                    "Tarball contains absolute path: \(path). Refusing to extract."
                )
            }
            // Split on `/` and reject any `..` component after normalisation.
            let parts = path.split(separator: "/")
            if parts.contains(where: { $0 == ".." }) {
                try? FileManager.default.removeItem(at: imageDir)
                throw .imageNotFound(
                    "Tarball contains path-traversal member: \(path). Refusing to extract."
                )
            }
        }

        // 6. Extract tarball. Belt-and-suspenders flags:
        //    --no-same-owner    — drop uid/gid from archive; ignores root-
        //                         owned members shipped in the tarball.
        //    --no-xattrs        — strip extended attributes (no SELinux
        //                         labels, no immutable flags leaking in).
        //    --no-mac-metadata  — drop macOS-specific AppleDouble/resource-
        //                         fork metadata (irrelevant for a Linux
        //                         image anyway).
        //    Plus the path-traversal pre-scan above, this closes the
        //    trust-boundary surface called out in the v0.7.1 isolation
        //    probe findings.
        progress("Extracting to \(imageDir.path)...")
        let tarResult = runProcess(
            "/usr/bin/tar",
            arguments: [
                "xzf", downloadedFile.path,
                "-C", imageDir.path,
                "--no-same-owner",
                "--no-xattrs",
                "--no-mac-metadata",
            ]
        )

        guard tarResult.exitCode == 0 else {
            // Clean up partial extraction
            try? FileManager.default.removeItem(at: imageDir)
            throw .imageNotFound(
                "Extraction failed (exit \(tarResult.exitCode)): \(tarResult.stderr)"
            )
        }

        // 6. Verify required files exist (initrd is optional for baked images)
        let requiredFiles = ["vmlinuz", "rootfs.img"]
        var missingFiles: [String] = []
        for file in requiredFiles {
            let path = imageDir.appendingPathComponent(file)
            if !FileManager.default.fileExists(atPath: path.path) {
                missingFiles.append(file)
            }
        }

        if !missingFiles.isEmpty {
            try? FileManager.default.removeItem(at: imageDir)
            throw .imageNotFound(
                "Image tarball is missing required files: \(missingFiles.joined(separator: ", ")). "
                + "The release may be malformed."
            )
        }

        // 7. Verify rootfs.img is non-trivial (at least 1MB)
        let rootfsPath = imageDir.appendingPathComponent("rootfs.img")
        let rootfsSize = (try? FileManager.default.attributesOfItem(
            atPath: rootfsPath.path
        )[.size] as? Int) ?? 0

        if rootfsSize < 1_048_576 {
            try? FileManager.default.removeItem(at: imageDir)
            throw .imageNotFound(
                "rootfs.img is suspiciously small (\(formatBytes(rootfsSize))). "
                + "The image may be corrupted."
            )
        }

        progress("Image ready: \(formatBytes(rootfsSize)) rootfs")
    }

    // MARK: - Private

    private func download(from urlString: String) async throws -> URL {
        guard let url = URL(string: urlString) else {
            throw PullError(message: "Invalid URL: \(urlString)")
        }

        let (localURL, response): (URL, URLResponse)
        do {
            (localURL, response) = try await URLSession.shared.download(from: url)
        } catch let urlError as URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                throw PullError(message: "No internet connection.")
            case .timedOut:
                throw PullError(message: "Download timed out. Try again.")
            case .cannotFindHost, .dnsLookupFailed:
                throw PullError(message: "Cannot reach github.com. Check your connection.")
            default:
                throw PullError(message: "Network error: \(urlError.localizedDescription)")
            }
        }

        guard let http = response as? HTTPURLResponse else {
            throw PullError(message: "Unexpected response type.")
        }

        switch http.statusCode {
        case 200:
            return localURL
        case 404:
            throw PullError(
                message: "Release not found at \(repo). "
                + "Check https://github.com/\(repo)/releases for available versions."
            )
        case 403:
            throw PullError(
                message: "Access denied (HTTP 403). GitHub may be rate-limiting. "
                + "Try again in a few minutes."
            )
        case 500...599:
            throw PullError(
                message: "GitHub server error (HTTP \(http.statusCode)). Try again later."
            )
        default:
            throw PullError(message: "Unexpected HTTP status \(http.statusCode).")
        }
    }

    /// Resolve which GitHub release tag to pull from. Order:
    ///   1. explicit `self.tag` set at init (pin mode — no network)
    ///   2. `LUMINA_IMAGE_TAG` env var (easy override for testing)
    ///   3. GitHub API latest release containing `assetName` (normal path)
    ///   4. `Self.fallbackTag` (offline / rate-limited / unexpected error)
    ///
    /// The API call is bounded to 3 seconds. If it fails for any
    /// reason, we log once and fall through to the hardcoded fallback
    /// — never block the boot on a transient GitHub issue.
    private func resolveTag(
        progress: @Sendable (_ message: String) -> Void
    ) async -> String {
        if let explicit = tag { return explicit }
        if let env = ProcessInfo.processInfo.environment["LUMINA_IMAGE_TAG"],
           !env.isEmpty {
            progress("Using image tag from LUMINA_IMAGE_TAG: \(env)")
            return env
        }
        if let latest = await Self.resolveLatestTag(
            repo: repo, assetName: assetName, timeout: 3.0
        ) {
            return latest
        }
        progress("GitHub API unreachable; using pinned fallback \(Self.fallbackTag)")
        return Self.fallbackTag
    }

    /// Query GitHub's releases endpoint and return the most recent
    /// release tag whose asset list includes `assetName`. Nil on any
    /// failure — caller falls back to the pinned tag.
    ///
    /// We list `per_page=10` rather than hit `/latest` because a
    /// release that doesn't ship the image asset (e.g. a CLI-only
    /// patch release) would mislead `/latest` into 404-ing the image
    /// download. Walking the first page handles that cleanly.
    static func resolveLatestTag(
        repo: String,
        assetName: String,
        timeout: TimeInterval = 3.0
    ) async -> String? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=10") else {
            return nil
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            return nil
        }

        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200 else {
            return nil
        }

        // Minimal decode: only the two fields we need off each release.
        struct Asset: Decodable { let name: String }
        struct Release: Decodable {
            let tag_name: String
            let draft: Bool?
            let prerelease: Bool?
            let assets: [Asset]
        }

        guard let releases = try? JSONDecoder().decode([Release].self, from: data) else {
            return nil
        }

        // Skip drafts and pre-releases; pick first stable release
        // carrying the image asset.
        return releases.first(where: { release in
            (release.draft ?? false) == false &&
            (release.prerelease ?? false) == false &&
            release.assets.contains(where: { $0.name == assetName })
        })?.tag_name
    }

    private func hashFile(at url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "unknown" }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func runProcess(
        _ path: String, arguments: [String]
    ) -> (exitCode: Int32, stderr: String, stdout: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let stderrPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = stdoutPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (-1, error.localizedDescription, "")
        }
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        return (process.terminationStatus, stderr, stdout)
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes >= 1_073_741_824 {
            return String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
        } else if bytes >= 1_048_576 {
            return String(format: "%.1f MB", Double(bytes) / 1_048_576)
        } else if bytes >= 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024)
        }
        return "\(bytes) bytes"
    }
}

private struct PullError: Error {
    let message: String
}
