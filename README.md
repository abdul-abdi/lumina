<div align="center">

# Lumina

**Native Apple Workload Runtime for Agents**

`subprocess.run()` for virtual machines — with interactive PTYs, port forwarding, and live observability.

[![CI](https://github.com/abdul-abdi/lumina/actions/workflows/ci.yml/badge.svg)](https://github.com/abdul-abdi/lumina/actions/workflows/ci.yml)
[![Swift 6](https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white)](https://swift.org)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B%20Sonoma-000?logo=apple)](https://developer.apple.com/macos/)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-M1%2FM2%2FM3%2FM4-333)](https://support.apple.com/en-us/116943)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Boot a Linux VM, run a command, get the output.<br>
One function call. ~390ms cold start. ~31ms warm exec. Zero host access.

![demo](demo.gif)

</div>

---

## Install

> **Requires:** macOS 14+ (Sonoma) · Apple Silicon (M1/M2/M3/M4)

```bash
make install                        # build + install to ~/.local/bin
lumina run "echo hello world"       # image auto-pulls on first run
```

Pre-built binary + image from the latest [release](https://github.com/abdul-abdi/lumina/releases/latest):

```bash
curl -fsSL https://github.com/abdul-abdi/lumina/releases/latest/download/lumina -o lumina
chmod +x lumina && sudo mv lumina /usr/local/bin/
```

> If `~/.local/bin` isn't on PATH: `export PATH="$HOME/.local/bin:$PATH"`.

## Why Lumina?

AI agents need to run untrusted code. The question is where.

| | Lumina | Docker | SSH to cloud VM |
|---|--------|--------|-----------------|
| **Cold start** | ~390ms P50 (M3 Pro) | ~3–5s | 30–60s |
| **Exec after boot** | ~31ms P50 · 1ms stdev | ~50–100ms | ~20–50ms (RTT) |
| **Isolation** | Hardware (Virtualization.framework) | Kernel namespaces (shared) | Full VM |
| **Host exposure** | None — no mounted fs, no daemon socket | Container escape risk | Network-exposed |
| **Cleanup** | Automatic — COW clone deleted on exit | Manual | Manual |
| **Dependencies** | Zero — ships as one binary | Docker daemon | Cloud account |
| **Agent-friendly** | Unified JSON envelope when piped | Text only | Text only |
| **Interactive REPL / TUI** | `lumina exec --pty` | `docker exec -it` | `ssh -t` |
| **Host-to-guest TCP** | `--forward 3000:3000` | `-p 3000:3000` | SSH tunnel |
| **Persistent sessions** | Built-in | N/A | SSH sessions |

Boot time is paid once. Exec latency is paid every iteration. Lumina sessions give you both: hardware-isolated VMs with subprocess-fast execution. No daemon, no container registry, no cloud credentials.

## Performance

Benchmarked on M3 Pro, macOS 26.4, release build with the default baked image.

| Workload | Lumina P50 | Lumina P95 | Apple `container` P50 | Apple P95 |
|---|---|---|---|---|
| Cold boot `true` | **390ms** | 470ms | 844ms | 1687ms |
| Cold boot `echo hello` | **403ms** | 450ms | 783ms | 1598ms |
| Warm session exec `true` | **31ms** (1ms stdev) | 33ms | 84ms (10ms stdev) | 111ms |
| Daemon idle memory | **0 MB** | — | ~54 MB | — |
| Sustained session exec rate | **100/s** | — | — | — |

Validated under stress: 8 concurrent 1GB VMs on 18GB M3 Pro, 100K-line stdout round-trip in ~1s, 3-minute sustained session with 171 periodic execs. [Full methodology →](https://github.com/abdul-abdi/lumina/wiki/Performance-Methodology)

## Usage

### One-shot

```bash
lumina run "echo hello"                          # streams on TTY, unified JSON when piped
lumina run "uname -srm" | jq -r .stdout          # parse the envelope
lumina run -e API_KEY=sk-123 "env | grep API"
lumina run --copy ./project:/code --workdir /code "make build"
lumina run --volume mydata:/data "cat /data/file.txt"
```

### Sessions — boot once, exec many

```bash
SID=$(lumina session start)                      # ~300ms
SID=$(lumina session start --memory 4GB --cpus 4 --forward 3000:3000)
lumina exec $SID "uname -a"                      # ~30ms
echo '{"k":1}' | lumina exec $SID "jq ."         # stdin piping
lumina cp ./script.py $SID:/tmp/script.py        # file transfer
lumina session list && lumina session stop $SID
```

### Interactive PTY (REPLs, TUIs)

```bash
SID=$(lumina session start)
lumina exec --pty $SID "sh"          # busybox shell
lumina exec --pty $SID "python3"     # REPL (install with apk first)
lumina exec --pty $SID "htop"        # TUI
```

CR-overwrite, ANSI colours, and window resizes pass through byte-perfect. Ctrl-C and SIGTERM restore your terminal cleanly.

### Port forwarding

```bash
SID=$(lumina session start --forward 3000:3000)
lumina exec $SID "python3 -m http.server 3000" &
curl http://127.0.0.1:3000/
lumina session stop $SID    # host listener released automatically
```

### Observability

```bash
lumina ps | jq .
# [{"sid": "…", "image": "default", "uptime_seconds": 42.6, "active_execs": 1}]
```

Full CLI reference — volumes, custom images, multi-VM networking, the `pool` command, every flag — lives in the [wiki](https://github.com/abdul-abdi/lumina/wiki/CLI-Reference).

---

## Output Contract

Piped JSON is a single envelope. TTY is human-readable text.

**Success:**

```json
{"stdout": "hello\n", "stderr": "", "exit_code": 0, "duration_ms": 668}
```

**Error** — `error` is set, `exit_code` absent, `partial_stdout` / `partial_stderr` present when the command actually ran:

```json
{"error": "timeout", "duration_ms": 3910, "partial_stdout": "begin\n", "partial_stderr": ""}
```

Exhaustive, mutually exclusive error states:

| `error` | Meaning | Partials? |
|---------|---------|-----------|
| `timeout` | Command's `--timeout` fired | yes |
| `vm_crashed` | Guest kernel or agent died mid-exec | yes |
| `session_disconnected` | Session IPC socket dropped mid-exec | yes |
| `connection_failed` | VM/session unreachable — command never started | no |

Legacy per-chunk NDJSON streaming is preserved via `LUMINA_OUTPUT=ndjson` for migration, removed in v0.8.0.

---

## Environment Variables

| Variable | Controls | Default |
|----------|----------|---------|
| `LUMINA_MEMORY` | VM memory | `1GB` |
| `LUMINA_CPUS` | CPU cores | `2` |
| `LUMINA_TIMEOUT` | Command timeout | `60s` |
| `LUMINA_DISK_SIZE` | Rootfs size | image default |
| `LUMINA_FORMAT` | `json` / `text` | auto (JSON piped, text TTY) |
| `LUMINA_STREAM` | `0` / `1`, text mode only | auto |
| `LUMINA_OUTPUT` | `ndjson` for legacy streaming | unset (unified envelope) |

For `lumina run`, resources come from env vars only. For `lumina session start`, flags (`--memory`, `--cpus`, `--disk-size`, `--forward`) override env vars.

---

## Learn More

- **[AGENT.md](AGENT.md)** — compact agent-facing reference: protocol, envelope, error states, PTY, port forwarding
- **[Architecture](https://github.com/abdul-abdi/lumina/wiki/Architecture)** — VM actor, executor pinning, CommandRunner dispatcher, session IPC, PTY + port-forward paths
- **[Protocol Reference](https://github.com/abdul-abdi/lumina/wiki/Protocol-Reference)** — full vsock + session IPC wire formats
- **[CLI Reference](https://github.com/abdul-abdi/lumina/wiki/CLI-Reference)** — every command and flag
- **[Swift Library](https://github.com/abdul-abdi/lumina/wiki/Swift-Library)** — lifecycle API, networking, custom images
- **[Custom Images](https://github.com/abdul-abdi/lumina/wiki/Custom-Images)** and **[Volumes](https://github.com/abdul-abdi/lumina/wiki/Volumes)** — bake packages, persist state
- **[Multi-VM Networking](https://github.com/abdul-abdi/lumina/wiki/Multi-VM-Networking)** — private network, VM-to-VM
- **[Recipes](https://github.com/abdul-abdi/lumina/wiki)** — Claude Code in a VM, CI pool, web-dev port forwarding
- **[Migration 0.5 → 0.6](https://github.com/abdul-abdi/lumina/wiki/Migration-0.5-to-0.6)** — breaking changes + escape hatches
- **[Debugging](https://github.com/abdul-abdi/lumina/wiki/Debugging)** — serial console, common crashes, `LuminaError` states
- **[Roadmap](ROADMAP.md)** — what's next: the v0.7.0 desktop stack (Linux/Windows/macOS guests + UI app)

---

## Swift Library (quick look)

```swift
import Lumina

let result = try await Lumina.run("cargo test", options: RunOptions(
    timeout: .seconds(120),
    env: ["CI": "true"]
))
print(result.stdout)

for try await chunk in Lumina.stream("make build") {
    switch chunk {
    case .stdout(let text): print(text, terminator: "")
    case .stderr(let text): FileHandle.standardError.write(Data(text.utf8))
    case .exit(let code):   print("Exit: \(code)")
    case .stdoutBytes, .stderrBytes: break  // binary output variants
    }
}
```

Deeper patterns — `VM` lifecycle, sessions from code, custom image builds, `withNetwork` — on the [Swift Library wiki page](https://github.com/abdul-abdi/lumina/wiki/Swift-Library).

---

## Building from Source

```bash
make build     # debug + codesign
make test      # 193 unit + 36 integration tests
make release   # optimized + codesign
make install   # -> ~/.local/bin/lumina
```

Guest agent + custom kernel + baked image instructions on the [Building from Source wiki page](https://github.com/abdul-abdi/lumina/wiki/Building-from-Source).

## License

[MIT](LICENSE) © 2026 Abdullahi Abdi
