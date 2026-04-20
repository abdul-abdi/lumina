#!/usr/bin/env bash
# tests/desktop.sh — EFI boot smoke test for v0.7.0 M3.
#
# Creates a fresh .luminaVM bundle with a small Alpine ARM64 ISO attached,
# boots it for 60 seconds, and asserts Alpine's init banner appears in the
# serial console. Destroys the bundle after.
#
# Requirements:
#   - Apple Silicon macOS host with VZ entitlement
#   - Codesigned `lumina` binary (make build)
#   - Network access to dl-cdn.alpinelinux.org
#
# Expected runtime: ~60 seconds after ISO cache is warm.
#
# Exit codes:
#   0  banner seen in serial output
#   1  banner not seen (boot likely failed)
#   2  missing dependency (curl, jq, etc.)
#   3  ISO checksum mismatch

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# -----------------------------------------------------------------------------
# Configuration — PRE-SHIP verify these before tagging v0.7.0.
# -----------------------------------------------------------------------------
# The exact URL and filename must be re-verified against
# https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64/ at
# the time of each tagged release. Alpine shuffles point releases; filenames
# change every few weeks.
ISO_URL="${LUMINA_DESKTOP_TEST_ISO_URL:-https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/aarch64/alpine-virt-3.20.3-aarch64.iso}"
ISO_SHA_FILE="$ROOT/tests/fixtures/alpine-efi.sha256"
CACHE_DIR="$HOME/.lumina/cache"
CACHE_ISO="$CACHE_DIR/alpine-efi.iso"

# -----------------------------------------------------------------------------
# Dependency checks
# -----------------------------------------------------------------------------
for tool in curl shasum timeout; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "error: missing required tool: $tool" >&2
        exit 2
    fi
done

# VZ capability check — fail fast on hosts that can't virtualize.
if ! sysctl -n kern.hv_support 2>/dev/null | grep -q 1; then
    echo "::notice::Host lacks VZ support (kern.hv_support != 1); skipping smoke test." >&2
    exit 0
fi

# -----------------------------------------------------------------------------
# ISO fetch + checksum
# -----------------------------------------------------------------------------
mkdir -p "$CACHE_DIR"
if [ ! -f "$CACHE_ISO" ]; then
    echo "Downloading Alpine ARM64 ISO from $ISO_URL"
    curl -fsSL -o "$CACHE_ISO" "$ISO_URL"
fi

if [ ! -f "$ISO_SHA_FILE" ]; then
    echo "Pinning first-seen checksum to $ISO_SHA_FILE (trust-on-first-use)"
    shasum -a 256 "$CACHE_ISO" | cut -d ' ' -f 1 > "$ISO_SHA_FILE"
fi

EXPECTED_SHA="$(cat "$ISO_SHA_FILE")"
ACTUAL_SHA="$(shasum -a 256 "$CACHE_ISO" | cut -d ' ' -f 1)"
if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
    echo "error: ISO checksum mismatch" >&2
    echo "  expected: $EXPECTED_SHA" >&2
    echo "  actual:   $ACTUAL_SHA" >&2
    exit 3
fi

# -----------------------------------------------------------------------------
# Run the test
# -----------------------------------------------------------------------------
BIN="$(swift build --show-bin-path)/lumina"
if [ ! -x "$BIN" ]; then
    echo "error: binary not found at $BIN (run 'make build' first)" >&2
    exit 2
fi

# Ephemeral working directory; cleaned up on exit.
WORK="$(mktemp -d -t lumina-desktop-smoke)"
trap "rm -rf '$WORK'" EXIT

echo "Creating ephemeral .luminaVM bundle at $WORK/vm"
"$BIN" desktop create \
    --root "$WORK/vm" \
    --name "Smoke test" \
    --os-variant "alpine-virt" \
    --memory 1GB \
    --cpus 2 \
    --disk-size 1GB \
    --iso "$CACHE_ISO" > "$WORK/create.json"

echo "Booting for 60s and capturing serial output"
SERIAL="$WORK/serial.log"
# The boot command runs forever; timeout kills it after 60s.
timeout 60 "$BIN" desktop boot "$WORK/vm" --headless --serial "$SERIAL" || true

# -----------------------------------------------------------------------------
# Assert
# -----------------------------------------------------------------------------
if [ ! -f "$SERIAL" ]; then
    echo "error: no serial log captured at $SERIAL" >&2
    exit 1
fi

# Alpine init prints "Welcome to Alpine" to the serial console.
if grep -q "Welcome to Alpine" "$SERIAL"; then
    echo "Alpine booted — EFI pipeline wired correctly."
    exit 0
else
    echo "error: Alpine boot banner not seen in serial output." >&2
    echo "--- tail of serial log ($SERIAL) ---" >&2
    tail -60 "$SERIAL" >&2 || echo "(empty)" >&2
    exit 1
fi
