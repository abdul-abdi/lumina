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

public struct DirectoryUpload: Sendable {
    public let localPath: URL
    public let remotePath: String

    public init(localPath: URL, remotePath: String) {
        self.localPath = localPath
        self.remotePath = remotePath
    }
}

public struct DirectoryDownload: Sendable {
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

// MARK: - Stdin

/// Stdin source for a command. Default `.closed` sends stdinClose immediately
/// so the guest sees EOF; `.source` streams chunks until the closure returns
/// nil (EOF), then closes.
///
/// Stdin data today is UTF-8. Non-UTF-8 bytes are lossy-converted via
/// `String(decoding:as:)`. Binary-safe stdin is planned alongside the
/// binary-stdout base64 envelope.
public enum Stdin: Sendable {
    case closed
    case source(@Sendable () async throws -> Data?)
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
    public var directoryUploads: [DirectoryUpload]
    public var directoryDownloads: [DirectoryDownload]
    public var mounts: [MountPoint]
    public var workingDirectory: String?
    /// Disk size in bytes. When larger than the image rootfs, the COW clone
    /// is resized before boot. Nil means use the image's original size.
    public var diskSize: UInt64?
    /// Stdin source. Default `.closed` sends EOF immediately.
    public var stdin: Stdin

    public static let `default` = RunOptions()

    public init(
        timeout: Duration = .seconds(60),
        memory: UInt64 = 1024 * 1024 * 1024,
        cpuCount: Int = 2,
        image: String = "default",
        env: [String: String] = [:],
        uploads: [FileUpload] = [],
        downloads: [FileDownload] = [],
        directoryUploads: [DirectoryUpload] = [],
        directoryDownloads: [DirectoryDownload] = [],
        mounts: [MountPoint] = [],
        workingDirectory: String? = nil,
        diskSize: UInt64? = nil,
        stdin: Stdin = .closed
    ) {
        self.timeout = timeout
        self.memory = memory
        self.cpuCount = cpuCount
        self.image = image
        self.env = env
        self.uploads = uploads
        self.downloads = downloads
        self.directoryUploads = directoryUploads
        self.directoryDownloads = directoryDownloads
        self.mounts = mounts
        self.workingDirectory = workingDirectory
        self.diskSize = diskSize
        self.stdin = stdin
    }
}

// MARK: - Graphics (v0.7.0 desktop stack, opt-in)

/// Keyboard device kind attached to a VM with a display.
///
/// `.usb` is the right default for Linux and Windows guests. `.mac` requires
/// a macOS guest (VZMacOSVirtualMachine) and is ignored otherwise.
public enum KeyboardKind: Sendable {
    case usb
    case mac
}

/// Pointing device kind attached to a VM with a display.
///
/// `.usbScreenCoordinate` is a standard USB mouse — works with every guest OS.
/// `.trackpad` requires a macOS guest and falls back to USB mouse otherwise.
public enum PointingDeviceKind: Sendable {
    case usbScreenCoordinate
    case trackpad
}

/// Display + input configuration for a VM. Presence triggers the desktop
/// code path in `VM.boot()`; absence (the default) leaves the agent path
/// untouched.
///
/// For agent workloads, leave `VMOptions.graphics` as `nil`. For desktop
/// workloads, pass a `GraphicsConfig`. See `LuminaGraphics` for convenience
/// factories (`.defaultDesktop`, `.retina`, etc.).
public struct GraphicsConfig: Sendable {
    public var widthInPixels: Int
    public var heightInPixels: Int
    public var keyboardKind: KeyboardKind
    public var pointingDeviceKind: PointingDeviceKind

    public init(
        widthInPixels: Int = 1920,
        heightInPixels: Int = 1080,
        keyboardKind: KeyboardKind = .usb,
        pointingDeviceKind: PointingDeviceKind = .usbScreenCoordinate
    ) {
        self.widthInPixels = widthInPixels
        self.heightInPixels = heightInPixels
        self.keyboardKind = keyboardKind
        self.pointingDeviceKind = pointingDeviceKind
    }
}

// MARK: - v0.7.0 M3: Bootable profiles

/// Identifier for a headless agent image in `~/.lumina/images/<name>/`.
///
/// Thin wrapper so callers can round-trip the name through `BootableProfile`
/// without plucking it out of `VMOptions.image` (which survives for backwards
/// compatibility but is derived from this value going forward).
public struct AgentImageRef: Sendable, Equatable {
    public let image: String

    public init(image: String) {
        self.image = image
    }
}

/// Configuration for a VZEFIBootLoader-based guest (Linux ISO boot, Windows 11 ARM).
///
/// The caller supplies URLs for the EFI variable store, primary read-write disk,
/// optional CD-ROM ISO for installer boots, and any extra virtio block devices.
/// `LuminaBootable.EFIBootable` (M3) consumes this to configure a
/// `VZVirtualMachineConfiguration`.
public struct EFIBootConfig: Sendable, Equatable {
    public var variableStoreURL: URL
    public var primaryDisk: URL
    public var cdromISO: URL?
    public var extraDisks: [URL]

    public init(
        variableStoreURL: URL,
        primaryDisk: URL,
        cdromISO: URL? = nil,
        extraDisks: [URL] = []
    ) {
        self.variableStoreURL = variableStoreURL
        self.primaryDisk = primaryDisk
        self.cdromISO = cdromISO
        self.extraDisks = extraDisks
    }
}

/// Configuration for a VZMacOSVirtualMachine-based guest (M5).
///
/// Hardware model + machine identifier are persisted as raw `Data` because
/// `VZMacHardwareModel` / `VZMacMachineIdentifier` are not `Sendable` and
/// their canonical representation is `dataRepresentation`. Nil values mean
/// "pick a reasonable default at install time" — the installer fills them in
/// and the final values persist in the VM bundle.
public struct MacOSBootConfig: Sendable, Equatable {
    public var ipsw: URL
    public var auxiliaryStorage: URL
    public var primaryDisk: URL
    public var hardwareModel: Data?
    public var machineIdentifier: Data?

    public init(
        ipsw: URL,
        auxiliaryStorage: URL,
        primaryDisk: URL,
        hardwareModel: Data? = nil,
        machineIdentifier: Data? = nil
    ) {
        self.ipsw = ipsw
        self.auxiliaryStorage = auxiliaryStorage
        self.primaryDisk = primaryDisk
        self.hardwareModel = hardwareModel
        self.machineIdentifier = machineIdentifier
    }
}

/// Describes how a VM should boot.
///
/// `.agent` preserves the v0.6.0 headless contract (Linux kernel + initrd +
/// lumina-agent + vsock). `.efi` and `.macOS` are the v0.7.0 full-OS paths.
/// When `VMOptions.bootable` is nil, `effectiveBootable` derives
/// `.agent(AgentImageRef(image: options.image))` so agent callers never have
/// to populate this field.
public enum BootableProfile: Sendable, Equatable {
    case agent(AgentImageRef)
    case efi(EFIBootConfig)
    case macOS(MacOSBootConfig)
}

// MARK: - v0.7.0 M4: Audio

/// Optional virtio sound device for desktop guests. nil = no sound device.
///
/// Linux desktop and Windows 11 ARM guests both benefit; agent path leaves
/// this nil and incurs zero cost.
public struct SoundConfig: Sendable, Equatable {
    public var enabled: Bool
    public var streamCount: Int

    public init(enabled: Bool, streamCount: Int = 1) {
        self.enabled = enabled
        self.streamCount = streamCount
    }
}

// MARK: - VM Options

public struct VMOptions: Sendable {
    public var memory: UInt64
    public var cpuCount: Int
    public var image: String
    public var networkProvider: any NetworkProvider
    public var mounts: [MountPoint]
    public var privateNetworkFd: Int32?  // Raw fd, not FileHandle (FileHandle isn't Sendable)
    public var networkHosts: [String: String]?
    public var networkIP: String?
    public var rosetta: Bool
    public var diskSize: UInt64?
    /// v0.7.0: optional display + input for the desktop use case.
    /// `nil` is the agent path — zero overhead. Non-nil wires
    /// `VZVirtioGraphicsDeviceConfiguration` + keyboard + pointing device.
    public var graphics: GraphicsConfig?
    /// v0.7.0 M4: optional virtio sound device for desktop guests.
    /// nil = no sound device (agent-path-safe).
    public var sound: SoundConfig?

    /// v0.7.0 M3: optional override for how this VM boots. `nil` means "use
    /// the headless agent path with `image`." Non-nil wins over `image`.
    ///
    /// Regression-gate invariant: the agent cold-boot path cannot read any
    /// `.efi` / `.macOS` code. The VM actor consults this property only when
    /// building the VZ configuration — never on the agent fast path.
    public var bootable: BootableProfile?

    /// Resolves `bootable` to a concrete profile.
    ///
    /// Returns `bootable` if set; otherwise falls back to
    /// `.agent(AgentImageRef(image: self.image))`. Call sites that dispatch
    /// on the profile (e.g. `VM.boot()`) use this to keep the agent path
    /// implicit.
    public var effectiveBootable: BootableProfile {
        if let b = bootable { return b }
        return .agent(AgentImageRef(image: image))
    }

    public static let `default` = VMOptions()

    public init(
        memory: UInt64 = 1024 * 1024 * 1024,
        cpuCount: Int = 2,
        image: String = "default",
        networkProvider: any NetworkProvider = NATNetworkProvider(),
        mounts: [MountPoint] = [],
        privateNetworkFd: Int32? = nil,
        networkHosts: [String: String]? = nil,
        networkIP: String? = nil,
        rosetta: Bool = false,
        diskSize: UInt64? = nil,
        graphics: GraphicsConfig? = nil,
        bootable: BootableProfile? = nil,
        sound: SoundConfig? = nil
    ) {
        self.memory = memory
        self.cpuCount = cpuCount
        self.image = image
        self.networkProvider = networkProvider
        self.mounts = mounts
        self.privateNetworkFd = privateNetworkFd
        self.networkHosts = networkHosts
        self.networkIP = networkIP
        self.rosetta = rosetta
        self.diskSize = diskSize
        self.graphics = graphics
        self.bootable = bootable
        self.sound = sound
    }

    public init(from runOptions: RunOptions) {
        self.memory = runOptions.memory
        self.cpuCount = runOptions.cpuCount
        self.image = runOptions.image
        self.networkProvider = NATNetworkProvider()
        self.mounts = runOptions.mounts
        self.privateNetworkFd = nil
        self.networkHosts = nil
        self.networkIP = nil
        self.diskSize = runOptions.diskSize
        // Auto-detect rosetta from image metadata
        self.rosetta = ImageStore().readMeta(name: runOptions.image)?.rosetta ?? false
        // Disposable `run` is never a desktop workload.
        self.graphics = nil
        // Disposable `run` always takes the agent path — the CLI has no way
        // to build a .luminaVM bundle in one shot today.
        self.bootable = nil
        // Disposable `run` is headless; no audio.
        self.sound = nil
    }
}

// MARK: - Run Result

public struct RunResult: Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public let wallTime: Duration

    /// Raw stdout bytes when any chunk was binary (non-UTF-8). When set,
    /// `stdout` is the lossy UTF-8 conversion; `stdoutBytes` is byte-exact.
    /// Nil when all chunks were valid UTF-8 — in which case `stdout` is
    /// byte-exact as well via String.utf8.
    public let stdoutBytes: Data?
    public let stderrBytes: Data?

    public var success: Bool { exitCode == 0 }

    public init(stdout: String, stderr: String, exitCode: Int32, wallTime: Duration, stdoutBytes: Data? = nil, stderrBytes: Data? = nil) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.wallTime = wallTime
        self.stdoutBytes = stdoutBytes
        self.stderrBytes = stderrBytes
    }
}

// MARK: - Output Chunk

public enum OutputChunk: Sendable, Equatable {
    case stdout(String)
    case stderr(String)
    /// Raw binary chunk. Produced when the guest emits a non-UTF-8 chunk
    /// (wire-encoded as base64). Consumers that want binary-safe output
    /// should handle these cases; text-only consumers can ignore them or
    /// convert with `String(decoding:as:)` which will be lossy.
    case stdoutBytes(Data)
    case stderrBytes(Data)
    case exit(Int32)
}

/// Chunks yielded by PTY exec streams. Distinct from OutputChunk because PTY
/// has a single merged output stream (no stdout/stderr separation).
public enum PtyChunk: Sendable, Equatable {
    /// Raw bytes from PTY master fd (base64-decoded).
    case output(Data)
    /// Process exited with this code.
    case exit(Int32)
}

// MARK: - VM State

public enum VMState: Sendable, Equatable {
    case idle
    case booting
    case ready
    case shutdown
}

// MARK: - Session Types

public struct SessionOptions: Sendable {
    public var cpuCount: Int
    public var memory: UInt64
    public var image: String
    public var timeout: Duration
    public var env: [String: String]
    public var volumes: [VolumeMount]

    public init(
        cpuCount: Int = 2,
        memory: UInt64 = 1024 * 1024 * 1024,
        image: String = "default",
        timeout: Duration = .seconds(60),
        env: [String: String] = [:],
        volumes: [VolumeMount] = []
    ) {
        self.cpuCount = cpuCount
        self.memory = memory
        self.image = image
        self.timeout = timeout
        self.env = env
        self.volumes = volumes
    }
}

public struct SessionInfo: Sendable, Codable {
    public let sid: String
    public let pid: Int32
    public let image: String
    public let cpuCount: Int
    public let memory: UInt64
    public let created: Date
    public var status: SessionState

    public init(
        sid: String,
        pid: Int32,
        image: String,
        cpuCount: Int,
        memory: UInt64,
        created: Date,
        status: SessionState
    ) {
        self.sid = sid
        self.pid = pid
        self.image = image
        self.cpuCount = cpuCount
        self.memory = memory
        self.created = created
        self.status = status
    }
}

public enum SessionState: String, Sendable, Codable, Equatable {
    case running
    case dead
}

public struct VolumeMount: Sendable {
    public let name: String
    public let guestPath: String

    public init(name: String, guestPath: String) {
        self.name = name
        self.guestPath = guestPath
    }
}

// MARK: - Image Types

public struct ImageInfo: Sendable {
    public let name: String
    public let base: String?
    public let command: String?
    public let rosetta: Bool
    public let created: Date
    public let sizeBytes: UInt64
}

public struct ImageMeta: Sendable, Codable {
    public let base: String?
    public let command: String?
    public let created: Date
    public let rosetta: Bool

    public init(base: String?, command: String?, created: Date, rosetta: Bool = false) {
        self.base = base
        self.command = command
        self.created = created
        self.rosetta = rosetta
    }

    // Backward-compatible decoding: old images lack the rosetta field
    private enum CodingKeys: String, CodingKey {
        case base, command, created, rosetta
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        base = try container.decodeIfPresent(String.self, forKey: .base)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        created = try container.decode(Date.self, forKey: .created)
        rosetta = try container.decodeIfPresent(Bool.self, forKey: .rosetta) ?? false
    }
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
    case sessionNotFound(String)
    case sessionDead(String)
    case sessionFailed(String)
}

extension LuminaError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .imageNotFound(let name): "image '\(name)' not found"
        case .cloneFailed(let e): "failed to clone disk image: \(e.localizedDescription)"
        case .bootFailed(let e): "VM failed to boot: \(e.localizedDescription)"
        case .connectionFailed: "failed to connect to guest agent"
        case .timeout: "command timed out"
        case .guestCrashed(let output): output.isEmpty ? "guest crashed" : "guest crashed: \(output)"
        case .protocolError(let msg): "protocol error: \(msg)"
        case .uploadFailed(let path, let reason): "upload failed for '\(path)': \(reason)"
        case .downloadFailed(let path, let reason): "download failed for '\(path)': \(reason)"
        case .sessionNotFound(let id): "session '\(id)' not found"
        case .sessionDead(let id): "session '\(id)' is no longer running"
        case .sessionFailed(let reason): "session failed: \(reason)"
        }
    }
}

// MARK: - Duration Helpers

extension Duration {
    /// Total milliseconds from both seconds and attoseconds components.
    /// Single definition to avoid fat-fingering the attosecond divisor.
    /// Named `totalMilliseconds` to avoid conflict with `Duration.milliseconds(_:)`.
    public var totalMilliseconds: Int {
        Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000)
    }
}

// MARK: - Parsing Helpers

/// Parse a human-readable duration string (e.g. "30s", "5m", "2h") into a Duration.
/// Returns nil on invalid input. Bare numbers are treated as seconds.
public func parseDuration(_ str: String) -> Duration? {
    let trimmed = str.trimmingCharacters(in: .whitespaces).lowercased()
    if trimmed.hasSuffix("s") {
        guard let num = Int(trimmed.dropLast()) else { return nil }
        return .seconds(num)
    } else if trimmed.hasSuffix("m") {
        guard let num = Int(trimmed.dropLast()) else { return nil }
        return .seconds(num * 60)
    } else if trimmed.hasSuffix("h") {
        guard let num = Int(trimmed.dropLast()) else { return nil }
        return .seconds(num * 3600)
    }
    guard let num = Int(trimmed) else { return nil }
    return .seconds(num)
}

/// A parsed `--forward host:guest` spec. Both ports are in [1, 65535].
public struct ForwardSpec: Equatable, Sendable {
    public let hostPort: Int
    public let guestPort: Int
    public init(hostPort: Int, guestPort: Int) {
        self.hostPort = hostPort
        self.guestPort = guestPort
    }
}

/// Parse a `--forward host:guest` spec. Returns nil if the input is
/// malformed or either port is out of range.
public func parseForwardSpec(_ spec: String) -> ForwardSpec? {
    let parts = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 2,
          let hostPort = Int(parts[0]),
          let guestPort = Int(parts[1]),
          (1...65_535).contains(hostPort),
          (1...65_535).contains(guestPort)
    else { return nil }
    return ForwardSpec(hostPort: hostPort, guestPort: guestPort)
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
