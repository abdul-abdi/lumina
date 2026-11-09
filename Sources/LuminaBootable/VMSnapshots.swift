import Darwin
import Foundation

public struct VMSnapshot: Identifiable, Hashable, Sendable {
    public let url: URL
    public let createdAt: Date
    public var id: URL { url }
}

extension VMBundle {
    static let snapshotFiles = ["disk.img", "efi.vars", "aux.img", "macos.hwmodel", "macos.machineid"]

    public var snapshots: [VMSnapshot] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: snapshotsDirectory, includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey]
        )) ?? []
        return entries.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .isDirectoryKey])
            guard values?.isDirectory == true else { return nil }
            return VMSnapshot(url: url, createdAt: values?.creationDate ?? .distantPast)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    public func takeSnapshot(at date: Date = Date()) throws -> VMSnapshot {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let destination = snapshotsDirectory.appendingPathComponent(formatter.string(from: date))
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            for name in Self.snapshotFiles {
                let source = rootURL.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                try flush(source)
                try clone(source, to: destination.appendingPathComponent(name))
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return VMSnapshot(url: destination, createdAt: date)
    }

    public func restore(_ snapshot: VMSnapshot) throws {
        for name in Self.snapshotFiles {
            let saved = snapshot.url.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: saved.path) else { continue }
            let target = rootURL.appendingPathComponent(name)
            let staged = rootURL.appendingPathComponent(".\(name).restoring")
            try? FileManager.default.removeItem(at: staged)
            try clone(saved, to: staged)
            guard rename(staged.path, target.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    public func deleteSnapshot(_ snapshot: VMSnapshot) throws {
        try FileManager.default.removeItem(at: snapshot.url)
    }

    private func flush(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        _ = fcntl(fd, F_FULLFSYNC)
    }

    private func clone(_ source: URL, to destination: URL) throws {
        guard clonefile(source.path, destination.path, 0) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

extension VMBundle {
    public var signIn: (user: String, password: String?)? {
        let variant = manifest.osVariant.lowercased()
        if variant == "omarchy" { return (NSUserName(), OmarchySeed.password(for: self)) }
        if manifest.osFamily == .windows || variant.hasPrefix("debian") || variant.hasPrefix("kali") {
            return ("lumina", "lumina")
        }
        return nil
    }
}
