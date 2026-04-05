# Lumina

**Native Apple Workload Runtime for Agents** — `subprocess.run()` for virtual machines.

Lumina is a lightweight Swift CLI and library that wraps Apple's Virtualization.framework to provide instant, disposable VMs on Mac. One function call boots a minimal Linux VM, runs your command, captures output, and tears everything down.

## Quick Start

```bash
# Install from source
make install

# Pull the pre-built Alpine image (~50MB)
lumina pull

# Run a command in a disposable VM
lumina run "echo hello world"
lumina run --timeout 30s "pip install numpy && python -c 'import numpy; print(numpy.__version__)'"
lumina run --stream "make build"
```

## Swift Library

```swift
import Lumina

// Simple — one function call
let result = try await Lumina.run("echo hello")
print(result.stdout)  // "hello\n"
print(result.success) // true

// With options
let result = try await Lumina.run("cargo test", options: RunOptions(
    timeout: .seconds(120),
    memory: 1024 * 1024 * 1024,  // 1GB
    cpuCount: 4
))

// Stream output in real time
for try await chunk in Lumina.stream("make build") {
    switch chunk {
    case .stdout(let text): print(text, terminator: "")
    case .stderr(let text): print(text, terminator: "", to: &stderr)
    case .exit(let code): print("Exit: \(code)")
    }
}

// Explicit VM lifecycle (connection reuse)
let vm = VM(options: VMOptions(cpuCount: 4))
try await vm.boot()
let r1 = try await vm.exec("apt-get install -y python3")
let r2 = try await vm.exec("python3 script.py")
await vm.shutdown()
```

## CLI

```bash
lumina run "echo hello"                      # run, print stdout
lumina run --stream "make build"             # stream output live
lumina run --timeout 30s "pip install numpy" # custom timeout
lumina run --memory 1GB --cpus 4 "cargo test" # resource config

lumina pull                                  # download default image
lumina pull --force                          # re-download image
lumina images                                # list cached images
lumina clean                                 # remove orphaned clones
lumina --version
```

## Requirements

- macOS 14+ (Sonoma)
- Apple Silicon (M1/M2/M3/M4)
- Go 1.21+ (to build guest agent from source)

## How It Works

1. Creates an APFS copy-on-write clone of a minimal Alpine Linux image (~50MB)
2. Boots a VM via Apple's Virtualization.framework (~1.5s)
3. Injects a guest agent + vsock kernel modules into the initramfs at boot time
4. Connects to the guest agent over virtio-socket (port 1024)
5. Sends your command, streams stdout/stderr back in real time
6. Tears down the VM and deletes the clone

Every run is fully isolated. The VM has no access to your host filesystem, credentials, or other processes.

## Architecture

```
lumina run "echo hello"
  → ImageStore resolves ~/.lumina/images/default/
  → DiskClone creates APFS COW clone of rootfs.img
  → InitrdPatcher injects agent + modules into initramfs
  → VM actor boots VZVirtualMachine (custom SerialExecutor)
  → CommandRunner connects via vsock, gets "ready" handshake
  → Sends exec message, streams output chunks, gets exit code
  → VM shuts down, clone deleted
```

Two-layer API:
- **Layer 1 (Convenience):** `Lumina.run()` / `Lumina.stream()` — boot, exec, teardown in one call
- **Layer 2 (Lifecycle):** `VM` actor — explicit `boot()`, `exec()`, `shutdown()` for multi-command sessions

### Guest Agent Protocol

Newline-delimited JSON over virtio-socket (port 1024):

| Direction | Message |
|-----------|---------|
| Guest → Host | `{"type":"ready"}` |
| Host → Guest | `{"type":"exec","cmd":"...","timeout":N,"env":{}}` |
| Guest → Host | `{"type":"output","stream":"stdout\|stderr","data":"..."}` |
| Guest → Host | `{"type":"exit","code":N}` |
| Guest → Host | `{"type":"heartbeat"}` (every 5s when idle) |

The guest agent supports connection reuse — multiple exec commands on a single connection.

## Building from Source

```bash
# Build + codesign (debug)
make build

# Build guest agent (cross-compile Go for linux/arm64)
cd Guest/lumina-agent && GOOS=linux GOARCH=arm64 go build -ldflags="-s -w" -o lumina-agent .

# Build VM image (requires Docker on macOS)
cd Guest && bash build-image.sh

# Run tests
make test              # unit tests (25)
make test-integration  # e2e tests (4, requires VM image)

# Install to /usr/local/bin
make install
```

## License

MIT
