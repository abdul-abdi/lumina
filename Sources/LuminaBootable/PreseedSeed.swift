// Sources/LuminaBootable/PreseedSeed.swift
//
// Cures the Debian-installer "netcfg first-probe DHCP race" by injecting a
// preseed.cfg into the installer's initrd. The kernel's initramfs format
// supports concatenated cpio.gz archives where later entries override
// earlier ones — so we don't have to decompress and rewrap the entire
// installer initrd, we just append our own cpio.gz with /preseed.cfg.
//
// See [[wiki/learnings/debian-netcfg-first-probe-race]]:
//   The default Debian/Kali installer sends ONE DHCP DISCOVER, declares
//   failure on no response, and bails. vmnet's bootpd misses that first
//   probe (lazy lease-table allocation). Our preseed sets
//   `netcfg/dhcp_retries=4` which makes d-i issue 4 probes ~5s apart —
//   bootpd is warm by probe 2 every time.
//
// `dhcp_timeout` does NOT help; it just extends the wait for ONE probe.
// `dhcp_retries` is the load-bearing knob.
//
// We pair this with `auto=true priority=critical preseed/file=/preseed.cfg`
// on the kernel cmdline so d-i is fully driven by preseed values.
// Without `auto=true`, d-i still prompts at the language/keyboard/clock
// stages even when we provide answers.

import Foundation

public struct PreseedSeed: Sendable {
    public let bundleRootURL: URL
    public let originalInitrd: URL
    public let preseedCfg: String

    public init(
        bundleRootURL: URL,
        originalInitrd: URL,
        preseedCfg: String = PreseedSeed.defaultDebianPreseed
    ) {
        self.bundleRootURL = bundleRootURL
        self.originalInitrd = originalInitrd
        self.preseedCfg = preseedCfg
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case missingTool(String)
        case stagingFailed(String)
        case cpioFailed(Int32, String)
        case gzipFailed(Int32, String)
        case writeFailed(URL, String)

        public var description: String {
            switch self {
            case .missingTool(let s): return "missing tool: \(s)"
            case .stagingFailed(let s): return "staging: \(s)"
            case .cpioFailed(let c, let s): return "cpio exit \(c): \(s)"
            case .gzipFailed(let c, let s): return "gzip exit \(c): \(s)"
            case .writeFailed(let u, let s): return "write \(u.lastPathComponent): \(s)"
            }
        }
    }

    /// Default preseed for Debian arm64 / Kali installer ARM64. Tuned for the
    /// minimal-friction install path: English, US keyboard, single full-disk
    /// install with `lumina:lumina` user, no proxy. The load-bearing line is
    /// `netcfg/dhcp_retries=4` — that's what fixes the vmnet race.
    public static let defaultDebianPreseed: String = """
    # Lumina-injected preseed (cures vmnet DHCP first-probe race).
    # Generated; do not hand-edit.

    # ---- Locale + keyboard
    d-i debian-installer/locale string en_US.UTF-8
    d-i keyboard-configuration/xkb-keymap select us
    d-i debian-installer/language string en
    d-i debian-installer/country string US

    # ---- Network — the load-bearing fix.
    # vmnet's bootpd misses the first DHCP DISCOVER. dhcp_retries=4 makes
    # d-i issue 4 probes ~5s apart; by probe 2 bootpd is warm. dhcp_timeout
    # alone does not help (extends ONE probe's wait, doesn't retry).
    d-i netcfg/choose_interface select auto
    d-i netcfg/dhcp_timeout string 60
    d-i netcfg/dhcp_retries string 4
    d-i netcfg/get_hostname string lumina-vm
    d-i netcfg/get_domain string local
    d-i netcfg/hostname string lumina-vm

    # ---- Mirror — Debian only. Kali's preseed should override mirror/*.
    d-i mirror/country string manual
    d-i mirror/protocol string http
    d-i mirror/http/hostname string deb.debian.org
    d-i mirror/http/directory string /debian
    d-i mirror/http/proxy string

    # ---- Clock + timezone
    d-i clock-setup/utc boolean true
    d-i time/zone string Etc/UTC
    d-i clock-setup/ntp boolean true

    # ---- Partitioning — single full-disk install. atomic = everything in /.
    d-i partman-auto/method string regular
    d-i partman-auto/choose_recipe select atomic
    d-i partman-lvm/device_remove_lvm boolean true
    d-i partman-md/device_remove_md boolean true
    d-i partman/confirm_write_new_label boolean true
    d-i partman/choose_partition select finish
    d-i partman/confirm boolean true
    d-i partman/confirm_nooverwrite boolean true

    # ---- Account setup — single user `lumina` with sudo. Non-prod default.
    d-i passwd/root-login boolean false
    d-i passwd/make-user boolean true
    d-i passwd/user-fullname string Lumina User
    d-i passwd/username string lumina
    d-i passwd/user-password password lumina
    d-i passwd/user-password-again password lumina

    # ---- APT setup
    d-i apt-setup/use_mirror boolean true
    d-i apt-setup/services-select multiselect security, updates
    d-i apt-setup/security_host string security.debian.org

    # ---- Package selection — keep tiny so install is fast.
    tasksel tasksel/first multiselect standard
    d-i pkgsel/include string openssh-server
    d-i pkgsel/upgrade select none
    popularity-contest popularity-contest/participate boolean false

    # ---- GRUB — install onto the primary disk, no prompt.
    d-i grub-installer/only_debian boolean true
    d-i grub-installer/with_other_os boolean false
    d-i grub-installer/bootdev string /dev/vda

    # ---- Finish without final prompt.
    d-i finish-install/reboot_in_progress note
    """

    /// Patch the initrd by appending a cpio.gz archive containing
    /// `/preseed.cfg`. Returns the URL of the patched initrd.
    ///
    /// Kernel's initramfs accepts a concatenation of gzipped cpio archives —
    /// see Documentation/filesystems/ramfs-rootfs-initramfs.rst. Each archive
    /// is unpacked over the filesystem in order; later entries silently
    /// overwrite earlier ones. So we don't decompress + rewrap the original
    /// initrd; we just append.
    public func patch() throws -> URL {
        // Tools present?
        let cpioPath = "/usr/bin/cpio"
        let gzipPath = "/usr/bin/gzip"
        guard FileManager.default.isExecutableFile(atPath: cpioPath) else {
            throw Error.missingTool(cpioPath)
        }
        guard FileManager.default.isExecutableFile(atPath: gzipPath) else {
            throw Error.missingTool(gzipPath)
        }

        // Stage area lives inside the bundle so a future cleanup pass can
        // sweep it. Unique per call — we don't share state across invocations.
        let stageDir = bundleRootURL.appendingPathComponent("preseed-stage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stageDir) }

        // Write the preseed.cfg file at the root of the stage dir. cpio
        // operates on relative paths, so we cd into stageDir and feed it
        // the bare filename.
        let preseedFile = stageDir.appendingPathComponent("preseed.cfg")
        do {
            try Data(preseedCfg.utf8).write(to: preseedFile)
        } catch {
            throw Error.writeFailed(preseedFile, "\(error)")
        }

        // Build cpio archive in newc format (the format Linux initramfs
        // expects). Pipe `echo preseed.cfg` into cpio so it archives just
        // that one file.
        let cpioOut = stageDir.appendingPathComponent("preseed.cpio")
        let cpioCmd = "cd '\(stageDir.path)' && echo preseed.cfg | '\(cpioPath)' -H newc -o > '\(cpioOut.path)'"
        let cpioResult = runShell(cpioCmd)
        guard cpioResult.exit == 0 else {
            throw Error.cpioFailed(cpioResult.exit, cpioResult.stderr)
        }

        // gzip the cpio archive.
        let gzOut = stageDir.appendingPathComponent("preseed.cpio.gz")
        let gzCmd = "'\(gzipPath)' -c '\(cpioOut.path)' > '\(gzOut.path)'"
        let gzResult = runShell(gzCmd)
        guard gzResult.exit == 0 else {
            throw Error.gzipFailed(gzResult.exit, gzResult.stderr)
        }

        // Concatenate original initrd + our cpio.gz into the patched output.
        // Output goes into the bundle root so it survives the stage dir
        // cleanup; same lifecycle as the bundle.
        let outURL = bundleRootURL.appendingPathComponent("initrd.preseeded")
        let original: Data
        let patch: Data
        do {
            original = try Data(contentsOf: originalInitrd)
            patch = try Data(contentsOf: gzOut)
        } catch {
            throw Error.writeFailed(outURL, "read sources: \(error)")
        }
        do {
            try (original + patch).write(to: outURL, options: .atomic)
        } catch {
            throw Error.writeFailed(outURL, "\(error)")
        }
        return outURL
    }

    /// Kernel cmdline that engages preseed + sets the right console for our
    /// virtio serial. Append after any caller-supplied prefix (e.g. distro
    /// hint from `LinuxISOExtractor`).
    public static let cmdlinePreseedFlags = "auto=true priority=critical preseed/file=/preseed.cfg"

    /// Runs a /bin/sh -c "..." pipeline. Returns (exit, stdout, stderr).
    private func runShell(_ command: String) -> (exit: Int32, stdout: String, stderr: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return (-1, "", "spawn: \(error)")
        }
        let so = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let se = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (p.terminationStatus, so, se)
    }
}
