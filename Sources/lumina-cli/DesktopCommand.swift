// Sources/lumina-cli/DesktopCommand.swift
//
// `lumina desktop` subcommand tree — v0.7.0 M3.
// Create, boot, and list `.luminaVM` bundles under ~/.lumina/desktop-vms/.

import ArgumentParser
import Foundation
import Lumina
import LuminaBootable

struct Desktop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "desktop",
        abstract: "Manage full-OS desktop VMs (Linux, Windows 11 ARM, macOS).",
        subcommands: [DesktopCreate.self, DesktopBoot.self, DesktopList.self,
                      DesktopInstallMacOS.self]
    )
}

// MARK: - Shared helpers

enum DesktopHelpers {
    /// Root directory for app-visible desktop VMs. Shared with the
    /// Lumina Desktop.app (M6).
    static var defaultRoot: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".lumina/desktop-vms")
    }

    /// Parse a memory string like "4GB" or "512MB" into bytes.
    static func parseMemoryOrExit(_ raw: String) -> UInt64 {
        guard let bytes = parseMemory(raw) else {
            FileHandle.standardError.write(Data("error: invalid memory value '\(raw)' (expected e.g. 4GB / 512MB)\n".utf8))
            exit(2)
        }
        return bytes
    }

    /// Parse a disk-size string like "32GB" into bytes.
    static func parseDiskOrExit(_ raw: String) -> UInt64 {
        parseMemoryOrExit(raw)  // same grammar
    }

    /// Resolve a bundle path to a VMBundle, exiting on failure with a
    /// helpful message.
    static func loadBundleOrExit(_ pathArg: String) -> VMBundle {
        let url = URL(fileURLWithPath: (pathArg as NSString).expandingTildeInPath)
        do {
            return try VMBundle.load(from: url)
        } catch VMBundle.Error.notABundle(let u) {
            FileHandle.standardError.write(Data("error: \(u.path) is not a .luminaVM bundle (missing manifest.json)\n".utf8))
            exit(2)
        } catch VMBundle.Error.invalidManifest(let u) {
            FileHandle.standardError.write(Data("error: \(u.path) has an unreadable manifest.json\n".utf8))
            exit(2)
        } catch {
            FileHandle.standardError.write(Data("error: failed to load bundle: \(error)\n".utf8))
            exit(2)
        }
    }
}

// MARK: - desktop create

struct DesktopCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new .luminaVM bundle and stage an install ISO."
    )

    @Option(name: .customLong("root"), help: "Bundle root directory. Defaults to ~/.lumina/desktop-vms/<uuid>/.")
    var root: String?

    @Option(name: .customLong("name"), help: "Human-readable VM name.")
    var name: String

    @Option(name: .customLong("os-variant"), help: "OS variant id (e.g. ubuntu-24.04, kali-rolling, windows-11-arm, macos-14).")
    var osVariant: String

    @Option(name: .customLong("memory"), help: "Memory allocation (e.g. 4GB).")
    var memory: String = "4GB"

    @Option(name: .customLong("cpus"), help: "Number of CPU cores.")
    var cpus: Int = 2

    @Option(name: .customLong("disk-size"), help: "Primary disk size (e.g. 32GB).")
    var diskSize: String = "32GB"

    @Option(name: .customLong("iso"), help: "Optional ISO to attach on first boot (installer).")
    var isoPath: String?

    @Flag(name: .customLong("json"), help: "Emit the resulting manifest as JSON.")
    var emitJSON = false

    @Flag(name: .customLong("force"), help: "Skip ARM64 architecture pre-flight check on the ISO.")
    var force = false

    mutating func run() async throws {
        let memBytes = DesktopHelpers.parseMemoryOrExit(memory)
        let diskBytes = DesktopHelpers.parseDiskOrExit(diskSize)

        // v0.7.0 M4: ARM64 pre-flight check on the ISO. Catches "downloaded
        // the x86 ISO by accident" before allocating disk + booting.
        if let iso = isoPath, !force {
            let isoURL = URL(fileURLWithPath: (iso as NSString).expandingTildeInPath)
            let arch: ISOInspector.Architecture
            do {
                arch = try ISOInspector.detectArchitecture(at: isoURL)
            } catch ISOInspector.Error.fileNotFound {
                FileHandle.standardError.write(Data("error: ISO not found: \(iso)\n".utf8))
                throw ExitCode(2)
            } catch {
                FileHandle.standardError.write(Data(
                    "warning: could not inspect ISO \(iso) (\(error)); proceeding.\n".utf8
                ))
                arch = .unknown
            }
            switch arch {
            case .arm64:
                break
            case .x86_64:
                FileHandle.standardError.write(Data(
                    "error: \(iso) is an x86_64 ISO. Lumina only boots ARM64 (aarch64) guests on Apple Silicon. Use --force to override.\n".utf8
                ))
                throw ExitCode(2)
            case .riscv64:
                FileHandle.standardError.write(Data(
                    "error: \(iso) is a RISC-V ISO. Lumina only boots ARM64 (aarch64) guests. Use --force to override.\n".utf8
                ))
                throw ExitCode(2)
            case .unknown:
                FileHandle.standardError.write(Data(
                    "warning: could not detect ISO architecture for \(iso); proceeding anyway. Pass --force to silence this warning.\n".utf8
                ))
            }
        }

        let osFamily: OSFamily
        switch osVariant.lowercased() {
        case let v where v.hasPrefix("ubuntu"), let v where v.hasPrefix("kali"),
             let v where v.hasPrefix("fedora"), let v where v.hasPrefix("debian"),
             let v where v.hasPrefix("alpine"):
            osFamily = .linux
        case let v where v.hasPrefix("windows"):
            osFamily = .windows
        case let v where v.hasPrefix("macos"):
            osFamily = .macOS
        default:
            osFamily = .linux
        }

        let id = UUID()
        let rootURL: URL
        if let r = root {
            rootURL = URL(fileURLWithPath: (r as NSString).expandingTildeInPath)
        } else {
            let base = DesktopHelpers.defaultRoot
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            rootURL = base.appendingPathComponent(id.uuidString)
        }

        let bundle: VMBundle
        do {
            bundle = try VMBundle.create(
                at: rootURL,
                name: name,
                osFamily: osFamily,
                osVariant: osVariant,
                memoryBytes: memBytes,
                cpuCount: cpus,
                diskBytes: diskBytes,
                id: id
            )
        } catch VMBundle.Error.alreadyExists(let u) {
            FileHandle.standardError.write(Data("error: \(u.path) already exists\n".utf8))
            throw ExitCode(2)
        } catch {
            FileHandle.standardError.write(Data("error: failed to create bundle: \(error)\n".utf8))
            throw ExitCode(1)
        }

        // Allocate the primary disk.
        do {
            try DiskImageAllocator.allocate(at: bundle.primaryDiskURL, logicalSize: diskBytes)
        } catch {
            FileHandle.standardError.write(Data("error: disk allocation failed: \(error)\n".utf8))
            throw ExitCode(1)
        }

        // Stage the installer ISO path into the logs directory's sidecar
        // for the first-boot resolver. The actual ISO is NOT copied; we
        // record its URL as an absolute path the boot command resolves.
        if let iso = isoPath {
            let isoURL = URL(fileURLWithPath: (iso as NSString).expandingTildeInPath)
            let sidecar = bundle.rootURL.appendingPathComponent("pending-iso.path")
            try Data(isoURL.path.utf8).write(to: sidecar, options: .atomic)
        }

        if emitJSON || isatty(fileno(stdout)) == 0 {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(bundle.manifest)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } else {
            print("Created \(rootURL.path)")
            print("  id:        \(id.uuidString)")
            print("  name:      \(name)")
            print("  os:        \(osVariant)")
            print("  memory:    \(memory)")
            print("  cpus:      \(cpus)")
            print("  disk:      \(diskSize)")
            if let iso = isoPath { print("  iso:       \(iso) (staged for first boot)") }
        }
    }
}

// MARK: - desktop boot

struct DesktopBoot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "boot",
        abstract: "Boot a .luminaVM bundle (EFI guests)."
    )

    @Argument(help: "Path to the .luminaVM bundle.")
    var bundlePath: String

    @Flag(name: .customLong("headless"), help: "Boot without opening a graphics device (serial-only diagnostic path).")
    var headless = false

    @Option(name: .customLong("serial"), help: "Write guest serial console output to this file.")
    var serialFile: String?

    @Option(name: .customLong("timeout"), help: "Shut the VM down after this many seconds (0 = no limit).")
    var timeoutSec: Int = 0

    @Flag(name: .customLong("rosetta"), help: "Mount Rosetta as /run/lumina-rosetta inside Linux guests for x86_64 binary translation.")
    var rosetta = false

    mutating func run() async throws {
        var bundle = DesktopHelpers.loadBundleOrExit(bundlePath)

        // Resolve the pending ISO sidecar if this is the first boot.
        var cdromURL: URL?
        let sidecar = bundle.rootURL.appendingPathComponent("pending-iso.path")
        if let data = try? Data(contentsOf: sidecar),
           let path = String(data: data, encoding: .utf8) {
            cdromURL = URL(fileURLWithPath: path.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // Ensure + persist a stable MAC on first boot. See
        // `LuminaDesktopSession.boot()` for the full rationale.
        let stableMAC = bundle.ensureMACAddress()

        let isWindows = bundle.manifest.osFamily == .windows
        let isInstallPhase = bundle.manifest.lastBootedAt == nil

        var opts = VMOptions.default
        opts.memory = bundle.manifest.memoryBytes
        opts.cpuCount = bundle.manifest.cpuCount
        opts.macAddress = stableMAC
        opts.bootable = .efi(EFIBootConfig(
            variableStoreURL: bundle.efiVarsURL,
            primaryDisk: bundle.primaryDiskURL,
            cdromISO: cdromURL,
            preferUSBCDROM: isWindows,
            installPhase: isInstallPhase
        ))
        if !headless {
            opts.graphics = GraphicsConfig(
                widthInPixels: 1920,
                heightInPixels: 1080,
                keyboardKind: .usb,
                pointingDeviceKind: .usbScreenCoordinate
            )
        }
        opts.rosetta = rosetta

        let vm = VM(options: opts)

        // Record last-booted timestamp.
        bundle.manifest.lastBootedAt = Date()
        try? bundle.save()

        // Kick off an async task that mirrors serial output to `serialFile`
        // if requested. We poll vm.serialOutput until shutdown.
        let serialTask: Task<Void, Never>? = serialFile.map { path in
            Task.detached {
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                FileManager.default.createFile(atPath: url.path, contents: nil)
                guard let handle = try? FileHandle(forWritingTo: url) else { return }
                defer { try? handle.close() }
                var last = ""
                while !Task.isCancelled {
                    let current = await vm.serialOutput
                    if current != last {
                        let delta = String(current.dropFirst(last.count))
                        try? handle.write(contentsOf: Data(delta.utf8))
                        last = current
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
        defer { serialTask?.cancel() }

        do {
            try await vm.boot()
        } catch {
            FileHandle.standardError.write(Data("error: boot failed: \(error)\n".utf8))
            throw ExitCode(1)
        }

        print("Booted \(bundle.manifest.name). Press Ctrl-C to stop.")

        // SIGINT/SIGTERM via DispatchSource, NOT the default POSIX handler —
        // the default disposition terminates the process without giving
        // vm.shutdown() a chance to run, which aborts any in-flight disk.img
        // writes. We bridge the dispatch source into the async context via
        // AsyncStream and await the first event (or the timeout).
        let signalQueue = DispatchQueue(label: "com.lumina.desktop-boot.signals")
        let (signalStream, signalContinuation) = AsyncStream<Int32>.makeStream()
        let signalSources: [DispatchSourceSignal] = [SIGINT, SIGTERM].map { sig in
            Foundation.signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
            src.setEventHandler { signalContinuation.yield(sig) }
            src.resume()
            return src
        }
        defer {
            signalSources.forEach { $0.cancel() }
            signalContinuation.finish()
        }

        let timeoutSeconds = timeoutSec
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in signalStream {
                    FileHandle.standardError.write(Data("\nShutting down...\n".utf8))
                    return
                }
            }
            if timeoutSeconds > 0 {
                group.addTask {
                    try? await Task.sleep(for: .seconds(timeoutSeconds))
                }
            }
            await group.next()
            group.cancelAll()
        }

        await vm.shutdown()
        serialTask?.cancel()
    }
}

// MARK: - desktop ls

struct DesktopList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls",
        abstract: "List .luminaVM bundles under ~/.lumina/desktop-vms/."
    )

    @Flag(name: .customLong("json"), help: "Emit as JSON.")
    var emitJSON = false

    mutating func run() throws {
        let root = DesktopHelpers.defaultRoot
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else {
            if emitJSON {
                print("[]")
            } else {
                print("No desktop VMs found in \(root.path)")
            }
            return
        }

        var manifests: [VMBundleManifest] = []
        for dir in entries {
            // Resolve symlinks so `.isDirectoryKey` sees the target type,
            // not the symlink itself (FileManager doesn't auto-resolve).
            let resolved = dir.resolvingSymlinksInPath()
            guard (try? resolved.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            guard let bundle = try? VMBundle.load(from: resolved) else { continue }
            manifests.append(bundle.manifest)
        }

        if emitJSON || isatty(fileno(stdout)) == 0 {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(manifests)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } else if manifests.isEmpty {
            print("No desktop VMs found in \(root.path)")
        } else {
            print("NAME                          OS                    MEM    CPUS  CREATED")
            for m in manifests.sorted(by: { $0.createdAt < $1.createdAt }) {
                let memGB = Double(m.memoryBytes) / (1024 * 1024 * 1024)
                let created = DateFormatter.shortDate.string(from: m.createdAt)
                let nameField = m.name.padding(toLength: 29, withPad: " ", startingAt: 0)
                let osField = m.osVariant.padding(toLength: 21, withPad: " ", startingAt: 0)
                print("\(nameField) \(osField) \(String(format: "%.1f", memGB))GB   \(m.cpuCount)     \(created)")
            }
        }
    }
}

private extension DateFormatter {
    static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
}

// MARK: - desktop install-macos (v0.7.0 M5)

struct DesktopInstallMacOS: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install-macos",
        abstract: "Restore a macOS guest from an IPSW into a .luminaVM bundle."
    )

    @Argument(help: "Path to the .luminaVM bundle (must already exist via 'desktop create').")
    var bundlePath: String

    @Option(name: .customLong("ipsw"), help: "Path to a macOS IPSW file (Apple's restore image).")
    var ipswPath: String

    @Option(name: .customLong("memory"), help: "Memory allocation for the install run (e.g. 8GB).")
    var memory: String = "8GB"

    @Option(name: .customLong("cpus"), help: "CPU cores for the install run.")
    var cpus: Int = 4

    mutating func run() async throws {
        var bundle = DesktopHelpers.loadBundleOrExit(bundlePath)
        let ipswURL = URL(fileURLWithPath: (ipswPath as NSString).expandingTildeInPath)

        guard FileManager.default.fileExists(atPath: ipswURL.path) else {
            FileHandle.standardError.write(Data("error: IPSW not found: \(ipswPath)\n".utf8))
            throw ExitCode(2)
        }

        // Ensure the bundle has a persisted MAC before install so regular
        // boots after install match what VZ saw during the install run.
        let stableMAC = bundle.ensureMACAddress()

        let cfg = MacOSBootConfig(
            ipsw: ipswURL,
            auxiliaryStorage: bundle.auxiliaryStorageURL,
            primaryDisk: bundle.primaryDiskURL
        )
        let vm = MacOSVM(
            bootConfig: cfg,
            memoryBytes: DesktopHelpers.parseMemoryOrExit(memory),
            cpuCount: cpus,
            macAddress: stableMAC
        )

        print("Restoring macOS from \(ipswPath) into \(bundle.rootURL.path)")
        print("This may take 30+ minutes; progress prints in 5% increments.")

        // Print progress when it crosses 5% buckets.
        let lastBucket = ProgressBucket()
        do {
            try await vm.install { fraction in
                let bucket = Int(fraction * 20)  // 0..20 = 5% increments
                if lastBucket.advanceTo(bucket) {
                    print("  \(Int(fraction * 100))% complete")
                }
            }
        } catch {
            FileHandle.standardError.write(Data("error: install failed: \(error)\n".utf8))
            throw ExitCode(1)
        }

        await vm.shutdown()
        print("Installation complete.")

        // Persist the resolved hardware model + machine identifier into the
        // bundle manifest so future boots know which IPSW lineage to use.
        // (For v0.7.0 we stash them in a sidecar; M6 grows the manifest schema.)
        let resolved = await vm.bootConfig
        if let hw = resolved.hardwareModel {
            try? hw.write(to: bundle.rootURL.appendingPathComponent("macos.hwmodel"), options: .atomic)
        }
        if let mid = resolved.machineIdentifier {
            try? mid.write(to: bundle.rootURL.appendingPathComponent("macos.machineid"), options: .atomic)
        }
    }
}

/// Single-write tracker so progress callbacks don't flood stdout. Actor
/// would be overkill — a class-with-NSLock matches the existing Lumina
/// patterns (see CommandRunner) and avoids dragging an actor into a
/// synchronous KVO callback.
private final class ProgressBucket: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Int = -1

    func advanceTo(_ next: Int) -> Bool {
        lock.withLock {
            if next > current {
                current = next
                return true
            }
            return false
        }
    }
}
