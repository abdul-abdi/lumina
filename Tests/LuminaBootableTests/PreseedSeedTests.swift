import Foundation
import Testing
@testable import LuminaBootable

@Suite struct PreseedSeedTests {
    @Test func patch_appendsGzippedCpioWithPreseed() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LuminaPreseedTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let original = tmp.appendingPathComponent("initrd.gz")
        try Data("ORIGINAL".utf8).write(to: original)

        let patched = try PreseedSeed(
            bundleRootURL: tmp, originalInitrd: original, preseedCfg: "d-i test string ok\n"
        ).patch()

        let bytes = try Data(contentsOf: patched)
        #expect(bytes.prefix(8) == Data("ORIGINAL".utf8))
        let gz = tmp.appendingPathComponent("tail.gz")
        try bytes.dropFirst(8).write(to: gz)
        let gunzip = Process()
        gunzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        gunzip.arguments = ["-dc", gz.path]
        let out = Pipe()
        gunzip.standardOutput = out
        try gunzip.run()
        let cpio = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        gunzip.waitUntilExit()
        #expect(gunzip.terminationStatus == 0)
        #expect(cpio.hasPrefix("070701"))
        #expect(cpio.contains("preseed.cfg"))
        #expect(cpio.contains("d-i test string ok"))
        #expect(cpio.contains("TRAILER!!!"))
    }

    @Test func cfg_picksMirrorByVariant() {
        let kali = PreseedSeed.cfg(forOSVariant: "kali-rolling")
        #expect(kali.contains("d-i mirror/http/hostname string http.kali.org"))
        #expect(kali.contains("d-i mirror/suite string kali-rolling"))
        #expect(kali.contains("d-i apt-setup/components string main contrib non-free non-free-firmware"))
        #expect(!kali.contains("security.debian.org"))

        let debian = PreseedSeed.cfg(forOSVariant: "debian-12")
        #expect(debian.contains("d-i mirror/http/hostname string deb.debian.org"))
        #expect(debian.contains("d-i apt-setup/security_host string security.debian.org"))
        #expect(!debian.contains("kali"))

        for cfg in [kali, debian] {
            #expect(cfg.contains("d-i netcfg/dhcp_retries string 4"))
            #expect(cfg.contains("d-i grub-installer/bootdev string /dev/vda"))
            #expect(!cfg.contains("\n "))
        }
    }
}
