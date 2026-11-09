import Foundation
import Testing
@testable import LuminaBootable

@Suite struct InstallerBootDiskTests {
    @Test func makesGPTDiskFromTheISOsOwnGrub() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lumina-bootdisk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let tree = tmp.appendingPathComponent("iso")
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("EFI/boot"), withIntermediateDirectories: true)
        try Data("grub".utf8).write(to: tree.appendingPathComponent("EFI/boot/grubaa64.efi"))
        let iso = try SeedISO.make(directory: tree, volumeName: "FAKE", at: tmp.appendingPathComponent("fake.iso"))
        let kernel = tmp.appendingPathComponent("vmlinuz")
        let initrd = tmp.appendingPathComponent("initrd.gz")
        try Data("k".utf8).write(to: kernel)
        try Data("i".utf8).write(to: initrd)

        let disk = try InstallerBootDisk.make(
            iso: iso, kernel: kernel, initrd: initrd, cmdline: "auto=true",
            at: tmp.appendingPathComponent("installer-boot.cdr")
        )

        let header = try FileHandle(forReadingFrom: disk).readToEnd() ?? Data()
        #expect(header.count > 1024)
        #expect(header.subdata(in: 512..<520) == Data("EFI PART".utf8))
        #expect(InstallerBootDisk.grubConfig(cmdline: "auto=true").contains("linux /lumina/vmlinuz auto=true"))
    }

    @Test func missingGrubIsAnError() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lumina-bootdisk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let tree = tmp.appendingPathComponent("iso")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: tree.appendingPathComponent("readme"))
        let iso = try SeedISO.make(directory: tree, volumeName: "FAKE", at: tmp.appendingPathComponent("fake.iso"))
        #expect(throws: InstallerBootDisk.Error.self) {
            try InstallerBootDisk.extractGrub(from: iso, to: tmp.appendingPathComponent("BOOTAA64.EFI"))
        }
    }
}

@Suite struct InstallerBootDiskSymlinkTests {
    @Test func symlinkedKernelIsRejected() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lumina-bootdisk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let link = tmp.appendingPathComponent("vmlinuz")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        #expect(throws: InstallerBootDisk.Error.self) {
            try InstallerBootDisk.requireRegularFile(link)
        }
    }
}
