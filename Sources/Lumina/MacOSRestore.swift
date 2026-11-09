import Foundation
@preconcurrency import Virtualization

public enum MacOSRestore {
    public static let cacheDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".lumina/cache/ipsw")

    public struct Error: Swift.Error, CustomStringConvertible {
        public let description: String

        public init(description: String) {
            self.description = description
        }
    }

    public static func latestIPSW(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let remote: URL = try await withCheckedThrowingContinuation { cont in
            VZMacOSRestoreImage.fetchLatestSupported { result in
                cont.resume(with: result.map(\.url))
            }
        }
        let destination = cacheDirectory.appendingPathComponent(remote.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try await download(remote, to: destination, progress: progress)
        return destination
    }

    public static func download(
        _ remote: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        var head = URLRequest(url: remote)
        head.httpMethod = "HEAD"
        let (_, response) = try await URLSession.shared.data(for: head)
        let total = Double(max(response.expectedContentLength, 1))

        let partial = destination.appendingPathExtension("part")
        let curl = Process()
        curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        curl.arguments = [
            "-fsSL", "--retry", "10", "--retry-all-errors", "--retry-delay", "2",
            "--speed-limit", "65536", "--speed-time", "60",
            "-C", "-", "-o", partial.path, remote.absoluteString,
        ]
        let stderr = Pipe()
        curl.standardError = stderr
        try curl.run()
        while curl.isRunning {
            let written = (try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            progress(min(Double(written) / total, 1))
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { curl.terminate() }
        }
        try Task.checkCancellation()
        guard curl.terminationStatus == 0 else {
            let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw Error(description: "IPSW download failed (curl exit \(curl.terminationStatus)): \(message)")
        }
        try FileManager.default.moveItem(at: partial, to: destination)
        progress(1)
    }
}
