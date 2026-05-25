// Sources/LuminaBootable/WindowsUnattend.swift
//
// Generates a NoCloud-style sidecar ISO containing an
// `autounattend.xml` that makes stock Windows 11 (Home/Pro/Enterprise)
// retail ARM64 ISOs install on Apple Silicon hosts.
//
// The problem this solves:
//   Apple Virtualization.framework on macOS 14+ exposes no TPM 2.0
//   device. Stock Windows 11 retail ISOs run a hardware-readiness
//   check during Setup's windowsPE pass and abort with "This PC
//   doesn't currently meet Windows 11 system requirements" before
//   the install-target screen, regardless of the user's actual CPU /
//   RAM / disk. Microsoft documents the bypass via four registry
//   keys under `HKLM\System\Setup\LabConfig`. Windows Setup applies
//   `autounattend.xml` automatically when a removable drive
//   containing the file at its root is attached during boot, so we
//   ship the bypass keys via a sidecar CD-ROM ISO that
//   `lumina iso boot --os windows --bypass-tpm-check` attaches
//   alongside the user's installer.
//
// The bypass keys (LabConfig pass=windowsPE):
//   BypassTPMCheck         = 1   (skip TPM 2.0 check)
//   BypassSecureBootCheck  = 1   (skip Secure Boot enforcement)
//   BypassRAMCheck         = 1   (skip 4 GB minimum)
//   BypassCPUCheck         = 1   (skip 2-core / 1 GHz / 64-bit /
//                                   compatible-CPU check)
//   BypassStorageCheck     = 1   (skip 64 GB system drive minimum)
//
// Layout of the generated ISO:
//   /autounattend.xml
//
// Volume label is "WIN" (length 1-11 chars per ISO9660 / Joliet);
// Windows Setup scans by content, not by label, so the label is
// purely cosmetic. We ship a stable label so the user's
// File Explorer and any debug logs identify the drive consistently.
//
// Why not FAT32 image: Windows Setup reads autounattend.xml from any
// recognized filesystem on any drive present at boot — CD-ROM
// (ISO9660), FAT, exFAT, NTFS. ISO9660 is the cheapest to generate
// from macOS without root (`hdiutil makehybrid` ships in every
// macOS install). It also matches the `CloudInitSeed` pattern in
// this same target, keeping the host-side toolchain consistent.

import Foundation

public struct WindowsUnattend: Sendable, Equatable {
    public var bypassTPMCheck: Bool
    public var bypassSecureBootCheck: Bool
    public var bypassRAMCheck: Bool
    public var bypassCPUCheck: Bool
    public var bypassStorageCheck: Bool

    public init(
        bypassTPMCheck: Bool = true,
        bypassSecureBootCheck: Bool = true,
        bypassRAMCheck: Bool = true,
        bypassCPUCheck: Bool = true,
        bypassStorageCheck: Bool = true
    ) {
        self.bypassTPMCheck = bypassTPMCheck
        self.bypassSecureBootCheck = bypassSecureBootCheck
        self.bypassRAMCheck = bypassRAMCheck
        self.bypassCPUCheck = bypassCPUCheck
        self.bypassStorageCheck = bypassStorageCheck
    }

    /// All five Win11-on-VZ bypass keys enabled. Matches what the
    /// Desktop wizard's `windowsTPMAdvisory` view recommends as the
    /// "advanced via unattend.xml" path.
    public static let allBypasses = WindowsUnattend()

    public enum Error: Swift.Error, Equatable {
        case writeFailed(URL, String)
        case hdiutilNotAvailable
        case hdiutilFailed(Int32, String)
    }

    /// Render the autounattend.xml content.
    ///
    /// Format reference: Microsoft's Unattended Windows Setup Reference
    /// (`Microsoft-Windows-Setup` component, `RunSynchronous` element).
    /// `windowsPE` pass runs before disk selection — which is when
    /// the readiness check fires — so all bypass keys must land there.
    public func generateXML() -> String {
        var commands: [(order: Int, command: String)] = []
        var nextOrder = 1
        func appendBypass(_ enabled: Bool, name: String) {
            guard enabled else { return }
            // Raw string (#"..."#) — backslashes are literal. The
            // Windows registry path uses single `\` per component;
            // doubled `\\` produces "path not found" at reg.exe time.
            let cmd = #"cmd /c reg add HKLM\System\Setup\LabConfig /v "# + name + #" /t REG_DWORD /d 1 /f"#
            commands.append((nextOrder, cmd))
            nextOrder += 1
        }
        appendBypass(bypassTPMCheck, name: "BypassTPMCheck")
        appendBypass(bypassSecureBootCheck, name: "BypassSecureBootCheck")
        appendBypass(bypassRAMCheck, name: "BypassRAMCheck")
        appendBypass(bypassCPUCheck, name: "BypassCPUCheck")
        appendBypass(bypassStorageCheck, name: "BypassStorageCheck")

        let entries = commands.map { (order, cmd) in
            """
                            <RunSynchronousCommand wcm:action="add">
                                <Order>\(order)</Order>
                                <Path>\(cmd)</Path>
                                <Description>Lumina Win11 readiness bypass — \(commandDescription(cmd))</Description>
                            </RunSynchronousCommand>
            """
        }.joined(separator: "\n")

        return """
        <?xml version="1.0" encoding="utf-8"?>
        <unattend xmlns="urn:schemas-microsoft-com:unattend">
            <settings pass="windowsPE">
                <component name="Microsoft-Windows-Setup"
                           processorArchitecture="arm64"
                           publicKeyToken="31bf3856ad364e35"
                           language="neutral"
                           versionScope="nonSxS"
                           xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
                           xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
                    <RunSynchronous>
        \(entries)
                    </RunSynchronous>
                </component>
            </settings>
        </unattend>
        """
    }

    private func commandDescription(_ cmd: String) -> String {
        if cmd.contains("BypassTPMCheck") { return "skip TPM 2.0 check" }
        if cmd.contains("BypassSecureBootCheck") { return "skip Secure Boot check" }
        if cmd.contains("BypassRAMCheck") { return "skip 4 GB RAM minimum" }
        if cmd.contains("BypassCPUCheck") { return "skip CPU compatibility check" }
        if cmd.contains("BypassStorageCheck") { return "skip 64 GB storage minimum" }
        return "Lumina bypass"
    }

    /// Generate the sidecar ISO under `directory/win-unattend.iso`. The
    /// ISO is read-only, ~4 KB on disk, and contains exactly one file
    /// (`autounattend.xml` at root). Caller is responsible for
    /// removing the file when the VM shuts down — the Lumina ISO-runs
    /// cleanup path handles ephemeral bundles automatically.
    public func generateISO(in directory: URL) throws -> URL {
        let hdiutilPath = "/usr/bin/hdiutil"
        guard FileManager.default.isExecutableFile(atPath: hdiutilPath) else {
            throw Error.hdiutilNotAvailable
        }

        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let outURL = directory.appendingPathComponent("win-unattend.iso")
        // hdiutil makehybrid refuses to overwrite an existing output
        // file. Boot-path callers want the ISO regenerated on every
        // boot (so changes to the bypass flags take effect), so
        // remove any prior copy first. Idempotent — missing file is
        // not an error.
        try? FileManager.default.removeItem(at: outURL)
        let staging = directory.appendingPathComponent("unattend-staging-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }

        do {
            try FileManager.default.createDirectory(
                at: staging, withIntermediateDirectories: true
            )
            try Data(generateXML().utf8).write(
                to: staging.appendingPathComponent("autounattend.xml")
            )
        } catch {
            throw Error.writeFailed(staging, "\(error)")
        }

        // hdiutil makehybrid — same pattern as CloudInitSeed. ISO9660
        // + Joliet for case preservation; volume label "WIN" is
        // cosmetic but consistent.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: hdiutilPath)
        proc.arguments = [
            "makehybrid",
            "-iso",
            "-joliet",
            "-default-volume-name", "WIN",
            "-o", outURL.path,
            staging.path,
        ]
        proc.standardOutput = FileHandle.nullDevice
        let stderrPipe = Pipe()
        proc.standardError = stderrPipe
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            throw Error.hdiutilFailed(-1, "\(error)")
        }
        if proc.terminationStatus != 0 {
            let stderr = String(
                data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            throw Error.hdiutilFailed(proc.terminationStatus, stderr)
        }
        return outURL
    }
}
