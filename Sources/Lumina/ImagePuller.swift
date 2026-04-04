// Sources/Lumina/ImagePuller.swift
import Foundation

/// Downloads pre-built VM images from GitHub Releases.
public struct ImagePuller: Sendable {
    public static let defaultRepo = "abdul-abdi/lumina"
    public static let defaultTag = "image-v0.1.0"
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
    /// Downloads the tarball, extracts vmlinuz + initrd + rootfs.img to ~/.lumina/images/default/.
    public func pull(
        name: String = "default",
        progress: @Sendable (_ message: String) -> Void = { _ in }
    ) async throws(LuminaError) {
        let url = "https://github.com/\(repo)/releases/download/\(tag)/\(assetName)"
        progress("Downloading image from \(url)...")

        // Download using URLSession
        let downloadURL: URL
        do {
            let (localURL, response) = try await URLSession.shared.download(
                from: URL(string: url)!
            )
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200
            else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                throw ImagePullError.downloadFailed(
                    "HTTP \(statusCode) — release may not exist yet. "
                    + "Build locally: cd Guest && sudo ./build-image.sh"
                )
            }
            downloadURL = localURL
        } catch let error as ImagePullError {
            throw .imageNotFound("Pull failed: \(error.localizedDescription)")
        } catch {
            throw .imageNotFound("Download failed: \(error.localizedDescription)")
        }

        progress("Extracting image...")

        // Extract tarball to image directory
        let imageDir = imageStore.baseDir.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)
        } catch {
            throw .cloneFailed(underlying: error)
        }

        // Use tar to extract
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["xzf", downloadURL.path, "-C", imageDir.path]

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw .imageNotFound("Failed to extract image: \(error.localizedDescription)")
        }

        guard process.terminationStatus == 0 else {
            throw .imageNotFound("tar extraction failed with exit code \(process.terminationStatus)")
        }

        // Verify the extracted files exist
        _ = try imageStore.resolve(name: name)

        progress("Image pulled to \(imageDir.path)")
    }
}

enum ImagePullError: Error {
    case downloadFailed(String)
}
