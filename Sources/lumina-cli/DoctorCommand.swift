// Sources/lumina-cli/DoctorCommand.swift
//
// `lumina doctor` — host health check. One-shot diagnostic that
// inspects everything Lumina needs to work well, then reports in
// human-readable text (TTY) or structured JSON (pipe).
//
// Designed to catch the class of failures that manifest as "lumina
// run just hangs" or "cold boot takes 3 seconds" — host-side vmnet
// state, competing VZ workloads, orphan run dirs, missing
// entitlements. These are real issues users hit and currently have
// no good signal for.
//
// Exit codes:
//   0  — healthy (no warnings or errors)
//   1  — warnings present (non-fatal, e.g. orphans, memory pressure)
//   2  — errors present (Lumina won't work until fixed, e.g. missing
//        entitlement, vmnet not functional)

import ArgumentParser
import Darwin
import Foundation
import Lumina
import LuminaBootable

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Host health check — inspect vmnet, images, sessions, entitlements, and surface anything that will slow or break Lumina."
    )

    @Flag(name: .long, help: "Emit structured JSON instead of human-readable text (also auto-detected when piped).")
    var json: Bool = false

    @Flag(name: .long, help: "Fix what's safe to fix automatically (orphan run-dirs). Reports everything else.")
    var fix: Bool = false

    @Option(name: .long, help: "Inspect an ISO file instead of running host checks. Reports arch (arm64 / x86_64 / riscv64 / unknown), size, and boot-loader viability for VZ EFI.")
    var iso: String? = nil

    func run() async throws {
        let report: DoctorReport
        if let iso {
            report = inspectISO(path: iso)
        } else {
            report = await generateReport(fix: fix)
        }

        let wantJSON = json || isatty(fileno(stdout)) == 0
        if wantJSON {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(report) {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
        } else {
            printHumanReport(report)
        }

        // Exit code mirrors severity.
        if report.checks.contains(where: { $0.severity == .error }) {
            throw ExitCode(2)
        } else if report.checks.contains(where: { $0.severity == .warning }) {
            throw ExitCode(1)
        }
    }

    // MARK: - ISO inspect

    /// `lumina doctor --iso <path>` — focused preflight for an installer
    /// ISO. Users hit this path after downloading an OS and before
    /// committing to `lumina desktop create`; a 30-second check beats a
    /// 30-second black-screen at the EFI firmware.
    ///
    /// Checks:
    ///   - File exists + non-empty + plausible size
    ///   - EFI boot architecture via ISOInspector.detectArchitecture() —
    ///     scans first 5MB of the ISO for BOOTAA64/BOOTX64/BOOTRISCV64 EFI
    ///     binary names. Rejects non-arm64 with a pointer at the fix.
    ///
    /// Intentionally omits signature/SHA-256 checks (that's `DesktopOSCatalog`
    /// + `ISOVerifier`, driven by the wizard). Doctor is the hardware-
    /// compat gate; the catalog is the integrity gate.
    private func inspectISO(path: String) -> DoctorReport {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        var checks: [DoctorCheck] = []

        // File existence + size.
        guard FileManager.default.fileExists(atPath: url.path) else {
            checks.append(DoctorCheck(
                id: "iso-file",
                severity: .error,
                title: "ISO not found",
                detail: "No file at \(url.path). Double-check the path."
            ))
            return DoctorReport(
                generatedAt: Date(),
                luminaVersion: "0.7.1",
                host: hostInfo(),
                checks: checks
            )
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
        if size < 32 * 1024 * 1024 {
            checks.append(DoctorCheck(
                id: "iso-size",
                severity: .warning,
                title: "ISO suspiciously small",
                detail: "File is \(formatBytesLocal(size)). A legitimate installer ISO is typically 150 MB+. Partial download?"
            ))
        } else {
            checks.append(DoctorCheck(
                id: "iso-size",
                severity: .info,
                title: "ISO size \(formatBytesLocal(size))",
                detail: "Within the normal range for an installer ISO."
            ))
        }

        // Architecture gate — the big one. ISOInspector scans the first
        // ~5MB of the image for EFI bootloader filenames; cheap, bounded,
        // and authoritative for the common case (all mainstream arm64
        // distros put BOOTAA64.EFI in the first MB).
        let arch: ISOInspector.Architecture
        do {
            arch = try ISOInspector.detectArchitecture(at: url)
        } catch {
            checks.append(DoctorCheck(
                id: "iso-arch",
                severity: .error,
                title: "Couldn't read ISO",
                detail: "\(error). File may be unreadable, corrupted, or a non-ISO container."
            ))
            return DoctorReport(
                generatedAt: Date(),
                luminaVersion: "0.7.1",
                host: hostInfo(),
                checks: checks
            )
        }

        switch arch {
        case .arm64:
            checks.append(DoctorCheck(
                id: "iso-arch",
                severity: .info,
                title: "ARM64 (aarch64) EFI bootloader detected",
                detail: "BOOTAA64.EFI present. This ISO should boot in Lumina Desktop."
            ))
        case .x86_64:
            checks.append(DoctorCheck(
                id: "iso-arch",
                severity: .error,
                title: "x86_64 ISO — will not boot",
                detail:
                    "BOOTX64.EFI present. Apple Silicon's Virtualization.framework does not emulate x86. "
                    + "Download the ARM64 / AArch64 build from the vendor and retry "
                    + "(Microsoft: 'Windows 11 ARM64 ISO', Ubuntu: 'arm64 server install image', "
                    + "Debian: 'netinst arm64')."
            ))
        case .riscv64:
            checks.append(DoctorCheck(
                id: "iso-arch",
                severity: .error,
                title: "RISC-V 64 ISO — will not boot",
                detail: "BOOTRISCV64.EFI present. VZ on Apple Silicon only boots arm64 guests."
            ))
        case .unknown:
            checks.append(DoctorCheck(
                id: "iso-arch",
                severity: .warning,
                title: "Architecture could not be determined",
                detail:
                    "No known EFI bootloader name (BOOTAA64/BOOTX64/BOOTRISCV64) found in the first 5MB. "
                    + "Some legitimate ISOs put the EFI binary deeper and still boot fine. "
                    + "Safe to try — if EFI sits at a black screen for 30s+ the ISO is probably unsuitable."
            ))
        }

        return DoctorReport(
            generatedAt: Date(),
            luminaVersion: "0.7.1",
            host: hostInfo(),
            checks: checks
        )
    }

    private func formatBytesLocal(_ bytes: UInt64) -> String {
        if bytes >= 1_073_741_824 {
            return String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
        } else if bytes >= 1_048_576 {
            return String(format: "%.0f MB", Double(bytes) / 1_048_576)
        }
        return "\(bytes) B"
    }

    // MARK: - Report generation

    private func generateReport(fix: Bool) async -> DoctorReport {
        var checks: [DoctorCheck] = []
        func step(_ name: String, _ body: () -> DoctorCheck) {
            if ProcessInfo.processInfo.environment["LUMINA_DOCTOR_TRACE"] == "1" {
                FileHandle.standardError.write(Data("doctor: \(name)…\n".utf8))
            }
            checks.append(body())
        }
        step("entitlements") { checkEntitlements() }
        step("memory") { checkMemoryPressure() }
        step("vz-processes") { checkCompetingVZProcesses() }
        step("vmnet-holders") { checkCompetingVmnetHolders() }
        step("vmnet") { checkVmnetBridges() }
        step("vmnet-leak") { checkVmnetInterfaceLeak() }
        step("images") { checkImages() }
        if ProcessInfo.processInfo.environment["LUMINA_DOCTOR_TRACE"] == "1" {
            FileHandle.standardError.write(Data("doctor: sessions…\n".utf8))
        }
        checks.append(await checkSessions())
        step("run-orphans") { checkRunOrphans(fix: fix) }
        step("home-layout") { checkHomeLayout() }

        return DoctorReport(
            generatedAt: Date(),
            luminaVersion: "0.7.1",
            host: hostInfo(),
            checks: checks
        )
    }

    // MARK: - Individual checks

    private func checkEntitlements() -> DoctorCheck {
        // If we're running, we almost certainly have the
        // Virtualization entitlement — but the lumina binary at
        // $PATH might differ from this one. Check both.
        //
        // ProcessInfo.arguments[0] is the invoked path.
        let argv0 = ProcessInfo.processInfo.arguments.first ?? "/usr/local/bin/lumina"
        let hasEnt = checkBinaryHasEntitlement(
            path: argv0,
            key: "com.apple.security.virtualization"
        )
        if hasEnt {
            return DoctorCheck(
                id: "entitlements",
                severity: .info,
                title: "Binary entitlements present",
                detail: "Running binary at \(argv0) has com.apple.security.virtualization."
            )
        } else {
            return DoctorCheck(
                id: "entitlements",
                severity: .error,
                title: "Missing Virtualization entitlement",
                detail: "The running lumina binary at \(argv0) lacks com.apple.security.virtualization. Boot will fail with VZErrorDomain Code 2. Re-run: codesign --entitlements lumina.entitlements --force -s - \(argv0)"
            )
        }
    }

    private func checkBinaryHasEntitlement(path: String, key: String) -> Bool {
        let output = runAndCapture(path: "/usr/bin/codesign",
                                   args: ["-d", "--entitlements", ":-", path])
        return output.stdout.contains(key) || output.stderr.contains(key)
    }

    /// Run a subprocess and return its captured stdout + stderr. Reads
    /// pipes BEFORE `waitUntilExit` to avoid the classic deadlock where
    /// a child blocks on pipe-write when the pipe buffer (≤64KB) fills
    /// and the parent blocks on waitUntilExit — neither can progress.
    private struct ProcessOutput {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    private func runAndCapture(path: String, args: [String]) -> ProcessOutput {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
        } catch {
            return ProcessOutput(stdout: "", stderr: "\(error)", exitCode: -1)
        }
        // Drain pipes concurrently on background queues so neither
        // fills before the child exits. DispatchGroup synchronizes
        // the writes against the reads below — the `@unchecked`
        // holder is safe because no access overlaps group.wait().
        final class Buffers: @unchecked Sendable {
            var out = Data()
            var err = Data()
        }
        let buf = Buffers()
        let outQueue = DispatchQueue(label: "doctor.out")
        let errQueue = DispatchQueue(label: "doctor.err")
        let group = DispatchGroup()
        group.enter()
        outQueue.async {
            buf.out = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        errQueue.async {
            buf.err = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        proc.waitUntilExit()
        group.wait()
        return ProcessOutput(
            stdout: String(data: buf.out, encoding: .utf8) ?? "",
            stderr: String(data: buf.err, encoding: .utf8) ?? "",
            exitCode: proc.terminationStatus
        )
    }

    private func checkMemoryPressure() -> DoctorCheck {
        // vm_stat output: `Pages free` / `Pages inactive` / etc.
        let result = runAndCapture(path: "/usr/bin/vm_stat", args: [])
        if result.exitCode != 0 {
            return DoctorCheck(id: "memory", severity: .warning,
                               title: "Couldn't query memory", detail: "vm_stat failed")
        }
        let str = result.stdout

        // Parse "Pages free:  12345."
        func parsePages(_ label: String) -> Int? {
            for line in str.split(separator: "\n") {
                if line.hasPrefix(label) {
                    let digits = line.filter { $0.isNumber }
                    return Int(digits)
                }
            }
            return nil
        }
        guard let free = parsePages("Pages free:"),
              let active = parsePages("Pages active:"),
              let inactive = parsePages("Pages inactive:"),
              let wired = parsePages("Pages wired down:"),
              let spec = parsePages("Pages speculative:") else {
            return DoctorCheck(id: "memory", severity: .warning,
                               title: "Couldn't parse vm_stat",
                               detail: "Memory pressure check skipped")
        }
        let total = free + active + inactive + wired + spec
        let freePct = Double(free + inactive + spec) / Double(total)
        let freeMb = (free + inactive + spec) * 16384 / 1_048_576

        if freePct < 0.05 {
            return DoctorCheck(
                id: "memory",
                severity: .warning,
                title: "Low memory available",
                detail: String(format: "Only %.1f%% free (~%d MB). VM cold-boot will be slow; 512 MB per VM recommended.", freePct * 100, freeMb)
            )
        }
        return DoctorCheck(
            id: "memory",
            severity: .info,
            title: "Memory pressure OK",
            detail: String(format: "%.1f%% available (~%d MB).", freePct * 100, freeMb)
        )
    }

    private func checkCompetingVZProcesses() -> DoctorCheck {
        let result = runAndCapture(path: "/bin/ps", args: ["ax", "-o", "pid,etime,command"])
        if result.exitCode != 0 {
            return DoctorCheck(id: "vz-processes", severity: .info,
                               title: "VZ processes",
                               detail: "ps unavailable; check skipped")
        }
        let str = result.stdout

        // Count VZ XPC helpers. Each running VM has one.
        let vzLines = str.split(separator: "\n").filter {
            $0.contains("Virtualization.VirtualMachine.xpc")
        }
        let count = vzLines.count

        if count == 0 {
            return DoctorCheck(
                id: "vz-processes",
                severity: .info,
                title: "No VZ processes running",
                detail: "Clean host state."
            )
        } else if count <= 3 {
            return DoctorCheck(
                id: "vz-processes",
                severity: .info,
                title: "\(count) VZ VM(s) running",
                detail: "Other VMs may compete for vmnet resources; this is normal up to ~10 on 18 GB hosts."
            )
        } else {
            return DoctorCheck(
                id: "vz-processes",
                severity: .warning,
                title: "\(count) VZ VMs — approaching host ceiling",
                detail: "Heavy VZ contention. vmnet-NAT may degrade (bridge allocations become flaky). Consider stopping unused VMs."
            )
        }
    }

    /// Other tools that hold vmnet NAT state collide with VZ's attempt
    /// to allocate its own bridge on the same subnet. Apple's `container`
    /// CLI with `--variant reserved` is the one observed in the wild.
    /// When it's running, `lumina run` silently gets a bridge with no
    /// IPv4; guest boots, gets an IP, but every outbound packet fails
    /// with "Network unreachable." The symptom is invisible until you
    /// `nslookup` from inside the guest — exactly the class of failure
    /// this doctor entry exists to make loud.
    private func checkCompetingVmnetHolders() -> DoctorCheck {
        let result = runAndCapture(path: "/bin/ps", args: ["ax", "-o", "pid,command"])
        if result.exitCode != 0 {
            return DoctorCheck(id: "vmnet-holders", severity: .info,
                               title: "vmnet holders", detail: "ps unavailable; skipped")
        }

        // Each entry: (matching-process-substring, friendly-name, fix hint).
        let knownHolders: [(needle: String, name: String, hint: String)] = [
            (
                needle: "container-network-vmnet",
                name: "Apple `container` CLI",
                hint: "Run `container system stop` to release vmnet. Restart later with `container system start` when you need container again."
            ),
        ]

        var found: [(String, String, String)] = []
        for line in result.stdout.split(separator: "\n") {
            let s = String(line)
            for h in knownHolders where s.contains(h.needle) {
                found.append((h.name, h.hint, s.trimmingCharacters(in: .whitespaces)))
                break
            }
        }

        if found.isEmpty {
            return DoctorCheck(
                id: "vmnet-holders",
                severity: .info,
                title: "No competing vmnet holders",
                detail: "No known NAT-reserving processes running."
            )
        }

        let names = found.map { $0.0 }.joined(separator: ", ")
        let hints = found.map { "- \($0.0): \($0.1)" }.joined(separator: "\n")
        return DoctorCheck(
            id: "vmnet-holders",
            severity: .error,
            title: "Competing vmnet holder(s): \(names)",
            detail:
                "Another tool has reserved vmnet's NAT subnet. VZ will silently fail to allocate a bridge IP; "
                + "every `lumina run` will appear to boot but outbound packets will hit 'Network unreachable'. "
                + "Fix:\n\(hints)"
        )
    }

    /// Count leaked `vmenetNN` interfaces. Each VZ VM boot pairs a
    /// host-side `bridgeNN` (ephemeral) with a guest-side `vmenetNN`.
    /// On clean shutdown both are destroyed. On crash or hard-kill the
    /// `vmenet*` leaks and accumulates across runs. Past ~20 leaked
    /// interfaces, vmnet's allocator starts refusing new bridges and
    /// VZ NAT attachments come up with no IPv4 — same silent-fail
    /// signature as the competing-holder case above.
    ///
    /// The only clean recovery is a host reboot (`ifconfig vmenet*
    /// destroy` needs sudo and doesn't always work on newer kernels).
    /// Flagging loudly here is the difference between a user spending
    /// an afternoon chasing a Lumina bug and spending 30 seconds
    /// rebooting.
    private func checkVmnetInterfaceLeak() -> DoctorCheck {
        let result = runAndCapture(path: "/sbin/ifconfig", args: ["-a"])
        if result.exitCode != 0 {
            return DoctorCheck(id: "vmnet-leak", severity: .info,
                               title: "vmnet leak check skipped",
                               detail: "ifconfig unavailable")
        }

        var vmenetCount = 0
        for line in result.stdout.split(separator: "\n") {
            // Interface lines start at column 0 with the name + ":".
            let s = String(line)
            if s.hasPrefix("vmenet") {
                vmenetCount += 1
            }
        }

        if vmenetCount == 0 {
            return DoctorCheck(
                id: "vmnet-leak",
                severity: .info,
                title: "No leaked vmenet interfaces",
                detail: "Clean vmnet state."
            )
        }
        if vmenetCount < 8 {
            return DoctorCheck(
                id: "vmnet-leak",
                severity: .info,
                title: "\(vmenetCount) vmenet interface(s) present",
                detail: "Normal — in-flight VMs each register one."
            )
        }
        if vmenetCount < 20 {
            return DoctorCheck(
                id: "vmnet-leak",
                severity: .warning,
                title: "\(vmenetCount) vmenet interfaces — accumulating",
                detail:
                    "Some prior VM shutdowns leaked their guest-side vmnet interface. Not yet fatal but close. "
                    + "If networking starts silently failing, reboot to flush vmnet state."
            )
        }
        return DoctorCheck(
            id: "vmnet-leak",
            severity: .error,
            title: "\(vmenetCount) leaked vmenet interfaces — vmnet is saturated",
            detail:
                "vmnet's bridge allocator won't give VZ a working IPv4 bridge in this state. "
                + "Every `lumina run` will silently boot but outbound packets will hit 'Network unreachable'. "
                + "The only reliable fix is to reboot the host — `ifconfig vmenetN destroy` requires root "
                + "and doesn't always stick on newer macOS kernels. After reboot, re-run `lumina doctor` "
                + "to confirm the count drops to 0."
        )
    }

    private func checkVmnetBridges() -> DoctorCheck {
        // VZ NAT creates bridge100, bridge101, … with an IP like
        // 192.168.64.1. bridge0 is a system-owned bridge (en0-style,
        // unrelated). Filter for bridgeN where N ≥ 100 — the vmnet-
        // managed range that VZ uses for NAT attachments.
        let result = runAndCapture(path: "/sbin/ifconfig", args: [])
        if result.exitCode != 0 {
            return DoctorCheck(id: "vmnet", severity: .warning,
                               title: "ifconfig unavailable",
                               detail: "Can't inspect vmnet bridges")
        }

        var bridges: [(name: String, ipv4: String?)] = []
        var current: String? = nil
        var currentIP: String? = nil
        for line in result.stdout.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            if s.hasPrefix("bridge") {
                if let name = current { bridges.append((name, currentIP)) }
                let comp = s.split(separator: ":").first.map { String($0) } ?? s
                current = comp
                currentIP = nil
            } else if s.contains("\tinet "), current != nil {
                let trimmed = s.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("inet ") {
                    let parts = trimmed.split(separator: " ")
                    if parts.count >= 2 {
                        currentIP = String(parts[1])
                    }
                }
            }
        }
        if let name = current { bridges.append((name, currentIP)) }

        // Filter to vmnet range: bridgeN where N ≥ 100.
        let vmnetBridges = bridges.filter { b in
            guard b.name.hasPrefix("bridge") else { return false }
            let suffix = String(b.name.dropFirst("bridge".count))
            guard let n = Int(suffix) else { return false }
            return n >= 100
        }
        let withIP = vmnetBridges.filter { $0.ipv4 != nil }

        if vmnetBridges.isEmpty {
            return DoctorCheck(
                id: "vmnet",
                severity: .info,
                title: "No vmnet bridges yet",
                detail: "No VZ NAT bridges (bridge100+) visible. A bridge will spawn on the next `lumina run`."
            )
        }
        if withIP.isEmpty {
            let names = vmnetBridges.map { $0.name }.joined(separator: ", ")
            return DoctorCheck(
                id: "vmnet",
                severity: .warning,
                title: "vmnet bridges up but no IPv4",
                detail: "Bridges \(names) exist without IPv4 addresses. vmnet DHCP allocation is degraded. Next `lumina run` will emit stage=timeout-anyway. Common causes: competing VZ workloads holding bridges, stale state after VZ crash. Restart affected VMs or reboot vmnet."
            )
        }
        let summary = withIP.map { "\($0.name) → \($0.ipv4!)" }
            .joined(separator: ", ")
        return DoctorCheck(
            id: "vmnet",
            severity: .info,
            title: "vmnet bridges healthy",
            detail: summary
        )
    }

    private func checkImages() -> DoctorCheck {
        let store = ImageStore()
        let names = store.list()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let baseDir = home.appendingPathComponent(".lumina/images")

        if names.isEmpty {
            return DoctorCheck(
                id: "images",
                severity: .warning,
                title: "No images installed",
                detail: "Run `lumina pull` to download the default image."
            )
        }

        var issues: [String] = []
        for name in names {
            let dir = baseDir.appendingPathComponent(name)
            let rootfs = dir.appendingPathComponent("rootfs.img")
            let vmlinuz = dir.appendingPathComponent("vmlinuz")
            if !FileManager.default.fileExists(atPath: rootfs.path) {
                issues.append("\(name): missing rootfs.img")
            }
            if !FileManager.default.fileExists(atPath: vmlinuz.path) {
                issues.append("\(name): missing vmlinuz")
            }
        }
        if issues.isEmpty {
            return DoctorCheck(
                id: "images",
                severity: .info,
                title: "\(names.count) image(s) installed",
                detail: names.joined(separator: ", ")
            )
        }
        return DoctorCheck(
            id: "images",
            severity: .error,
            title: "Image integrity issues",
            detail: issues.joined(separator: "; ")
        )
    }

    private func checkSessions() async -> DoctorCheck {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let sessionsDir = home.appendingPathComponent(".lumina/sessions")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: sessionsDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return DoctorCheck(
                id: "sessions",
                severity: .info,
                title: "No sessions directory",
                detail: "No live sessions."
            )
        }

        var badPerms: [String] = []
        var live = 0
        for entry in entries {
            let sock = entry.appendingPathComponent("control.sock")
            if FileManager.default.fileExists(atPath: sock.path) {
                live += 1
                var st = stat()
                if stat(sock.path, &st) == 0 {
                    let perms = Int(st.st_mode) & 0o777
                    if perms != 0o600 {
                        badPerms.append("\(entry.lastPathComponent): mode \(String(perms, radix: 8)) (expected 600)")
                    }
                }
            }
        }

        if !badPerms.isEmpty {
            return DoctorCheck(
                id: "sessions",
                severity: .warning,
                title: "Session sockets with weak perms",
                detail: "Other users may be able to connect to: \(badPerms.joined(separator: "; ")). Restart the affected sessions on v0.7.1+ to auto-chmod."
            )
        }
        return DoctorCheck(
            id: "sessions",
            severity: .info,
            title: "\(live) live session(s)",
            detail: live == 0 ? "No live sessions." : "All session sockets 0600."
        )
    }

    private func checkRunOrphans(fix: Bool) -> DoctorCheck {
        let removed: Int
        if fix {
            removed = DiskClone.cleanOrphans()
        } else {
            // Dry-run: we don't actually call cleanOrphans (no dry-run
            // mode on the store), so this counts every entry in runs/
            // including live in-flight runs from other processes. The
            // wording below makes that upper-bound explicit.
            let home = FileManager.default.homeDirectoryForCurrentUser
            let runsDir = home.appendingPathComponent(".lumina/runs")
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: runsDir, includingPropertiesForKeys: nil
            )) ?? []
            removed = entries.count
        }
        if removed == 0 {
            return DoctorCheck(
                id: "run-orphans",
                severity: .info,
                title: "No orphan run directories",
                detail: "~/.lumina/runs/ is clean."
            )
        }
        if fix {
            return DoctorCheck(
                id: "run-orphans",
                severity: .warning,
                title: "Cleaned \(removed) orphan run director\(removed == 1 ? "y" : "ies")",
                detail: "These accumulated from crashed `lumina run` invocations."
            )
        }
        return DoctorCheck(
            id: "run-orphans",
            severity: .warning,
            title: "Up to \(removed) run director\(removed == 1 ? "y" : "ies") in ~/.lumina/runs/",
            detail: "Some may be live runs from other processes; pass --fix to sweep only the ones whose owning `lumina run` has exited."
        )
    }

    private func checkHomeLayout() -> DoctorCheck {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let subdirs = ["images", "sessions", "volumes", "runs", "cache"]
        var missing: [String] = []
        for sub in subdirs {
            let path = home.appendingPathComponent(".lumina/\(sub)")
            var isDir: ObjCBool = false
            if !FileManager.default.fileExists(atPath: path.path, isDirectory: &isDir) {
                missing.append(sub)
            }
        }
        // `runs` and `cache` are created lazily; not having them is fine.
        let expected = ["images", "sessions", "volumes"]
        let criticallyMissing = missing.filter { expected.contains($0) }
        if criticallyMissing.isEmpty {
            return DoctorCheck(
                id: "home-layout",
                severity: .info,
                title: "~/.lumina/ layout looks OK",
                detail: "Core subdirs present."
            )
        }
        return DoctorCheck(
            id: "home-layout",
            severity: .info,
            title: "~/.lumina/ partially initialised",
            detail: "Missing (created on demand): \(criticallyMissing.joined(separator: ", "))"
        )
    }

    // MARK: - Host info

    private func hostInfo() -> DoctorHost {
        var unameInfo = utsname()
        uname(&unameInfo)
        let osName = withUnsafePointer(to: &unameInfo.sysname) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) {
                String(cString: $0)
            }
        }
        let osRelease = withUnsafePointer(to: &unameInfo.release) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) {
                String(cString: $0)
            }
        }
        let arch = withUnsafePointer(to: &unameInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) {
                String(cString: $0)
            }
        }
        return DoctorHost(
            os: "\(osName) \(osRelease)",
            arch: arch,
            cpuCount: ProcessInfo.processInfo.processorCount
        )
    }

    // MARK: - Human printer

    private func printHumanReport(_ report: DoctorReport) {
        print("lumina doctor — host health check")
        print(String(repeating: "=", count: 34))
        print("version: \(report.luminaVersion)")
        print("host:    \(report.host.os), \(report.host.arch), \(report.host.cpuCount) cores")
        print("")
        for check in report.checks {
            let icon: String
            switch check.severity {
            case .info:    icon = "  ✓"
            case .warning: icon = "  ⚠"
            case .error:   icon = "  ✘"
            }
            print("\(icon) \(check.title)")
            if !check.detail.isEmpty {
                print("    \(check.detail)")
            }
        }
        print("")
        let errs = report.checks.filter { $0.severity == .error }.count
        let warns = report.checks.filter { $0.severity == .warning }.count
        if errs > 0 {
            print("\(errs) error(s), \(warns) warning(s). Lumina may not work until errors are fixed.")
        } else if warns > 0 {
            print("\(warns) warning(s). Lumina will work; some paths may be degraded.")
        } else {
            print("All checks passed. 🚀")
        }
    }
}

// MARK: - Report types

private struct DoctorReport: Codable {
    let generatedAt: Date
    let luminaVersion: String
    let host: DoctorHost
    let checks: [DoctorCheck]
}

private struct DoctorHost: Codable {
    let os: String
    let arch: String
    let cpuCount: Int
}

private struct DoctorCheck: Codable {
    let id: String
    let severity: Severity
    let title: String
    let detail: String

    enum Severity: String, Codable {
        case info
        case warning
        case error
    }
}
