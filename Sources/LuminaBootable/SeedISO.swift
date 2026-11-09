import Foundation

public enum SeedISO {
    public struct Error: Swift.Error, CustomStringConvertible, Equatable {
        public let description: String
    }

    @discardableResult
    public static func make(files: [String: Data], volumeName: String, at output: URL) throws -> URL {
        let staging = output.deletingLastPathComponent()
            .appendingPathComponent(".seed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        for (name, data) in files {
            try data.write(to: staging.appendingPathComponent(name))
        }
        return try make(directory: staging, volumeName: volumeName, at: output)
    }

    @discardableResult
    public static func make(directory: URL, volumeName: String, at output: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: output)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = [
            "makehybrid", "-iso", "-joliet",
            "-default-volume-name", volumeName,
            "-o", output.path, directory.path,
        ]
        proc.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        proc.standardError = stderr
        do {
            try proc.run()
        } catch {
            throw Error(description: "hdiutil: \(error)")
        }
        let message = stderr.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw Error(description: "hdiutil exit \(proc.terminationStatus): \(String(decoding: message, as: UTF8.self))")
        }
        return output
    }
}
