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
    /// destination directory plus the per-distro kernel cmdline
    /// snippet that has to run alongside `console=hvc0` for the boot
    /// to actually reach userspace. Caller is responsible for deleting
    /// the directory when the VM shuts down.
    public struct Extracted: Sendable, Equatable {
        public let kernel: URL
        public let initramfs: URL
        /// Name of the matched layout (e.g. "Alpine standard (LTS)").
        public let layoutName: String
        /// Distro-specific cmdline append. Empty for layouts where the
        /// kernel default is sufficient. Caller appends this to the
        /// base `console=hvc0 earlycon=hvc0 quiet`.
        public let cmdlineExtra: String
    }

    /// Candidate kernel-path / initramfs-path pairs, tried in order.
    /// Paths are relative to the ISO root, no leading slash. Matched
    /// by exact substring in `bsdtar -tf` output.
    ///
    /// `cmdlineExtra` is the distro-specific kernel cmdline glue
    /// needed alongside `console=hvc0` to actually reach userspace.
    /// Without these snippets the kernel boots, the initramfs runs,
    /// and then `switch_root` fails because the live-init scripts
    /// can't locate their squashfs/casper/install media. We learned
    /// this empirically by capturing the panic line on Alpine 3.23.
    ///
    /// Per-distro hints (verified against shipping ISOs as of 2026-04):
    ///   - Alpine: Lumina attaches the installer ISO as a virtio-block
    ///     device (`/dev/vdb` — `vda` is the primary disk), NOT as a
    ///     `/dev/cdrom`/`/dev/sr0` SCSI cd-rom. Alpine's mkinitfs init
    ///     script's media-discovery defaults assume the latter, so we
    ///     have to point it at vdb directly: `alpine_dev=vdb:iso9660`.
    ///     `modloop=/boot/modloop-lts` then tells the init script where
    ///     the squashfs lives on that mount, and `modules=...` ensures
    ///     the loop+squashfs modules are available in the initramfs
    ///     stage so the modloop can be mounted at all.
    ///   - Ubuntu (casper): `boot=casper` activates the live-boot
    ///     init script set; `live-media-path=/casper` points it at
    ///     the right directory inside the ISO.
    ///   - Debian (install.a64): the d-i kernel auto-detects most
    ///     things; no extra cmdline is needed for serial-mode
    ///     installs (we still pass `quiet` and the operator can
    ///     remove it).
    ///   - Fedora (pxeboot): `root=live:CDLABEL=Fedora-...` is
    ///     ISO-label-specific and we don't know it ahead of time.
    ///     Pass `inst.stage2=hd:LABEL=Fedora` and let dracut search
    ///     by label prefix; works on most spins.
    ///   - Arch arm64: `archisobasedir=arch` plus the search-by-label
    ///     mechanism in archiso's mkinitcpio hook (`archisosearch`),
    ///     same fallback story as Fedora.
    public static let knownLayouts: [(kernel: String, initramfs: String, name: String, cmdlineExtra: String)] = [
        (
            "casper/vmlinuz",
            "casper/initrd",
            "Ubuntu live/server",
            "boot=casper live-media-path=/casper"
        ),
        (
            "install.a64/vmlinuz",
            "install.a64/initrd.gz",
            "Debian arm64 netinst",
            ""  // d-i kernel doesn't need extra hints for the serial path
        ),
        (
            "boot/vmlinuz-lts",
            "boot/initramfs-lts",
            "Alpine standard (LTS)",
            // Alpine's init script's `myopts` allowlist (parsed from
            // /proc/cmdline) does NOT include `alpine_dev` or
            // `modloop` keys — verified empirically on 3.23 — so
            // those silently drop. What it DOES honour is `modules=`,
            // which forces an early `modprobe -a` of the listed
            // modules. We list iso9660 + virtio-blk so nlplug-findfs
            // (Alpine's actual block-device-and-boot-media scanner)
            // can see and mount the attached ISO.
            "modules=iso9660,virtio_blk,loop,squashfs,sd-mod,usb-storage,ext4"
        ),
        (
            "boot/vmlinuz-virt",
            "boot/initramfs-virt",
            "Alpine virt",
            "modules=iso9660,virtio_blk,loop,squashfs,sd-mod,usb-storage,ext4"
        ),
        (
            "images/pxeboot/vmlinuz",
            "images/pxeboot/initrd.img",
            "Fedora Live / netinst",
            "inst.stage2=hd:LABEL=Fedora rd.live.image"
        ),
        (
            "arch/boot/aarch64/vmlinuz-linux",
            "arch/boot/aarch64/initramfs-linux.img",
            "Arch arm64",
            "archisobasedir=arch archisosearch"
        ),
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
        var matched: (layout: (kernel: String, initramfs: String, name: String, cmdlineExtra: String), kernel: String, initramfs: String)? = nil
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
            layoutName: matched.layout.name,
            cmdlineExtra: matched.layout.cmdlineExtra
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
