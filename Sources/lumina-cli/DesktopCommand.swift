import ArgumentParser
import Foundation
import Lumina
import LuminaBootable
import Virtualization

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
    static var defaultRoot: URL { VMBundle.libraryRoot }

    static func createBundle(
        at root: URL,
        name: String,
        osFamily: OSFamily,
        osVariant: String,
        memory: String,
        cpus: Int,
        diskSize: String,
        network: String,
        bridgeInterface: String?,
        id: UUID = UUID()
    ) throws -> VMBundle {
        let networkMode: NetworkMode?
        switch network.lowercased() {
        case "nat": networkMode = nil
        case "bridged": networkMode = .bridged(interface: bridgeInterface)
        default:
            FileHandle.standardError.write(Data("error: --network must be 'nat' or 'bridged' (got '\(network)')\n".utf8))
            throw ExitCode(2)
        }
        let memoryBytes = try parseMemoryOrExit(memory)
        let diskBytes = try parseMemoryOrExit(diskSize, what: "disk-size")
        do {
            let bundle = try VMBundle.create(
                at: root, name: name, osFamily: osFamily, osVariant: osVariant,
                memoryBytes: memoryBytes, cpuCount: cpus,
                diskBytes: diskBytes, networkMode: networkMode, id: id
            )
            try DiskImageAllocator.allocate(at: bundle.primaryDiskURL, logicalSize: bundle.manifest.diskBytes)
            return bundle
        } catch VMBundle.Error.alreadyExists(let u) {
            FileHandle.standardError.write(Data("error: \(u.path) already exists\n".utf8))
            throw ExitCode(2)
        } catch {
            FileHandle.standardError.write(Data("error: failed to create bundle at \(root.path): \(error)\n".utf8))
            throw ExitCode(1)
        }
    }

    static func checkArchitecture(_ iso: URL, displayPath: String) throws {
        guard FileManager.default.fileExists(atPath: iso.path) else {
            FileHandle.standardError.write(Data("error: ISO not found: \(displayPath)\n".utf8))
            throw ExitCode(2)
        }
        let arch: ISOInspector.Architecture
        do {
            arch = try ISOInspector.detectArchitecture(at: iso)
        } catch {
            FileHandle.standardError.write(Data("warning: ISO inspection failed (\(error)); proceeding.\n".utf8))
            return
        }
        switch arch {
        case .arm64:
            return
        case .unknown:
            FileHandle.standardError.write(Data(
                "warning: could not detect ISO architecture for \(displayPath); proceeding (pass --force to silence).\n".utf8
            ))
        case .x86_64, .riscv64:
            let name = arch == .x86_64 ? "x86_64" : "RISC-V"
            var msg = """
            error: \(displayPath) is an \(name) ISO. Apple Virtualization (and therefore
                   Lumina) only boots ARM64 (aarch64) guests on Apple Silicon.

            """
            if let entry = DesktopOSCatalog.suggestArm64Equivalent(forFilename: iso.lastPathComponent) {
                msg += "\n       For \(entry.displayName), use the ARM64 build:\n         \(entry.isoURL.absoluteString)\n\n"
            }
            FileHandle.standardError.write(Data((msg + "       To override (will fail to boot), pass --force.\n").utf8))
            throw ExitCode(2)
        }
    }

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

    @Option(name: .customLong("seed"), help: "Directory packed into a 'cidata' ISO on first boot (cloud-init NoCloud, Omarchy autoinstall).")
    var seedPath: String?

    @Flag(name: .customLong("json"), help: "Emit the resulting manifest as JSON.")
    var emitJSON = false

    @Flag(name: .customLong("force"), help: "Skip ARM64 architecture pre-flight check on the ISO.")
    var force = false

    @Flag(name: .customLong("no-verify-iso"),
          help: "Skip SHA-256 verification even when the ISO filename matches a DesktopOSCatalog entry. v0.7.1+: matched ISOs are verified by default.")
    var noVerifyISO = false

    @Option(name: .customLong("network"),
            help: "Network attachment mode: 'nat' (default, vmnet NAT) or 'bridged' (join host LAN, guest DHCPs against your router — bypasses vmnet and fixes the Debian/Kali netcfg DHCP-race).")
    var networkMode: String = "nat"

    @Option(name: .customLong("bridge-interface"),
            help: "Host interface to bridge against when --network=bridged (e.g. 'en0'). Defaults to the first bridgeable interface.")
    var bridgeInterface: String?

    mutating func run() async throws {
        if let iso = isoPath, !force {
            try DesktopHelpers.checkArchitecture(
                URL(fileURLWithPath: (iso as NSString).expandingTildeInPath), displayPath: iso
            )
        }

        // v0.7.1 M3: SHA-256 verification on catalog ISOs. The Desktop
        // wizard has always done this; the CLI parity gap was tracked on
        // the v0.7.1 runway. If the ISO filename matches a
        // `DesktopOSCatalog` entry's URL filename, hash the file and
        // compare. Mismatch = refuse to create (same contract the
        // wizard ships). Non-matched ISOs (BYO distros, Windows MSA,
        // Apple IPSWs) are silently skipped — there's no catalog
        // digest to check against.
        if let iso = isoPath, !noVerifyISO {
            let isoURL = URL(fileURLWithPath: (iso as NSString).expandingTildeInPath)
            if let entry = ISOVerifier.catalogEntry(matching: isoURL) {
                FileHandle.standardError.write(Data(
                    "→ verifying \(entry.displayName) SHA-256 (\(entry.sha256.prefix(8))…)\n".utf8
                ))
                let actual = try ISOVerifier.sha256Hex(ofFileAt: isoURL)
                if actual.lowercased() != entry.sha256.lowercased() {
                    FileHandle.standardError.write(Data("""
                        error: SHA-256 mismatch for \(iso).
                          expected \(entry.sha256)
                          actual   \(actual)
                        The file is corrupted, tampered with, or not the catalog version.
                        Pass --no-verify-iso to skip (not recommended).
                        \n
                        """.utf8))
                    throw ExitCode(2)
                }
                FileHandle.standardError.write(Data("✓ SHA-256 matches\n".utf8))
            }
        }

        let variant = osVariant.lowercased()
        let osFamily: OSFamily = variant.hasPrefix("windows") ? .windows
            : variant.hasPrefix("macos") ? .macOS : .linux

        let id = UUID()
        let rootURL: URL
        if let r = root {
            rootURL = URL(fileURLWithPath: (r as NSString).expandingTildeInPath)
        } else {
            let base = DesktopHelpers.defaultRoot
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            rootURL = base.appendingPathComponent(id.uuidString)
        }

        let bundle = try DesktopHelpers.createBundle(
            at: rootURL, name: name, osFamily: osFamily, osVariant: osVariant,
            memory: memory, cpus: cpus, diskSize: diskSize,
            network: networkMode, bridgeInterface: bridgeInterface, id: id
        )

        if let seed = seedPath {
            let seedURL = URL(fileURLWithPath: (seed as NSString).expandingTildeInPath)
            do {
                try FileManager.default.copyItem(at: seedURL, to: bundle.seedDirectory)
            } catch {
                FileHandle.standardError.write(Data("error: --seed: \(error.localizedDescription)\n".utf8))
                throw ExitCode(2)
            }
        } else if osVariant == "omarchy" {
            try OmarchySeed.write(into: bundle)
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
        abstract: "Boot a .luminaVM bundle."
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

    @Flag(name: .customLong("capture-serial"), help: "Bypass ISO GRUB, boot kernel+initramfs directly via VZLinuxBootLoader with console=hvc0 earlycon=hvc0. Use when --serial captures 0 bytes. Linux only; supported: Ubuntu/Debian/Alpine/Fedora/Arch arm64.")
    var captureSerial = false

    mutating func run() async throws {
        let bundle = DesktopHelpers.loadBundleOrExit(bundlePath)
        if bundle.manifest.osFamily == .macOS {
            _ = try await DesktopRunner.runMacOS(bundle, timeout: timeoutSec, window: !headless)
            return
        }
        do {
            _ = try await DesktopRunner.boot(
                bundle, cdrom: bundle.pendingISO, graphics: !headless, rosetta: rosetta,
                captureSerial: captureSerial, serialFile: serialFile, timeout: timeoutSec,
                banner: "Booted \(bundle.manifest.name). Press Ctrl-C to stop.\n"
            )
        } catch let error as FirstBootError {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            throw ExitCode(1)
        }
    }
}

enum DesktopRunner {
    enum Stop { case signal, timeout, guest }

    static func boot(
        _ bundle: VMBundle,
        cdrom: URL?,
        graphics: Bool,
        rosetta: Bool,
        captureSerial: Bool,
        serialFile: String?,
        timeout: Int,
        banner: String
    ) async throws -> Stop {
        var bundle = bundle
        bundle.ensureMACAddress()
        var cdrom = cdrom
        if cdrom == nil, bundle.manifest.lastBootedAt == nil, let name = InstallerSource.displayName(for: bundle.manifest.osVariant) {
            FileHandle.standardError.write(Data("Downloading \(name) (cached after the first time)…\n".utf8))
            cdrom = try await bundle.fetchInstaller()
        }
        if bundle.manifest.osFamily == .windows, bundle.manifest.lastBootedAt == nil, WindowsDrivers.cachedISO == nil {
            FileHandle.standardError.write(Data("Downloading the virtio drivers Windows needs for networking (~880 MB, cached)…\n".utf8))
            do {
                _ = try await WindowsDrivers.ensure()
            } catch {
                FileHandle.standardError.write(Data("warning: driver download failed (\(error)); Windows will install without network drivers\n".utf8))
            }
        }
        let plan = try prepareFirstBoot(
            bundle: bundle,
            attachedISO: cdrom,
            captureSerial: captureSerial,
            isFirstBoot: bundle.manifest.lastBootedAt == nil
        )
        for event in plan.events {
            FileHandle.standardError.write(Data(formatFirstBootEvent(event).utf8))
        }
        let installing = bundle.manifest.lastBootedAt == nil
            ? ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Installing \(bundle.manifest.name)")
            : nil
        defer { installing.map(ProcessInfo.processInfo.endActivity) }
        var opts = bundle.vmOptions(cdrom: cdrom, plan: plan)
        if let serialFile {
            opts.serialLogURL = URL(fileURLWithPath: (serialFile as NSString).expandingTildeInPath)
        }
        if graphics { opts.graphics = GraphicsConfig() }
        opts.rosetta = rosetta
        let stop = try await run(VM(options: opts), timeout: timeout, window: graphics ? bundle.manifest.name : nil) {
            try? bundle.recordBoot()
            FileHandle.standardError.write(Data(banner.utf8))
        }
        guard stop == .guest, plan.bootDisk != nil, bundle.manifest.lastBootedAt != nil else { return stop }
        FileHandle.standardError.write(Data("Install finished. Starting \(bundle.manifest.name) from its disk…\n".utf8))
        return try await boot(
            bundle, cdrom: nil, graphics: graphics, rosetta: rosetta, captureSerial: false,
            serialFile: serialFile, timeout: timeout, banner: banner
        )
    }

    static func run(
        _ vm: VM,
        timeout: Int,
        window: String? = nil,
        onBooted: () throws -> Void = {}
    ) async throws -> Stop {
        let guestStop = GuestStopSignal()
        await vm.setDelegate(guestStop)

        do {
            try await vm.boot()
        } catch {
            FileHandle.standardError.write(Data("error: boot failed: \(friendlyError(error))\n".utf8))
            throw ExitCode(1)
        }
        try onBooted()
        if let window {
            let machine = await vm.vzMachine().machine
            await DesktopWindow.show(machine, title: window)
        }
        let stop = await waitForStop(guestStop, timeout: timeout)
        await vm.shutdown()
        withExtendedLifetime(guestStop) {}
        return stop
    }

    static func runMacOS(_ bundle: VMBundle, timeout: Int, window: Bool) async throws -> Stop {
        guard bundle.isMacOSInstalled else {
            FileHandle.standardError.write(Data("error: macOS is not installed in this bundle yet; run 'lumina desktop install-macos \(bundle.rootURL.path)'\n".utf8))
            throw ExitCode(1)
        }
        let vm = bundle.macOSVM()
        let guestStop = GuestStopSignal()
        await vm.setDelegate(guestStop)
        do {
            try await vm.boot()
        } catch {
            FileHandle.standardError.write(Data("error: boot failed: \(error)\n".utf8))
            throw ExitCode(1)
        }
        var booted = bundle
        try? booted.recordBoot()
        if window {
            let machine = await vm.vzMachine().machine
            await DesktopWindow.show(machine, title: bundle.manifest.name)
        }
        FileHandle.standardError.write(Data("Booted \(bundle.manifest.name). Press Ctrl-C to stop.\n".utf8))
        let stop = await waitForStop(guestStop, timeout: timeout)
        await vm.shutdown()
        withExtendedLifetime(guestStop) {}
        return stop
    }

    private static func waitForStop(_ guestStop: GuestStopSignal, timeout: Int) async -> Stop {
        let signalQueue = DispatchQueue(label: "com.lumina.desktop.signals")
        let (signals, signalContinuation) = AsyncStream<Int32>.makeStream()
        let sources: [DispatchSourceSignal] = [SIGINT, SIGTERM].map { sig in
            Foundation.signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
            src.setEventHandler { signalContinuation.yield(sig) }
            src.resume()
            return src
        }
        defer {
            sources.forEach { $0.cancel() }
            signalContinuation.finish()
            Foundation.signal(SIGINT, SIG_DFL)
            Foundation.signal(SIGTERM, SIG_DFL)
        }

        let stop = await withTaskGroup(of: Stop?.self) { group -> Stop in
            group.addTask { for await _ in signals { return .signal }; return nil }
            group.addTask { for await _ in guestStop.stream { return .guest }; return nil }
            if timeout > 0 {
                group.addTask {
                    try? await Task.sleep(for: .seconds(timeout))
                    return Task.isCancelled ? nil : .timeout
                }
            }
            defer { group.cancelAll() }
            while let next = await group.next() {
                if let reason = next { return reason }
            }
            return .signal
        }
        switch stop {
        case .signal: FileHandle.standardError.write(Data("\nshutting down…\n".utf8))
        case .timeout: FileHandle.standardError.write(Data("→ --timeout reached, shutting down…\n".utf8))
        case .guest: FileHandle.standardError.write(Data("→ guest powered off\n".utf8))
        }
        return stop
    }
}

private final class GuestStopSignal: NSObject, VZVirtualMachineDelegate, @unchecked Sendable {
    let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    override init() {
        (stream, continuation) = AsyncStream.makeStream()
        super.init()
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) { continuation.yield() }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        continuation.yield()
    }
}

/// Translate a `FirstBootPlan.Event` into the stderr line the CLI has
/// historically emitted for that case. Centralized here so the wire
/// the user sees is identical to v0.7.1, while the orchestrator stays
/// pure.
private func formatFirstBootEvent(_ event: FirstBootPlan.Event) -> String {
    switch event {
    case .linuxDirectMatched(let layoutName):
        return "installer: matched \(layoutName)\n"
    case .linuxDirectUnknownLayoutFallback(let tried, let supported):
        return "error: linux-direct: couldn't find a known kernel layout. "
            + "Supported: \(supported.joined(separator: ", ")). "
            + "Tried: \(tried.joined(separator: ", "))\nfalling back to standard EFI boot\n"
    case .linuxDirectExtractFailed(let reason):
        return "error: linux-direct: ISO extraction failed: \(reason)\nfalling back to standard EFI boot\n"
    case .preseedInjected:
        return "preseed: injected /preseed.cfg into initrd; netcfg/dhcp_retries=4 will defeat the vmnet bootpd race\n"
    case .preseedFailed(let reason):
        return "warning: preseed injection failed (\(reason)); booting unpatched. If DHCP fails in netcfg, click Retry.\n"
    case .autounattendGenerated(let iso):
        return "windows: autounattend sidecar generated at \(iso.lastPathComponent); "
            + "bypasses TPM/SecureBoot/RAM/CPU/Storage checks; skips MSA OOBE\n"
    case .autounattendFailed(let reason):
        return "warning: autounattend generation failed (\(reason)); Win11 Setup may refuse compat check\n"
    case .seedAttached(let iso):
        return "seed: attached \(iso.lastPathComponent) (volume cidata)\n"
    case .seedFailed(let reason):
        return "warning: seed ISO failed (\(reason)); the installer will run interactively\n"
    case .installerBootDisk(let disk):
        return "installer: booting through EFI from \(disk.lastPathComponent)\n"
    case .bootDiskFailed(let reason):
        return "warning: installer boot disk failed (\(reason)); booting the kernel directly, the installed system may not boot\n"
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
        abstract: "Restore macOS into a .luminaVM bundle (downloads the newest supported IPSW unless --ipsw is given)."
    )

    @Argument(help: "Path to the .luminaVM bundle (create it with 'desktop create --os-variant macos').")
    var bundlePath: String

    @Option(name: .customLong("ipsw"), help: "Path to a macOS IPSW file (Apple's restore image).")
    var ipswPath: String?

    mutating func run() async throws {
        var bundle = DesktopHelpers.loadBundleOrExit(bundlePath)
        let ipsw = ipswPath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        if let ipsw, !FileManager.default.fileExists(atPath: ipsw.path) {
            FileHandle.standardError.write(Data("error: IPSW not found: \(ipsw.path)\n".utf8))
            throw ExitCode(2)
        }
        print("Restoring macOS into \(bundle.rootURL.path). This takes 15-30 minutes.")
        let reported = ProgressBucket()
        do {
            try await bundle.installMacOS(ipsw: ipsw) { phase, fraction in
                if reported.advanceTo(phase == .downloading ? Int(fraction * 20) : 21 + Int(fraction * 20)) {
                    print("  \(phase == .downloading ? "downloading" : "installing") \(Int(fraction * 100))%")
                }
            }
        } catch {
            FileHandle.standardError.write(Data("error: install failed: \(error)\n".utf8))
            throw ExitCode(1)
        }
        print("Installation complete. Boot it in Lumina.app or with 'lumina desktop boot'.")
    }
}

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
