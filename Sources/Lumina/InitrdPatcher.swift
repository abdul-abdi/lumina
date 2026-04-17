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

        // Read kernel modules (vsock etc.) if available.
        // Resolve symlinks first — FileManager.contentsOfDirectory(at: URL) returns
        // ENOTDIR for symlinked directories on macOS, even when the target is a real
        // directory. This breaks custom images whose modules dir symlinks to the base.
        var moduleFiles: [(name: String, data: Data)] = []
        if let modulesDir = modulesDir {
            let resolvedDir = modulesDir.resolvingSymlinksInPath()
            let fm = FileManager.default
            if let entries = try? fm.contentsOfDirectory(at: resolvedDir, includingPropertiesForKeys: nil) {
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
        let initScript = Self.customInitScript()
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

    private static func customInitScript() -> String {
        // SYNC WARNING: The baked rootfs init script at Guest/build-image.sh (/sbin/init)
        // shares network config logic with the lumina-init generated here.
        // If you change network, virtiofs, or agent startup behavior below,
        // check Guest/build-image.sh for the corresponding baked version.
        //
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
            "# Boot profile phase marker (emitted to kernel log → serial console).",
            "# Parsed by the host from dmesg / SerialConsole for BootProfile.",
            "_lumina_mark() { echo \"LUMINA_BOOT phase=$1 t=$(cut -d' ' -f1 /proc/uptime)\" > /dev/kmsg 2>/dev/null; }",
            "_lumina_mark init_start",
            "",
            "# Parse kernel command line for root=",
            "ROOT_DEV=",
            "for param in $(cat /proc/cmdline); do",
            "  case \"$param\" in",
            "    root=*) ROOT_DEV=\"${param#root=}\" ;;",
            "  esac",
            "done",
            "",
            "# Load kernel modules from initramfs overlay (insmod in dependency order)",
            "# Boot: ext4 deps → ext4 → virtio_blk/net",
            "# Agent: vsock chain",
            "# Mounts: fuse → virtiofs",
            "for m in crc32c_generic.ko.gz libcrc32c.ko.gz crc16.ko.gz mbcache.ko.gz jbd2.ko.gz ext4.ko.gz virtio_blk.ko.gz af_packet.ko.gz failover.ko.gz net_failover.ko.gz virtio_net.ko.gz vsock.ko.gz vmw_vsock_virtio_transport_common.ko.gz vmw_vsock_virtio_transport.ko.gz fuse.ko.gz virtiofs.ko.gz; do",
            "  if [ -f \"/lumina-modules/$m\" ]; then",
            "    gunzip -f \"/lumina-modules/$m\" 2>/dev/null",
            "    insmod \"/lumina-modules/${m%.gz}\" 2>/dev/null",
            "  fi",
            "done",
            "_lumina_mark modules_loaded",
        ]

        lines += [
            "",
            "# Wait for block device to appear (up to 5 seconds).",
            "# 20ms polling — virtio_blk probe typically completes in <30ms on VZ.",
            "# Old 100ms polling added 70-90ms p50 on the critical path.",
            "n=0",
            "while [ ! -b \"$ROOT_DEV\" ] && [ \"$n\" -lt 250 ]; do",
            "  mdev -s 2>/dev/null",
            "  sleep 0.02",
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
            "_lumina_mark rootfs_mounted",
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
            "mkdir -p /dev/pts",
            "mount -t devpts -o gid=5,mode=620 devpts /dev/pts 2>/dev/null",
            "[ -e /dev/ptmx ] || ln -sf /dev/pts/ptmx /dev/ptmx",
            "# Boot profile — second-stage init (after switch_root)",
            "_lumina_mark() { echo \"LUMINA_BOOT phase=$1 t=$(cut -d' ' -f1 /proc/uptime)\" > /dev/kmsg 2>/dev/null; }",
            "_lumina_mark init2_start",
            "hostname lumina 2>/dev/null",
            "ip link set lo up 2>/dev/null",
            "ip link set eth0 up 2>/dev/null",
            "",
            "# Parse all lumina_* kernel cmdline params in ONE pass.",
            "# Previously this was three separate loops each forking `cat /proc/cmdline`.",
            "LUMINA_MOUNTS=",
            "LUMINA_ROSETTA=",
            "LUMINA_NET_IP=",
            "LUMINA_HOSTS=",
            "for param in $(cat /proc/cmdline); do",
            "  case \"$param\" in",
            "    lumina_mounts=*)  LUMINA_MOUNTS=\"${param#lumina_mounts=}\" ;;",
            "    lumina_rosetta=*) LUMINA_ROSETTA=\"${param#lumina_rosetta=}\" ;;",
            "    lumina_ip=*)      LUMINA_NET_IP=\"${param#lumina_ip=}\" ;;",
            "    lumina_hosts=*)   LUMINA_HOSTS=\"${param#lumina_hosts=}\" ;;",
            "  esac",
            "done",
            "",
            "# Mount virtio-fs shares BEFORE agent starts (commands may need mounted paths)",
            "if [ -n \"$LUMINA_MOUNTS\" ]; then",
            "  OLD_IFS=\"$IFS\"",
            "  IFS=','",
            "  for spec in $LUMINA_MOUNTS; do",
            "    tag=\"${spec%%:*}\"",
            "    mpath=\"${spec#*:}\"",
            "    mkdir -p \"$mpath\"",
            "    mount -t virtiofs \"$tag\" \"$mpath\" 2>/dev/null",
            "  done",
            "  IFS=\"$OLD_IFS\"",
            "fi",
            "",
            "# Rosetta (x86_64 binary translation)",
            "if [ \"$LUMINA_ROSETTA\" = \"1\" ]; then",
            "  mkdir -p /mnt/rosetta",
            "  mount -t virtiofs rosetta /mnt/rosetta 2>/dev/null",
            "  if [ -f /mnt/rosetta/rosetta ]; then",
            "    mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null",
            "    echo ':rosetta:M::\\x7fELF\\x02\\x01\\x01\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x02\\x00\\x3e\\x00:\\xff\\xff\\xff\\xff\\xff\\xfe\\xfe\\x00\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xfe\\xff\\xff\\xff:/mnt/rosetta/rosetta:F' > /proc/sys/fs/binfmt_misc/register 2>/dev/null",
            "  fi",
            "fi",
            "",
            "# Background network config — off the critical path.",
            "# The agent communicates via vsock (not TCP), so it can start and",
            "# send 'ready' before the network is up. By the time the first exec",
            "# needs network (~200ms+ after ready), this will have completed.",
            "(",
            "  # Wait for carrier on eth0 (VZ NAT link takes ~100ms to come up)",
            "  n=0",
            "  while [ \"$n\" -lt 20 ] && ! ip link show eth0 2>/dev/null | grep -q 'state UP'; do",
            "    sleep 0.1",
            "    n=$((n+1))",
            "  done",
            "",
            "  # Disable IPv6 — VZ NAT only provides IPv4 routing. Without this,",
            "  # DNS returns AAAA records and clients try IPv6 first (Happy Eyeballs),",
            "  # which times out because there is no IPv6 default route, causing",
            "  # multi-second delays before IPv4 fallback.",
            "  echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null",
            "",
            "  # Network: DHCP — let vmnet assign the correct IP and gateway.",
            "  # Static MAC-derived IPs hardcoded the subnet to 192.168.64.0/24, but",
            "  # vmnet will pick a different range (e.g. 192.168.65.0/24) when that",
            "  # range is already in use by another interface or VPN.",
            "  udhcpc -i eth0 -t 5 -T 1 -n -q -s /usr/share/udhcpc/default.script 2>/dev/null",
            "",
            "  # Source network init if present (injected by appendNetworkOverlay)",
            "  if [ -f /lumina-net-init ]; then",
            "    . /lumina-net-init",
            "  fi",
            ") &",
            "",
            "_lumina_mark agent_exec",
            "exec /usr/local/bin/lumina-agent",
            "INITEOF",
            "chmod 755 /sysroot/sbin/lumina-init",
            "",
            "# Switch root — lumina-init becomes PID 1 in the real rootfs",
            "_lumina_mark switch_root",
            "exec switch_root /sysroot /sbin/lumina-init",
        ]

        return lines.joined(separator: "\n") + "\n"
    }

    /// Append a network overlay to an existing combined initrd.
    /// Adds /lumina-hosts file and eth1 configuration to the init script.
    /// Called AFTER createCombinedInitrd, composes on top of it.
    static func appendNetworkOverlay(
        initrdURL: URL,
        hosts: [String: String],
        ip: String
    ) throws(LuminaError) {
        var cpio = Data()
        cpio.append(cpioEntry(path: ".", mode: 0o40755, data: Data()))

        // /lumina-hosts file
        var hostsContent = "127.0.0.1 localhost\n"
        for (name, addr) in hosts.sorted(by: { $0.key < $1.key }) {
            hostsContent += "\(addr) \(name)\n"
        }
        cpio.append(cpioEntry(path: "lumina-hosts", mode: 0o100644, data: Data(hostsContent.utf8)))

        // /lumina-net-init script (sourced by the main init if present)
        let netInit = """
        #!/bin/sh
        # Configure eth1 for private networking
        ip addr add "\(ip)/24" dev eth1 2>/dev/null
        ip link set eth1 up 2>/dev/null
        # Copy network hosts file
        if [ -f /lumina-hosts ]; then
            cp /lumina-hosts /etc/hosts
        fi
        """
        cpio.append(cpioEntry(path: "lumina-net-init", mode: 0o100755, data: Data(netInit.utf8)))

        cpio.append(cpioTrailer())

        let compressedCpio = try gzipCompress(cpio, tempDir: initrdURL.deletingLastPathComponent())

        // Append to existing initrd (Linux supports concatenated initramfs)
        do {
            let handle = try FileHandle(forWritingTo: initrdURL)
            handle.seekToEndOfFile()
            handle.write(compressedCpio)
            try handle.close()
        } catch {
            throw .bootFailed(underlying: PatcherError.writeFailed("network overlay: \(error)"))
        }
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
        // -1 (fastest): 27ms vs -9 (slowest): 277ms on a 2.4MB agent binary.
        // Size difference is ~130KB — decompressed once during kernel boot.
        process.arguments = ["-f", "-1", inputFile.path]
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
