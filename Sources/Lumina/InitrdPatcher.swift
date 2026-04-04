// Sources/Lumina/InitrdPatcher.swift
import Foundation

/// Creates a combined initramfs by appending a supplementary cpio archive
/// (containing lumina-agent + custom init) to the stock Alpine initrd.
///
/// Linux supports concatenated initramfs images — the kernel extracts
/// each cpio in order, with later entries overriding earlier ones.
/// This lets us inject the guest agent and a custom /init without
/// modifying the base image files.
enum InitrdPatcher {

    /// Creates a combined initrd at `outputURL` by concatenating the base
    /// initrd with a supplementary cpio containing the agent and init script.
    ///
    /// The supplementary cpio contains:
    /// - `/init` — custom init script that mounts rootfs, copies agent, switch_roots
    /// - `/lumina-agent` — the guest agent binary (linux/arm64 ELF)
    static func createCombinedInitrd(
        baseInitrd: URL,
        agentBinary: URL,
        modulesDir: URL?,
        outputURL: URL
    ) throws(LuminaError) {
        // Read base initrd
        let baseData: Data
        do {
            baseData = try Data(contentsOf: baseInitrd)
        } catch {
            throw .bootFailed(underlying: PatcherError.readFailed("base initrd: \(error)"))
        }

        // Read agent binary
        let agentData: Data
        do {
            agentData = try Data(contentsOf: agentBinary)
        } catch {
            throw .bootFailed(underlying: PatcherError.readFailed("agent binary: \(error)"))
        }

        // Read kernel modules (vsock etc.) if available
        var moduleFiles: [(name: String, data: Data)] = []
        if let modulesDir = modulesDir {
            let fm = FileManager.default
            if let entries = try? fm.contentsOfDirectory(at: modulesDir, includingPropertiesForKeys: nil) {
                for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    if entry.pathExtension == "gz" || entry.pathExtension == "ko" {
                        if let data = try? Data(contentsOf: entry) {
                            moduleFiles.append((name: entry.lastPathComponent, data: data))
                        }
                    }
                }
            }
        }

        // Build the supplementary cpio archive (newc format)
        let initScript = Self.customInitScript(hasModules: !moduleFiles.isEmpty)
        var cpio = Data()
        cpio.append(cpioEntry(path: ".", mode: 0o40755, data: Data()))
        cpio.append(cpioEntry(path: "init", mode: 0o100755, data: Data(initScript.utf8)))
        cpio.append(cpioEntry(path: "lumina-agent", mode: 0o100755, data: agentData))

        // Add kernel modules under /lumina-modules/
        if !moduleFiles.isEmpty {
            cpio.append(cpioEntry(path: "lumina-modules", mode: 0o40755, data: Data()))
            for module in moduleFiles {
                cpio.append(cpioEntry(path: "lumina-modules/\(module.name)", mode: 0o100644, data: module.data))
            }
        }

        cpio.append(cpioTrailer())

        // Gzip-compress the supplementary cpio.
        // Linux expects each concatenated initramfs segment to be independently
        // compressed (or uncompressed cpio). Gzipping ensures the kernel's
        // unpack_to_rootfs() recognizes it as a new segment after the base initrd.
        let compressedCpio = try gzipCompress(cpio, tempDir: outputURL.deletingLastPathComponent())

        // Concatenate: base initrd (gzip) + supplementary cpio (gzip)
        var combined = baseData
        combined.append(compressedCpio)

        // Write combined initrd
        do {
            try combined.write(to: outputURL)
        } catch {
            throw .bootFailed(underlying: PatcherError.writeFailed("combined initrd: \(error)"))
        }
    }

    // MARK: - Custom Init Script

    private static func customInitScript(hasModules: Bool = false) -> String {
        // No leading whitespace — this script is written verbatim into the cpio.
        // Each line must start at column 0 for the shell to parse correctly.
        var lines: [String] = [
            "#!/bin/sh",
            "# Lumina custom init — injected via initrd overlay",
            "",
            "# Bootstrap busybox symlinks (mount, cat, modprobe, etc.)",
            "/bin/busybox mkdir -p /usr/bin /usr/sbin /sbin",
            "/bin/busybox --install -s",
            "export PATH=/usr/bin:/bin:/usr/sbin:/sbin",
            "",
            "# Mount essential filesystems",
            "mount -t proc proc /proc",
            "mount -t sysfs sys /sys",
            "mount -t devtmpfs dev /dev 2>/dev/null || mount -t tmpfs dev /dev",
            "",
            "# Parse kernel command line for root=",
            "ROOT_DEV=",
            "for param in $(cat /proc/cmdline); do",
            "  case \"$param\" in",
            "    root=*) ROOT_DEV=\"${param#root=}\" ;;",
            "  esac",
            "done",
            "",
            "# Load virtio modules for block device access",
            "modprobe virtio_blk 2>/dev/null",
            "modprobe ext4 2>/dev/null",
        ]

        // Load vsock modules before switch_root (they live in the initramfs,
        // not on the rootfs, so modprobe won't find them after switch_root).
        if hasModules {
            lines += [
                "",
                "# Load vsock kernel modules (in dependency order)",
                "for m in vsock.ko.gz vmw_vsock_virtio_transport_common.ko.gz vmw_vsock_virtio_transport.ko.gz; do",
                "  if [ -f \"/lumina-modules/$m\" ]; then",
                "    gunzip -f \"/lumina-modules/$m\" 2>/dev/null",
                "    insmod \"/lumina-modules/${m%.gz}\" 2>/dev/null",
                "  fi",
                "done",
            ]
        }

        lines += [
            "",
            "# Wait for block device to appear (up to 5 seconds)",
            "n=0",
            "while [ ! -b \"$ROOT_DEV\" ] && [ \"$n\" -lt 50 ]; do",
            "  mdev -s 2>/dev/null",
            "  sleep 0.1",
            "  n=$((n+1))",
            "done",
            "",
            "if [ ! -b \"$ROOT_DEV\" ]; then",
            "  echo \"lumina-init: root device $ROOT_DEV not found\" >&2",
            "  exec /bin/sh",
            "fi",
            "",
            "# Mount root filesystem",
            "mkdir -p /sysroot",
            "mount -o rw \"$ROOT_DEV\" /sysroot",
            "if [ $? -ne 0 ]; then",
            "  echo \"lumina-init: failed to mount $ROOT_DEV\" >&2",
            "  exec /bin/sh",
            "fi",
            "",
            "# Install lumina-agent from initramfs into rootfs",
            "mkdir -p /sysroot/usr/local/bin",
            "cp /lumina-agent /sysroot/usr/local/bin/lumina-agent",
            "chmod 755 /sysroot/usr/local/bin/lumina-agent",
            "",
            "# Create minimal init wrapper on rootfs",
            "cat > /sysroot/sbin/lumina-init << 'INITEOF'",
            "#!/bin/sh",
            "mount -t proc proc /proc 2>/dev/null",
            "mount -t sysfs sys /sys 2>/dev/null",
            "mount -t devtmpfs dev /dev 2>/dev/null",
            "hostname lumina 2>/dev/null",
            "ip link set lo up 2>/dev/null",
            "ip link set eth0 up 2>/dev/null",
            "udhcpc -i eth0 -s /usr/share/udhcpc/default.script -q 2>/dev/null &",
            "exec /usr/local/bin/lumina-agent",
            "INITEOF",
            "chmod 755 /sysroot/sbin/lumina-init",
            "",
            "# Switch root — lumina-init becomes PID 1 in the real rootfs",
            "exec switch_root /sysroot /sbin/lumina-init",
        ]

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - CPIO newc format

    /// Create a cpio newc entry for a file or directory.
    private static func cpioEntry(path: String, mode: UInt32, data: Data) -> Data {
        let ino: UInt32 = 0
        let nlink: UInt32 = (mode & 0o40000) != 0 ? 2 : 1
        let nameSize = UInt32(path.utf8.count + 1) // +1 for NUL
        let fileSize = UInt32(data.count)

        let header = String(format:
            "070701" +          // magic
            "%08X" +            // ino
            "%08X" +            // mode
            "%08X" +            // uid
            "%08X" +            // gid
            "%08X" +            // nlink
            "%08X" +            // mtime
            "%08X" +            // filesize
            "%08X" +            // devmajor
            "%08X" +            // devminor
            "%08X" +            // rdevmajor
            "%08X" +            // rdevminor
            "%08X" +            // namesize
            "%08X",             // check (always 0)
            ino, mode, 0, 0, nlink, 0, fileSize, 0, 0, 0, 0, nameSize, 0
        )

        var entry = Data(header.utf8)
        entry.append(Data(path.utf8))
        entry.append(0) // NUL terminator

        // Pad to 4-byte boundary after header + name
        let headerNameLen = entry.count
        let namePad = (4 - (headerNameLen % 4)) % 4
        entry.append(contentsOf: [UInt8](repeating: 0, count: namePad))

        // File data
        entry.append(data)

        // Pad data to 4-byte boundary
        let dataPad = (4 - (data.count % 4)) % 4
        entry.append(contentsOf: [UInt8](repeating: 0, count: dataPad))

        return entry
    }

    /// CPIO trailer entry signaling end of archive.
    private static func cpioTrailer() -> Data {
        cpioEntry(path: "TRAILER!!!", mode: 0, data: Data())
    }

    /// Gzip-compress data using /usr/bin/gzip (the system tool).
    private static func gzipCompress(_ data: Data, tempDir: URL) throws(LuminaError) -> Data {
        let inputFile = tempDir.appendingPathComponent("supplement.cpio")
        let outputFile = tempDir.appendingPathComponent("supplement.cpio.gz")

        do {
            try data.write(to: inputFile)
        } catch {
            throw .bootFailed(underlying: PatcherError.writeFailed("temp cpio: \(error)"))
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-f", "-9", inputFile.path]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw .bootFailed(underlying: PatcherError.writeFailed("gzip failed: \(error)"))
        }

        guard process.terminationStatus == 0 else {
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw .bootFailed(underlying: PatcherError.writeFailed("gzip exit \(process.terminationStatus): \(stderr)"))
        }

        do {
            return try Data(contentsOf: outputFile)
        } catch {
            throw .bootFailed(underlying: PatcherError.readFailed("compressed cpio: \(error)"))
        }
    }
}

// MARK: - Errors

enum PatcherError: Error, Sendable {
    case readFailed(String)
    case writeFailed(String)
}
