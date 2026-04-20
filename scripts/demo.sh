#!/usr/bin/env bash
# scripts/demo.sh — scripted v0.6.0 walkthrough for README recording.
#
# This script runs a deterministic demo of Lumina v0.6.0 features. Record it
# with asciinema or terminalizer to produce the README GIF:
#
#   asciinema rec -c "bash scripts/demo.sh" demo.cast
#   agg --speed 1.4 --theme monokai demo.cast demo.gif
#
# or:
#
#   terminalizer record demo -c "bash scripts/demo.sh"
#   terminalizer render demo -o demo.gif
#
# Requires: lumina installed (~/.local/bin or /usr/local/bin), jq, nc.
# Run from the repo root.

set -uo pipefail

GREEN="\033[1;32m"
CYAN="\033[1;36m"
DIM="\033[2m"
BOLD="\033[1m"
NC="\033[0m"

# --- Helpers --------------------------------------------------------------

# Type out a command slowly (one char at a time), then execute it.
type_cmd() {
  local cmd="$1"
  printf "${CYAN}\$${NC} "
  for ((i = 0; i < ${#cmd}; i++)); do
    printf "%s" "${cmd:$i:1}"
    sleep 0.03
  done
  printf "\n"
  sleep 0.4
  eval "$cmd"
}

# Print a section header and pause.
section() {
  printf "\n${BOLD}# %s${NC}\n" "$1"
  sleep 1.2
}

# Brief pause between segments so the viewer can read output.
pause() { sleep "${1:-1.5}"; }

# Cleanup trap — kill any sessions we started.
cleanup() {
  for sid in $(lumina session list 2>/dev/null | jq -r '.[].sid' 2>/dev/null); do
    lumina session stop "$sid" >/dev/null 2>&1 || true
  done
  rm -f /tmp/lumina-demo-*
}
trap cleanup EXIT

# --- Intro ----------------------------------------------------------------

clear
printf "${BOLD}Lumina v0.6.0 — 60-second tour${NC}\n"
printf "${DIM}subprocess.run() for VMs: interactive, observable, forwarded${NC}\n"
pause 2

# --- 1. One-shot: unified JSON envelope -----------------------------------

section "1. One-shot — unified JSON envelope"
type_cmd 'lumina run "echo hello from an Apple-native VM" | jq .'
pause 2

# --- 2. Session: boot once, exec many ------------------------------------

section "2. Session — boot once, exec many"
type_cmd 'SID=$(lumina session start | jq -r .sid) && echo "SID=$SID"'
pause 1
type_cmd 'lumina exec $SID "uname -a"'
pause 1
type_cmd 'lumina exec $SID "cat /etc/os-release | head -2"'
pause 2

# --- 3. File transfer via lumina cp --------------------------------------

section "3. File transfer — lumina cp"
echo "hello from the host" > /tmp/lumina-demo-input.txt
type_cmd 'lumina cp /tmp/lumina-demo-input.txt $SID:/tmp/in.txt'
pause 0.8
type_cmd 'lumina exec $SID "tr \"[:lower:]\" \"[:upper:]\" </tmp/in.txt > /tmp/out.txt && cat /tmp/out.txt"'
pause 1
type_cmd 'lumina cp $SID:/tmp/out.txt /tmp/lumina-demo-output.txt && cat /tmp/lumina-demo-output.txt'
pause 2

# --- 4. Observability: lumina ps -----------------------------------------

section "4. Observability — lumina ps"
type_cmd 'lumina ps | jq .'
pause 2

# --- 5. Port forwarding: host TCP -> guest --------------------------------

section "5. Port forwarding — host :34321 -> guest :3000"
lumina session stop "$SID" >/dev/null 2>&1
type_cmd 'SID=$(lumina session start --forward 34321:3000 | jq -r .sid) && echo "SID=$SID"'
pause 1

printf "${DIM}# In the guest: one-shot nc listener that serves a known payload${NC}\n"
sleep 0.8
lumina exec "$SID" 'echo "Hello from inside the VM — routed through vsock" | nc -l -p 3000' \
  > /tmp/lumina-demo-ncout.json 2>&1 &
BGPID=$!

printf "${DIM}# On the host: connect to 127.0.0.1:34321${NC}\n"
sleep 1.2
type_cmd 'nc -w 3 127.0.0.1 34321'
wait $BGPID 2>/dev/null || true
pause 2

# --- 6. Interactive PTY (non-interactive preview) -------------------------

section "6. Interactive PTY — REPLs, TUIs, shells"
printf "${DIM}# 'lumina exec --pty' allocates a real pseudoterminal in the guest.${NC}\n"
printf "${DIM}# Example (run in your own terminal, not here):${NC}\n"
printf "${CYAN}\$${NC}  lumina exec --pty \$SID \"python3\"\n"
printf "${CYAN}\$${NC}  lumina exec --pty \$SID \"htop\"\n"
printf "${CYAN}\$${NC}  lumina exec --pty \$SID \"claude\"\n"
pause 3

# --- Wrap-up --------------------------------------------------------------

section "Lumina v0.6.0 — native, fast, agent-ready"
printf "  ${GREEN}•${NC} Unified JSON envelope for run + exec\n"
printf "  ${GREEN}•${NC} lumina exec --pty for interactive sessions\n"
printf "  ${GREEN}•${NC} lumina session start --forward for TCP into the VM\n"
printf "  ${GREEN}•${NC} lumina ps for live session inventory\n"
printf "  ${GREEN}•${NC} See AGENT.md for the agent-facing API surface\n"
pause 3
