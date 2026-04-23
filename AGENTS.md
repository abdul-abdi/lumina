# Lumina — Agent Guide

> This file follows the [agents.md](https://agents.md) open standard — stewarded by the
> Agentic AI Foundation under the Linux Foundation and read by Claude Code, Codex, Jules,
> Cursor, Aider, Copilot, and other AI coding tools.

This file describes Lumina from the perspective of an AI coding agent driving it. If you
are any such agent and you have been told to use Lumina, read this page first. Everything
here reflects what ships in v0.7.2.

## v0.7.2 deltas (current — read these first)

- **Hardened network configure, default-await stays safe and is now fast.** Guest `internal/network/network.go` now batches `ip link/addr/route` into one `ip -batch -` call, reads `/proc/net/route` to verify the default route actually landed, retries up to 3× on failure, and emits `network_error` with reason when setup truly breaks. `network_ready` carries `config_ms` + `stage` (`operstate` / `carrier` / `timeout-anyway`) so the host can surface soft-fallback warnings. Carrier wait ceiling shrunk 2s → 400ms. Net result: `lumina run "echo hello"` went from ~3050ms to ~680ms (P50, default-await, healthy host).
- **`--no-wait-network` CLI flag / `RunOptions.awaitNetworkReady = false`.** Opt-out for workloads that know they don't touch DNS/TCP in the first ~20ms. Default stays `true` (reliable). Saves ~150ms on top of the already-fast default.
- **`LUMINA_BOOT_TRACE=1` stderr trace.** Agent-path boot now reports phase breakdown: `image resolve / disk clone / config build / vz start / vsock connect / guest agent ready / total`. Use this when diagnosing slow boots — the hotspot is rarely where you'd guess.
- **`BootPhases.isValid`** accessor distinguishes populated vs. agent-path-attached (zero-valued) BootPhases for UI gating.
- **Session socket hardening.** `~/.lumina/sessions/<sid>/control.sock` is now mode `0600` and the session directory is `0700` — other users on the host can no longer connect to your session.

## v0.7.1 deltas

- **Stable MAC per `.luminaVM` bundle.** Desktop bundles persist a locally-administered MAC in `manifest.json`. Legacy manifests get lazily backfilled on first boot via `VMBundle.ensureMACAddress()`. Fixes the vmnet DHCP-churn class of "Network autoconfiguration failed" errors.
- **Cancel-during-boot is safe.** `VM.boot()` and `MacOSVM.install()` wrap `vm.start`/installer calls in `withTaskCancellationHandler`; a mid-boot cancel releases `flock()` on the disk and the next boot starts cold. Prior design produced `VZErrorDomain Code 2` on retry.
- **Pre-start delegate install.** Guest crashes in the 300–500ms kernel window now surface as `.crashed(reason:)` via `VZVirtualMachineDelegate`. Call `VM.setDelegate(_:)` before `boot()`; post-boot `setDelegate` also works (actor-serialized).
- **`VM.serialTail(lines:)`** returns the last N newline-separated lines from `SerialConsole`, ANSI CSI-stripped. Used by the Desktop running-VM window to show a live serial tail during `.booting` and `.crashed`. Agents that want a readable excerpt of guest output can call it directly.
- **Windows 11 ARM** uses USB mass-storage for the installer ISO (`EFIBootConfig.preferUSBCDROM = true` for `osFamily == .windows`) instead of virtio-block; fixes "Windows cannot find media." `EFIBootConfig.installPhase` flips the primary disk sync mode to `.fsync` during first install for ~2× faster partman; reverts to `.full` on subsequent boots.
- **Guest agent split** — `main.go` is now 48 lines (accept loop only); state lives in `*Manager` structs under `Guest/lumina-agent/internal/`. Heartbeat failure now also kills active PTY process groups (previously leaked).
- **Idle-TTL sessions** — `lumina session start --ttl 30m` auto-shuts-down when idle (no client activity + zero active execs) for the TTL window. Default `0` disables.
- **Desktop library** has an **Agent Images** sidebar section that surfaces `~/.lumina/images/*`. Each row shows build metadata and offers "Copy `run`", "Open in Terminal" (spawns Terminal.app with `lumina session start --image <name>`), and "Remove".
- **NetworkMode** — `manifest.json` can carry `"networkMode": {"mode": "nat"}` (default) or `"networkMode": {"mode": "bridged", "interfaceIdentifier": "en0"}`. Bridged requires `com.apple.vm.networking` entitlement (paid Apple Developer Program); ad-hoc builds reject the config at `validate()`.

Notarization moved from v0.7.1 to v0.7.2; ad-hoc signing remains the default distribution.

## What Lumina Is

Lumina is `subprocess.run()` for virtual machines on macOS Apple Silicon. It
boots a Linux VM, executes a command inside it, and returns output as structured
JSON. There are two shapes you will use:

- **One-shot:** `lumina run "<cmd>"` — boots a disposable VM, runs the command,
  tears the VM down. ~680ms cold start P50 on M3 Pro (v0.7.2+, default-await;
  ~540ms with `--no-wait-network` for no-network workloads). The CI regression
  gate holds median ≤ 2000ms so this number won't silently drift.
- **Session:** `lumina session start` gives you a persistent VM id (SID). You
  then `lumina exec <sid> "<cmd>"` as many times as you want at ~30ms per
  exec. Sessions support interactive PTYs, port forwarding, and file transfer.

Sessions are the primitive you want for agentic workflows. One-shot `run` is
convenient for isolated commands that do not share state.

The VM is sealed. No host filesystem, no SSH server, no escape hatch. The only
ways in or out are `lumina cp`, `--volume`, and `--forward`. This is a feature.

## Stable Primitives

These are the surfaces you should rely on. Flags not listed here exist but may
change — the ones below are contract.

### `lumina session start [flags]`

```bash
lumina session start
lumina session start --memory 4GB --cpus 4 --disk-size 8GB
lumina session start --image claude-box
lumina session start --forward 3000:3000 --forward 8080:80
lumina session start --ttl 30m            # auto-shut-down after 30 minutes idle (v0.7.1)
```

Provisioning (memory, cpus, disk-size, image, forward) belongs on `session
start`, not on `exec`. Output is a single JSON object `{"sid": "<id>"}` (or
plain SID text on a TTY). SIDs are UUID-form strings — treat them as opaque.

### `lumina exec <sid> "<cmd>" [flags]`

```bash
lumina exec <sid> "echo hello"
lumina exec <sid> --workdir /app "make test"
lumina exec <sid> -e API_KEY=sk-123 "python3 main.py"
lumina exec <sid> --timeout 60s "pytest"
```

Per-invocation flags only: `--workdir`, `--env/-e`, `--timeout`. Piped output
is the unified envelope (see below). A TTY stdout gets streamed text.

### `lumina exec --pty <sid> "<cmd>"`

```bash
lumina exec --pty <sid> "claude"
lumina exec --pty <sid> "python3"
lumina exec --pty <sid> "vim README.md"
```

Opens an interactive PTY for REPLs, curses apps, interactive installers, or
anything that checks `isatty()`. Your stdin/stdout are placed in raw mode for
the duration; the terminal is restored on exit, SIGINT, or SIGTERM via
`DispatchSourceSignal` handlers. `--pty` is a distinct protocol, not a
modified exec — the output is a raw byte stream, not the JSON envelope.

Only one PTY can be active per session at a time. Regular `exec` calls can run
concurrently alongside an active PTY.

### `lumina cp <src> <dst>`

```bash
lumina cp ./input.txt  <sid>:/work/input.txt
lumina cp <sid>:/work/output.txt ./output.txt
lumina cp ./src-dir/   <sid>:/work/src/        # directories, auto-detected
```

Explicit direction: the side that begins with `<sid>:` is the VM. Use this for
session file transfer instead of `--copy`/`--download` flags on `exec`.

### `lumina ps`

```bash
lumina ps
```

Lists live sessions. Piped JSON payload:

```json
[
  {"sid":"<id>","image":"default","uptime_seconds":742,"active_execs":1},
  {"sid":"<id>","image":"claude-box","uptime_seconds":37,"active_execs":0}
]
```

Unreachable sessions (stale socket, crashed process) appear as
`{"sid":"<id>","error":"unreachable"}`. TTY output is a human-readable table.

### `lumina session stop <sid>`

Clean teardown. Idempotent — stopping an already-stopped SID is not an error.

### `lumina images` (v0.7.1: surfaced in Desktop)

```bash
lumina images list                                            # list ~/.lumina/images/*
lumina images create mypy --from default --run "apk add python3"
lumina images inspect mypy                                    # print meta.json
lumina images remove mypy
```

Agent images built here are visible in the **Lumina Desktop → Agent Images**
sidebar as of v0.7.1. Rows offer "Copy `run`" (copies `lumina run --image
<name>` to clipboard) and "Open in Terminal" (spawns Terminal.app with
`lumina session start --image <name>`). The image metadata at
`~/.lumina/images/<name>/meta.json` carries `{base, command, created, rosetta}`.

### `lumina desktop` (v0.7.0)

Desktop VMs are a different primitive from agent sessions: they boot a
full installer ISO (Ubuntu, Kali, Fedora, Debian, Windows 11 ARM, macOS)
into a persistent `.luminaVM` bundle. They have NO `lumina-agent` inside —
you cannot `exec` commands in them. Use them when you want the graphical
OS for interactive work; use agent sessions when you want scripted
execution.

```bash
# Create an empty .luminaVM bundle + stage an installer ISO.
lumina desktop create \
    --name "Ubuntu 24.04" \
    --os-variant ubuntu-24.04 \
    --memory 4GB --cpus 2 --disk-size 32GB \
    --iso ~/Downloads/ubuntu-24.04-arm64.iso

# Boot the bundle (blocks until Ctrl-C).
lumina desktop boot ~/.lumina/desktop-vms/<id>/ --serial /tmp/ubuntu.log

# List desktop bundles.
lumina desktop ls           # human-readable on TTY
lumina desktop ls --json    # machine-readable

# JSON shape from `desktop ls`:
# [
#   {
#     "id": "<uuid>",
#     "name": "Ubuntu 24.04",
#     "osFamily": "linux",
#     "osVariant": "ubuntu-24.04",
#     "memoryBytes": 4294967296,
#     "cpuCount": 2,
#     "diskBytes": 34359738368,
#     "createdAt": "2026-04-20T...Z",
#     "lastBootedAt": null,
#     "schemaVersion": 1
#   }
# ]
```

Bundles live at `~/.lumina/desktop-vms/<uuid>/` and are visible to both
CLI and the Lumina Desktop app. Agents that don't need graphical
interaction should continue to use `session start` + `exec`.

**v0.7.1 manifest fields** (`manifest.json`):

```json
{
  "id": "<uuid>",
  "name": "Ubuntu 24.04",
  "osFamily": "linux",
  "osVariant": "ubuntu-24.04",
  "memoryBytes": 4294967296,
  "cpuCount": 2,
  "diskBytes": 34359738368,
  "createdAt": "2026-04-22T13:08:21Z",
  "lastBootedAt": "2026-04-23T08:06:38Z",
  "macAddress": "76:86:91:9c:a3:5d",        // locally-administered, stable across reboots
  "networkMode": {"mode": "nat"},           // or {"mode":"bridged","interfaceIdentifier":"en0"}
  "schemaVersion": 1
}
```

Legacy manifests without `macAddress` / `networkMode` are handled via
backwards-compatible defaults. `ensureMACAddress()` backfills the MAC
lazily on the next boot and persists; the log line
`lumina: warning: failed to persist MAC for <bundle>` surfaces when
the save path fails (the in-memory MAC is still used for that boot but
the next cold boot will regenerate).

#### ARM64-only

Lumina only boots aarch64 guests. `lumina desktop create` runs an
architecture pre-flight on the supplied `--iso` and rejects x86_64 / RISC-V
ISOs with a clear error. Pass `--force` to skip the check (intended for
ISOs whose EFI bootloader filename is non-standard; you'll find out very
quickly if it doesn't actually boot).

#### ISO integrity

`DesktopOSCatalog` carries hardcoded SHA-256 digests for Ubuntu 24.04, Kali
2026.1, Fedora 42, Debian 12.12 (URLs + digests verified against each
vendor's signed SHA256SUMS). The Lumina Desktop **app wizard** streams any
user-picked catalog ISO through SHA-256 before creating the VM and refuses
mismatches. `lumina desktop create --iso` (CLI path) does not yet verify —
if you're scripting and integrity matters, `shasum -a 256` the file
yourself before passing it to `--iso`, or drive creation through the app.
BYO / Windows-MSA / Apple-IPSW paths have no catalog digest to check
against — Apple IPSWs are signed and verified by `VZMacOSRestoreImage`.

#### Windows 11 ARM caveats

- The ISO must be Microsoft's "Windows 11 (multi-edition) ARM64" retail
  ISO. Microsoft requires a Microsoft Account to download; Lumina cannot
  redistribute. Drop the downloaded ISO on `desktop create --iso`.
- A few keys hit a translation gap between macOS HID and Windows 11 ARM's
  inbox keyboard driver — most visibly the backslash and the F-key row.
  v0.7.0 ships the remap table at `Sources/LuminaBootable/WindowsSupport.swift`
  (`WindowsInputQuirks`); the Desktop app applies it at the input
  layer when the focused VM is `osFamily == .windows`. Headless `lumina
  desktop boot` users won't notice — there's no keyboard input over serial.
- **v0.7.1**: the installer ISO attaches via `VZUSBMassStorageDeviceConfiguration`
  (not virtio-block) for `osFamily == .windows`. Windows setup was
  refusing to detect virtio-block-as-CD-ROM ("Windows cannot find media");
  USB mass-storage presents as a genuine removable drive and works.
  During the install phase (`lastBootedAt == nil`) the primary disk runs
  with `.fsync` sync mode, halving partman time; reverts to `.full`
  after first successful boot.

## Output Envelope Contract

When stdout is a pipe, `lumina run` and `lumina exec` emit a single JSON
object. This is the v0.6.0 unified envelope — do not assume NDJSON.

### Success

```json
{
  "stdout": "hello\n",
  "stderr": "",
  "exit_code": 0,
  "duration_ms": 31
}
```

### Error

```json
{
  "error": "timeout",
  "duration_ms": 30012,
  "partial_stdout": "starting build...\n",
  "partial_stderr": ""
}
```

**Rules you can rely on:**

1. Success and error are disjoint. A success response has `exit_code` and no
   `error`. An error response has `error` and no `exit_code`. Dispatch on the
   presence of the `error` field first.
2. `error` is one of a fixed, mutually-exclusive set:
   - `timeout` — host-side deadline exceeded. `partial_*` present.
   - `vm_crashed` — VM process died mid-exec. `partial_*` present.
   - `connection_failed` — vsock could not be established. Command never ran;
     no `partial_*`.
   - `session_disconnected` — Unix socket IPC lost mid-session-exec. `partial_*`
     present. Only applies to `lumina exec`, never to `lumina run`.
3. `duration_ms` is always present, measured wall-clock on the host.
4. A non-zero `exit_code` is a successful exec whose command failed — this is
   not an error envelope. The command ran to completion, just returned
   non-zero. Parse `exit_code` second.

### Legacy NDJSON

If a consumer cannot migrate immediately, set `LUMINA_OUTPUT=ndjson` to get the
pre-v0.6.0 streaming NDJSON format for `exec`. This opt-in is scheduled for
removal in v0.8.0. New code should not use it.

## Error States — How to Handle Each

| State                   | What happened                               | Retry?                                     |
|-------------------------|---------------------------------------------|--------------------------------------------|
| `timeout`               | Command exceeded `--timeout`                | Consider longer timeout, or chunk the work |
| `vm_crashed`            | Guest died mid-exec (OOM, kernel panic)     | For sessions, `session stop` and restart   |
| `connection_failed`     | vsock never came up                         | Session is dead — restart                  |
| `session_disconnected`  | Control socket broke mid-exec               | Reconnect or restart the session           |

Do not treat a non-zero `exit_code` as an error state. It is a successful exec
of a command that returned non-zero. `make: *** [build] Error 1` is a
`duration_ms + stderr + exit_code: 2` response, not an `error`.

## What NOT to Do

- **Do not assume boot time.** v0.7.2 `lumina run "true"` measures ~680ms P50
  default-await (reliability guarantee preserved) / ~540ms with
  `--no-wait-network`, on M3 Pro release builds. `BootPhases.totalMs` alone is
  ~570ms legacy / ~390ms baked. The CI gate caps median at 2000ms. Image
  variant, host load, and first-run image fetch move
  the number. If you need fast iteration, start a session once and `exec`
  many times. Warm exec is ~31ms P50 with 1ms stdev.
- **Do not rely on ordering between concurrent `exec`s.** Multiple execs on one
  session run in parallel. If one exec writes a file another exec reads, chain
  them with `&&` inside one `exec` invocation or sequence them serially from the
  agent.
- **Do not treat each `exec` as stateful.** Each `exec` is a fresh shell. Env
  vars set in one exec do not persist. Working directory changes do not persist
  (use `--workdir` each time or chain with `&&`). If you need stateful shell
  behavior, put it in one `exec`:
  ```bash
  lumina exec <sid> "cd /app && export FOO=bar && make build"
  ```
- **Do not use virtio-fs mounts for heavy writes.** Compilation and package
  installs over `--volume ./host:/guest` have been observed to silently
  fail. Use `lumina cp` or `--copy`/`--download` for transfers, and build
  inside the VM's own disk.
- **Do not bind forwarded ports to `0.0.0.0`.** You cannot — `--forward` always
  binds `127.0.0.1`. This is intentional.
- **Do not parse `lumina ps` TTY output.** Pipe it so you get JSON, or it will
  break on the next column tweak.
- **Do not assume `LUMINA_OUTPUT=ndjson` will exist forever.** It is removed in
  v0.8.0. Treat the unified envelope as the stable format.

## Example Agent Workflow

```bash
set -euo pipefail

# 1. Start a session. Capture the SID from JSON output (piped).
SID=$(lumina session start --memory 4GB --forward 3000:3000 | jq -r '.sid')
trap 'lumina session stop "$SID" >/dev/null 2>&1 || true' EXIT

# 2. Upload the project.
lumina cp ./project/ "$SID:/work/project/"

# 3. Install deps. Check exit_code from the envelope.
RESULT=$(lumina exec "$SID" --workdir /work/project "npm ci")
if [ "$(echo "$RESULT" | jq -r '.error // empty')" != "" ]; then
  echo "install failed: $(echo "$RESULT" | jq -r '.error')" >&2
  exit 1
fi

# 4. Run tests. Capture stdout/stderr from the envelope.
RESULT=$(lumina exec "$SID" --workdir /work/project --timeout 120s "npm test")
CODE=$(echo "$RESULT" | jq -r '.exit_code // -1')
echo "$RESULT" | jq -r '.stdout'
if [ "$CODE" != "0" ]; then
  echo "$RESULT" | jq -r '.stderr' >&2
  exit "$CODE"
fi

# 5. Pull build output back to the host.
lumina cp "$SID:/work/project/dist/" ./dist/

# session is torn down by the EXIT trap
```

## Known failure modes (read if an agent reports a flake)

None of these are regressions — they are the irreducible surface of running
arbitrary OS installers in a virtualized ARM64 sandbox. Where a v0.7.1 fix
exists it's noted inline.

- **vmnet NAT `bootpd` first-probe DHCP race.** Embedded `bootpd` in macOS's
  vmnet can drop the first DHCP DISCOVER. Debian/Kali `netcfg` has a
  single-probe short timeout and fails. Upstream Apple bug, unfixable
  host-side. **Workaround**: in the installer's failure screen, pick
  "Retry network autoconfiguration" — the second DISCOVER usually wins.
  **Structural fix**: switch `networkMode` to `bridged` (bypasses vmnet).
  Requires paid Apple Developer Program + `com.apple.vm.networking`
  entitlement; ad-hoc builds reject the config at `validate()`.
- **Post-install "no network"** when installer skipped netcfg entirely
  (clicked past the failure screen). Inside the guest: `sudo dhclient ens3`,
  then `sudo nmcli connection add type ethernet ifname ens3 con-name eth0
  autoconnect yes` to persist.
- **Windows 11 ARM "cannot find media"** — fixed in v0.7.1 by USB mass-storage
  attachment. If you still hit it, confirm `manifest.json.osFamily == "windows"`
  so `preferUSBCDROM` defaults to true.
- **VZErrorDomain Code 2 on retry after cancel** — fixed in v0.7.1 via
  `withTaskCancellationHandler`. If you see this on an older build, wait
  ~30s for VZ to drop the disk lock or reboot the host.
- **Concurrent VM ceiling** ≈ 10 on 18GB M3 Pro at 512MB each. Memory-bound
  (macOS caps total VM-eligible RAM at ~2/3 of physical). vsock port
  descriptors do NOT push the ceiling.
- **UnidentifiedDeveloper warning on first `Lumina.app` launch.** Expected —
  ad-hoc signed. Right-click → Open. Notarization is on the v0.7.2 runway.
- **virtio-fs heavy-write corruption** — don't use `--volume ./host:/guest`
  for `make`, package installs, or anything that writes >100MB. Use
  `lumina cp` or the `--copy` / `--download` patterns.

## See Also

- `CLAUDE.md` at the repo root — architecture, protocol messages, repository
  layout. Written for contributors to Lumina itself.
- `ROADMAP.md` — v0.7.2 candidates, v0.8 post-release plans.
- `lumina <cmd> --help` — flag-level reference. The CLI is the source of truth
  for flag names.
