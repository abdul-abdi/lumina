// Sources/Lumina/Types.swift
import Foundation

// MARK: - File Transfer

public struct FileUpload: Sendable {
    public let localPath: URL
    public let remotePath: String
    public let mode: String

    public init(localPath: URL, remotePath: String, mode: String = "0644") {
        self.localPath = localPath
        self.remotePath = remotePath
        self.mode = mode
    }
}

public struct FileDownload: Sendable {
    public let remotePath: String
    public let localPath: URL

    public init(remotePath: String, localPath: URL) {
        self.remotePath = remotePath
        self.localPath = localPath
    }
}

public struct MountPoint: Sendable {
    public let hostPath: URL
    public let guestPath: String
    public let readOnly: Bool

    public init(hostPath: URL, guestPath: String, readOnly: Bool = false) {
        self.hostPath = hostPath
        self.guestPath = guestPath
        self.readOnly = readOnly
    }
}

// MARK: - Run Options

public struct RunOptions: Sendable {
    public var timeout: Duration
    public var memory: UInt64
    public var cpuCount: Int
    public var image: String
    public var env: [String: String]
    public var uploads: [FileUpload]
    public var downloads: [FileDownload]
    public var mounts: [MountPoint]

    public static let `default` = RunOptions()

    public init(
        timeout: Duration = .seconds(60),
        memory: UInt64 = 512 * 1024 * 1024,
        cpuCount: Int = 2,
        image: String = "default",
        env: [String: String] = [:],
        uploads: [FileUpload] = [],
        downloads: [FileDownload] = [],
        mounts: [MountPoint] = []
    ) {
        self.timeout = timeout
        self.memory = memory
        self.cpuCount = cpuCount
        self.image = image
        self.env = env
        self.uploads = uploads
        self.downloads = downloads
        self.mounts = mounts
    }
}

// MARK: - VM Options

public struct VMOptions: Sendable {
    public var memory: UInt64
    public var cpuCount: Int
    public var image: String
    public var networkProvider: any NetworkProvider
    public var mounts: [MountPoint]

    public static let `default` = VMOptions()

    public init(
        memory: UInt64 = 512 * 1024 * 1024,
        cpuCount: Int = 2,
        image: String = "default",
        networkProvider: any NetworkProvider = NATNetworkProvider(),
        mounts: [MountPoint] = []
    ) {
        self.memory = memory
        self.cpuCount = cpuCount
        self.image = image
        self.networkProvider = networkProvider
        self.mounts = mounts
    }

    public init(from runOptions: RunOptions) {
        self.memory = runOptions.memory
        self.cpuCount = runOptions.cpuCount
        self.image = runOptions.image
        self.networkProvider = NATNetworkProvider()
        self.mounts = runOptions.mounts
    }
}

// MARK: - Run Result

public struct RunResult: Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public let wallTime: Duration

    public var success: Bool { exitCode == 0 }

    public init(stdout: String, stderr: String, exitCode: Int32, wallTime: Duration) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.wallTime = wallTime
    }
}

// MARK: - Output Chunk

public enum OutputChunk: Sendable, Equatable {
    case stdout(String)
    case stderr(String)
    case exit(Int32)
}

// MARK: - VM State

public enum VMState: Sendable, Equatable {
    case idle
    case booting
    case ready
    case executing
    case shutdown
}

// MARK: - Errors

public enum LuminaError: Error, Sendable {
    case imageNotFound(String)
    case cloneFailed(underlying: any Error & Sendable)
    case bootFailed(underlying: any Error & Sendable)
    case connectionFailed
    case timeout
    case guestCrashed(serialOutput: String)
    case protocolError(String)
    case uploadFailed(path: String, reason: String)
    case downloadFailed(path: String, reason: String)
}

// MARK: - Parsing Helpers

/// Parse a human-readable duration string (e.g. "30s", "5m") into a Duration.
/// Returns nil on invalid input. Bare numbers are treated as seconds.
public func parseDuration(_ str: String) -> Duration? {
    let trimmed = str.trimmingCharacters(in: .whitespaces).lowercased()
    if trimmed.hasSuffix("s") {
        guard let num = Int(trimmed.dropLast()) else { return nil }
        return .seconds(num)
    } else if trimmed.hasSuffix("m") {
        guard let num = Int(trimmed.dropLast()) else { return nil }
        return .seconds(num * 60)
    }
    guard let num = Int(trimmed) else { return nil }
    return .seconds(num)
}

/// Parse a human-readable memory string (e.g. "512MB", "1GB") into bytes.
/// Returns nil on invalid input. Requires MB or GB suffix.
public func parseMemory(_ str: String) -> UInt64? {
    let trimmed = str.trimmingCharacters(in: .whitespaces).uppercased()
    if trimmed.hasSuffix("GB") {
        guard let num = UInt64(trimmed.dropLast(2)), num > 0 else { return nil }
        return num * 1024 * 1024 * 1024
    } else if trimmed.hasSuffix("MB") {
        guard let num = UInt64(trimmed.dropLast(2)), num > 0 else { return nil }
        return num * 1024 * 1024
    }
    return nil
}
