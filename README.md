<div align="center">

# Lumina

**Native Apple Workload Runtime for Agents** — `subprocess.run()` for virtual machines.

[![CI](https://github.com/abdul-abdi/lumina/actions/workflows/ci.yml/badge.svg)](https://github.com/abdul-abdi/lumina/actions/workflows/ci.yml)
[![Swift 6](https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white)](https://swift.org)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B%20Sonoma-000?logo=apple)](https://developer.apple.com/macos/)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-M1%2FM2%2FM3%2FM4-333)](https://support.apple.com/en-us/116943)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Boot a disposable Linux VM, run a command, get the output.<br>
One function call. ~1.5s cold start. Zero host access.

![demo](demo.gif)

</div>

---

## Get Started

> **Requires:** macOS 14+ (Sonoma) · Apple Silicon (M1/M2/M3/M4) · Go 1.21+ (guest agent only)

```bash
make install                        # build from source
lumina run "echo hello world"       # image auto-pulls on first run
```

## Features

| | Feature | Example |
|---|---------|---------|
| ⚡ | **Instant VMs** | ~1.5s cold start, APFS copy-on-write clones |
| 🔒 | **Full isolation** | No host filesystem, credentials, or process access |
| 📡 | **Live streaming** | `--stream` for real-time stdout/stderr |
| 📁 | **File transfers** | `--copy local:remote` / `--download remote:local` |
| 📂 | **Directory mounts** | `--mount host:guest` via virtio-fs |
| 🔑 | **Environment vars** | `-e KEY=VAL` (repeatable) |
| 🔄 | **Smart output** | Auto-JSON when piped, text on TTY |
| 🧹 | **Self-cleaning** | Orphaned clones removed via signal handlers + `atexit` |

---

## Usage

### CLI

```bash
# Basics
lumina run "echo hello"
lumina run --stream "make build"
lumina run --timeout 2m --memory 1GB --cpus 4 "cargo test"

# Environment variables
lumina run -e API_KEY=sk-123 -e DEBUG=1 "env | grep API"

# File transfers
lumina run --copy ./data.csv:/tmp/data.csv \
           --download /tmp/results.json:./results.json \
           "python3 process.py"

# Mount a host directory
lumina run --mount ./src:/mnt/src "cat /mnt/src/README.md"
```

<details>
<summary><strong>Full CLI Reference</strong></summary>

```bash
# Execution
lumina run <command>                          # run, print stdout
lumina run --stream <command>                 # stream output live
lumina run --timeout 30s <command>            # custom timeout (30s, 5m)
lumina run --memory 1GB --cpus 4 <command>    # resource config
lumina run -e KEY=VAL <command>               # env vars (repeatable)
lumina run --copy local:remote <command>      # upload before exec
lumina run --download remote:local <command>  # download after exec
lumina run --mount host:guest <command>       # virtio-fs sharing

# Output format (auto-detects: JSON when piped, text on TTY)
lumina run --text <command>                   # force text output
LUMINA_FORMAT=json lumina run <command>       # force JSON output

# Image management
lumina pull                                   # download default image
lumina pull --force                           # re-download
lumina images                                 # list cached images
lumina clean                                  # remove orphaned clones
lumina --version
```

</details>

### Swift Library

```swift
import Lumina

// One-shot — boot, exec, teardown in one call
let result = try await Lumina.run("cargo test", options: RunOptions(
    timeout: .seconds(120),
    memory: 1024 * 1024 * 1024,
    cpuCount: 4,
    env: ["CI": "true"]
))
print(result.stdout)

// Stream output in real time
for try await chunk in Lumina.stream("make build") {
    switch chunk {
    case .stdout(let text): print(text, terminator: "")
    case .stderr(let text): print(text, terminator: "", to: &stderr)
    case .exit(let code):   print("Exit: \(code)")
    }
}
```

<details>
<summary><strong>Advanced: File Transfers, Lifecycle API, NetworkProvider</strong></summary>

```swift
// File transfers
let result = try await Lumina.run("python3 /tmp/process.py", options: RunOptions(
    uploads: [FileUpload(localPath: inputURL, remotePath: "/tmp/process.py")],
    downloads: [FileDownload(remotePath: "/tmp/out.json", localPath: outputURL)]
))

// Lifecycle API — explicit control, connection reuse
let vm = VM(options: VMOptions(cpuCount: 4))
try await vm.boot()
try await vm.uploadFiles([FileUpload(localPath: scriptURL, remotePath: "/tmp/run.sh")])
let r1 = try await vm.exec("chmod +x /tmp/run.sh && /tmp/run.sh")
try await vm.downloadFiles([FileDownload(remotePath: "/tmp/results.json", localPath: resultsURL)])
await vm.shutdown()

// Custom networking — implement the NetworkProvider protocol
let vm = VM(options: VMOptions(networkProvider: MyCustomProvider()))
```

</details>

---

## How It Works

```mermaid
sequenceDiagram
    participant CLI as lumina run
    participant IS as ImageStore
    participant DC as DiskClone
    participant IP as InitrdPatcher
    participant VM as VM Actor
    participant CR as CommandRunner
    participant GA as Guest Agent

    CLI->>IS: resolve("default")
    IS-->>CLI: kernel, initrd, rootfs, agent
    CLI->>DC: create APFS COW clone
    DC-->>CLI: ephemeral rootfs copy
    CLI->>IP: inject agent + vsock modules
    IP-->>CLI: combined initramfs
    CLI->>VM: boot(VZVirtualMachine)
    Note over VM: Dedicated SerialExecutor
    VM->>CR: connect vsock:1024
    CR->>GA: waiting...
    GA-->>CR: {"type":"ready"}
    CR->>GA: {"type":"exec","cmd":"..."}
    loop streaming
        GA-->>CR: {"type":"output","stream":"stdout","data":"..."}
    end
    GA-->>CR: {"type":"exit","code":0}
    CR-->>CLI: RunResult
    CLI->>VM: shutdown()
    VM->>DC: delete clone
    Note over CLI,GA: Every run is fully isolated
```

<details>
<summary><strong>Guest Agent Protocol</strong></summary>

Newline-delimited JSON over virtio-socket (port 1024, max 64KB per message):

```mermaid
sequenceDiagram
    participant H as Host (CommandRunner)
    participant G as Guest (lumina-agent)

    G->>H: {"type":"ready"}
    H->>G: {"type":"exec","cmd":"...","timeout":N,"env":{}}
    loop streaming
        G->>H: {"type":"output","stream":"stdout","data":"..."}
        G->>H: {"type":"output","stream":"stderr","data":"..."}
    end
    G->>H: {"type":"exit","code":0}
    Note over G,H: Connection supports reuse — send another exec
    loop idle
        G-->>H: {"type":"heartbeat"} (every 5s)
    end
```

**File transfers** use the same vsock connection with ACK-based backpressure:

| Direction | Messages |
|-----------|----------|
| Upload (host → guest) | `upload` → `upload_ack` per 48KB chunk → `upload_done` |
| Download (guest → host) | `download_req` → `download_data` per 48KB chunk (seq + EOF) |

Timeout strategy: the host enforces deadlines on its side. The guest receives a safety-net timeout at 3x the host value (minimum 30s) — loose enough to never race, tight enough to clean up if the host crashes.

</details>

<details>
<summary><strong>Architecture Deep Dive</strong></summary>

### Two-Layer API

| Layer | Entry Point | Use Case |
|-------|------------|----------|
| **Convenience** | `Lumina.run()` / `Lumina.stream()` | One-shot commands. `withVM` scope handles full lifecycle. |
| **Lifecycle** | `VM` actor | Multi-command sessions. Explicit `boot()`, `exec()`, `shutdown()`, `uploadFiles()`, `downloadFiles()`. |

### Internal Components

| Component | Role | Key Detail |
|-----------|------|------------|
| **VM** | Actor wrapping `VZVirtualMachine` | Custom `VMExecutor` (SerialExecutor) pins all VZ calls to a dedicated DispatchQueue |
| **CommandRunner** | vsock protocol + state machine | `ConnectionState` enum with explicit transitions, NSLock for thread safety |
| **InitrdPatcher** | Initramfs injection | Builds cpio newc archives, concatenates with base initrd — Linux extracts both |
| **DiskClone** | Per-run ephemeral COW clones | PID file–based orphan detection; cleanup via `atexit` + signal handlers |
| **ImageStore** | Long-lived image cache | Resolves kernel + initrd + rootfs + optional agent + optional kernel modules |
| **ImagePuller** | GitHub Releases downloader | SHA256 verification, auto-pull on first run |
| **NetworkProvider** | Pluggable network backend | Default: `NATNetworkProvider` (VZ NAT). Protocol allows custom implementations. |
| **SerialConsole** | Serial output capture | Reads `hvc0` for crash diagnostics; surfaced in `LuminaError.guestCrashed` |

### Design Constraints

- Zero shared mutable state between concurrent runs
- Zero external Swift dependencies (library target) — only `Virtualization.framework`
- All public types are `Sendable`
- Guest agent uses raw `AF_VSOCK` syscalls (Go's `net` doesn't support vsock)
- Static networking in guest (192.168.64.4/24) — avoids DHCP latency, DNS uses gateway as nameserver

</details>

---

## Building from Source

```bash
make build               # build + codesign (entitlements required)
make test                # unit tests
make test-integration    # e2e tests (requires VM image)
make release             # optimized build + codesign
make run ARGS="echo hi"  # build, sign, and run
make clean               # remove .build/
```

<details>
<summary><strong>Building Components Separately</strong></summary>

```bash
# Build guest agent (cross-compile Go → linux/arm64)
cd Guest/lumina-agent && GOOS=linux GOARCH=arm64 go build -ldflags="-s -w" -o lumina-agent .

# Build VM image (requires e2fsprogs: brew install e2fsprogs)
cd Guest && sudo ./build-image.sh
```

</details>

