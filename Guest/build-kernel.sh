#!/bin/bash
# Guest/build-kernel.sh
# Builds a custom minimal Linux kernel for Lumina VMs.
# All required drivers compiled built-in (=y), CONFIG_MODULES=n.
#
# Must be run on Linux arm64 (native compile on CI).
# Output: a raw ARM64 Image suitable for VZLinuxBootLoader.
#
# Prerequisites: build-essential, flex, bison, bc, libelf-dev, libssl-dev, curl
# Usage: bash build-kernel.sh <output-vmlinuz-path>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT="${1:?Usage: build-kernel.sh <output-path>}"
WORK_DIR=$(mktemp -d)
ALPINE_VERSION="3.20"
ALPINE_ARCH="aarch64"
ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}"

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

echo "=== Lumina Kernel Builder ==="

# ── Step 1: Determine kernel version from Alpine ────────────
echo "--- Step 1: Resolving kernel version ---"
curl -fsSL "${ALPINE_MIRROR}/main/${ALPINE_ARCH}/APKINDEX.tar.gz" \
    | tar xzf - -C "$WORK_DIR" APKINDEX 2>/dev/null
PKGVER=$(awk '/^P:linux-virt$/,/^$/' "$WORK_DIR/APKINDEX" | awk -F: '/^V:/{print $2}')
if [ -z "$PKGVER" ]; then
    echo "Error: could not determine linux-virt package version"
    exit 1
fi

# Extract major.minor.patch from Alpine package version (e.g. "6.6.87-r0" -> "6.6.87")
KERNEL_VERSION="${PKGVER%%-*}"
KERNEL_MAJOR="${KERNEL_VERSION%%.*}"
KERNEL_REST="${KERNEL_VERSION#*.}"
KERNEL_MINOR="${KERNEL_REST%%.*}"

echo "  Alpine linux-virt: $PKGVER"
echo "  Kernel version:    $KERNEL_VERSION"

# ── Step 2: Download kernel source ──────────────────────────
echo "--- Step 2: Downloading kernel $KERNEL_VERSION source ---"
KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_MAJOR}.x/linux-${KERNEL_VERSION}.tar.xz"
curl -fSL "$KERNEL_URL" -o "$WORK_DIR/linux.tar.xz"
echo "  Extracting..."
tar xf "$WORK_DIR/linux.tar.xz" -C "$WORK_DIR"
KERNEL_SRC="$WORK_DIR/linux-${KERNEL_VERSION}"

# ── Step 3: Configure kernel ───────────────────────────────
echo "--- Step 3: Configuring kernel ---"
cd "$KERNEL_SRC"

# Use arm64 defconfig as the base — NOT Alpine's virt config.
#
# Alpine's virt config has hundreds of =m (module) entries because Alpine
# uses initramfs to load modules at boot. When we set CONFIG_MODULES=n,
# conf --olddefconfig hits dependency violations: some =y config selects a
# symbol that depends on MODULES, which is now disabled. conf writes the
# .config and then exits 1 (conf_errors() > 0) with no error message printed.
#
# arm64 defconfig is cleaner: virtio configs are already =y, there are far
# fewer =m entries, and no Alpine-specific quirks.
echo "  Base config: arm64 defconfig"
make defconfig 2>&1

echo "  Applying Lumina overrides..."

# Disable module support entirely — all drivers must be built-in.
# --disable writes "# CONFIG_MODULES is not set" (correct bool form).
# Do NOT use --set-val X n — "CONFIG_X=n" is invalid for bool configs and
# causes conf --olddefconfig to exit 1.
"$KERNEL_SRC/scripts/config" --disable CONFIG_MODULES

# Filesystem: ext4 + dependencies
"$KERNEL_SRC/scripts/config" --enable CONFIG_EXT4_FS
"$KERNEL_SRC/scripts/config" --enable CONFIG_JBD2
"$KERNEL_SRC/scripts/config" --enable CONFIG_MBCACHE
"$KERNEL_SRC/scripts/config" --enable CONFIG_CRC16
"$KERNEL_SRC/scripts/config" --enable CONFIG_CRC32
"$KERNEL_SRC/scripts/config" --enable CONFIG_CRYPTO_CRC32C

# Block device
"$KERNEL_SRC/scripts/config" --enable CONFIG_VIRTIO_BLK

# Networking
"$KERNEL_SRC/scripts/config" --enable CONFIG_VIRTIO_NET
"$KERNEL_SRC/scripts/config" --enable CONFIG_PACKET
"$KERNEL_SRC/scripts/config" --enable CONFIG_NET_FAILOVER
"$KERNEL_SRC/scripts/config" --enable CONFIG_FAILOVER

# vsock (agent communication)
"$KERNEL_SRC/scripts/config" --enable CONFIG_VSOCKETS
"$KERNEL_SRC/scripts/config" --enable CONFIG_VIRTIO_VSOCKETS
# CONFIG_VIRTIO_VSOCKETS_COMMON is a hidden symbol selected automatically —
# do not set it explicitly.

# FUSE + virtiofs (directory sharing)
"$KERNEL_SRC/scripts/config" --enable CONFIG_FUSE_FS
"$KERNEL_SRC/scripts/config" --enable CONFIG_VIRTIO_FS

# VirtIO core (must be built-in for all virtio devices)
"$KERNEL_SRC/scripts/config" --enable CONFIG_VIRTIO
"$KERNEL_SRC/scripts/config" --enable CONFIG_VIRTIO_MMIO
"$KERNEL_SRC/scripts/config" --enable CONFIG_VIRTIO_PCI

# Serial console (Apple Virtualization.framework console)
"$KERNEL_SRC/scripts/config" --enable CONFIG_HVC_DRIVER
"$KERNEL_SRC/scripts/config" --enable CONFIG_VIRTIO_CONSOLE

# Entropy source
"$KERNEL_SRC/scripts/config" --enable CONFIG_HW_RANDOM_VIRTIO

# devtmpfs (auto-populated /dev at boot)
"$KERNEL_SRC/scripts/config" --enable CONFIG_DEVTMPFS
"$KERNEL_SRC/scripts/config" --enable CONFIG_DEVTMPFS_MOUNT

echo "  Resolving dependencies (olddefconfig)..."
if ! make olddefconfig 2>&1; then
    echo "ERROR: make olddefconfig failed. .config snapshot:"
    grep -E "^CONFIG_MODULES|^CONFIG_VIRTIO|^CONFIG_VSOCK|^CONFIG_EXT4|^CONFIG_FUSE" \
        .config 2>/dev/null | sort || true
    exit 1
fi

# Verify critical configs survived olddefconfig — it can silently downgrade
# =y to =m or =n if dependency resolution conflicts. If any of these aren't
# built-in, the VM will boot but fail silently (no vsock = no agent comms,
# no ext4 = can't mount root, no virtio_blk = no disk).
echo "  Verifying critical configs..."
CRITICAL_CONFIGS=(
    CONFIG_MODULES:n          # No module loading
    CONFIG_EXT4_FS:y          # Root filesystem
    CONFIG_VIRTIO_BLK:y       # Block device
    CONFIG_VIRTIO_NET:y       # Network
    CONFIG_VSOCKETS:y         # Agent communication
    CONFIG_VIRTIO_VSOCKETS:y  # vsock transport
    CONFIG_FUSE_FS:y          # virtiofs dependency
    CONFIG_VIRTIO_FS:y        # Directory sharing
    CONFIG_VIRTIO:y           # VirtIO core
    CONFIG_DEVTMPFS:y         # /dev population
)

FAILED=false
for entry in "${CRITICAL_CONFIGS[@]}"; do
    KEY="${entry%%:*}"
    EXPECTED="${entry#*:}"
    # Use || true to prevent bash 4.4+ set -e from exiting when grep finds no
    # match (exit 1). With set -euo pipefail, a failed pipeline inside $()
    # propagates as a non-zero assignment exit status and triggers errexit
    # before any echo runs — silently killing the loop.
    if [ "$EXPECTED" = "n" ]; then
        ACTUAL=$(grep "^${KEY}=" .config 2>/dev/null | cut -d= -f2) || true
        if [ -n "$ACTUAL" ] && [ "$ACTUAL" != "n" ]; then
            echo "  FAIL: $KEY=$ACTUAL (expected not set or =n)"
            FAILED=true
        else
            echo "  OK:   $KEY is disabled"
        fi
    else
        ACTUAL=$(grep "^${KEY}=" .config 2>/dev/null | cut -d= -f2) || true
        if [ "$ACTUAL" != "$EXPECTED" ]; then
            echo "  FAIL: $KEY=$ACTUAL (expected =$EXPECTED)"
            FAILED=true
        else
            echo "  OK:   $KEY=$ACTUAL"
        fi
    fi
done

if [ "$FAILED" = true ]; then
    echo "Error: Critical kernel configs were downgraded by olddefconfig."
    echo "Check dependency conflicts in the kernel config."
    exit 1
fi

# ── Step 4: Build kernel ───────────────────────────────────
echo "--- Step 4: Building kernel ($(nproc) threads) ---"
make -j"$(nproc)" Image

# The raw ARM64 Image is at arch/arm64/boot/Image
KERNEL_IMAGE="$KERNEL_SRC/arch/arm64/boot/Image"
if [ ! -f "$KERNEL_IMAGE" ]; then
    echo "Error: Kernel build did not produce arch/arm64/boot/Image"
    exit 1
fi

# ── Step 5: Verify ARM64 Image magic ──────────────────────
MAGIC=$(dd if="$KERNEL_IMAGE" bs=1 skip=56 count=4 2>/dev/null | od -A n -t x1 | tr -cd '0-9a-f')
if [ "$MAGIC" != "41524d64" ]; then
    echo "Error: Built kernel missing ARM64 Image magic (got: $MAGIC)"
    exit 1
fi

# ── Step 6: Copy output ───────────────────────────────────
mkdir -p "$(dirname "$OUTPUT")"
cp "$KERNEL_IMAGE" "$OUTPUT"

KERNEL_SIZE=$(du -h "$OUTPUT" | cut -f1)
KERNEL_SHA=$(sha256sum "$OUTPUT" | cut -d' ' -f1)

echo "=== Kernel Build Complete ==="
echo "  Output:   $OUTPUT"
echo "  Size:     $KERNEL_SIZE"
echo "  SHA-256:  $KERNEL_SHA"
echo "  Version:  $KERNEL_VERSION"
echo "  Modules:  disabled (CONFIG_MODULES=n)"
