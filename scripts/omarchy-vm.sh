#!/bin/bash
# Installs Omarchy (edge channel, aarch64) into a Lumina desktop VM with
# nobody at the keyboard, using the ISO's own autoinstall contract: a
# `cidata` drive carrying the configurator's answer files
# (omarchy-iso: configs/airootfs/usr/local/bin/omarchy-cidata-load).
#
#   scripts/omarchy-vm.sh [name]
#
# Env: DISK_GB (80), MEMORY (8GB), CPUS (6), LUMINA (lumina on PATH).
# The login password is random and kept in the macOS Keychain:
#   security find-generic-password -s lumina-<name> -w
set -euo pipefail

name=${1:-omarchy}
lumina=${LUMINA:-lumina}
disk_gb=${DISK_GB:-80}
bundle=~/.lumina/desktop-vms/$name
cache=~/.lumina/cache/omarchy
user=$(id -un)
log() { printf '\033[1m==> %s\033[0m\n' "$*" >&2; }

[[ -e $bundle ]] && { echo "error: $bundle exists" >&2; exit 2; }
mkdir -p "$cache"

log "Resolving the newest Omarchy aarch64 ISO"
manifest=$(curl -fsSL https://nightly.omarchy.org/edge-aarch64/latest.json)
url=$(jq -r .url <<<"$manifest") sha=$(jq -r .sha256 <<<"$manifest")
iso=$cache/$(basename "$url")
if [[ ! -f $iso ]]; then
  log "Downloading $(basename "$iso") ($(jq -r '.size / 1e9 | floor' <<<"$manifest") GB)"
  curl -fL --retry 3 -C - -o "$iso.part" "$url"
  mv "$iso.part" "$iso"
fi
echo "$sha  $iso" | shasum -a 256 -c --quiet

log "Writing autoinstall answers"
seed=$(mktemp -d)
trap 'rm -rf "$seed"' EXIT
password=$(openssl rand -base64 18)
security add-generic-password -U -a "$user" -s "lumina-$name" -w "$password"
hash=$(openssl passwd -6 "$password")
ssh-keygen -q -t ed25519 -N '' -C "lumina-$name" -f "$seed/id_ed25519"

mib=$((1024 * 1024)) gib=$((1024 * 1024 * 1024))
boot_size=$((2 * gib)) main_start=$((2 * gib + mib))
main_size=$((disk_gb * gib - main_start - mib))
part() { # start size fs flags mountpoint btrfs-subvolumes
  jq -n --argjson start "$1" --argjson size "$2" --arg fs "$3" --argjson flags "$4" \
    --arg mount "$5" --argjson btrfs "$6" '{
      btrfs: $btrfs, dev_path: null, flags: $flags, fs_type: $fs,
      mount_options: (if $fs == "btrfs" then ["compress=zstd"] else [] end),
      mountpoint: (if $mount == "" then null else $mount end),
      obj_id: (if $fs == "btrfs" then "8c2c2b92-1070-455d-b76a-56263bab24aa" else "ea21d3f2-82bb-49cc-ab5d-6f81ae94e18d" end),
      size: {sector_size: {unit: "B", value: 512}, unit: "B", value: $size},
      start: {sector_size: {unit: "B", value: 512}, unit: "B", value: $start},
      status: "create", type: "primary"}'
}
subvolumes='[{"mountpoint":"/","name":"@"},{"mountpoint":"/home","name":"@home"},
  {"mountpoint":"/var/log","name":"@log"},{"mountpoint":"/var/cache/pacman/pkg","name":"@pkg"}]'
jq -n --arg host "$name" \
  --argjson esp "$(part "$mib" "$boot_size" fat32 '["boot","esp"]' /boot '[]')" \
  --argjson root "$(part "$main_start" "$main_size" btrfs '[]' '' "$subvolumes")" '{
  "archinstall-language": "English", app_config: null, auth_config: {},
  audio_config: {audio: "pipewire"},
  bootloader_config: {bootloader: "Limine", uki: false, removable: false},
  custom_commands: [],
  omarchy_install: {
    mode: "full_disk", defer_provisioning: false, target_mount: "/mnt",
    boot: {esp_mount: "/boot", esp_path: "/EFI/limine", efi_binary: "limine_aa64.efi", enable_fallback: true},
    storage: {kernel: "linux-omarchy"}},
  disk_config: {config_type: "default_layout",
    device_modifications: [{device: "/dev/vda", partitions: [$esp, $root], wipe: true}]},
  hostname: $host, kernels: ["linux-omarchy"], network_config: {type: "iso"},
  ntp: true, parallel_downloads: 8, script: null, services: [], swap: true, timezone: "UTC",
  locale_config: {kb_layout: "us", sys_enc: "UTF-8", sys_lang: "en_US.UTF-8"},
  mirror_config: {custom_repositories: [], custom_servers: [{url: "https://arm-mirror.omarchy.org/$arch/$repo"}],
    mirror_regions: {}, optional_repositories: []},
  packages: ["base-devel", "git", "omarchy-keyring", "omarchy-settings-dev", "omarchy-dev"],
  profile_config: {gfx_driver: null, greeter: null, profile: {}},
  version: "3.0.9"}' >"$seed/user_configuration.json"
jq -n --arg hash "$hash" --arg user "$user" '{
  root_enc_password: $hash,
  users: [{enc_password: $hash, groups: [], sudo: true, username: $user}]}' >"$seed/user_credentials.json"
echo false >"$seed/user_encrypt_installation.txt"
cp "$seed/id_ed25519.pub" "$seed/authorized_keys"
# The live ISO runs cloud-init too: this key lets the host watch the install.
printf 'instance-id: lumina-%s\n' "$name" >"$seed/meta-data"
printf '#cloud-config\nusers: []\ndisable_root: false\nssh_authorized_keys:\n  - %s\n' \
  "$(cat "$seed/id_ed25519.pub")" >"$seed/user-data"

key=$(mktemp -d)/id_ed25519
mv "$seed/id_ed25519" "$key"
rm "$seed/id_ed25519.pub"

log "Creating $bundle"
"$lumina" desktop create --root "$bundle" --name "$name" --os-variant omarchy \
  --memory "${MEMORY:-8GB}" --cpus "${CPUS:-6}" --disk-size "${disk_gb}GB" \
  --iso "$iso" --seed "$seed" >/dev/null
mkdir -p "$bundle/ssh"
mv "$key" "$bundle/ssh/id_ed25519"
echo "$bundle"
