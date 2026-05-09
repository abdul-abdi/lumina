// Sources/lumina-cli/IsoCommand.swift
//
// `lumina iso` subcommand tree — v0.7.x.
//
// One-step CLI surface for booting, inspecting, and listing ARM64
// installer / live ISOs without going through the bundle-creation
// dance that `lumina desktop create + boot` requires.
//
// === Design overview ===
//
// Three subcommands:
//
//   lumina iso inspect <path>     arch + distro fingerprint + recommended
//                                 flags, exits 0; rejects only on file-not-
//                                 found (read-only verb).
//   lumina iso boot --iso <path>  one-step boot. Ephemeral disk by default
//                                 (cleaned on shutdown), or persistent at
//                                 --persist <dir>. x86_64 / RISC-V ISOs are
//                                 refused with an actionable message.
//   lumina iso ls                 DesktopOSCatalog entries (downloadable
//                                 known-good distros), JSON when piped.
//
// === Boot path layering (Linux) ===
//
//   1. LinuxISOExtractor.knownLayouts — hand-tuned per-distro
//      (Ubuntu / Debian / Alpine LTS+virt / Fedora / Arch). Each
//      entry carries kernel/initramfs paths AND a cmdlineExtra
//      string that's been verified to reach userspace on hvc0.
//   2. Failure of (1) → plain EFI boot. The user gets a working
//      VM via the ISO's own GRUB; serial capture is unavailable
//      but the bundle's framebuffer (--graphics) works.
//   3. Silent-kernel detection: even when (1) succeeds the kernel
//      may not emit on hvc0 (Debian d-i is the canonical case).
//      A polling task watches `vm.serialOutput` for 8s post-boot;
//      if 0 bytes captured AND --graphics not passed, prints a
//      hint pointing at --graphics or --no-capture-serial.
//
// === OS detection ===
//
//   `IsoTargetOS.detect(forFilename:)` filename heuristic drives
//   CD-ROM device choice (Windows → VZUSBMassStorage so Setup
//   accepts it; Linux → virtio-block) and TPM advisory display.
//   `--os {auto, linux, windows, macos}` forces a specific path.
//
// === Windows TPM bypass ===
//
//   Apple's Virtualization.framework exposes no TPM 2.0. Stock
//   Win11 retail ISOs abort Setup at the readiness check. Pass
//   `--bypass-tpm-check` (Windows-only): generates an
//   autounattend.xml sidecar ISO via `WindowsUnattend.generateISO`
//   that disables BypassTPMCheck/BypassSecureBootCheck/
//   BypassRAMCheck/BypassCPUCheck/BypassStorageCheck under
//   `HKLM\System\Setup\LabConfig` during the windowsPE pass,
//   then attaches it as a second USB mass-storage CD-ROM via
//   `EFIBootConfig.extraCDROMs`. Windows Setup scans drives for
//   autounattend.xml, finds the sidecar, applies the keys before
//   the readiness check fires.
//
// === Non-goals (v1) ===
//
//   - Agent injection / vsock exec against ISO-booted VMs.
//   - `lumina iso run --iso X "cmd"` returning a JSON envelope.
//   - Boot-once-snapshot to convert installer ISOs into Lumina images.
//   - macOS guest CLI surface (use `lumina desktop install-macos`).
//   - Generic grub.cfg variable-expansion parser. Considered for
//     unknown-distro support; rejected because Archboot-style
//     fully scripted grub.cfgs require an actual GRUB interpreter
//     (the kernel/initrd paths live in shell variables expanded
//     at GRUB runtime). The plain-EFI fallback is the right
//     primitive for that case.

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
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            return
        }

        // Text output
        print("ISO:           \(url.path)")
        print("size:          \(formatBytes(size))")
        print("architecture:  \(archString(arch))")
        if arch == .x86_64 || arch == .riscv64 {
            FileHandle.standardError.write(Data(IsoBootHelpers.formatArchRejection(
                isoPath: url.path, arch: arch
            ).utf8))
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

    @Option(name: .long, help: "Mirror serial console output to this file (also written to <bundle>/logs/serial.log).")
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

    @Flag(name: .customLong("bypass-tpm-check"),
          help: "Windows-only: auto-generate an autounattend.xml sidecar ISO that disables Windows 11 Setup's TPM/SecureBoot/RAM/CPU/storage readiness checks. Apple Virtualization.framework has no TPM; without this flag stock Win11 retail ISOs abort Setup before the install-target screen. No-op when target OS is not windows.")
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

        // Windows TPM advisory — Apple's Virtualization.framework has no
        // TPM API, and stock Win11 Home/Pro retail ISOs refuse OOBE
        // without TPM 2.0. Surface this BEFORE booting so the user
        // doesn't waste an install attempt.
        if resolvedOS == .windows {
            FileHandle.standardError.write(Data("""

                ⚠ KNOWN CONSTRAINT: WINDOWS 11 TPM
                  Apple's Virtualization.framework exposes no TPM. Stock Windows 11
                  Home/Pro retail ISOs refuse Setup without TPM 2.0. Workable paths:
                    • Tiny11 ARM ISO (pre-bypassed). Not Microsoft-signed.
                    • Windows Insider Preview ISO (TPM bypass during flighting).
                    • Inject LabConfig\\BypassTPMCheck=1 via unattend.xml on a
                      FAT32 sidecar (advanced).
                  Stock retail ISOs WILL boot to the Setup screen but cannot
                  proceed past the TPM check.

                """.utf8))
        }

        // Pre-flight: architecture check. x86_64 / RISC-V get a friendly
        // refusal (with an ARM64 alternative URL when the filename matches
        // a catalog entry). Inspection failures degrade to a warning —
        // we proceed with boot and let the EFI loader speak truthfully.
        if !force {
            let archResult: Result<ISOInspector.Architecture, any Error> = Result {
                try ISOInspector.detectArchitecture(at: isoURL)
            }
            switch archResult {
            case .success(.arm64):
                break
            case .success(.x86_64):
                FileHandle.standardError.write(Data(IsoBootHelpers.formatArchRejection(
                    isoPath: iso, arch: .x86_64
                ).utf8))
                throw ExitCode(2)
            case .success(.riscv64):
                FileHandle.standardError.write(Data(IsoBootHelpers.formatArchRejection(
                    isoPath: iso, arch: .riscv64
                ).utf8))
                throw ExitCode(2)
            case .success(.unknown):
                FileHandle.standardError.write(Data(
                    "warning: could not detect ISO architecture for \(iso); proceeding (pass --force to silence).\n".utf8
                ))
            case .failure(let err):
                FileHandle.standardError.write(Data(
                    "warning: ISO inspection failed (\(err)); proceeding.\n".utf8
                ))
            }
        }

        try await proceedWithBoot(isoURL: isoURL, targetOS: resolvedOS)
    }

    private func proceedWithBoot(isoURL: URL, targetOS: IsoTargetOS) async throws {
        // Parse memory + disk size.
        let resolvedMemory = resolveMemory(flag: memory)
        let resolvedCPUs = resolveCpus(flag: cpus)
        guard let memBytes = parseMemory(resolvedMemory) else {
            FileHandle.standardError.write(Data(
                "error: invalid memory '\(resolvedMemory)' (expected e.g. 2GB / 512MB)\n".utf8
            ))
            throw ExitCode(2)
        }
        guard let diskBytes = parseMemory(diskSize) else {
            FileHandle.standardError.write(Data(
                "error: invalid disk size '\(diskSize)' (expected e.g. 16GB)\n".utf8
            ))
            throw ExitCode(2)
        }

        // Network mode.
        let parsedNetworkMode: NetworkMode
        switch networkMode.lowercased() {
        case "nat":
            parsedNetworkMode = .nat
        case "bridged":
            parsedNetworkMode = .bridged(interface: bridgeInterface)
        default:
            FileHandle.standardError.write(Data(
                "error: --network must be 'nat' or 'bridged' (got '\(networkMode)')\n".utf8
            ))
            throw ExitCode(2)
        }

        // Resolve / create the bundle directory.
        let (bundleRoot, isEphemeral) = try resolveBundleRoot()

        let bundleOSFamily: OSFamily
        switch targetOS {
        case .linux, .auto: bundleOSFamily = .linux
        case .windows:      bundleOSFamily = .windows
        case .macos:        bundleOSFamily = .macOS  // unreachable — refused earlier
        }

        var bundle: VMBundle
        let manifestPath = bundleRoot.appendingPathComponent("manifest.json")
        if FileManager.default.fileExists(atPath: manifestPath.path) {
            // Existing bundle (persistent, repeat boot).
            bundle = DesktopHelpers.loadBundleOrExit(bundleRoot.path)
        } else {
            // New bundle (ephemeral or first persistent boot).
            do {
                bundle = try VMBundle.create(
                    at: bundleRoot,
                    name: "iso-boot-\(isoURL.deletingPathExtension().lastPathComponent)",
                    osFamily: bundleOSFamily,
                    osVariant: "iso-\(targetOS.rawValue)",
                    memoryBytes: memBytes,
                    cpuCount: resolvedCPUs,
                    diskBytes: diskBytes
                )
            } catch {
                FileHandle.standardError.write(Data(
                    "error: failed to create VM bundle at \(bundleRoot.path): \(error)\n".utf8
                ))
                throw ExitCode(1)
            }
            switch parsedNetworkMode {
            case .nat: break
            case .bridged:
                bundle.manifest.networkMode = parsedNetworkMode
                try? bundle.save()
            }
            // Allocate sparse primary disk.
            do {
                try DiskImageAllocator.allocate(
                    at: bundle.primaryDiskURL, logicalSize: diskBytes
                )
            } catch {
                FileHandle.standardError.write(Data(
                    "error: disk allocation failed: \(error)\n".utf8
                ))
                throw ExitCode(1)
            }
        }

        // --capture-serial extraction (auto-attempted unless opted out
        // OR target is Windows — there's no Linux kernel to extract).
        var captureKernel: URL?
        var captureInitrd: URL?
        var captureCmdline: String?
        if !noCaptureSerial && targetOS == .linux {
            let extractDir = bundle.rootURL.appendingPathComponent("linux-direct")
            do {
                if let arts = try IsoBootHelpers.runCaptureSerialExtraction(
                    iso: isoURL, destination: extractDir, quiet: false
                ) {
                    captureKernel = arts.kernel
                    captureInitrd = arts.initramfs
                    captureCmdline = arts.cmdline
                }
            } catch IsoBootHelpers.CaptureError.unknownLayout(_) {
                // Unknown layout: fall back to plain EFI boot. Surface a
                // hint so `--serial` users aren't surprised by 0 bytes.
                let supported = LinuxISOExtractor.knownLayouts
                    .map { $0.name }
                    .joined(separator: ", ")
                FileHandle.standardError.write(Data(
                    "→ unknown Linux layout — booting via EFI (GRUB). --capture-serial inactive.\n   Supported for capture: \(supported).\n".utf8
                ))
            } catch IsoBootHelpers.CaptureError.extractionFailed(let detail) {
                FileHandle.standardError.write(Data(
                    "warning: kernel/initramfs extraction failed: \(detail). Falling back to plain EFI boot.\n".utf8
                ))
            }
        }

        // Build VMOptions.
        let stableMAC = bundle.ensureMACAddress()
        let isInstallPhase = bundle.manifest.lastBootedAt == nil

        var opts = VMOptions.default
        opts.memory = bundle.manifest.memoryBytes
        opts.cpuCount = bundle.manifest.cpuCount
        opts.macAddress = stableMAC
        switch bundle.manifest.networkMode ?? .nat {
        case .nat:
            opts.networkProvider = NATNetworkProvider()
        case .bridged(let iface):
            opts.networkProvider = BridgedNetworkProvider(interfaceIdentifier: iface)
        }
        opts.serialLogURL = bundle.logsDirectory.appendingPathComponent("serial.log")
        // Windows-only: generate an autounattend.xml sidecar ISO that
        // disables Win11 Setup's TPM/SecureBoot/RAM/CPU/storage
        // readiness checks. The sidecar lives inside the bundle so
        // ephemeral cleanup sweeps it; persistent bundles regenerate
        // it on each boot (cost is ~5 ms).
        var extraCDROMs: [URL] = []
        if targetOS == .windows && bypassTpmCheck {
            let unattendDir = bundle.rootURL.appendingPathComponent("win-unattend")
            do {
                let unattendISO = try WindowsUnattend.allBypasses
                    .generateISO(in: unattendDir)
                extraCDROMs.append(unattendISO)
                FileHandle.standardError.write(Data(
                    "→ TPM bypass: attached autounattend.xml sidecar at \(unattendISO.path)\n".utf8
                ))
            } catch {
                FileHandle.standardError.write(Data(
                    "warning: failed to generate autounattend.xml sidecar (\(error)); proceeding without TPM bypass.\n".utf8
                ))
            }
        } else if targetOS == .windows && !bypassTpmCheck {
            FileHandle.standardError.write(Data(
                "→ tip: pass --bypass-tpm-check to auto-generate an autounattend.xml sidecar that lets stock Win11 retail ISOs proceed past the readiness check.\n".utf8
            ))
        }

        // Windows guests need VZUSBMassStorage CD-ROM (Windows refuses
        // virtio-block-as-CD-ROM with "cannot find media"). Linux
        // accepts either; default to virtio for parity with desktop.
        opts.bootable = .efi(EFIBootConfig(
            variableStoreURL: bundle.efiVarsURL,
            primaryDisk: bundle.primaryDiskURL,
            cdromISO: isoURL,
            preferUSBCDROM: targetOS == .windows,
            installPhase: isInstallPhase,
            linuxDirectKernel: captureKernel,
            linuxDirectInitramfs: captureInitrd,
            linuxDirectCmdline: captureCmdline,
            extraCDROMs: extraCDROMs
        ))
        if graphics {
            opts.graphics = GraphicsConfig(
                widthInPixels: 1920,
                heightInPixels: 1080,
                keyboardKind: .usb,
                pointingDeviceKind: .usbScreenCoordinate
            )
        }
        opts.rosetta = rosetta

        let vm = VM(options: opts)
        bundle.manifest.lastBootedAt = Date()
        try? bundle.save()

        // Optional serial mirror task.
        let serialTask: Task<Void, Never>? = serial.map { path in
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

        // Silent-kernel detection: if --capture-serial is on but the
        // kernel emits nothing in the first 8 seconds, surface a hint
        // pointing at --graphics. Catches Debian d-i and similar
        // installer kernels that boot fine via EFI/framebuffer but
        // don't initialise virtio-console output. The 8s window covers
        // the slowest legitimate cold boot in the test matrix
        // (Archboot ~2.5s, Alpine ~0.6s) with margin.
        let captureSerialActive = (captureKernel != nil)
        let silentKernelHint: Task<Void, Never>? = captureSerialActive ? Task.detached {
            try? await Task.sleep(for: .seconds(8))
            if Task.isCancelled { return }
            let serialBytes = await vm.serialOutput.utf8.count
            if serialBytes == 0 && !graphics {
                FileHandle.standardError.write(Data("""
                    ⚠ silent kernel: 0 bytes on virtio-console (hvc0) after 8s.
                      The kernel booted but isn't emitting to our serial port.
                      Known on Debian d-i and some installer kernels. Workarounds:
                        --graphics            open a framebuffer window
                        --no-capture-serial   plain EFI/GRUB boot (uses ISO's
                                              own console config; serial may
                                              still be silent)
                    \n
                    """.utf8))
            }
        } : nil

        // Boot.
        do {
            try await vm.boot()
        } catch {
            FileHandle.standardError.write(Data(
                "error: boot failed: \(friendlyError(error))\n".utf8
            ))
            // Preserve ephemeral bundle on failure for post-mortem.
            if isEphemeral {
                FileHandle.standardError.write(Data(
                    "  bundle preserved for inspection: \(bundleRoot.path)\n".utf8
                ))
            }
            serialTask?.cancel()
            throw ExitCode(1)
        }

        // Print friendly banner.
        let mode = (captureKernel != nil) ? "linux-direct (serial captured)" : "EFI"
        FileHandle.standardError.write(Data(
            "✓ booted \(isoURL.lastPathComponent) — mode: \(mode)\n".utf8
        ))
        if !graphics {
            FileHandle.standardError.write(Data(
                "  serial log: \(bundle.logsDirectory.appendingPathComponent("serial.log").path)\n".utf8
            ))
        }
        if isEphemeral {
            FileHandle.standardError.write(Data(
                "  bundle (ephemeral): \(bundleRoot.path)\n".utf8
            ))
        }
        FileHandle.standardError.write(Data(
            "  Press Ctrl-C to stop.\n".utf8
        ))

        // Wait for SIGINT/SIGTERM or --timeout.
        let signalQueue = DispatchQueue(label: "com.lumina.iso-boot.signals")
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
            Foundation.signal(SIGINT, SIG_DFL)
            Foundation.signal(SIGTERM, SIG_DFL)
        }

        let timeoutSeconds = timeout
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in signalStream {
                    FileHandle.standardError.write(Data("\nshutting down…\n".utf8))
                    return
                }
            }
            if timeoutSeconds > 0 {
                group.addTask {
                    try? await Task.sleep(for: .seconds(timeoutSeconds))
                    FileHandle.standardError.write(Data(
                        "→ --timeout reached, shutting down…\n".utf8
                    ))
                }
            }
            await group.next()
            group.cancelAll()
        }

        await vm.shutdown()
        serialTask?.cancel()
        silentKernelHint?.cancel()

        // Cleanup ephemeral bundle (only on clean shutdown — failures
        // preserved earlier for post-mortem).
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
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(entries)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
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
