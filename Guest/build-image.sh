#!/bin/bash
# Guest/build-image.sh
# Builds the default Alpine Linux image for Lumina VMs.
#
# On macOS: automatically runs inside a Docker container (requires Docker Desktop).
# On Linux: runs natively (requires root/sudo).
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

# 1. Download Alpine minirootfs
echo "--- Downloading Alpine minirootfs ---"
MINIROOTFS="alpine-minirootfs-${ALPINE_VERSION}.0-${ALPINE_ARCH}.tar.gz"
curl -fSL "${ALPINE_MIRROR}/releases/${ALPINE_ARCH}/${MINIROOTFS}" -o "$WORK_DIR/$MINIROOTFS"

# 2. Download Alpine kernel and initrd (virt flavor)
echo "--- Downloading Alpine virt kernel ---"
mkdir -p "$WORK_DIR/boot"
# Fetch the kernel package and extract vmlinuz + initramfs
KERNEL_PKG_URL="${ALPINE_MIRROR}/main/${ALPINE_ARCH}"
# Use apk to fetch kernel files into work dir
cd "$WORK_DIR"
mkdir -p apk-root
tar xzf "$MINIROOTFS" -C apk-root

# Chroot and install kernel
sudo cp /etc/resolv.conf apk-root/etc/resolv.conf 2>/dev/null || true
sudo chroot apk-root /sbin/apk add --no-cache linux-virt 2>/dev/null || {
    # Fallback: install via apk with root dir
    sudo apk add --root apk-root --initdb --no-cache linux-virt 2>/dev/null || {
        echo "Downloading kernel directly..."
        # Direct download fallback
        curl -fSL "${KERNEL_PKG_URL}/$(curl -fsSL ${KERNEL_PKG_URL}/ | grep -o 'linux-virt-[0-9][^"]*\.apk' | head -1)" -o kernel.apk
        mkdir -p kernel-extract
        tar xzf kernel.apk -C kernel-extract 2>/dev/null || true
    }
}

# Find kernel and initrd
VMLINUZ=$(find "$WORK_DIR" -name "vmlinuz-*" -o -name "vmlinuz" 2>/dev/null | head -1)
INITRD=$(find "$WORK_DIR" -name "initramfs-*" -o -name "initrd" 2>/dev/null | head -1)

if [ -z "$VMLINUZ" ]; then
    echo "Error: Could not find vmlinuz. Kernel installation may have failed."
    exit 1
fi

# 3. Create rootfs.img
echo "--- Creating rootfs.img ---"
dd if=/dev/zero of="$WORK_DIR/rootfs.img" bs=1 count=0 seek="$ROOTFS_SIZE" 2>/dev/null
mkfs.ext4 -q -F "$WORK_DIR/rootfs.img"

# 4. Mount and populate rootfs
echo "--- Populating rootfs ---"
mkdir -p "$WORK_DIR/rootfs"
sudo mount -t ext4 -o loop "$WORK_DIR/rootfs.img" "$WORK_DIR/rootfs"

sudo tar xzf "$WORK_DIR/$MINIROOTFS" -C "$WORK_DIR/rootfs"

# Install lumina-agent
sudo mkdir -p "$WORK_DIR/rootfs/usr/local/bin"
sudo cp "$AGENT_BINARY" "$WORK_DIR/rootfs/usr/local/bin/lumina-agent"
sudo chmod +x "$WORK_DIR/rootfs/usr/local/bin/lumina-agent"

# Create minimal init script
sudo tee "$WORK_DIR/rootfs/sbin/init" > /dev/null << 'INITEOF'
#!/bin/sh
# Lumina minimal init
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev

# Set hostname
hostname lumina

# Start lumina-agent
exec /usr/local/bin/lumina-agent
INITEOF
sudo chmod +x "$WORK_DIR/rootfs/sbin/init"

# Install basic tools via apk in chroot
sudo chroot "$WORK_DIR/rootfs" /sbin/apk add --no-cache \
    python3 git curl ca-certificates 2>/dev/null || echo "Warning: could not install extra tools"

sudo umount "$WORK_DIR/rootfs"

# 5. Output
echo "--- Saving to $OUTPUT_DIR ---"
mkdir -p "$OUTPUT_DIR"
cp "$VMLINUZ" "$OUTPUT_DIR/vmlinuz"
[ -n "$INITRD" ] && cp "$INITRD" "$OUTPUT_DIR/initrd" || touch "$OUTPUT_DIR/initrd"
cp "$WORK_DIR/rootfs.img" "$OUTPUT_DIR/rootfs.img"

echo "=== Done ==="
echo "Image saved to: $OUTPUT_DIR"
echo "  vmlinuz:   $(du -h "$OUTPUT_DIR/vmlinuz" | cut -f1)"
echo "  initrd:    $(du -h "$OUTPUT_DIR/initrd" | cut -f1)"
echo "  rootfs.img: $(du -h "$OUTPUT_DIR/rootfs.img" | cut -f1)"
