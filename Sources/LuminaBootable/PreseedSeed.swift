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

    public init(bundleRootURL: URL, originalInitrd: URL, preseedCfg: String) {
        self.bundleRootURL = bundleRootURL
        self.originalInitrd = originalInitrd
        self.preseedCfg = preseedCfg
    }

    public struct Error: Swift.Error, CustomStringConvertible {
        public let description: String
    }

    public static let cmdlinePreseedFlags = "auto=true priority=critical preseed/file=/preseed.cfg"

    public static func cfg(forOSVariant osVariant: String) -> String {
        let mirror: String
        let apt: String
        let packages: String
        if osVariant.lowercased().contains("kali") {
            mirror = """
            d-i mirror/http/hostname string http.kali.org
            d-i mirror/http/directory string /kali
            d-i mirror/http/proxy string
            d-i mirror/suite string kali-rolling
            d-i mirror/codename string kali-rolling
            """
            apt = """
            d-i apt-setup/services-select multiselect
            d-i apt-setup/components string main contrib non-free non-free-firmware
            """
            packages = """
            tasksel tasksel/first multiselect standard
            d-i pkgsel/include string openssh-server kali-desktop-xfce
            """
        } else {
            mirror = """
            d-i mirror/http/hostname string deb.debian.org
            d-i mirror/http/directory string /debian
            d-i mirror/http/proxy string
            """
            apt = """
            d-i apt-setup/services-select multiselect security, updates
            d-i apt-setup/security_host string security.debian.org
            """
            packages = """
            tasksel tasksel/first multiselect standard, desktop, gnome-desktop, ssh-server
            d-i pkgsel/include string openssh-server
            """
        }
        return """
        d-i debian-installer/locale string en_US.UTF-8
        d-i keyboard-configuration/xkb-keymap select us
        d-i debian-installer/language string en
        d-i debian-installer/country string US
        d-i netcfg/choose_interface select auto
        d-i netcfg/dhcp_timeout string 60
        d-i netcfg/dhcp_retries string 4
        d-i netcfg/get_hostname string lumina-vm
        d-i netcfg/get_domain string local
        d-i netcfg/hostname string lumina-vm
        d-i mirror/country string manual
        d-i mirror/protocol string http
        \(mirror)
        d-i clock-setup/utc boolean true
        d-i time/zone string Etc/UTC
        d-i clock-setup/ntp boolean true
        d-i partman-auto/disk string /dev/vda
        d-i partman-auto/method string regular
        d-i partman-auto/choose_recipe select atomic
        d-i partman-lvm/device_remove_lvm boolean true
        d-i partman-md/device_remove_md boolean true
        d-i partman/confirm_write_new_label boolean true
        d-i partman/choose_partition select finish
        d-i partman/confirm boolean true
        d-i partman/confirm_nooverwrite boolean true
        d-i passwd/root-login boolean false
        d-i passwd/make-user boolean true
        d-i passwd/user-fullname string Lumina User
        d-i passwd/username string lumina
        d-i passwd/user-password password lumina
        d-i passwd/user-password-again password lumina
        d-i apt-setup/use_mirror boolean true
        \(apt)
        \(packages)
        d-i pkgsel/upgrade select none
        popularity-contest popularity-contest/participate boolean false
        d-i grub-installer/only_debian boolean true
        d-i grub-installer/with_other_os boolean false
        d-i grub-installer/bootdev string /dev/vda
        d-i grub-installer/force-efi-extra-removable boolean true
        d-i finish-install/reboot_in_progress note
        d-i debian-installer/exit/poweroff boolean true

        """
    }

    public func patch() throws -> URL {
        let stage = bundleRootURL.appendingPathComponent("preseed-stage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        try Data(preseedCfg.utf8).write(to: stage.appendingPathComponent("preseed.cfg"))

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", "set -o pipefail; echo preseed.cfg | /usr/bin/cpio -H newc -o | /usr/bin/gzip -c"]
        proc.currentDirectoryURL = stage
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        try proc.run()
        let archive = out.fileHandleForReading.readDataToEndOfFile()
        let message = err.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw Error(description: "cpio | gzip exit \(proc.terminationStatus): \(String(decoding: message, as: UTF8.self))")
        }

        let outURL = bundleRootURL.appendingPathComponent("initrd.preseeded")
        try (Data(contentsOf: originalInitrd) + archive).write(to: outURL, options: .atomic)
        return outURL
    }
}
