// Sources/Lumina/ImagePuller.swift
import Foundation
import CryptoKit

/// Downloads pre-built VM images from GitHub Releases.
public struct ImagePuller: Sendable {
    public static let defaultRepo = "abdul-abdi/lumina"
    public static let defaultTag = "lumina-v0.2.0"
    public static let defaultAssetName = "lumina-image-default.tar.gz"

    private let repo: String
    private let tag: String
    private let assetName: String
    private let imageStore: ImageStore

    public init(
        repo: String = ImagePuller.defaultRepo,
        tag: String = ImagePuller.defaultTag,
        assetName: String = ImagePuller.defaultAssetName,
        imageStore: ImageStore = ImageStore()
    ) {
        self.repo = repo
        self.tag = tag
        self.assetName = assetName
        self.imageStore = imageStore
    }

    /// Check if the default image is already available.
    public func imageExists(name: String = "default") -> Bool {
        (try? imageStore.resolve(name: name)) != nil
    }

    /// Pull the default image from GitHub Releases.
    /// Downloads the tarball, verifies integrity, extracts vmlinuz + initrd + rootfs.img.
    public func pull(
        name: String = "default",
        progress: @Sendable (_ message: String) -> Void = { _ in }
    ) async throws(LuminaError) {
        let releaseURL = "https://github.com/\(repo)/releases/download/\(tag)/\(assetName)"
        progress("Downloading \(assetName) from \(repo) (\(tag))...")

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

        // 3. Compute SHA256 for verification logging
        let sha256 = hashFile(at: downloadedFile)
        progress("Downloaded \(formatBytes(fileSize)) (SHA256: \(sha256.prefix(12))...)")

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

        // 5. Extract tarball
        progress("Extracting to \(imageDir.path)...")
        let tarResult = runProcess(
            "/usr/bin/tar", arguments: ["xzf", downloadedFile.path, "-C", imageDir.path]
        )

        guard tarResult.exitCode == 0 else {
            // Clean up partial extraction
            try? FileManager.default.removeItem(at: imageDir)
            throw .imageNotFound(
                "Extraction failed (exit \(tarResult.exitCode)): \(tarResult.stderr)"
            )
        }

        // 6. Verify all required files exist
        let requiredFiles = ["vmlinuz", "initrd", "rootfs.img"]
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
                message: "Release '\(tag)' not found at \(repo). "
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

    private func hashFile(at url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "unknown" }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func runProcess(
        _ path: String, arguments: [String]
    ) -> (exitCode: Int32, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (-1, error.localizedDescription)
        }
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        return (process.terminationStatus, stderr)
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
