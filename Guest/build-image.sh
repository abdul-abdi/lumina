#!/bin/bash
# Guest/build-image.sh
# Builds the default Alpine Linux image for Lumina VMs.
# Works natively on macOS and Linux — no Docker, no sudo.
#
# Prerequisites: e2fsprogs (brew install e2fsprogs), curl, zstd, Go (for agent)
# Output: ~/.lumina/images/default/{vmlinuz, rootfs.img}

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${1:-$HOME/.lumina/images/default}"
KERNEL="${LUMINA_KERNEL:-}"
WORK_DIR=$(mktemp -d)
ALPINE_VERSION="3.24"
ALPINE_ARCH="aarch64"
ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}"
ROOTFS_SIZE_MB=1024

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

echo "=== Lumina Image Builder ==="
echo "Output: $OUTPUT_DIR"

# --- Prerequisites ---

AGENT_BINARY="$SCRIPT_DIR/lumina-agent/lumina-agent"
if [ ! -f "$AGENT_BINARY" ]; then
    echo "--- Building guest agent (Go cross-compile) ---"
    (cd "$SCRIPT_DIR/lumina-agent" && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -ldflags="-s -w" -o lumina-agent .)
fi

# Find mke2fs — Homebrew installs e2fsprogs outside PATH on macOS
MKE2FS=$(command -v mke2fs 2>/dev/null || true)
if [ -z "$MKE2FS" ]; then
    for prefix in /opt/homebrew /usr/local; do
        if [ -x "$prefix/opt/e2fsprogs/sbin/mke2fs" ]; then
            MKE2FS="$prefix/opt/e2fsprogs/sbin/mke2fs"
            break
        fi
    done
fi
DEBUGFS=$(command -v debugfs 2>/dev/null || true)
if [ -z "$DEBUGFS" ]; then
    for prefix in /opt/homebrew /usr/local; do
        if [ -x "$prefix/opt/e2fsprogs/sbin/debugfs" ]; then
            DEBUGFS="$prefix/opt/e2fsprogs/sbin/debugfs"
            break
        fi
    done
fi
if [ -z "$MKE2FS" ] || [ -z "$DEBUGFS" ]; then
    echo "Error: e2fsprogs tools (mke2fs, debugfs) not found."
    if [[ "$(uname)" == "Darwin" ]]; then
        echo "  Install: brew install e2fsprogs"
    else
        echo "  Install: apt-get install e2fsprogs"
    fi
    exit 1
fi

# ============================================================
# Step 1: Download Alpine minirootfs
# ============================================================
echo "--- Step 1: Downloading Alpine minirootfs ---"
MINIROOTFS="alpine-minirootfs-${ALPINE_VERSION}.0-${ALPINE_ARCH}.tar.gz"
curl -fSL "${ALPINE_MIRROR}/releases/${ALPINE_ARCH}/${MINIROOTFS}" -o "$WORK_DIR/$MINIROOTFS"

if [ -z "$KERNEL" ]; then
    echo "--- Step 2: Fetching guest kernel ---"
    KERNEL="$WORK_DIR/vmlinuz"
    bash "$SCRIPT_DIR/fetch-kernel.sh" "$KERNEL"
fi

# ============================================================
# Step 4: Build rootfs directory tree + ext4 image
# ============================================================
echo "--- Step 4: Building rootfs ---"
ROOTFS_DIR="$WORK_DIR/rootfs"
mkdir -p "$ROOTFS_DIR"
tar xzf "$WORK_DIR/$MINIROOTFS" -C "$ROOTFS_DIR"

# Install lumina-agent
mkdir -p "$ROOTFS_DIR/usr/local/bin"
cp "$AGENT_BINARY" "$ROOTFS_DIR/usr/local/bin/lumina-agent"
chmod 755 "$ROOTFS_DIR/usr/local/bin/lumina-agent"

# The kernel boots straight to this rootfs and runs /sbin/init as PID 1.
rm -f "$ROOTFS_DIR/sbin/init"
cat > "$ROOTFS_DIR/sbin/init" << 'INITEOF'
#!/bin/sh
# Lumina init — baked into rootfs image

# The kernel gives PID 1 only HOME and TERM. BusyBox ash finds commands
# via a built-in default it never exports, so anything we exec that is
# not a shell — the Go agent, and every process it spawns — would see an
# empty PATH and fail to resolve `ip`, `mount`, or anything else by name.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

mount -t proc proc /proc 2>/dev/null
mount -t sysfs sys /sys 2>/dev/null
mount -t devtmpfs dev /dev 2>/dev/null
# openpty(3) needs a devpts instance, not just /dev/ptmx. Without this every
# `exec --pty` fails with "open /dev/ptmx: no such file or directory".
mkdir -p /dev/pts 2>/dev/null
mount -t devpts devpts /dev/pts -o gid=5,mode=620,ptmxmode=666 2>/dev/null

# Boot profile markers — parsed by host from dmesg (BootProfile).
# Writes to /dev/kmsg; visible via SerialConsole or `dmesg | grep LUMINA_BOOT`.
_lumina_mark() { echo "LUMINA_BOOT phase=$1 t=$(cut -d' ' -f1 /proc/uptime)" > /dev/kmsg 2>/dev/null; }
_lumina_mark init_start

hostname lumina 2>/dev/null
ip link set lo up 2>/dev/null
ip link set eth0 up 2>/dev/null

# Parse all lumina_* kernel cmdline params in ONE pass.
LUMINA_MOUNTS=
LUMINA_ROSETTA=
LUMINA_NET_IP=
LUMINA_HOSTS=
for param in $(cat /proc/cmdline); do
  case "$param" in
    lumina_mounts=*)  LUMINA_MOUNTS="${param#lumina_mounts=}" ;;
    lumina_rosetta=*) LUMINA_ROSETTA="${param#lumina_rosetta=}" ;;
    lumina_ip=*)      LUMINA_NET_IP="${param#lumina_ip=}" ;;
    lumina_hosts=*)   LUMINA_HOSTS="${param#lumina_hosts=}" ;;
  esac
done

# Mount virtio-fs shares BEFORE agent starts (commands may need mounted paths)
if [ -n "$LUMINA_MOUNTS" ]; then
  OLD_IFS="$IFS"
  IFS=','
  for spec in $LUMINA_MOUNTS; do
    tag="${spec%%:*}"
    mpath="${spec#*:}"
    mkdir -p "$mpath"
    mount -t virtiofs "$tag" "$mpath" 2>/dev/null
  done
  IFS="$OLD_IFS"
fi

# Rosetta (x86_64 binary translation)
if [ "$LUMINA_ROSETTA" = "1" ]; then
  mkdir -p /mnt/rosetta
  mount -t virtiofs rosetta /mnt/rosetta 2>/dev/null
  if [ -f /mnt/rosetta/rosetta ]; then
    mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null
    echo ':rosetta:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00:\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/mnt/rosetta/rosetta:F' > /proc/sys/fs/binfmt_misc/register 2>/dev/null
  fi
fi

# Background network config — off the critical path.
# The agent communicates via vsock (not TCP), so it can start and
# send 'ready' before the network is up.
(
  # Wait for carrier on eth0 (VZ NAT link takes ~100ms to come up)
  n=0
  while [ "$n" -lt 20 ] && ! ip link show eth0 2>/dev/null | grep -q 'state UP'; do
    sleep 0.1
    n=$((n+1))
  done

  # Disable IPv6 — VZ NAT only provides IPv4 routing.
  # The host-side `configure_network` (network.go) does this too;
  # keeping it here so eth0 stays sane even if the host driver
  # doesn't run (e.g. custom library callers that skip
  # `vm.configureNetwork()`).
  echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null

  # NOTE: udhcpc was previously invoked here as a fallback DHCP
  # client. Removed in v0.7.2 — every internal caller of `VM`
  # (Lumina.run, Lumina.stream, Lumina.createImage,
  # SessionProcess, Pool, Network) drives `configure_network`
  # over vsock, which is faster and authoritative. udhcpc raced
  # the host driver, occasionally installed a different IP/route
  # than the host requested, and added 30–80 ms of churn on
  # every boot.
  #
  # Library callers using the public `VM` actor directly
  # (Layer 3 — Lifecycle in the three-layer API) MUST call
  # `vm.configureNetwork()` themselves before the first exec
  # if they need NAT eth0 outbound (DNS, internet). Skipping
  # it leaves eth0 admin-down with no IP/route — traffic out
  # the default route will fail. See the docstring on
  # `VM.boot()`. configureNetwork() brings eth0 up via
  # `ip link set eth0 up` and assigns the IP/route over vsock.

  # Private networking config — LUMINA_NET_IP / LUMINA_HOSTS were parsed
  # from /proc/cmdline at init start (outer scope).
  if [ -n "$LUMINA_NET_IP" ]; then
    ip addr add "${LUMINA_NET_IP}/24" dev eth1 2>/dev/null
    ip link set eth1 up 2>/dev/null
  fi
  if [ -n "$LUMINA_HOSTS" ]; then
    echo "127.0.0.1 localhost" > /etc/hosts
    OLD_IFS="$IFS"
    IFS=','
    for entry in $LUMINA_HOSTS; do
      name="${entry%%:*}"
      addr="${entry#*:}"
      echo "$addr $name" >> /etc/hosts
    done
    IFS="$OLD_IFS"
  fi
) &

_lumina_mark agent_exec
exec /usr/local/bin/lumina-agent
INITEOF
chmod 755 "$ROOTFS_DIR/sbin/init"

echo "--- Step 5: Creating rootfs.img (ext4, no mount/sudo) ---"
"$MKE2FS" -t ext4 -d "$ROOTFS_DIR" -b 4096 -q "$WORK_DIR/rootfs.img" "${ROOTFS_SIZE_MB}M"

# Fix file ownership — mke2fs -d copies host UIDs (e.g. 501 on macOS).
# Set all files/dirs to root:root so the rootfs has correct metadata.
UID_FIX="$WORK_DIR/fix_uids.cmds"
(cd "$ROOTFS_DIR" && find . -mindepth 1) | while IFS= read -r entry; do
    entry="${entry#./}"
    echo "set_inode_field \"$entry\" uid 0"
    echo "set_inode_field \"$entry\" gid 0"
done > "$UID_FIX"
"$DEBUGFS" -w -f "$UID_FIX" "$WORK_DIR/rootfs.img" >/dev/null 2>&1

# ============================================================
# Step 6: Copy outputs
# ============================================================
echo "--- Step 6: Saving to $OUTPUT_DIR ---"
mkdir -p "$OUTPUT_DIR"
cp "$KERNEL" "$OUTPUT_DIR/vmlinuz"
cp "$WORK_DIR/rootfs.img" "$OUTPUT_DIR/rootfs.img"
echo "=== Done ==="
echo "  vmlinuz:    $(du -h "$OUTPUT_DIR/vmlinuz" | cut -f1)"
echo "  rootfs.img: $(du -h "$OUTPUT_DIR/rootfs.img" | cut -f1)"
