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

    func run() async throws {
        let report = await generateReport(fix: fix)

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
        step("vmnet") { checkVmnetBridges() }
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
            // Dry-run: count dirs that would be removed without actually
            // removing them. cleanOrphans doesn't expose a dry-run mode,
            // so we approximate by listing the runs dir.
            let home = FileManager.default.homeDirectoryForCurrentUser
            let runsDir = home.appendingPathComponent(".lumina/runs")
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: runsDir, includingPropertiesForKeys: nil
            )) ?? []
            removed = entries.count  // upper bound
        }
        if removed == 0 {
            return DoctorCheck(
                id: "run-orphans",
                severity: .info,
                title: "No orphan run directories",
                detail: "~/.lumina/runs/ is clean."
            )
        }
        let verb = fix ? "Cleaned" : "Found"
        let hint = fix ? "" : " Pass --fix to remove."
        return DoctorCheck(
            id: "run-orphans",
            severity: .warning,
            title: "\(verb) \(removed) orphan run director(y|ies)",
            detail: "These accumulate from crashed `lumina run` invocations.\(hint)"
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
