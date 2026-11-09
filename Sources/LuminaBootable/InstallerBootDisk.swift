import Foundation

public enum InstallerBootDisk {
    public struct Error: Swift.Error, CustomStringConvertible, Equatable {
        public let description: String
    }

    static let configDirectories = ["EFI/debian", "EFI/ubuntu", "EFI/kali", "boot/grub"]

    static func grubConfig(cmdline: String) -> String {
        """
        search --no-floppy --file --set=root /lumina/vmlinuz
        linux /lumina/vmlinuz \(cmdline)
        initrd /lumina/initrd
        boot

        """
    }

    @discardableResult
    public static func make(iso: URL, kernel: URL, initrd: URL, cmdline: String, at output: URL) throws -> URL {
        let fm = FileManager.default
        let staging = output.deletingLastPathComponent()
            .appendingPathComponent(".boot-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging.appendingPathComponent("EFI/BOOT"), withIntermediateDirectories: true)
        try fm.createDirectory(at: staging.appendingPathComponent("lumina"), withIntermediateDirectories: true)

        try extractGrub(from: iso, to: staging.appendingPathComponent("EFI/BOOT/BOOTAA64.EFI"))
        try fm.copyItem(at: kernel, to: staging.appendingPathComponent("lumina/vmlinuz"))
        try fm.copyItem(at: initrd, to: staging.appendingPathComponent("lumina/initrd"))
        let config = Data(grubConfig(cmdline: cmdline).utf8)
        for dir in configDirectories {
            let url = staging.appendingPathComponent(dir)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try config.write(to: url.appendingPathComponent("grub.cfg"))
        }

        try? fm.removeItem(at: output)
        let bytes = [kernel, initrd].compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.reduce(0, +)
        let result = LinuxISOExtractor.runProcess("/usr/bin/hdiutil", arguments: [
            "create", "-quiet", "-srcfolder", staging.path, "-size", "\(bytes / 1_048_576 + 64)m",
            "-fs", "MS-DOS", "-fsargs", "-F 32", "-volname", "LUMINABOOT",
            "-layout", "GPTSPUD", "-format", "UDTO", "-o", output.path,
        ])
        guard result.exitCode == 0, fm.fileExists(atPath: output.path) else {
            throw Error(description: "hdiutil create exit \(result.exitCode): \(result.stderr)\(result.stdout)")
        }
        return output
    }

    static func extractGrub(from iso: URL, to destination: URL) throws {
        let list = LinuxISOExtractor.runProcess("/usr/bin/bsdtar", arguments: ["-tf", iso.path])
        guard list.exitCode == 0 else {
            throw Error(description: "bsdtar -tf exit \(list.exitCode): \(list.stderr)")
        }
        guard let entry = list.stdout.split(separator: "\n").map(String.init)
            .first(where: { $0.lowercased().hasSuffix("efi/boot/grubaa64.efi") })
        else {
            throw Error(description: "no EFI/boot/grubaa64.efi in \(iso.lastPathComponent)")
        }
        let scratch = destination.deletingLastPathComponent().appendingPathComponent(".grub-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let extract = LinuxISOExtractor.runProcess("/usr/bin/bsdtar", arguments: ["-xf", iso.path, "-C", scratch.path, entry])
        guard extract.exitCode == 0 else {
            throw Error(description: "bsdtar -xf exit \(extract.exitCode): \(extract.stderr)")
        }
        try FileManager.default.moveItem(at: scratch.appendingPathComponent(entry), to: destination)
    }
}
