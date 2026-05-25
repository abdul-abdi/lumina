// Sources/lumina-cli/IsoBootHelpers.swift
//
// Shared helpers for `lumina iso` and `lumina desktop boot`.
//
// Two responsibilities:
//   1. `runCaptureSerialExtraction(...)` — wraps LinuxISOExtractor with
//      friendly stderr messages. Used by both subcommands so the
//      `--capture-serial` UX stays in lockstep.
//   2. `suggestArm64Equivalent(forFilename:)` — best-effort mapping from
//      an x86_64 ISO filename to an ARM64 catalog entry, so the rejection
//      message can point the user at a working URL.

import Foundation
import Lumina
import LuminaBootable

enum IsoBootHelpers {
    /// Result of attempting to extract a kernel + initramfs from an ISO
    /// for `--capture-serial` mode. All three fields are non-nil on
    /// success; nil triple = caller should fall back to plain EFI boot.
    struct CaptureSerialArtifacts {
        var kernel: URL
        var initramfs: URL
        var cmdline: String
        var layoutName: String
    }

    enum CaptureError: Error {
        case extractionFailed(String)
        case unknownLayout([String])
    }

    /// Extract kernel + initramfs out of `iso` into `destination` so the
    /// VZLinuxBootLoader path can boot with `console=hvc0 earlycon=hvc0`.
    /// Returns nil when the ISO has an unknown layout — the caller
    /// decides whether that's fatal (`lumina desktop boot --capture-serial`
    /// treats it as fatal) or recoverable (`lumina iso boot` falls back
    /// to plain EFI boot, since `--capture-serial` is implicit).
    ///
    /// `quiet=true` suppresses stderr "matched layout" output (used by
    /// `lumina iso boot` which has its own startup banner).
    static func runCaptureSerialExtraction(
        iso: URL,
        destination: URL,
        quiet: Bool = false
    ) throws -> CaptureSerialArtifacts? {
        // Reset extraction directory between invocations so a previous
        // distro's leftover files can't co-exist with the new layout.
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(
            at: destination, withIntermediateDirectories: true
        )

        let extracted: LinuxISOExtractor.Extracted
        do {
            extracted = try LinuxISOExtractor.extract(
                iso: iso, destination: destination
            )
        } catch LinuxISOExtractor.Error.unknownLayout(let tried) {
            throw CaptureError.unknownLayout(tried)
        } catch {
            throw CaptureError.extractionFailed("\(error)")
        }

        // Base cmdline: hvc0 for serial output, earlycon for pre-init
        // panic capture. Deliberately NOT `quiet` — the whole point of
        // --capture-serial is to see what happens, and Alpine/Debian-style
        // init scripts gate their progress prints on KOPT_quiet=no.
        let base = "console=hvc0 earlycon=hvc0"
        let cmdline = extracted.cmdlineExtra.isEmpty
            ? base
            : base + " " + extracted.cmdlineExtra

        if !quiet {
            let info = "→ matched \(extracted.layoutName); booting kernel+initramfs directly via VZLinuxBootLoader (--capture-serial)\n"
            FileHandle.standardError.write(Data(info.utf8))
        }

        return CaptureSerialArtifacts(
            kernel: extracted.kernel,
            initramfs: extracted.initramfs,
            cmdline: cmdline,
            layoutName: extracted.layoutName
        )
    }

    /// Format a friendly stderr message for an x86_64 / RISC-V refusal.
    /// Includes a download URL when `DesktopOSCatalog.suggestArm64Equivalent`
    /// finds a match for the filename.
    static func formatArchRejection(
        isoPath: String,
        arch: ISOInspector.Architecture
    ) -> String {
        let archName: String
        switch arch {
        case .x86_64:  archName = "x86_64"
        case .riscv64: archName = "RISC-V"
        case .arm64, .unknown: archName = "non-ARM64"
        }
        let filename = (isoPath as NSString).lastPathComponent
        var msg = """
        error: \(isoPath) is an \(archName) ISO. Apple Virtualization (and therefore
               Lumina) only boots ARM64 (aarch64) guests on Apple Silicon.

        """
        if let entry = DesktopOSCatalog.suggestArm64Equivalent(forFilename: filename) {
            msg += """

               For \(entry.displayName), use the ARM64 build:
                 \(entry.isoURL.absoluteString)

            """
        }
        msg += "       To override (will fail to boot), pass --force.\n"
        return msg
    }
}
