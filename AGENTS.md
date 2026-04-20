# Lumina — Agent Guide

> This file follows the [agents.md](https://agents.md) open standard — stewarded by the
> Agentic AI Foundation under the Linux Foundation and read by Claude Code, Codex, Jules,
> Cursor, Aider, Copilot, and other AI coding tools.

This file describes Lumina from the perspective of an AI coding agent driving it. If you
are any such agent and you have been told to use Lumina, read this page first. Everything
here reflects what ships in v0.6.0.

## What Lumina Is

Lumina is `subprocess.run()` for virtual machines on macOS Apple Silicon. It
boots a Linux VM, executes a command inside it, and returns output as structured
JSON. There are two shapes you will use:

- **One-shot:** `lumina run "<cmd>"` — boots a disposable VM, runs the command,
  tears the VM down. ~400ms cold start.
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

### `lumina desktop` (v0.7.0+, experimental)

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
CLI and the Lumina Desktop app (v0.7.0 M6). Agents that don't need
graphical interaction should continue to use `session start` + `exec`.

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

- **Do not assume boot time.** Cold start is targeting ~400ms in v0.6.0, but
  image variant, host load, and first-run image fetch change this. If you need
  fast iteration, start a session once and `exec` many times.
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

## See Also

- `CLAUDE.md` at the repo root — architecture, protocol messages, repository
  layout. Written for contributors to Lumina itself.
- `lumina <cmd> --help` — flag-level reference. The CLI is the source of truth
  for flag names.
