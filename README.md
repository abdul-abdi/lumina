<div align="center">

# Lumina

**Native Apple Workload Runtime**

`subprocess.run()` for virtual machines — plus a proper macOS app for booting full operating systems.

[![CI](https://github.com/abdul-abdi/lumina/actions/workflows/ci.yml/badge.svg)](https://github.com/abdul-abdi/lumina/actions/workflows/ci.yml)
[![Swift 6](https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white)](https://swift.org)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B%20Sonoma-000?logo=apple)](https://developer.apple.com/macos/)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-M1%2FM2%2FM3%2FM4-333)](https://support.apple.com/en-us/116943)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

One function call to boot a Linux VM, run a command, parse the output.<br>
One app to install Ubuntu, Kali, Windows 11 ARM, or macOS — and dispose of it anytime.

![demo](demo.gif)

**🤖 Building with an AI agent?** → [`AGENTS.md`](AGENTS.md) is the agent-facing reference — wire protocol, unified JSON envelope, error states, PTY, port forwarding, and the `lumina desktop` surface.

</div>

---

## What v0.7.0 adds — "Lumina Desktop"

v0.6.0 shipped a headless agent runtime: boot a Linux VM, run a command, get structured JSON. That's still here.

**v0.7.0 adds the full-OS stack** on top of the same runtime:

- 🐧 **Linux desktop guests** — Ubuntu, Kali, Fedora, Debian ARM64 ISOs boot through `VZEFIBootLoader`
- 🪟 **Windows 11 on ARM** — retail ISO install flow
- 🍎 **macOS guests** — IPSW-restored `VZMacOSVirtualMachine` (needs Apple Silicon host)
- 🖥 **Lumina Desktop.app** — a SwiftUI library + wizard + per-VM windows, with ⌘K fuzzy launcher, live per-card disk sparklines, drag-drop ISOs, native fullscreen, and a brand-aware look per guest OS (Ubuntu orange, Kali cyber blue, Windows MS blue, macOS silver, …)
- 🎨 **Ad-hoc signed build** — no Apple Developer Program account required; notarization is a v0.7.1 upgrade

The agent path is untouched. The CI regression gate holds `lumina run "true"` P50 ≤ 550ms (measured: 524–558ms).

## Install

> **Requires:** macOS 14+ (Sonoma) · Apple Silicon (M1/M2/M3/M4)

**CLI only:**

```bash
make install                        # build + install to ~/.local/bin
lumina run "echo hello world"       # image auto-pulls on first run
```

**Desktop app:**

```bash
bash scripts/build-app.sh --install  # builds .app, signs ad-hoc, installs to /Applications, launches
```

On first launch macOS will warn "from an unidentified developer" — right-click `Lumina.app` in `/Applications` → Open, then confirm. Notarization ships in v0.7.1.

Pre-built binary + image from the latest [release](https://github.com/abdul-abdi/lumina/releases/latest):

```bash
curl -fsSL https://github.com/abdul-abdi/lumina/releases/latest/download/lumina -o lumina
chmod +x lumina && sudo mv lumina /usr/local/bin/
```

> If `~/.local/bin` isn't on PATH: `export PATH="$HOME/.local/bin:$PATH"`.

## Why Lumina?

### Against Docker (agent workloads)

AI agents running untrusted code need hardware isolation. Lumina is a `subprocess.run()` shape over that.

| | Lumina | Docker | SSH to cloud VM |
|---|--------|--------|-----------------|
| **Cold start** | ~540ms P50 (M3 Pro) | ~3–5s | 30–60s |
| **Exec after boot** | ~31ms P50 · 1ms stdev | ~50–100ms | ~20–50ms (RTT) |
| **Isolation** | Hardware (Virtualization.framework) | Kernel namespaces (shared) | Full VM |
| **Host exposure** | None — no mounted fs, no daemon socket | Container escape risk | Network-exposed |
| **Cleanup** | Automatic — COW clone deleted on exit | Manual | Manual |
| **Dependencies** | Zero — ships as one binary | Docker daemon | Cloud account |
| **Agent-friendly** | Unified JSON envelope when piped | Text only | Text only |

### Against Parallels / UTM / VirtualBuddy (desktop workloads)

For running full operating systems on your Mac, v0.7.0 Lumina Desktop competes differently.

| | Lumina Desktop | Parallels | UTM | VirtualBuddy |
|---|----------------|-----------|-----|--------------|
| **Price** | Free · MIT | $120/yr | Free | Free |
| **CLI ↔ app coherence** | Shared `~/.lumina/` — boot from Terminal or the app, same VM | Separate | Separate | None (macOS-only) |
| **Per-OS card branding** | ✓ each VM looks like its OS | Generic chrome | Generic chrome | macOS-only |
| **Live disk-growth sparklines** | ✓ every card | — | — | — |
| **⌘K fuzzy launcher** | ✓ | — | — | — |
| **FSEvents live library** | ✓ 80ms update | — | — | — |
| **Rosetta-at-runtime** | ✓ | ✓ | — | — |
| **Headless CLI for agents** | ✓ same binary | — | — | — |
| **Apple Silicon native** | ✓ VZ | ✓ | ✓ | ✓ |

## Performance

Benchmarked on M3 Pro, macOS 26.4, release build.

### Agent path (v0.6.0 carry-over)

| Workload | P50 | P95 | Context |
|---|---|---|---|
| Cold boot `true` | **524ms** | 558ms | fresh VM, agent handshake, vsock ready |
| Cold boot `echo hello` | 542ms | 603ms | including first exec dispatch |
| Warm session exec `true` | **31ms** (1ms stdev) | 33ms | agent already connected |
| 4 concurrent cold boots | **753ms** aggregate wall-clock | — | Apple Silicon + VZ scales cleanly |
| Daemon idle memory | **0 MB** | — | no daemon — sessions are spawned processes |
| Sustained session exec rate | **100/s** | — | 3-minute soak test |

### Desktop path (v0.7.0 new)

| Workload | Measured | Context |
|---|---|---|
| VM library cold launch (app) | **1,226ms** | fresh dyld cache, first Lumina.app open |
| VM library warm launch | **542ms** (3-run median) | cached; hot dyld |
| VM library memory (steady) | **114 MB** RSS | SwiftUI + NSVisualEffectView + AppModel |
| EFI VM boot (Alpine cold) | **~852ms** | `vm.boot()` call → "Booted" message |
| Host-side overhead per running VM | **~25 MB** RSS | Lumina process; VZ memory separate |
| FSEvents pickup (new VM appears) | **80ms** | coalesced from directory write events |
| Binary size (`Lumina.app`) | **4.6 MB** | no Sparkle, no bundled frameworks |

Validated under stress: 10 concurrent 512MB VMs booted on 18GB M3 Pro, 100K-line stdout round-trip in ~1s, 3-minute sustained session with 171 periodic execs.  [Full methodology →](https://github.com/abdul-abdi/lumina/wiki/Performance-Methodology)

---

## Usage

### One-shot agent workloads

```bash
lumina run "echo hello"                          # streams on TTY, unified JSON when piped
lumina run "uname -srm" | jq -r .stdout          # parse the envelope
lumina run -e API_KEY=sk-123 "env | grep API"
lumina run --copy ./project:/code --workdir /code "make build"
lumina run --volume mydata:/data "cat /data/file.txt"
```

### Persistent agent sessions — boot once, exec many

```bash
SID=$(lumina session start)                      # ~540ms
SID=$(lumina session start --memory 4GB --cpus 4 --forward 3000:3000)
lumina exec $SID "uname -a"                      # ~31ms
echo '{"k":1}' | lumina exec $SID "jq ."         # stdin piping
lumina cp ./script.py $SID:/tmp/script.py        # file transfer
lumina exec --pty $SID "claude"                  # interactive TTY
lumina session list && lumina session stop $SID
```

### Desktop VMs — install Ubuntu, Kali, Windows 11 ARM, macOS

```bash
# Create a bundle + stage an installer ISO
lumina desktop create --name "Ubuntu Dev" --os-variant ubuntu-24.04 \
    --memory 4GB --cpus 2 --disk-size 32GB --iso ./ubuntu-24.04.3-live-server-arm64.iso

# Boot it (headless or graphical)
lumina desktop boot ~/.lumina/desktop-vms/<uuid>           # windowed, default
lumina desktop boot ~/.lumina/desktop-vms/<uuid> --headless --serial out.log

# macOS guests — restore from IPSW (needs ~15GB)
lumina desktop install-macos ~/.lumina/desktop-vms/<uuid> --ipsw ./UniversalMac.ipsw

# List everything (shares state with the app)
lumina desktop ls
```

### Lumina Desktop.app (v0.7.0)

Open `/Applications/Lumina.app` — or press **⌘K** once it's running to fuzzy-search and launch any VM with one keystroke.

| Shortcut | Action |
|---|---|
| ⌘K | Command launcher — type a VM name, hit Enter, it boots |
| ⌘N | New VM wizard |
| ⌘B / ⌘. | Boot / Stop selected VM |
| ⌘R | Restart selected VM |
| ⌘T | Take snapshot |
| ⌘⌃F | Fullscreen the running VM |
| ⌘1 / ⌘2 | Grid / List layout |
| ⌘, | Preferences |
| ⌘/ | Keyboard shortcuts |

Drag any `.iso`, `.img`, or `.ipsw` onto the window → wizard opens pre-filled.

Full CLI reference lives in the [wiki](https://github.com/abdul-abdi/lumina/wiki/CLI-Reference).

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

For `lumina run`, resources come from env vars only. For `lumina session start` and `lumina desktop create`, flags (`--memory`, `--cpus`, `--disk-size`, `--forward`) override env vars.

---

## Learn More

- **[AGENTS.md](AGENTS.md)** — compact agent-facing reference: protocol, envelope, error states, PTY, port forwarding, `lumina desktop`
- **[ROADMAP.md](ROADMAP.md)** — what's shipped, what's next
- **[Architecture](https://github.com/abdul-abdi/lumina/wiki/Architecture)** — VM actor, executor pinning, CommandRunner dispatcher, session IPC, EFI / macOS pipelines
- **[Protocol Reference](https://github.com/abdul-abdi/lumina/wiki/Protocol-Reference)** — full vsock + session IPC wire formats
- **[CLI Reference](https://github.com/abdul-abdi/lumina/wiki/CLI-Reference)** — every command and flag
- **[Swift Library](https://github.com/abdul-abdi/lumina/wiki/Swift-Library)** — lifecycle API, networking, custom images
- **[Custom Images](https://github.com/abdul-abdi/lumina/wiki/Custom-Images)** and **[Volumes](https://github.com/abdul-abdi/lumina/wiki/Volumes)** — bake packages, persist state
- **[Multi-VM Networking](https://github.com/abdul-abdi/lumina/wiki/Multi-VM-Networking)** — private network, VM-to-VM
- **[Recipes](https://github.com/abdul-abdi/lumina/wiki)** — Claude Code in a VM, CI pool, Ubuntu desktop, Windows 11 ARM, macOS-in-a-VM
- **[Debugging](https://github.com/abdul-abdi/lumina/wiki/Debugging)** — serial console, common crashes, `LuminaError` states

---

## Swift Library (quick look)

```swift
import Lumina

// Headless agent path
let result = try await Lumina.run("cargo test", options: RunOptions(
    timeout: .seconds(120),
    env: ["CI": "true"]
))
print(result.stdout)

// Streaming — text + binary
for try await chunk in Lumina.stream("make build") {
    switch chunk {
    case .stdout(let text): print(text, terminator: "")
    case .stderr(let text): FileHandle.standardError.write(Data(text.utf8))
    case .exit(let code):   print("Exit: \(code)")
    case .stdoutBytes, .stderrBytes: break  // binary output variants
    }
}

// Desktop path — boot a .luminaVM bundle
import LuminaBootable
let bundle = try VMBundle.load(from: URL(fileURLWithPath: "~/.lumina/desktop-vms/<uuid>"))
var opts = VMOptions.default
opts.memory = bundle.manifest.memoryBytes
opts.cpuCount = bundle.manifest.cpuCount
opts.bootable = .efi(EFIBootConfig(
    variableStoreURL: bundle.efiVarsURL,
    primaryDisk: bundle.primaryDiskURL
))
opts.graphics = GraphicsConfig(widthInPixels: 1920, heightInPixels: 1080)
let vm = VM(options: opts)
try await vm.boot()
```

Deeper patterns — `MacOSVM` actor, `IPSWCatalog`, snapshots, `withNetwork`, custom image builds — on the [Swift Library wiki page](https://github.com/abdul-abdi/lumina/wiki/Swift-Library).

---

## Building from Source

```bash
make build                        # debug + codesign
make test                         # 282 unit + 36 integration tests
make release                      # optimized + codesign
make install                      # -> ~/.local/bin/lumina
make test-desktop                 # Alpine ARM64 EFI smoke test
bash scripts/build-app.sh --install   # build + install + launch Lumina.app
bash scripts/generate-icon.swift  # regenerate AppIcon.icns
```

Guest agent + custom kernel + baked image + xcodegen app project instructions on the [Building from Source wiki page](https://github.com/abdul-abdi/lumina/wiki/Building-from-Source).

## Project Structure

```
Sources/
├── Lumina/                 — headless agent runtime (zero external deps)
├── LuminaGraphics/         — virtio-GPU + input device helpers
├── LuminaBootable/         — EFI + IPSW boot pipelines, DesktopOSCatalog
├── LuminaDesktopKit/       — SwiftUI primitives: AppModel, LibraryView, VMCard, ⌘K launcher, OSBrand
├── LuminaDesktopApp/       — @main entry for Lumina.app (SPM-buildable)
└── lumina-cli/             — unified CLI (agent + desktop)

Apps/LuminaDesktop/         — xcodegen project for contributors who prefer Xcode
Guest/lumina-agent/         — in-VM agent binary (Go, linux/arm64)
web/lumina.run/             — marketing site (single file)
```

## License

[MIT](LICENSE) © 2026 Abdullahi Abdi
