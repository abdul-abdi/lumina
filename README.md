# Lumina

**Native Apple Workload Runtime for Agents** — `subprocess.run()` for virtual machines.

Lumina is a lightweight Swift CLI and library that wraps Apple's Virtualization.framework to provide instant, disposable VMs on Mac. One function call boots a minimal Linux VM, runs your command, captures output, and tears everything down.

## Quick Start

```bash
# Build the image first (requires sudo)
cd Guest && GOOS=linux GOARCH=arm64 go build -ldflags="-s -w" -o lumina-agent/lumina-agent lumina-agent/
sudo ./build-image.sh

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

// Explicit VM lifecycle
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

lumina images                                # list cached images
lumina clean                                 # remove orphaned clones
lumina version
```

## Requirements

- macOS 13+ (Ventura)
- Apple Silicon (M1/M2/M3/M4)
- Go 1.21+ (to build guest agent)

## How It Works

1. Creates an APFS copy-on-write clone of a minimal Alpine Linux image (~50MB)
2. Boots a VM via Apple's Virtualization.framework (~1.5s)
3. Connects to a tiny guest agent over virtio-socket
4. Sends your command, streams stdout/stderr back
5. Tears down the VM and deletes the clone

Every run is fully isolated. The VM has no access to your host filesystem, credentials, or other processes.

## License

MIT
