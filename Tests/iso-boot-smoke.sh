#!/usr/bin/env bash
# tests/iso-boot-smoke.sh — `lumina iso boot` real-VM smoke.
#
# Exercises the v0.7.x ISO CLI surface against a real ARM64 ISO. Boots
# Alpine virt aarch64 via `lumina iso boot --persist` for a 25-second
# window, then asserts the Alpine init banner appears in the bundle's
# captured serial.log. Destroys the bundle after.
#
# Why a shell smoke and not a swift-testing test:
#   `swift build --build-tests` produces a `.xctest` bundle whose inner
#   Mach-O does NOT accept `codesign --entitlements` (verified
#   2026-05-09 on macOS 26 — the entitlements blob never embeds, so
#   `vm.boot()` returns VZErrorDomain code 2 with
#   `virtualizationEntitlementMissing`). The codesigned `lumina`
#   binary itself works fine, so we test through it.
#
# Requirements:
#   - Apple Silicon macOS host with VZ support (kern.hv_support == 1)
#   - Codesigned `lumina` binary (`make build`)
#
# Expected runtime: ~30 seconds after ISO cache is warm; first run
# adds an ~80 MB Alpine virt download.
#
# Exit codes:
#   0  Alpine banner observed in serial.log
#   1  Banner not observed (boot failed silently)
#   2  Missing dependency (curl, shasum)
#   3  ISO checksum mismatch (trust-on-first-use)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
ISO_URL="${LUMINA_ISO_BOOT_TEST_URL:-https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/alpine-virt-3.21.4-aarch64.iso}"
ISO_SHA_FILE="$ROOT/tests/fixtures/alpine-iso-boot.sha256"
CACHE_DIR="$HOME/.lumina/cache/test-isos"
CACHE_ISO="$CACHE_DIR/alpine-virt-3.21.4-aarch64.iso"
BUNDLE_DIR="$(mktemp -d -t lumina-iso-boot-XXXXXX)"
trap 'rm -rf "$BUNDLE_DIR"' EXIT

# -----------------------------------------------------------------------------
# Dependency checks
# -----------------------------------------------------------------------------
for tool in curl shasum; do
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
# ISO fetch + checksum (trust-on-first-use)
# -----------------------------------------------------------------------------
mkdir -p "$CACHE_DIR"
if [ ! -f "$CACHE_ISO" ]; then
    echo "Downloading Alpine virt ARM64 ISO from $ISO_URL"
    curl -fsSL -o "$CACHE_ISO" "$ISO_URL"
fi

mkdir -p "$ROOT/tests/fixtures"
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
# Run `lumina iso boot`
# -----------------------------------------------------------------------------
BIN="$(swift build --show-bin-path)/lumina"
if [ ! -x "$BIN" ]; then
    echo "error: lumina binary not found at $BIN. Run 'make build' first." >&2
    exit 2
fi

echo "Booting Alpine via $BIN iso boot..."
echo "  bundle: $BUNDLE_DIR/vm"
echo "  iso:    $CACHE_ISO"

# 25s timeout is enough for Alpine virt to boot to userspace and emit
# the init banner (observed at ~0.6 s into a successful run).
"$BIN" iso boot \
    --iso "$CACHE_ISO" \
    --memory 1GB --cpus 2 --disk-size 4GB \
    --persist "$BUNDLE_DIR/vm" \
    --timeout 25 \
    >/dev/null 2>&1 || true   # exit code is 0 on clean shutdown anyway

SERIAL="$BUNDLE_DIR/vm/logs/serial.log"
if [ ! -f "$SERIAL" ]; then
    echo "error: serial.log not produced at $SERIAL" >&2
    exit 1
fi

BYTES=$(wc -c < "$SERIAL" | tr -d ' ')
echo "Serial bytes captured: $BYTES"

# -----------------------------------------------------------------------------
# Assertion — Alpine init banner OR Welcome line
# -----------------------------------------------------------------------------
if grep -qE "Alpine Init|Welcome to Alpine Linux" "$SERIAL"; then
    echo "PASS: Alpine reached userspace ($BYTES bytes serial captured)"
    exit 0
else
    echo "FAIL: Alpine init banner not observed in $BYTES bytes" >&2
    echo "Serial preview (first 500 chars):" >&2
    head -c 500 "$SERIAL" >&2
    echo "" >&2
    exit 1
fi
