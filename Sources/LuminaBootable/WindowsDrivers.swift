import Foundation

public enum WindowsDrivers {
    static let remote = URL(string: "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.302-1/virtio-win-0.1.302.iso")!
    static let sha256 = "303f7ae40dad495d6ae474fdc571df58958a4dbc5c37a522d80f9a203867949d"

    public static var cachedISO: URL? {
        let url = InstallerSource.cacheRoot.appendingPathComponent("virtio-win").appendingPathComponent(remote.lastPathComponent)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public static func ensure(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        try await InstallerSource.verifiedDownload(remote, sha256: sha256, into: "virtio-win", progress: progress)
    }
}
