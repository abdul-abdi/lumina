// Sources/LuminaBootable/LinuxISOExtractor.swift
//
// Extracts the kernel + initramfs out of a Linux installer ISO so the
// host can boot them via VZLinuxBootLoader with a caller-controlled
// kernel cmdline. The only reason we do this is to inject
// `console=hvc0 earlycon=hvc0` for `--serial` log capture — stock arm64
// Linux ISOs ship GRUB configs that direct console output to `tty0` /
// `efifb`, so VZ's virtio-console receives zero bytes at boot.
//
// Tradeoff the caller accepts: no GRUB menu, no timer-delay splash,
// no in-ISO bootloader choice. This is explicitly a debug/capture
// path, not the default for installs.
//
// Implementation: reads ISO9660 directly via `bsdtar`, which ships
// with macOS and has native ISO9660 + UDF support. We list the
// archive, find a matching kernel+initramfs pair from a small
// hard-coded catalog of known distro layouts, and extract exactly
// those two files. No mount required (earlier attempt used
// `hdiutil attach` which fails on hybrid GPT+ISO9660 images —
// Alpine's standard ISO is one of those).
//
// Distro coverage (first match wins; add rows as new layouts appear
// in the wild):
//
//   - Ubuntu Live/Server:  /casper/vmlinuz + /casper/initrd
//   - Debian arm64 netinst: /install.a64/vmlinuz + /install.a64/initrd.gz
//   - Alpine standard (LTS kernel): /boot/vmlinuz-lts + /boot/initramfs-lts
//   - Alpine virt (older):  /boot/vmlinuz-virt + /boot/initramfs-virt
//   - Fedora Live:         /images/pxeboot/vmlinuz + /images/pxeboot/initrd.img
//   - Arch arm64:          /arch/boot/aarch64/vmlinuz-linux + /arch/boot/aarch64/initramfs-linux.img

import Foundation

public struct LinuxISOExtractor: Sendable {
    public enum Error: Swift.Error, Equatable {
        case listFailed(String)
        case unknownLayout(triedPaths: [String])
        case extractFailed(String)
    }

    /// Pair of URLs to the extracted kernel + initramfs inside the
    /// destination directory. Caller is responsible for deleting the
    /// directory when the VM shuts down.
    public struct Extracted: Sendable, Equatable {
        public let kernel: URL
        public let initramfs: URL
        /// Name of the matched layout (e.g. "Alpine standard (LTS)").
        /// Useful for log messages and test assertions.
        public let layoutName: String
    }

    /// Candidate kernel-path / initramfs-path pairs, tried in order.
    /// Paths are relative to the ISO root, no leading slash. Matched
    /// by exact substring in `bsdtar -tf` output.
    public static let knownLayouts: [(kernel: String, initramfs: String, name: String)] = [
        ("casper/vmlinuz",                     "casper/initrd",                         "Ubuntu live/server"),
        ("install.a64/vmlinuz",                "install.a64/initrd.gz",                 "Debian arm64 netinst"),
        ("boot/vmlinuz-lts",                   "boot/initramfs-lts",                    "Alpine standard (LTS)"),
        ("boot/vmlinuz-virt",                  "boot/initramfs-virt",                   "Alpine virt"),
        ("images/pxeboot/vmlinuz",             "images/pxeboot/initrd.img",             "Fedora Live / netinst"),
        ("arch/boot/aarch64/vmlinuz-linux",    "arch/boot/aarch64/initramfs-linux.img", "Arch arm64"),
    ]

    /// Find a matching layout via `bsdtar -tf`, then extract it via
    /// `bsdtar -xf`. `destination` must exist.
    public static func extract(
        iso: URL,
        destination: URL
    ) throws -> Extracted {
        // 1. List archive contents.
        let list = runProcess("/usr/bin/bsdtar", arguments: ["-tf", iso.path])
        guard list.exitCode == 0 else {
            throw Error.listFailed(
                "bsdtar -tf exit \(list.exitCode): \(list.stderr)"
            )
        }
        let members = Set(list.stdout.split(separator: "\n").map(String.init))

        // 2. Find a matching layout.
        var tried: [String] = []
        var matched: (layout: (kernel: String, initramfs: String, name: String), kernel: String, initramfs: String)? = nil
        for layout in knownLayouts {
            tried.append(layout.kernel)
            // bsdtar may list paths with or without a leading "./" or
            // uppercase variants depending on the ISO's Joliet layer.
            // Accept any member whose normalised form matches.
            if let k = members.first(where: { matchesPath($0, layout.kernel) }),
               let i = members.first(where: { matchesPath($0, layout.initramfs) }) {
                matched = (layout, k, i)
                break
            }
        }

        guard let matched else {
            throw Error.unknownLayout(triedPaths: Array(Set(tried)).sorted())
        }

        // 3. Extract exactly those two files into destination.
        // `-C destination` sets the output dir; trailing positional args
        // restrict extraction to specific members.
        let extractArgs = [
            "-xf", iso.path,
            "-C", destination.path,
            matched.kernel, matched.initramfs,
        ]
        let extractResult = runProcess("/usr/bin/bsdtar", arguments: extractArgs)
        guard extractResult.exitCode == 0 else {
            throw Error.extractFailed(
                "bsdtar -xf exit \(extractResult.exitCode): \(extractResult.stderr)"
            )
        }

        let extractedKernel = destination.appendingPathComponent(matched.kernel)
        let initrdURL = destination.appendingPathComponent(matched.initramfs)

        // Sanity check: bsdtar claimed success but ensure the files
        // actually landed.
        guard FileManager.default.fileExists(atPath: extractedKernel.path),
              FileManager.default.fileExists(atPath: initrdURL.path) else {
            throw Error.extractFailed(
                "bsdtar succeeded but expected files are missing: \(extractedKernel.lastPathComponent), \(initrdURL.lastPathComponent)"
            )
        }

        // Modern arm64 Linux ISOs ship the kernel as a PE32+ EFI
        // application with a compressed arm64 Image embedded inside
        // (CONFIG_EFI_ZBOOT). VZLinuxBootLoader wants the raw arm64
        // Image — not the PE wrapper, not the gzipped payload. If we
        // detect the zboot format, strip the wrapper and decompress
        // the payload. Non-zboot kernels (raw Image, older distros)
        // pass through unchanged.
        let kernelURL = try unwrapEFIZBootIfNeeded(
            kernel: extractedKernel, destination: destination
        )

        return Extracted(
            kernel: kernelURL,
            initramfs: initrdURL,
            layoutName: matched.layout.name
        )
    }

    /// If `kernel` is a CONFIG_EFI_ZBOOT PE32+ wrapper around a gzipped
    /// arm64 Image, extract and decompress it. Return the URL of the
    /// resulting raw Image. Otherwise return `kernel` unchanged (it's
    /// already in a format VZLinuxBootLoader accepts).
    ///
    /// zboot format (upstream: drivers/firmware/efi/libstub/zboot.c):
    ///   offset 0:  "MZ\0\0"      (DOS/PE header magic; also first instr)
    ///   offset 4:  "zimg"        (zboot signature — the detection marker)
    ///   offset 8:  u32 LE        payload offset from start of file
    ///   offset 12: u32 LE        payload size (compressed)
    ///   offset 24: compression   ("gzip\0\0\0\0" observed in practice)
    ///
    /// The payload is a raw gzip stream. We shell out to `gunzip` to
    /// decompress — Foundation's Compression framework handles raw
    /// deflate but not the gzip wrapper cleanly. `gunzip` ships with
    /// every macOS install.
    ///
    /// Non-zboot files either start with "ARM\x64" at offset 0x38 (the
    /// raw arm64 Image magic) or something else entirely. In either
    /// case, we leave them alone and let VZLinuxBootLoader sort it out.
    static func unwrapEFIZBootIfNeeded(
        kernel: URL, destination: URL
    ) throws -> URL {
        guard let handle = try? FileHandle(forReadingFrom: kernel) else {
            return kernel
        }
        defer { try? handle.close() }
        let header = handle.readData(ofLength: 32)
        guard header.count >= 16 else { return kernel }

        // Detect "zimg" at offset 4.
        let zimgMagic: [UInt8] = [0x7a, 0x69, 0x6d, 0x67] // "zimg"
        let headerBytes = [UInt8](header)
        guard Array(headerBytes[4..<8]) == zimgMagic else {
            // Not zboot — could be raw Image, legacy uImage, or
            // something else. Pass through.
            return kernel
        }

        let payloadOffset = UInt32(headerBytes[8])
            | (UInt32(headerBytes[9]) << 8)
            | (UInt32(headerBytes[10]) << 16)
            | (UInt32(headerBytes[11]) << 24)
        let payloadSize = UInt32(headerBytes[12])
            | (UInt32(headerBytes[13]) << 8)
            | (UInt32(headerBytes[14]) << 16)
            | (UInt32(headerBytes[15]) << 24)

        guard payloadOffset > 0, payloadSize > 0 else {
            throw Error.extractFailed(
                "zboot kernel has zero payload offset/size — corrupt ISO?"
            )
        }

        // Read the compressed payload. File size is bounded (<100 MB
        // kernel payload) so a single Data read is fine.
        try handle.seek(toOffset: UInt64(payloadOffset))
        let compressed = handle.readData(ofLength: Int(payloadSize))
        guard compressed.count == Int(payloadSize) else {
            throw Error.extractFailed(
                "zboot payload short read: wanted \(payloadSize), got \(compressed.count)"
            )
        }

        // Write compressed payload to tmp, gunzip it to the final path.
        let gzTmp = destination.appendingPathComponent("vmlinuz-raw.gz")
        let rawOut = destination.appendingPathComponent("vmlinuz-raw")
        try? FileManager.default.removeItem(at: gzTmp)
        try? FileManager.default.removeItem(at: rawOut)
        do {
            try compressed.write(to: gzTmp)
        } catch {
            throw Error.extractFailed("writing zboot payload: \(error)")
        }

        // gunzip -c <in> > <out>  —  -c writes to stdout so we can
        // redirect to the final path without overwriting-in-place
        // semantics that some gunzip builds disagree on.
        let gunzipResult = runProcess(
            "/bin/sh",
            arguments: ["-c", "/usr/bin/gunzip -c \(shellEscape(gzTmp.path)) > \(shellEscape(rawOut.path))"]
        )
        try? FileManager.default.removeItem(at: gzTmp)
        guard gunzipResult.exitCode == 0,
              FileManager.default.fileExists(atPath: rawOut.path) else {
            throw Error.extractFailed(
                "gunzip exit \(gunzipResult.exitCode): \(gunzipResult.stderr)"
            )
        }

        return rawOut
    }

    private static func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Does a tar member entry match a known layout path? Accepts the
    /// path verbatim, with a leading "./", or case-mismatched (Joliet
    /// layer can uppercase). Rejects any path ending in "/" (directory
    /// entries).
    static func matchesPath(_ member: String, _ target: String) -> Bool {
        if member.hasSuffix("/") { return false }
        if member == target { return true }
        if member == "./" + target { return true }
        if member.lowercased() == target.lowercased() { return true }
        if member.lowercased() == "./" + target.lowercased() { return true }
        return false
    }

    // Small, focused process runner. Intentionally duplicated from
    // ImagePuller / DoctorCommand — the latter two live in Lumina /
    // lumina-cli and this file is in LuminaBootable, so sharing would
    // require a new shared utility target. ~15 lines of duplication is
    // cheaper than the target reshuffle.
    private static func runProcess(
        _ path: String, arguments: [String]
    ) -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (-1, "", error.localizedDescription)
        }
        let stdout = String(
            data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let stderr = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }
}
