import ArgumentParser
import Foundation
import Lumina
import LuminaBootable

struct Iso: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "iso",
        abstract: "Boot, inspect, and list ARM64 installer / live ISOs.",
        subcommands: [IsoBoot.self, IsoInspect.self, IsoList.self]
    )
}

// MARK: - iso inspect

struct IsoInspect: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Show architecture, distro fingerprint, and recommended boot flags for an ISO."
    )

    @Argument(help: "Path to the .iso file.")
    var path: String

    @Flag(name: .customLong("json"), help: "Force JSON output (auto-detected when piped).")
    var emitJSON = false

    @Flag(name: .customLong("text"), help: "Force text output (overrides --json).")
    var emitText = false

    func run() async throws {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            FileHandle.standardError.write(Data("error: ISO not found: \(path)\n".utf8))
            throw ExitCode(2)
        }

        // Architecture
        let arch: ISOInspector.Architecture
        do {
            arch = try ISOInspector.detectArchitecture(at: url)
        } catch {
            FileHandle.standardError.write(Data("error: failed to inspect ISO: \(error)\n".utf8))
            throw ExitCode(1)
        }

        // Size
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))
            .flatMap { ($0[.size] as? NSNumber)?.uint64Value } ?? 0

        // Distro layout — peek into the ISO for a known layout. We
        // shell to bsdtar -tf via LinuxISOExtractor knownLayouts matching
        // logic. Doing a true extract is overkill for inspect; we only
        // need to know if a match exists.
        let layout = detectKnownLayout(iso: url)

        // Catalog match — filename-based.
        let catalogMatch = ISOVerifier.catalogEntry(matching: url)

        // Recommended specs come from catalog when available, else defaults.
        let recMemory: String
        let recCPUs: Int
        let recDiskSize: String
        if let entry = catalogMatch {
            recMemory = formatBytes(entry.recommendedMemoryBytes)
            recCPUs = entry.recommendedCPUs
            recDiskSize = formatBytes(entry.recommendedDiskBytes)
        } else {
            recMemory = "2GB"
            recCPUs = 2
            recDiskSize = "16GB"
        }

        let isJSON = emitJSON || (!emitText && isatty(fileno(stdout)) == 0)

        if isJSON {
            let report = InspectReport(
                path: url.path,
                size_bytes: size,
                architecture: archString(arch),
                distro_layout: layout.map {
                    InspectReport.Layout(
                        name: $0.name,
                        kernel_path: $0.kernel,
                        initramfs_path: $0.initramfs,
                        cmdline_extra: $0.cmdlineExtra
                    )
                },
                catalog_match: catalogMatch.map {
                    InspectReport.CatalogMatch(
                        id: $0.id,
                        display_name: $0.displayName,
                        sha256_expected: $0.sha256
                    )
                },
                recommended: InspectReport.Recommended(
                    memory: recMemory,
                    cpus: recCPUs,
                    disk_size: recDiskSize
                )
            )
            encodeAndPrint(report, pretty: true)
            return
        }

        // Text output
        print("ISO:           \(url.path)")
        print("size:          \(formatBytes(size))")
        print("architecture:  \(archString(arch))")
        if arch == .x86_64 || arch == .riscv64 {
            try? DesktopHelpers.checkArchitecture(url, displayPath: url.path)
        }
        if let layout = layout {
            print("distro layout: \(layout.name)")
            print("  kernel:      \(layout.kernel)")
            print("  initramfs:   \(layout.initramfs)")
            if !layout.cmdlineExtra.isEmpty {
                print("  cmdline:     \(layout.cmdlineExtra)")
            }
        } else {
            print("distro layout: unknown (will boot via plain EFI; --capture-serial unavailable)")
        }
        if let entry = catalogMatch {
            print("catalog:       \(entry.id) (\(entry.displayName))")
            print("  expected sha256: \(entry.sha256)")
        }
        print("recommended:   \(recMemory) memory / \(recCPUs) CPUs / \(recDiskSize) disk")
    }

    /// Best-effort detection of a known LinuxISOExtractor layout via
    /// `bsdtar -tf`. Returns nil when nothing matches or bsdtar fails.
    ///
    /// Pipe-deadlock note: a Debian-class ISO produces ~70 KB of file
    /// listing output, which exceeds the macOS pipe buffer. We MUST drain
    /// stdout (and stderr — see /dev/null pattern below) before calling
    /// `waitUntilExit()`; otherwise bsdtar blocks on write and we hang.
    private func detectKnownLayout(iso: URL) -> KnownLayout? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        proc.arguments = ["-tf", iso.path]
        let stdoutPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return nil
        }
        // Read FIRST — readDataToEndOfFile returns when bsdtar closes
        // stdout (i.e. on exit), at which point waitUntilExit is a
        // no-op. Reversed order deadlocks on >pipe-buffer outputs.
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        guard let stdout = String(data: stdoutData, encoding: .utf8) else { return nil }
        let members = Set(stdout.split(separator: "\n").map(String.init))

        for layout in LinuxISOExtractor.knownLayouts {
            let kHit = members.contains(where: { isoMemberMatches($0, layout.kernel) })
            let iHit = members.contains(where: { isoMemberMatches($0, layout.initramfs) })
            if kHit && iHit {
                return KnownLayout(
                    name: layout.name,
                    kernel: layout.kernel,
                    initramfs: layout.initramfs,
                    cmdlineExtra: layout.cmdlineExtra
                )
            }
        }
        return nil
    }

    /// Mirrors `LinuxISOExtractor.matchesPath` (internal in LuminaBootable).
    /// Accepts the path verbatim, with a leading "./", or with case
    /// differences (Joliet layer can uppercase). Rejects directory entries.
    private func isoMemberMatches(_ member: String, _ target: String) -> Bool {
        if member.hasSuffix("/") { return false }
        if member == target { return true }
        if member == "./" + target { return true }
        if member.lowercased() == target.lowercased() { return true }
        if member.lowercased() == "./" + target.lowercased() { return true }
        return false
    }

    private struct KnownLayout {
        let name: String
        let kernel: String
        let initramfs: String
        let cmdlineExtra: String
    }
}

// MARK: - iso boot

/// Target guest OS family. Drives CD-ROM device choice (Windows
/// requires VZUSBMassStorage; Linux accepts virtio-block) and surfaces
/// distro-specific advisories before boot.
enum IsoTargetOS: String, CaseIterable {
    case auto, linux, windows, macos

    /// Heuristic detection from the ISO filename. Returns `.windows` on
    /// any of `win11/win10/windows/tiny11`, `.macos` on `.ipsw` or
    /// `macos.iso`, and `.linux` otherwise.
    static func detect(forFilename filename: String) -> IsoTargetOS {
        let lower = filename.lowercased()
        if lower.hasSuffix(".ipsw") { return .macos }
        if lower.contains("macos") || lower.contains("osx") { return .macos }
        if lower.contains("windows") || lower.contains("win11") ||
           lower.contains("win10") || lower.contains("tiny11") {
            return .windows
        }
        return .linux
    }
}

struct IsoBoot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "boot",
        abstract: "Boot any ARM64 installer / live ISO. One step, no bundle dance."
    )

    @Option(name: .long, help: "Path to the .iso file to boot.")
    var iso: String

    @Option(name: .long, help: "Persist the VM bundle at this directory. Without this flag, the bundle is ephemeral and removed on clean shutdown.")
    var persist: String?

    @Option(name: .long, help: "Memory allocation (default 2GB). Env: LUMINA_MEMORY.")
    var memory: String = "2GB"

    @Option(name: .long, help: "CPU count (default 2). Env: LUMINA_CPUS.")
    var cpus: Int = 2

    @Option(name: .customLong("disk-size"), help: "Primary virtual disk size (default 16GB). Sparse — actual usage starts near zero.")
    var diskSize: String = "16GB"

    @Option(name: .long, help: "Write serial console output to this file instead of <bundle>/logs/serial.log.")
    var serial: String?

    @Flag(name: .customLong("no-capture-serial"),
          help: "Disable automatic kernel+initramfs extraction. Default: extract when the ISO matches a known layout (Ubuntu/Debian/Alpine/Fedora/Arch arm64) so serial is captured via console=hvc0; otherwise plain EFI boot.")
    var noCaptureSerial = false

    @Option(name: .long, help: "Auto-shutdown after N seconds (0 = run until Ctrl-C).")
    var timeout: Int = 0

    @Flag(name: .long, help: "Mount Rosetta as /run/lumina-rosetta inside Linux guests for x86_64 binary translation.")
    var rosetta = false

    @Flag(name: .long, help: "Open a graphics window (requires GUI host). Default: headless serial-only.")
    var graphics = false

    @Flag(name: .long, help: "Skip ARM64 architecture pre-flight check on the ISO. The boot will fail; this exists for diagnostic / future-arch testing.")
    var force = false

    @Option(name: .customLong("network"),
            help: "Network attachment mode: 'nat' (default) or 'bridged'.")
    var networkMode: String = "nat"

    @Option(name: .customLong("bridge-interface"),
            help: "Host interface to bridge against when --network=bridged.")
    var bridgeInterface: String?

    @Option(name: .customLong("os"),
            help: "Target guest OS: auto (default — filename heuristic), linux, windows, or macos. Drives CD-ROM device type and TPM advisory. macOS is rejected — use `lumina desktop install-macos` with an IPSW.")
    var osHint: String = "auto"

    @Flag(name: .customLong("bypass-tpm-check"), help: .hidden)
    var bypassTpmCheck = false

    func run() async throws {
        installSignalHandlers()

        let isoURL = URL(fileURLWithPath: (iso as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: isoURL.path) else {
            FileHandle.standardError.write(Data("error: ISO not found: \(iso)\n".utf8))
            throw ExitCode(2)
        }

        // Resolve target guest OS.
        let resolvedOS: IsoTargetOS
        switch osHint.lowercased() {
        case "auto":
            resolvedOS = IsoTargetOS.detect(forFilename: isoURL.lastPathComponent)
        case "linux":
            resolvedOS = .linux
        case "windows":
            resolvedOS = .windows
        case "macos":
            resolvedOS = .macos
        default:
            FileHandle.standardError.write(Data(
                "error: --os must be one of: auto, linux, windows, macos (got '\(osHint)')\n".utf8
            ))
            throw ExitCode(2)
        }

        // macOS guests don't ship as ISOs — Apple uses IPSW restore
        // images consumed by VZMacOSInstaller. The CLI surface for
        // macOS lives elsewhere; refuse here with a clear pointer.
        if resolvedOS == .macos {
            let detail: String
            if isoURL.pathExtension.lowercased() == "ipsw" {
                detail = "This looks like an IPSW. macOS guests use VZMacOSInstaller, not VZEFIBootLoader."
            } else {
                detail = "macOS does not distribute installer ISOs. Apple Silicon macOS guests need an IPSW (restore image)."
            }
            let macosMsg = """
                error: \(detail)

                       Use the macOS installation path instead:
                         lumina desktop install-macos --ipsw <path/or/url>

                       Auto-detected from filename. Pass --os linux or
                       --os windows to override if this is wrong.

                """
            FileHandle.standardError.write(Data(macosMsg.utf8))
            throw ExitCode(2)
        }

        if !force {
            try DesktopHelpers.checkArchitecture(isoURL, displayPath: iso)
        }

        try await proceedWithBoot(isoURL: isoURL, targetOS: resolvedOS)
    }

    private func proceedWithBoot(isoURL: URL, targetOS: IsoTargetOS) async throws {
        let (bundleRoot, isEphemeral) = try resolveBundleRoot()
        let bundle = FileManager.default.fileExists(atPath: bundleRoot.appendingPathComponent("manifest.json").path)
            ? DesktopHelpers.loadBundleOrExit(bundleRoot.path)
            : try DesktopHelpers.createBundle(
                at: bundleRoot,
                name: "iso-boot-\(isoURL.deletingPathExtension().lastPathComponent)",
                osFamily: targetOS == .windows ? .windows : .linux,
                osVariant: "iso-\(targetOS.rawValue)",
                memory: resolveMemory(flag: memory),
                cpus: resolveCpus(flag: cpus),
                diskSize: diskSize,
                network: networkMode,
                bridgeInterface: bridgeInterface
            )
        let serialLog = serial ?? bundle.logsDirectory.appendingPathComponent("serial.log").path

        func boot(captureSerial: Bool) async throws {
            var banner = "✓ booted \(isoURL.lastPathComponent) — mode: \(captureSerial ? "linux-direct (serial captured)" : "EFI")\n"
            if !graphics { banner += "  serial log: \(serialLog)\n" }
            if isEphemeral { banner += "  bundle (ephemeral): \(bundleRoot.path)\n" }
            _ = try await DesktopRunner.boot(
                bundle, cdrom: isoURL, graphics: graphics, rosetta: rosetta,
                captureSerial: captureSerial, serialFile: serial, timeout: timeout,
                banner: banner + "  Press Ctrl-C to stop.\n"
            )
        }

        do {
            do {
                try await boot(captureSerial: !noCaptureSerial && targetOS == .linux)
            } catch FirstBootError.unknownLayout(_, let supported) {
                FileHandle.standardError.write(Data(
                    "→ unknown Linux layout — booting via EFI (GRUB). --capture-serial inactive.\n   Supported for capture: \(supported.joined(separator: ", ")).\n".utf8
                ))
                try await boot(captureSerial: false)
            }
        } catch {
            if isEphemeral {
                FileHandle.standardError.write(Data("  bundle preserved for inspection: \(bundleRoot.path)\n".utf8))
            }
            throw error
        }
        if isEphemeral {
            try? FileManager.default.removeItem(at: bundleRoot)
        }
    }

    /// Resolve the bundle root directory and report whether it's
    /// ephemeral. Ephemeral bundles live under `~/.lumina/iso-runs/<uuid>/`
    /// and are removed after a clean shutdown.
    private func resolveBundleRoot() throws -> (URL, isEphemeral: Bool) {
        if let p = persist {
            let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
            if !FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            }
            return (url, false)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let runs = home.appendingPathComponent(".lumina/iso-runs")
        try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)
        // Sweep stale ephemeral bundles older than 7 days.
        cleanupStaleEphemerals(at: runs)
        let unique = runs.appendingPathComponent(UUID().uuidString)
        return (unique, true)
    }

    private func cleanupStaleEphemerals(at runs: URL) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: runs,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        for entry in entries {
            let mod = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date()
            if mod < cutoff {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }
}

// MARK: - iso ls

struct IsoList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls",
        abstract: "List known-good downloadable ARM64 ISOs from the Lumina catalog."
    )

    @Flag(name: .customLong("json"), help: "Force JSON output (auto-detected when piped).")
    var emitJSON = false

    @Flag(name: .customLong("text"), help: "Force text output (overrides --json).")
    var emitText = false

    func run() async throws {
        let isJSON = emitJSON || (!emitText && isatty(fileno(stdout)) == 0)

        if isJSON {
            let entries = DesktopOSCatalog.all.map { entry in
                IsoCatalogEntry(
                    id: entry.id,
                    display_name: entry.displayName,
                    family: entry.family.rawValue,
                    iso_url: entry.isoURL.absoluteString,
                    sha256: entry.sha256,
                    size_bytes: entry.isoSizeBytes,
                    recommended_memory: formatBytes(entry.recommendedMemoryBytes),
                    recommended_cpus: entry.recommendedCPUs,
                    recommended_disk: formatBytes(entry.recommendedDiskBytes)
                )
            }
            encodeAndPrint(entries, pretty: true)
            return
        }

        // Text output: aligned columns.
        let nameWidth = (DesktopOSCatalog.all.map { $0.displayName.count }.max() ?? 30) + 2
        print("ID            \("NAME".padding(toLength: nameWidth, withPad: " ", startingAt: 0))SIZE       URL")
        for entry in DesktopOSCatalog.all {
            let id = entry.id.padding(toLength: 14, withPad: " ", startingAt: 0)
            let name = entry.displayName.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
            let size = formatBytes(entry.isoSizeBytes).padding(toLength: 11, withPad: " ", startingAt: 0)
            print("\(id)\(name)\(size)\(entry.isoURL.absoluteString)")
        }
        print("")
        print("Note: \(DesktopOSCatalog.all.count) catalog entries shown. `lumina iso boot` accepts ANY ARM64 ISO,")
        print("      not just catalog entries. SHA-256 verification is opt-in for catalog matches.")
    }
}

// MARK: - JSON shapes

private struct InspectReport: Encodable {
    let path: String
    let size_bytes: UInt64
    let architecture: String
    let distro_layout: Layout?
    let catalog_match: CatalogMatch?
    let recommended: Recommended

    struct Layout: Encodable {
        let name: String
        let kernel_path: String
        let initramfs_path: String
        let cmdline_extra: String
    }

    struct CatalogMatch: Encodable {
        let id: String
        let display_name: String
        let sha256_expected: String
    }

    struct Recommended: Encodable {
        let memory: String
        let cpus: Int
        let disk_size: String
    }
}

private struct IsoCatalogEntry: Encodable {
    let id: String
    let display_name: String
    let family: String
    let iso_url: String
    let sha256: String
    let size_bytes: UInt64
    let recommended_memory: String
    let recommended_cpus: Int
    let recommended_disk: String
}

// MARK: - Formatting helpers

private func archString(_ a: ISOInspector.Architecture) -> String {
    switch a {
    case .arm64:   return "arm64"
    case .x86_64:  return "x86_64"
    case .riscv64: return "riscv64"
    case .unknown: return "unknown"
    }
}

private func formatBytes(_ bytes: UInt64) -> String {
    let units: [(UInt64, String)] = [
        (1024 * 1024 * 1024, "GB"),
        (1024 * 1024, "MB"),
        (1024, "KB"),
    ]
    for (factor, unit) in units {
        if bytes >= factor {
            let v = Double(bytes) / Double(factor)
            // Whole numbers stay clean; fractions show one decimal.
            if v.truncatingRemainder(dividingBy: 1) == 0 {
                return "\(Int(v))\(unit)"
            }
            return String(format: "%.1f%@", v, unit)
        }
    }
    return "\(bytes)B"
}
