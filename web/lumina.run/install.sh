#!/usr/bin/env sh
# Lumina installer — fetches the latest signed CLI binary.
#
# Usage:   curl -fsSL https://abdul-abdi.github.io/lumina/install.sh | sh
# Env:     LUMINA_PREFIX  install dir (default: ~/.local/bin)
#          LUMINA_VERSION tag to install (default: latest)

set -eu

REPO="abdul-abdi/lumina"
PREFIX="${LUMINA_PREFIX:-${HOME}/.local/bin}"
VERSION="${LUMINA_VERSION:-latest}"

# ── Preflight ────────────────────────────────────────────────
os=$(uname -s)
arch=$(uname -m)

if [ "$os" != "Darwin" ]; then
  printf 'lumina: unsupported OS %s — requires macOS\n' "$os" >&2
  exit 1
fi

if [ "$arch" != "arm64" ]; then
  printf 'lumina: unsupported arch %s — requires Apple Silicon (arm64)\n' "$arch" >&2
  exit 1
fi

macos_major=$(sw_vers -productVersion | cut -d. -f1)
if [ "$macos_major" -lt 14 ]; then
  printf 'lumina: macOS 14 (Sonoma) or newer required — detected %s\n' "$(sw_vers -productVersion)" >&2
  exit 1
fi

for cmd in curl install mkdir; do
  command -v "$cmd" >/dev/null 2>&1 || {
    printf 'lumina: missing required tool: %s\n' "$cmd" >&2
    exit 1
  }
done

# ── Resolve tag ──────────────────────────────────────────────
if [ "$VERSION" = "latest" ]; then
  api="https://api.github.com/repos/${REPO}/releases/latest"
  # GitHub API returns the tag without extra lookup; parse without jq.
  tag=$(curl -fsSL "$api" \
    | awk -F'"' '/"tag_name":/ {print $4; exit}')
  if [ -z "$tag" ]; then
    printf 'lumina: could not resolve latest release tag from %s\n' "$api" >&2
    exit 1
  fi
else
  tag="$VERSION"
fi

printf 'lumina: installing %s to %s\n' "$tag" "$PREFIX"

# ── Download binary ──────────────────────────────────────────
url="https://github.com/${REPO}/releases/download/${tag}/lumina"
tmp=$(mktemp -t lumina.XXXXXX)
# Ensure we clean up on any exit path.
trap 'rm -f "$tmp"' EXIT

if ! curl -fSL --progress-bar "$url" -o "$tmp"; then
  printf 'lumina: download failed from %s\n' "$url" >&2
  exit 1
fi

# ── Install ──────────────────────────────────────────────────
mkdir -p "$PREFIX"
install -m 0755 "$tmp" "${PREFIX}/lumina"

# GitHub downloads carry com.apple.quarantine; strip it so Gatekeeper
# doesn't block the ad-hoc-signed binary on first run.
xattr -dr com.apple.quarantine "${PREFIX}/lumina" 2>/dev/null || true

# ── Report ───────────────────────────────────────────────────
printf '\nlumina %s installed → %s/lumina\n' "$tag" "$PREFIX"

case ":$PATH:" in
  *":${PREFIX}:"*)
    ;;
  *)
    printf '\n  warning: %s is not in PATH\n' "$PREFIX"
    printf '  add this to your shell rc:\n\n'
    printf '      export PATH="%s:$PATH"\n\n' "$PREFIX"
    ;;
esac

printf 'next: run  %s/lumina run "echo hello from a VM"\n' "$PREFIX"
