# Lumina

Native Apple Workload Runtime for Agents — `subprocess.run()` for virtual machines.

## Repository Structure

```
lumina/
├── Package.swift                    # Swift package manifest (SPM)
├── Sources/
│   ├── Lumina/                      # Library target
│   │   ├── Lumina.swift             # Convenience API (run, stream, createImage, withNetwork)
│   │   ├── VM.swift                 # VM actor (VZVirtualMachine lifecycle)
│   │   ├── CommandRunner.swift      # vsock protocol + state machine
│   │   ├── ImageStore.swift         # Image cache + custom image creation (~/.lumina/images/)
│   │   ├── ImagePuller.swift        # Downloads default image from GitHub Releases
│   │   ├── DiskClone.swift          # Per-run COW clone management
│   │   ├── InitrdPatcher.swift      # Initramfs overlay (agent injection, network config)
│   │   ├── SerialConsole.swift      # Serial console capture
│   │   ├── Protocol.swift           # vsock message types + codec
│   │   ├── NetworkProvider.swift    # Network attachment protocol (NAT, file-handle)
│   │   ├── Session.swift            # SessionPaths — filesystem layout for sessions
│   │   ├── SessionProtocol.swift    # Session IPC codec (NDJSON over Unix socket)
│   │   ├── SessionServer.swift      # Unix socket listener for session processes
│   │   ├── SessionClient.swift      # Unix socket client for CLI commands
│   │   ├── NetworkSwitch.swift      # SOCK_DGRAM ethernet frame relay
│   │   ├── Network.swift            # Network actor — manages VM groups on shared switch
│   │   ├── VolumeStore.swift        # Named persistent volumes (~/.lumina/volumes/)
│   │   └── Types.swift              # RunResult, RunOptions, VMOptions, SessionOptions, etc.
│   └── lumina-cli/                  # CLI executable target
│       ├── CLI.swift                # ArgumentParser commands (run, session, exec, images, etc.)
│       ├── Helpers.swift            # Shared CLI helpers (signal handlers, output format)
│       └── SessionProcess.swift     # Hidden _session-serve background process
├── Guest/
│   ├── lumina-agent/                # Guest agent (Go, linux/arm64)
│   │   ├── main.go
│   │   └── go.mod
│   └── build-image.sh              # Alpine image builder script
├── Tests/
│   └── LuminaTests/                # swift-testing suite
│       ├── IntegrationTests.swift   # Full Lumina.run() tests (require real VM)
│       ├── ProtocolTests.swift      # vsock protocol parsing
│       ├── DiskCloneTests.swift     # COW clone create/remove/orphan
│       ├── SessionTests.swift       # Session types, SessionPaths
│       ├── SessionProtocolTests.swift  # Session IPC codec
│       ├── SessionServerTests.swift # Unix socket bind/accept
│       ├── SessionClientTests.swift # Client connect error paths
│       ├── ImageStoreTests.swift    # Image creation/removal/inspect
│       ├── VolumeStoreTests.swift   # Volume CRUD
│       ├── NetworkSwitchTests.swift # SOCK_DGRAM relay, IP assignment
│       ├── NetworkTests.swift       # Network overlay, VMOptions defaults
│       ├── TypesTests.swift         # Type defaults, parsing helpers
│       ├── ParsingTests.swift       # Duration/memory parsing
│       └── SerialConsoleTests.swift # Serial console append/output
└── .github/workflows/ci.yml        # Build + test on macOS
```

## Architecture

Three-layer API:
- **Layer 1 (Convenience):** `Lumina.run()` / `Lumina.stream()` — boot, exec, teardown in one call
- **Layer 2 (Sessions):** `session start/stop/list`, `exec` — persistent VMs with Unix socket IPC
- **Layer 3 (Lifecycle):** `VM` actor — explicit `boot()`, `exec()`, `shutdown()` for power users

Seven internal components:
- **VM** — actor wrapping `VZVirtualMachine`, pinned to dedicated executor (thread affinity)
- **CommandRunner** — vsock protocol over port 1024, explicit `ConnectionState` state machine
- **ImageStore** — long-lived image cache at `~/.lumina/images/`, custom image creation with staging-dir atomicity
- **DiskClone** — per-run ephemeral COW clones at `~/.lumina/runs/<uuid>/`
- **SessionServer/Client** — Unix domain socket IPC for persistent sessions at `~/.lumina/sessions/<sid>/`
- **VolumeStore** — named persistent volumes at `~/.lumina/volumes/<name>/data/`
- **NetworkSwitch** — SOCK_DGRAM ethernet frame relay for VM-to-VM networking

### Architecture Rules

- `VM` is an actor with a dedicated executor. All `VZVirtualMachine` calls (start, stop, pause) MUST happen on that executor. Never call VZ methods from outside the actor.
- `CommandRunner` models connection state explicitly via `ConnectionState` enum — no implicit state transitions.
- `DiskClone` and `ImageStore` are separate concerns. DiskClone handles per-run ephemeral copies; ImageStore handles the long-lived cache. Do not merge them.
- No shared mutable state between concurrent runs. Each `Lumina.run()` creates its own VM actor, COW clone, and vsock connection.
- `SessionServer` and `SessionClient` communicate via NDJSON over Unix domain sockets. One client at a time per session.
- `VolumeStore` and `ImageStore` are separate concerns. VolumeStore manages named host directories; ImageStore manages image caches with staging-dir atomicity.
- `NetworkSwitch` reads ports under lock each iteration of the relay loop (not a one-time snapshot) to support dynamic VM join.
- `VMOptions.privateNetworkFd` is `Int32?` not `FileHandle?` — FileHandle isn't Sendable in Swift 6.
- All public types must be `Sendable`.
- Zero external Swift package dependencies beyond `swift-argument-parser` (CLI only). The library target links only Apple frameworks (`Virtualization`).

### vsock Protocol

Newline-delimited JSON over `VZVirtioSocketDevice`, port 1024, max 64KB per message.
- Guest sends `{"type":"ready"}` on connect
- Host sends `{"type":"exec","cmd":"...","timeout":N,"env":{...}}`
- Guest streams `{"type":"output","stream":"stdout|stderr","data":"..."}` then `{"type":"exit","code":N}`

### Session IPC Protocol

NDJSON over Unix domain socket at `~/.lumina/sessions/<sid>/control.sock`, max 64KB per message.
- Client sends `SessionRequest`: exec, upload, download, shutdown
- Server sends `SessionResponse`: output, exit, error, uploadDone, downloadDone

## Dev Commands

```bash
# Build (debug + codesign with entitlements)
make build

# Build release + codesign
make release

# Install to ~/.local/bin (or: make install PREFIX=/usr/local)
make install

# Run unit tests
make test

# Run e2e integration tests (requires VM image + jq)
make test-integration

# Build, sign, and run with args
make run ARGS="echo hello"

# Clean build artifacts
make clean

# Build guest agent (cross-compile Go → linux/arm64)
cd Guest/lumina-agent && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -ldflags="-s -w" -o lumina-agent

# Build Alpine image (requires e2fsprogs: brew install e2fsprogs)
cd Guest && bash build-image.sh
```

### CLI Commands

```bash
# Disposable VM
lumina run "echo hello"
lumina run --stream "make build"
lumina run --volume mydata:/data "ls /data"

# Sessions (persistent VM)
lumina session start --image default
lumina exec <sid> "echo hello"
lumina session list
lumina session stop <sid>

# Images
lumina images list
lumina images create python --from default --run "apk add python3"
lumina images inspect python
lumina images remove python

# Volumes
lumina volume create mydata
lumina volume list
lumina volume inspect mydata
lumina volume remove mydata

# Networking
lumina network run --file manifest.json
```

## Testing Conventions

- Runner: `swift test` (swift-testing framework, `@Test func` syntax)
- Location: `Tests/LuminaTests/`
- Unit tests: protocol parsing, type defaults, DiskClone paths, session types, session protocol codec, socket bind/accept, volume CRUD, network switch relay, image creation
- Integration tests: full `Lumina.run()` with real VMs (require Apple Silicon + macOS host)
- Name test files `<Component>Tests.swift`
- Target 80% coverage on unit-testable code

## Key Patterns

**Adding a new VM configuration option:**
1. Add field to `RunOptions` and `VMOptions` in `Types.swift`
2. Wire it through `VMOptions(from:)` conversion
3. Apply it in `VM.boot()` where `VZVirtualMachineConfiguration` is built
4. Add CLI flag in `CLI.swift` via ArgumentParser
5. Add unit test for default value, integration test for behavior

**Adding a new protocol message type:**
1. Define the JSON shape in this doc and `CommandRunner.swift`
2. Add parsing case in CommandRunner's message handler
3. Add corresponding `OutputChunk` case if it surfaces to consumers
4. Add unit test in `ProtocolTests.swift`

## Proactive Checks

After editing Swift files in `Sources/` or `Tests/`:
- Run `make build` to catch compilation errors (includes codesign)
- Run unit tests only for fast feedback: `swift test --filter ProtocolTests`, `swift test --filter SessionTests`, `swift test --filter NetworkSwitchTests`, etc.
- Only run full `make test` when changing integration-level code (VM, Lumina.swift) or before completing a task

After editing Go files in `Guest/lumina-agent/`:
- Run `cd Guest/lumina-agent && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -ldflags="-s -w" -o lumina-agent` to verify it compiles

Before completing any task:
- Run `make build` (must succeed with zero errors)
- Run `make test` (all tests must pass — unit AND integration)
- Verify no `Sendable` warnings — all public types must conform

Before committing:
- Run `make build && make test`
- Ensure commit message follows `<type>: <description>` format
- Do NOT commit until user approves

## Tooling Notes

- The `swift-lsp` plugin is enabled globally. Use LSP-powered tools (go-to-definition, find-references) when verifying call sites, especially for `VZVirtualMachine` thread-affinity checks.
