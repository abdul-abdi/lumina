#!/bin/bash
# Guest/build-image.sh
# Builds the default Alpine Linux image for Lumina VMs.
#
# On macOS: automatically runs inside a Docker container (requires Docker Desktop).
# On Linux: runs natively (requires root/sudo + e2fsprogs).
#
# Output: ~/.lumina/images/default/{vmlinuz, initrd, rootfs.img}

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${1:-$HOME/.lumina/images/default}"

# --- macOS: delegate to Docker ---
if [[ "$(uname)" == "Darwin" ]]; then
    echo "=== macOS detected — building inside Docker ==="

    if ! command -v docker &>/dev/null; then
        echo "Error: Docker is required to build images on macOS."
        echo "Install Docker Desktop: https://www.docker.com/products/docker-desktop/"
        exit 1
    fi

    if ! docker info &>/dev/null; then
        echo "Error: Docker daemon is not running. Start Docker Desktop and try again."
        exit 1
    fi

    # Build guest agent if not already built
    AGENT_BINARY="$SCRIPT_DIR/lumina-agent/lumina-agent"
    if [ ! -f "$AGENT_BINARY" ]; then
        echo "--- Building guest agent (Go cross-compile) ---"
        (cd "$SCRIPT_DIR/lumina-agent" && GOOS=linux GOARCH=arm64 go build -ldflags="-s -w" -o lumina-agent .)
    fi

    mkdir -p "$OUTPUT_DIR"

    docker run --rm --platform linux/arm64 \
        -v "$SCRIPT_DIR:/guest:ro" \
        -v "$OUTPUT_DIR:/out" \
        alpine:3.20 sh -c "
            apk add --no-cache e2fsprogs bash curl &&
            bash /guest/build-image.sh /out
        "

    echo "=== Done (via Docker) ==="
    echo "Image saved to: $OUTPUT_DIR"
    ls -lh "$OUTPUT_DIR"/
    exit 0
fi

# --- Linux: native build ---
AGENT_BINARY="$SCRIPT_DIR/lumina-agent/lumina-agent"
WORK_DIR=$(mktemp -d)
ALPINE_VERSION="3.20"
ALPINE_ARCH="aarch64"
ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}"
ROOTFS_SIZE="1G"

cleanup() {
    echo "Cleaning up..."
    sudo umount "$WORK_DIR/rootfs" 2>/dev/null || true
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

echo "=== Lumina Image Builder ==="
echo "Output: $OUTPUT_DIR"
echo "Work dir: $WORK_DIR"

# Check prerequisites
if [ ! -f "$AGENT_BINARY" ]; then
    echo "Error: lumina-agent binary not found at $AGENT_BINARY"
    echo "Build it first: cd Guest/lumina-agent && GOOS=linux GOARCH=arm64 go build -ldflags='-s -w' -o lumina-agent ."
    exit 1
fi

if ! command -v mkfs.ext4 &>/dev/null; then
    echo "Error: mkfs.ext4 not found. Install e2fsprogs: apt-get install e2fsprogs (or apk add e2fsprogs)"
    exit 1
fi

# ============================================================
# Step 1: Download Alpine minirootfs
# ============================================================
echo "--- Step 1: Downloading Alpine minirootfs ---"
MINIROOTFS="alpine-minirootfs-${ALPINE_VERSION}.0-${ALPINE_ARCH}.tar.gz"
curl -fSL "${ALPINE_MIRROR}/releases/${ALPINE_ARCH}/${MINIROOTFS}" -o "$WORK_DIR/$MINIROOTFS"

# ============================================================
# Step 2: Get kernel + initramfs from Alpine linux-virt package
# ============================================================
echo "--- Step 2: Installing Alpine virt kernel ---"
BOOT_ROOT="$WORK_DIR/apk-root"
mkdir -p "$BOOT_ROOT"
tar xzf "$WORK_DIR/$MINIROOTFS" -C "$BOOT_ROOT"

# Install linux-virt via chroot to get vmlinuz + initramfs
sudo cp /etc/resolv.conf "$BOOT_ROOT/etc/resolv.conf" 2>/dev/null || true

# Mount necessary filesystems for chroot
sudo mount -t proc proc "$BOOT_ROOT/proc" 2>/dev/null || true
sudo mount -t sysfs sys "$BOOT_ROOT/sys" 2>/dev/null || true
sudo mount --bind /dev "$BOOT_ROOT/dev" 2>/dev/null || true

sudo chroot "$BOOT_ROOT" /sbin/apk add --no-cache linux-virt

# Unmount chroot filesystems
sudo umount "$BOOT_ROOT/dev" 2>/dev/null || true
sudo umount "$BOOT_ROOT/sys" 2>/dev/null || true
sudo umount "$BOOT_ROOT/proc" 2>/dev/null || true

# Find kernel and initrd at their known paths
VMLINUZ="$BOOT_ROOT/boot/vmlinuz-virt"
INITRD="$BOOT_ROOT/boot/initramfs-virt"

if [ ! -f "$VMLINUZ" ]; then
    echo "Error: vmlinuz-virt not found at $VMLINUZ"
    echo "Contents of $BOOT_ROOT/boot/:"
    ls -la "$BOOT_ROOT/boot/" 2>/dev/null || echo "(directory does not exist)"
    exit 1
fi

if [ ! -f "$INITRD" ]; then
    echo "Error: initramfs-virt not found at $INITRD"
    echo "Contents of $BOOT_ROOT/boot/:"
    ls -la "$BOOT_ROOT/boot/" 2>/dev/null || echo "(directory does not exist)"
    exit 1
fi

echo "  vmlinuz:    $(du -h "$VMLINUZ" | cut -f1)"
echo "  initramfs:  $(du -h "$INITRD" | cut -f1)"

# ============================================================
# Step 3: Create rootfs.img (ext4)
# ============================================================
echo "--- Step 3: Creating rootfs.img ---"
dd if=/dev/zero of="$WORK_DIR/rootfs.img" bs=1 count=0 seek="$ROOTFS_SIZE" 2>/dev/null
mkfs.ext4 -q -F "$WORK_DIR/rootfs.img"

# ============================================================
# Step 4: Populate rootfs
# ============================================================
echo "--- Step 4: Populating rootfs ---"
mkdir -p "$WORK_DIR/rootfs"
sudo mount -t ext4 -o loop "$WORK_DIR/rootfs.img" "$WORK_DIR/rootfs"

# Extract Alpine base
sudo tar xzf "$WORK_DIR/$MINIROOTFS" -C "$WORK_DIR/rootfs"

# Install lumina-agent
sudo mkdir -p "$WORK_DIR/rootfs/usr/local/bin"
sudo cp "$AGENT_BINARY" "$WORK_DIR/rootfs/usr/local/bin/lumina-agent"
sudo chmod +x "$WORK_DIR/rootfs/usr/local/bin/lumina-agent"

# Create minimal init script (no OpenRC — direct exec)
sudo tee "$WORK_DIR/rootfs/sbin/init" > /dev/null << 'INITEOF'
#!/bin/sh
# Lumina minimal init
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev

# Set hostname
hostname lumina

# Configure networking (for outbound NAT)
ip link set lo up 2>/dev/null
ip link set eth0 up 2>/dev/null
udhcpc -i eth0 -s /usr/share/udhcpc/default.script -q 2>/dev/null &

# Start lumina-agent
exec /usr/local/bin/lumina-agent
INITEOF
sudo chmod +x "$WORK_DIR/rootfs/sbin/init"

# Install extra tools in the rootfs via chroot
echo "--- Installing extra tools in rootfs ---"
sudo cp /etc/resolv.conf "$WORK_DIR/rootfs/etc/resolv.conf" 2>/dev/null || true
sudo mount -t proc proc "$WORK_DIR/rootfs/proc" 2>/dev/null || true
sudo mount -t sysfs sys "$WORK_DIR/rootfs/sys" 2>/dev/null || true
sudo mount --bind /dev "$WORK_DIR/rootfs/dev" 2>/dev/null || true

sudo chroot "$WORK_DIR/rootfs" /sbin/apk add --no-cache \
    python3 git curl ca-certificates 2>/dev/null || echo "Warning: could not install extra tools (non-fatal)"

sudo umount "$WORK_DIR/rootfs/dev" 2>/dev/null || true
sudo umount "$WORK_DIR/rootfs/sys" 2>/dev/null || true
sudo umount "$WORK_DIR/rootfs/proc" 2>/dev/null || true
sudo umount "$WORK_DIR/rootfs"

# ============================================================
# Step 5: Copy outputs
# ============================================================
echo "--- Step 5: Saving to $OUTPUT_DIR ---"
mkdir -p "$OUTPUT_DIR"
cp "$VMLINUZ" "$OUTPUT_DIR/vmlinuz"
cp "$INITRD" "$OUTPUT_DIR/initrd"
cp "$WORK_DIR/rootfs.img" "$OUTPUT_DIR/rootfs.img"

echo "=== Done ==="
echo "Image saved to: $OUTPUT_DIR"
echo "  vmlinuz:    $(du -h "$OUTPUT_DIR/vmlinuz" | cut -f1)"
echo "  initrd:     $(du -h "$OUTPUT_DIR/initrd" | cut -f1)"
echo "  rootfs.img: $(du -h "$OUTPUT_DIR/rootfs.img" | cut -f1)"
