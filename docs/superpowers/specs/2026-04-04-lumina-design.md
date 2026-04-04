# Lumina Design Spec

**Date:** 2026-04-04
**Status:** Reviewed (Karpathy, Carmack, Hickey)
**One-liner:** Native Apple Workload Runtime for Agents — `subprocess.run()` for virtual machines.

## Overview

Lumina is a lightweight, open-source Swift CLI and library that wraps Apple's Virtualization.framework to provide instant, disposable VMs on Mac. One function call boots a minimal Linux VM, executes a command, captures output, and tears everything down.

The name "Lumina" is Latin for "brilliant light" — a translation of the Arabic name Nawra.

## Public API

### Two layers (per Hickey review)

**Layer 1 — Convenience API** (most users):
```swift
public struct Lumina {
    /// Run a command in a disposable VM, return result when complete
    public static func run(
        _ command: String,
        options: RunOptions = .default
    ) async throws(LuminaError) -> RunResult

    /// Stream output from a command in a disposable VM
    public static func stream(
        _ command: String,
        options: RunOptions = .default
    ) -> AsyncThrowingStream<OutputChunk, Error>
}
```

**Layer 2 — VM lifecycle API** (power users, future pooling):
```swift
public actor VM {
    public init(options: VMOptions = .default) throws(LuminaError)
    public func boot() async throws(LuminaError)
    public func exec(_ command: String, env: [String: String] = [:]) async throws(LuminaError) -> RunResult
    public func stream(_ command: String, env: [String: String] = [:]) -> AsyncThrowingStream<OutputChunk, Error>
    public func shutdown() async
    public var state: VMState { get }
}

public enum VMState: Sendable {
    case idle
    case booting
    case ready       // guest agent connected
    case executing
    case shutdown
}
```

`Lumina.run()` is implemented as:
```swift
public static func run(_ command: String, options: RunOptions = .default) async throws(LuminaError) -> RunResult {
    let vm = try VM(options: VMOptions(from: options))
    defer { Task { await vm.shutdown() } }
    try await vm.boot()
    return try await vm.exec(command)
}
```

### Types

```swift
public struct RunOptions: Sendable {
    public var timeout: Duration = .seconds(60)   // total wall time (boot + exec + teardown)
    public var memory: UInt64 = 512 * 1024 * 1024 // 512MB
    public var cpuCount: Int = 2
    public var image: String = "default"
    public static let `default` = RunOptions()
}

public struct VMOptions: Sendable {
    public var memory: UInt64 = 512 * 1024 * 1024
    public var cpuCount: Int = 2
    public var image: String = "default"
}

public struct RunResult: Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public let wallTime: Duration
    public var success: Bool { exitCode == 0 }
}

public enum OutputChunk: Sendable {
    case stdout(String)
    case stderr(String)
    case exit(Int32)
}

public enum LuminaError: Error, Sendable {
    case imageNotFound(String)
    case cloneFailed(underlying: Error)
    case bootFailed(underlying: Error)
    case connectionFailed             // vsock handshake failed after retries
    case timeout                      // wall-clock timeout exceeded
    case guestCrashed(serialOutput: String)
    case protocolError(String)        // malformed message from guest
}
```

### Timeout Semantics

- `RunOptions.timeout` = **total wall time** from call to return (boot + connect + exec + teardown)
- The exec message sends a **command timeout** = `RunOptions.timeout - elapsed` (remaining time)
- Guest agent enforces command timeout server-side (kills the process)
- Host enforces wall-clock timeout (tears down VM if exceeded)
- Both sides enforce — belt and suspenders

### CLI (`lumina`)

```bash
# Core — run commands in disposable VMs
lumina run "echo hello"                          # run, print stdout
lumina run --stream "make build"                 # stream stdout/stderr live
lumina run --timeout 30s "pip install numpy"     # custom timeout
lumina run --memory 1GB --cpus 4 "cargo test"   # custom resources
lumina run --verbose "python script.py"          # also print serial console (debug)

# Image management
lumina pull                    # pull default Alpine image from GitHub releases
lumina images                  # list cached images
lumina clean                   # remove orphaned COW clones and stale images

# Meta
lumina version
```

## Architecture

```
┌─────────────────────────────────────────┐
│  Consumer (CLI or Swift app)            │
│  lumina run "echo hi"                   │
│  try await Lumina.run("echo hi")        │
│  — or —                                 │
│  let vm = try VM()                      │
│  try await vm.boot()                    │
│  let r = try await vm.exec("echo hi")  │
│  await vm.shutdown()                    │
└──────────────┬──────────────────────────┘
               │
┌──────────────▼──────────────────────────┐
│  Lumina Swift Library                   │
│                                         │
│  ┌───────────────────────────────────┐  │
│  │ VM (actor)                        │  │
│  │ Wraps VZVirtualMachine            │  │
│  │ Pinned to dedicated executor      │  │
│  │ Configures CPU, memory, network   │  │
│  │ Attaches VZVirtioSocketDevice     │  │
│  │ Captures serial console output    │  │
│  │ Exposes VMState enum              │  │
│  └───────────────┬───────────────────┘  │
│                  │                       │
│  ┌───────────────▼───────────────────┐  │
│  │ CommandRunner                     │  │
│  │ Connects to guest via vsock:1024  │  │
│  │ Waits for {"type":"ready"} msg    │  │
│  │ Sends commands, streams output    │  │
│  │ Chunks data at 64KB per message   │  │
│  │ Models state machine explicitly   │  │
│  │ Enforces timeout                  │  │
│  └───────────────────────────────────┘  │
│                                         │
│  ┌───────────────────────────────────┐  │
│  │ ImageStore                        │  │
│  │ Long-lived image cache            │  │
│  │ ~/.lumina/images/                 │  │
│  │ pull / list / clean               │  │
│  └───────────────────────────────────┘  │
│                                         │
│  ┌───────────────────────────────────┐  │
│  │ DiskClone                         │  │
│  │ Per-run ephemeral COW clone       │  │
│  │ ~/.lumina/runs/<uuid>/rootfs.img  │  │
│  │ create / remove / cleanOrphans    │  │
│  └───────────────────────────────────┘  │
└──────────────┬──────────────────────────┘
               │
┌──────────────▼──────────────────────────┐
│  Apple Virtualization.framework         │
│  (hardware-backed isolation)            │
└─────────────────────────────────────────┘
```

### Components

**VM** (actor) — Owns the `VZVirtualMachine` lifecycle. Uses a dedicated executor to satisfy VZVirtualMachine's thread affinity requirements. Configures:
- `VZVirtualMachineConfiguration` (CPU count, memory size)
- `VZLinuxBootLoader` (kernel + initrd from image)
- `VZVirtioSocketDevice` (host-guest communication)
- `VZVirtioConsoleDeviceSerialPortConfiguration` (serial console capture for debugging)
- `VZNATNetworkDeviceAttachment` (outbound networking)
- `VZDiskImageStorageDeviceAttachment` (COW clone)

Provides: `boot()`, `exec()`, `stream()`, `shutdown()`, `state` observation. Registers `withTaskCancellationHandler` for cleanup on cancellation/crash.

**CommandRunner** — Speaks the vsock protocol. Explicitly models connection state:
```swift
enum ConnectionState {
    case disconnected
    case connecting
    case waitingForReady
    case ready
    case executing
    case finished
}
```
Connects to guest agent on vsock port 1024 with retry+backoff (max 2s, 50ms intervals). Waits for `{"type":"ready"}` handshake before sending commands. Chunks output data at 64KB max per message. Returns `RunResult` (buffered) or yields `OutputChunk` (streaming).

**ImageStore** — Long-lived image cache at `~/.lumina/images/`. Responsibilities:
- `pull()` — downloads Alpine image bundle from GitHub releases (kernel, initrd, rootfs.img as a tar.gz)
- `list()` — returns cached images
- `clean()` — removes stale images
- `resolve(name:)` — returns paths to kernel, initrd, rootfs for a given image name

**DiskClone** — Per-run ephemeral disk management. Separated from ImageStore (per Hickey review). Responsibilities:
- `create(from:)` — creates APFS COW clone via `cp -c` to `~/.lumina/runs/<uuid>/rootfs.img`
- `remove()` — deletes the clone directory after teardown
- `cleanOrphans()` — scans `~/.lumina/runs/` for stale clones on startup, removes them. A clone is orphaned if its parent process no longer exists (checked via PID file in the clone directory).

### Concurrency

Multiple `Lumina.run()` calls can execute concurrently from different Swift tasks. Each call creates its own `VM` actor, its own COW clone (unique UUID path), and its own vsock connection. No shared mutable state between concurrent runs.

## vsock Protocol

Newline-delimited JSON over `VZVirtioSocketDevice`, port `1024`. Max message size: 64KB.

### Guest → Host (handshake)

```json
{"type": "ready"}
```

Sent by guest agent once it's listening. Host retries vsock connection with 50ms backoff until this is received or timeout.

### Host → Guest

```json
{"type": "exec", "cmd": "pip install numpy && python script.py", "timeout": 25, "env": {"KEY": "val"}}
```

`timeout` is seconds remaining from the wall-clock budget (total timeout minus boot time).

### Guest → Host (streaming)

```json
{"type": "output", "stream": "stdout", "data": "...up to 64KB..."}
{"type": "output", "stream": "stderr", "data": "WARNING: ...\n"}
{"type": "exit", "code": 0}
```

The `data` field is capped at 64KB. Larger output is chunked into multiple messages by the guest agent. The `exit` message is always the last message. After receiving it, the host initiates teardown.

## Guest Agent (`lumina-agent`)

A small Go binary (~2MB stripped) baked into the Alpine base image. Compiled for `linux/arm64`.

**Behavior:**
1. Starts on boot via simple init script (not OpenRC — too slow)
2. Logs "lumina-agent starting" to serial console (for host-side debug)
3. Listens on vsock port 1024
4. Sends `{"type":"ready"}` to host on connection
5. Reads exec message (JSON line)
6. Spawns `/bin/sh -c <cmd>` with provided env vars
7. Streams stdout and stderr as JSON lines (64KB chunks) back to host
8. Enforces command timeout (kills process with SIGKILL if exceeded)
9. On process exit, sends exit message with code
10. Closes connection

**Source location:** `Guest/lumina-agent/main.go`
**Build:** `GOOS=linux GOARCH=arm64 go build -ldflags="-s -w" -o lumina-agent`

## Serial Console

Every VM attaches a `VZVirtioConsoleDeviceSerialPortConfiguration` connected to a pipe. Serial output is:
- Captured into a buffer (capped at 1MB)
- Included in `LuminaError.guestCrashed(serialOutput:)` on failure
- Printed to stderr when `--verbose` flag is used in CLI
- Used to detect guest agent startup ("lumina-agent starting" marker)

This is critical for debugging boot failures and guest crashes.

## Base Image

**Distribution:** Alpine Linux (aarch64), ~50MB total.

**Contents:**
- Linux kernel (alpine-virt flavor, minimal modules)
- initrd
- rootfs.img (ext4) containing:
  - Alpine base (musl, busybox, apk)
  - `lumina-agent` binary at `/usr/local/bin/lumina-agent`
  - Simple init script (`/sbin/init` → mount filesystems → start lumina-agent)
  - Common tools: `python3`, `git`, `curl` (pre-installed for convenience)

**Storage:** `~/.lumina/images/default/` containing `vmlinuz`, `initrd`, `rootfs.img`.

**Distribution:** Downloaded from GitHub releases as `lumina-image-default-vX.Y.Z.tar.gz` via `lumina pull`. First run of `lumina run` triggers auto-pull if no image exists.

**Build script:** `Guest/build-image.sh` — downloads Alpine minirootfs, installs lumina-agent and tools, creates ext4 rootfs.img, extracts kernel and initrd. Outputs a tar.gz suitable for GitHub release upload.

## Execution Flow

```
lumina run "echo hello"
  │
  ├─ 0. DiskClone.cleanOrphans()             →  remove stale clones from previous crashes
  ├─ 1. DiskClone.create(from: image)        →  cp -c to ~/.lumina/runs/<uuid>/rootfs.img
  ├─ 2. VM.boot()                            →  VZVirtualMachine starts, serial console attached
  ├─ 3. CommandRunner.connect()              →  vsock retry loop, wait for {"type":"ready"}
  ├─ 4. CommandRunner.exec("echo hello")     →  sends JSON, streams output (64KB chunks)
  ├─ 5. CommandRunner receives exit msg      →  captures exitCode
  ├─ 6. VM.shutdown()                        →  stops VZVirtualMachine (same executor as boot)
  ├─ 7. DiskClone.remove()                   →  deletes ~/.lumina/runs/<uuid>/
  └─ 8. Return RunResult                     →  stdout: "hello\n", exitCode: 0
```

**Performance target:** Steps 1-8 in ~2 seconds for trivial commands. Boot time (steps 1-3) is ~1.5s. Pooling in v0.2 will bring this to <500ms.

**Crash safety:** Step 0 runs on every invocation. Each clone directory contains a `.pid` file with the host process PID. `cleanOrphans()` checks if the PID is still alive; if not, the clone is removed. Additionally, `lumina clean` manually triggers orphan removal.

## Project Structure

```
lumina/
├── Package.swift                          # Swift package manifest
├── Sources/
│   ├── Lumina/                            # Library target
│   │   ├── Lumina.swift                   # Convenience API (run, stream)
│   │   ├── VM.swift                       # VM actor (lifecycle, VZVirtualMachine)
│   │   ├── CommandRunner.swift            # vsock protocol + I/O + state machine
│   │   ├── ImageStore.swift               # Image cache (~/.lumina/images/)
│   │   ├── DiskClone.swift                # Per-run COW clone management
│   │   ├── SerialConsole.swift            # Serial console capture
│   │   └── Types.swift                    # RunResult, RunOptions, OutputChunk, LuminaError, VMState
│   └── lumina-cli/                        # CLI executable target
│       └── main.swift                     # swift-argument-parser wrapper
├── Guest/
│   ├── lumina-agent/                      # Guest agent source
│   │   ├── main.go
│   │   └── go.mod
│   └── build-image.sh                     # Alpine image builder script
├── Tests/
│   └── LuminaTests/
│       ├── LuminaRunTests.swift           # Integration tests for Lumina.run()
│       ├── ProtocolTests.swift            # Unit tests for vsock protocol parsing
│       └── DiskCloneTests.swift           # COW clone create/remove/orphan tests
├── README.md
├── LICENSE                                # MIT
└── .github/
    └── workflows/
        └── ci.yml                         # Build + test on macOS
```

## Dependencies

| Dependency | Purpose | Version |
|-----------|---------|---------|
| `Virtualization.framework` | VM creation and management | macOS 13+ |
| `swift-argument-parser` | CLI argument parsing | 1.3+ |
| Go toolchain | Build guest agent | 1.21+ (build-time only) |

No other runtime dependencies. The library has zero external Swift package dependencies — only Apple frameworks.

## Constraints

- **macOS 13+ (Ventura)** — minimum for Virtualization.framework vsock support
- **Apple Silicon only** — Virtualization.framework on ARM; guests are `linux/arm64`
- **No GPU passthrough** — Metal is not exposed to VMs. CPU-only compute inside the VM.
- **No persistent VMs** — every `Lumina.run()` creates and destroys. The `VM` actor can be used for explicit lifecycle management.
- **Concurrent runs supported** — each run uses its own VM actor and COW clone. No shared mutable state.

## Future (v0.2+, out of scope)

- VM pooling (pre-boot VMs for <500ms execution)
- MCP server (expose `Lumina.run()` as a tool for AI agents)
- Custom images (`--image ubuntu-24.04`)
- OCI image support
- VirtioFS shared folders (mount host directories into VM)
- Snapshot/restore
- Network policy (block outbound, allowlist domains)

## Testing Strategy

- **Unit tests:** Protocol serialization/deserialization, RunOptions defaults, DiskClone path logic, ConnectionState transitions
- **Integration tests:** Full `Lumina.run()` with real VMs — requires macOS + Apple Silicon CI runner
- **Crash safety tests:** Kill process mid-run, verify orphan cleanup on next invocation
- **Boot time benchmark:** Automated check that boot-to-ready is under 2 seconds
