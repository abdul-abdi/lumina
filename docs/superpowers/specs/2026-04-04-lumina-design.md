# Lumina Design Spec

**Date:** 2026-04-04
**Status:** Draft
**One-liner:** Native Apple Workload Runtime for Agents — `subprocess.run()` for virtual machines.

## Overview

Lumina is a lightweight, open-source Swift CLI and library that wraps Apple's Virtualization.framework to provide instant, disposable VMs on Mac. One function call boots a minimal Linux VM, executes a command, captures output, and tears everything down. The VM is an implementation detail the user never manages.

The name "Lumina" is Latin for "brilliant light" — a translation of the Arabic name Nawra.

## Public API

### Library (`import Lumina`)

```swift
public struct Lumina {
    /// Run a command in a disposable VM, return result when complete
    public static func run(
        _ command: String,
        options: RunOptions = .default
    ) async throws -> RunResult

    /// Stream output from a command in a disposable VM
    public static func stream(
        _ command: String,
        options: RunOptions = .default
    ) -> AsyncThrowingStream<OutputChunk, Error>
}

public struct RunOptions: Sendable {
    public var timeout: Duration = .seconds(60)
    public var memory: UInt64 = 512 * 1024 * 1024  // 512MB
    public var cpuCount: Int = 2
    public var image: String = "default"
    public static let `default` = RunOptions()
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
```

### CLI (`lumina`)

```bash
# Core — run commands in disposable VMs
lumina run "echo hello"                          # run, print stdout
lumina run --stream "make build"                 # stream stdout/stderr live
lumina run --timeout 30s "pip install numpy"     # custom timeout
lumina run --memory 1GB --cpus 4 "cargo test"   # custom resources

# Image management
lumina pull                    # pull default Alpine image
lumina images                  # list cached images
lumina clean                   # remove COW clones and stale images

# Meta
lumina version
```

## Architecture

```
┌─────────────────────────────────────────┐
│  Consumer (CLI or Swift app)            │
│  lumina run "echo hi"                   │
│  try await Lumina.run("echo hi")        │
└──────────────┬──────────────────────────┘
               │
┌──────────────▼──────────────────────────┐
│  Lumina Swift Library                   │
│                                         │
│  ┌───────────────────────────────────┐  │
│  │ LuminaVM                          │  │
│  │ Wraps VZVirtualMachine            │  │
│  │ Configures CPU, memory, network   │  │
│  │ Attaches VZVirtioSocketDevice     │  │
│  │ Manages boot → run → teardown     │  │
│  └───────────────┬───────────────────┘  │
│                  │                       │
│  ┌───────────────▼───────────────────┐  │
│  │ CommandRunner                     │  │
│  │ Connects to guest via vsock:1024  │  │
│  │ Sends command, streams output     │  │
│  │ Enforces timeout                  │  │
│  │ Returns RunResult or stream       │  │
│  └───────────────────────────────────┘  │
│                                         │
│  ┌───────────────────────────────────┐  │
│  │ ImageManager                      │  │
│  │ Stores images in ~/.lumina/images │  │
│  │ Creates APFS COW clones per run   │  │
│  │ Handles pull and cleanup          │  │
│  └───────────────────────────────────┘  │
└──────────────┬──────────────────────────┘
               │
┌──────────────▼──────────────────────────┐
│  Apple Virtualization.framework         │
│  (hardware-backed isolation)            │
└─────────────────────────────────────────┘
```

### Components

**LuminaVM** — Owns the `VZVirtualMachine` lifecycle. Configures:
- `VZVirtualMachineConfiguration` (CPU count, memory size)
- `VZLinuxBootLoader` (kernel + initrd from image)
- `VZVirtioSocketDevice` (host-guest communication)
- `VZNATNetworkDeviceAttachment` (outbound networking)
- `VZDiskImageStorageDeviceAttachment` (COW clone of base image)

Provides: `boot() async throws`, `shutdown() async`, state observation.

**CommandRunner** — Speaks the vsock protocol. Connects to the guest agent on vsock port 1024. Sends exec messages, receives streamed output. Enforces timeout by cancelling the VM if exceeded. Returns a complete `RunResult` (buffered mode) or yields `OutputChunk` values (streaming mode).

**ImageManager** — Manages `~/.lumina/images/`. Responsibilities:
- `pull()` — downloads and extracts the default Alpine image (kernel, initrd, rootfs.img)
- `createCOWClone()` — creates an APFS clone of rootfs.img for a single run
- `removeCOWClone()` — deletes the clone after teardown
- `listImages()` — returns cached images
- `clean()` — removes all COW clones and optionally stale images

## vsock Protocol

Newline-delimited JSON over `VZVirtioSocketDevice`, port `1024`.

### Host → Guest

```json
{"type": "exec", "cmd": "pip install numpy && python script.py", "timeout": 30, "env": {"KEY": "val"}}
```

### Guest → Host (streaming)

```json
{"type": "output", "stream": "stdout", "data": "Installing numpy...\n"}
{"type": "output", "stream": "stderr", "data": "WARNING: ...\n"}
{"type": "exit", "code": 0}
```

The `exit` message is always the last message for a given exec. After receiving it, the host tears down the VM.

## Guest Agent (`lumina-agent`)

A small Go binary (~2MB stripped) baked into the Alpine base image. Compiled for `linux/arm64`.

**Behavior:**
1. Starts on boot via init system (OpenRC or simple init script)
2. Listens on vsock port 1024 (`VHOST_VSOCK_GUEST_CID` + port)
3. Accepts one connection from host
4. Reads exec message (JSON line)
5. Spawns `/bin/sh -c <cmd>` with provided env vars
6. Streams stdout and stderr as JSON lines back to host
7. On process exit, sends exit message with code
8. Closes connection

**Source location:** `Guest/lumina-agent/main.go`
**Build:** `GOOS=linux GOARCH=arm64 go build -ldflags="-s -w" -o lumina-agent`

## Base Image

**Distribution:** Alpine Linux (aarch64), ~50MB total.

**Contents:**
- Linux kernel (alpine-virt flavor, minimal modules)
- initrd
- rootfs.img containing:
  - Alpine base (musl, busybox, apk)
  - `lumina-agent` binary at `/usr/local/bin/lumina-agent`
  - Init script that starts lumina-agent on boot
  - Common tools: `python3`, `git`, `curl`, `gcc` (optional, configurable in future)

**Storage:** `~/.lumina/images/default/` containing `vmlinuz`, `initrd`, `rootfs.img`.

**Build script:** `Guest/build-image.sh` — downloads Alpine minirootfs, installs lumina-agent, creates ext4 rootfs.img, extracts kernel and initrd.

## Execution Flow

```
lumina run "echo hello"
  │
  ├─ 1. ImageManager.createCOWClone()     →  APFS clone of rootfs.img (~instant)
  ├─ 2. LuminaVM.boot()                   →  VZVirtualMachine starts with kernel + COW disk
  ├─ 3. CommandRunner.connect()            →  vsock connection to guest agent
  ├─ 4. CommandRunner.exec("echo hello")   →  sends JSON, streams output
  ├─ 5. CommandRunner receives exit msg    →  captures exitCode
  ├─ 6. LuminaVM.shutdown()               →  stops the VM
  ├─ 7. ImageManager.removeCOWClone()      →  deletes the COW disk
  └─ 8. Return RunResult                   →  stdout: "hello\n", exitCode: 0
```

**Target:** Steps 1-8 complete in under 2 seconds for trivial commands. Boot time (steps 1-3) should be under 1.5 seconds.

## Project Structure

```
lumina/
├── Package.swift                          # Swift package manifest
├── Sources/
│   ├── Lumina/                            # Library target
│   │   ├── Lumina.swift                   # Public API (run, stream)
│   │   ├── LuminaVM.swift                 # VZVirtualMachine wrapper
│   │   ├── CommandRunner.swift            # vsock protocol + I/O
│   │   ├── ImageManager.swift             # Image storage + COW clones
│   │   └── Types.swift                    # RunResult, RunOptions, OutputChunk
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
│       └── ProtocolTests.swift            # Unit tests for vsock protocol parsing
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
- **No persistent VMs** — every `run()` creates and destroys. Statefulness is a non-goal for v0.1.
- **Single concurrent VM per `run()` call** — no built-in pooling (interface designed to allow it in v0.2).

## Future (v0.2+, out of scope)

- VM pooling (pre-boot VMs for instant execution)
- MCP server (expose `Lumina.run()` as a tool for AI agents)
- Custom images (`--image ubuntu-24.04`)
- OCI image support
- VirtioFS shared folders (mount host directories into VM)
- Snapshot/restore
- Network policy (block outbound, allowlist domains)

## Testing Strategy

- **Unit tests:** Protocol serialization/deserialization, RunOptions defaults, ImageManager path logic
- **Integration tests:** Full `Lumina.run()` with real VMs — requires macOS + Apple Silicon CI runner
- **Boot time benchmark:** Automated check that boot-to-ready is under 2 seconds
