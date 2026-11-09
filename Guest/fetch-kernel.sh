#!/bin/bash
# Fetches the guest kernel: Kata Containers' arm64 build, the one Apple's
# `container` CLI boots. Usage: Guest/fetch-kernel.sh <output-path>
set -euo pipefail

out=${1:?usage: fetch-kernel.sh <output-path>}
version=4.3.1
member=./opt/kata/share/kata-containers/vmlinux-6.18.56-208
sha256=2c5bf7cde334ad5307d482f45cceda496f91c9b6b96f5278c47f4f4eac1bbae6
url=https://github.com/kata-containers/kata-containers/releases/download/$version/kata-static-$version-arm64.tar.zst

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curl -fsSL --retry 3 -o "$work/kata.tar.zst" "$url"
actual=$( (command -v sha256sum >/dev/null && sha256sum "$work/kata.tar.zst" || shasum -a 256 "$work/kata.tar.zst") | cut -d' ' -f1)
[[ $actual == "$sha256" ]] || { echo "kata tarball sha256 mismatch: $actual" >&2; exit 1; }
zstd -dc "$work/kata.tar.zst" | tar -x -C "$work" "$member"
mkdir -p "$(dirname "$out")"
mv "$work/$member" "$out"
