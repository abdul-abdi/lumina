#!/usr/bin/env bash
# Guest/fetch-apple-kernel.sh
# Sets up a Lumina image directory using Apple's containerization kernel.
#
# Apple ships a custom-stripped Linux kernel (CONFIG_MODULES=n, all virtio
# drivers built-in) with their `container` CLI. It reaches /sbin/init in
# ~85ms vs ~2100ms for Alpine's linux-virt. Lumina can boot it unmodified
# with an Alpine rootfs — 7-8× cold-boot speedup on M3 Pro.
#
# This script copies that kernel into a Lumina image directory, creating
# a baked-mode image (kernel + rootfs, no initrd, agent pre-installed in
# rootfs). Requires an existing Lumina rootfs to clone from (falls back
# to building one if none exists).
#
# Apple's kernel is open-source (Apache 2.0, github.com/apple/containerization).
# Lumina does NOT bundle it; it's on the user to install Apple's CLI which
# builds and places the kernel locally. This keeps the dependency explicit.
#
# Usage:
#   bash fetch-apple-kernel.sh                 # image name defaults to "fast"
#   bash fetch-apple-kernel.sh --name default  # overwrite default image
#
# Requires: apple/container CLI installed (https://github.com/apple/container).
# Install: brew install --cask container

set -euo pipefail

IMAGE_NAME="fast"
while [ $# -gt 0 ]; do
    case "$1" in
        --name) IMAGE_NAME="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

APPLE_KERNEL_DIR="$HOME/Library/Application Support/com.apple.container/kernels"
LUMINA_IMAGES="$HOME/.lumina/images"
TARGET_DIR="$LUMINA_IMAGES/$IMAGE_NAME"
SOURCE_ROOTFS="$LUMINA_IMAGES/default/rootfs.img"
# Fall back to legacy-alpine if default has already been flipped to baked.
if [ ! -f "$SOURCE_ROOTFS" ]; then
    SOURCE_ROOTFS="$LUMINA_IMAGES/legacy-alpine/rootfs.img"
fi

echo "=== Lumina: set up fast image using Apple's kernel ==="

# ── Locate Apple's kernel ──────────────────────────────────
if [ ! -d "$APPLE_KERNEL_DIR" ]; then
    cat >&2 <<EOF
Error: Apple container kernel directory not found:
  $APPLE_KERNEL_DIR

Install Apple's container CLI to get the kernel:
  brew install --cask container

Or build the kernel from source:
  https://github.com/apple/containerization
EOF
    exit 1
fi

# Prefer the symlinked default.kernel-arm64 so this tracks Apple's updates.
KERNEL=""
if [ -L "$APPLE_KERNEL_DIR/default.kernel-arm64" ]; then
    KERNEL="$APPLE_KERNEL_DIR/default.kernel-arm64"
elif [ -L "$APPLE_KERNEL_DIR/default.vmlinux" ]; then
    KERNEL="$APPLE_KERNEL_DIR/default.vmlinux"
else
    # Fall back: pick the newest vmlinux-*.
    KERNEL=$(ls -t "$APPLE_KERNEL_DIR"/vmlinux-* 2>/dev/null | head -1 || true)
fi

if [ -z "$KERNEL" ] || [ ! -f "$KERNEL" ]; then
    echo "Error: no kernel found in $APPLE_KERNEL_DIR" >&2
    echo "Run \`container system start\` to trigger kernel setup." >&2
    exit 1
fi

echo "Kernel:  $(basename "$KERNEL")"
echo "Size:    $(du -h "$KERNEL" | cut -f1)"

# ── Locate source rootfs ──────────────────────────────────
if [ ! -f "$SOURCE_ROOTFS" ]; then
    cat >&2 <<EOF
Error: no existing Lumina rootfs to clone from.
Looked in:
  $LUMINA_IMAGES/default/rootfs.img
  $LUMINA_IMAGES/legacy-alpine/rootfs.img

Build one first:
  bash Guest/build-image.sh
EOF
    exit 1
fi

echo "Rootfs:  $SOURCE_ROOTFS"

# ── Assemble image directory ──────────────────────────────
mkdir -p "$TARGET_DIR"
cp "$KERNEL" "$TARGET_DIR/vmlinuz"
# APFS COW clone — instant, ~30ms even for multi-GB rootfs.
cp -c "$SOURCE_ROOTFS" "$TARGET_DIR/rootfs.img"

# Write minimal meta.json so `lumina images inspect` reports source.
cat > "$TARGET_DIR/meta.json" <<EOF
{
  "name": "$IMAGE_NAME",
  "kernel_source": "apple/container",
  "kernel_file": "$(basename "$KERNEL")",
  "boot_contract": "baked",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo ""
echo "Image ready: $TARGET_DIR"
echo "  vmlinuz:    $(du -h "$TARGET_DIR/vmlinuz" | cut -f1)"
echo "  rootfs.img: $(du -h "$TARGET_DIR/rootfs.img" | cut -f1)"
echo "  initrd:     (none — baked mode, kernel boots directly to rootfs)"
echo ""
echo "Try it:  lumina run --image $IMAGE_NAME \"echo ready\""
