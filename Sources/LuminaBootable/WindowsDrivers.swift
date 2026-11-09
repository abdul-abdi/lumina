import CryptoKit
import Foundation
import Lumina

public enum WindowsDrivers {
    static let remote = URL(string: "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.302-1/virtio-win-0.1.302.iso")!
    static let sha256 = "303f7ae40dad495d6ae474fdc571df58958a4dbc5c37a522d80f9a203867949d"
    static let destination = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".lumina/cache/virtio-win/virtio-win-0.1.302.iso")

    public static var cachedISO: URL? {
        FileManager.default.fileExists(atPath: destination.path) ? destination : nil
    }

    public static func ensure(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        if let cachedISO { return cachedISO }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let staged = destination.appendingPathExtension("download")
        try await MacOSRestore.download(remote, to: staged, progress: progress)
        guard try digest(of: staged) == sha256 else {
            try? FileManager.default.removeItem(at: staged)
            throw MacOSRestore.Error(description: "virtio-win ISO failed its SHA-256 check")
        }
        try FileManager.default.moveItem(at: staged, to: destination)
        return destination
    }

    private static func digest(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
