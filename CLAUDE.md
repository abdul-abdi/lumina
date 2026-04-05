# Lumina

Native Apple Workload Runtime for Agents — `subprocess.run()` for virtual machines.

## Repository Structure

```
lumina/
├── Package.swift                    # Swift package manifest (SPM)
├── Sources/
│   ├── Lumina/                      # Library target
│   │   ├── Lumina.swift             # Convenience API (Lumina.run, Lumina.stream)
│   │   ├── VM.swift                 # VM actor (VZVirtualMachine lifecycle)
│   │   ├── CommandRunner.swift      # vsock protocol + state machine
│   │   ├── ImageStore.swift         # Image cache (~/.lumina/images/)
│   │   ├── DiskClone.swift          # Per-run COW clone management
│   │   ├── SerialConsole.swift      # Serial console capture
│   │   └── Types.swift              # RunResult, RunOptions, OutputChunk, LuminaError, VMState
│   └── lumina-cli/                  # CLI executable target
│       └── main.swift               # swift-argument-parser wrapper
├── Guest/
│   ├── lumina-agent/                # Guest agent (Go, linux/arm64)
│   │   ├── main.go
│   │   └── go.mod
│   └── build-image.sh              # Alpine image builder script
├── Tests/
│   └── LuminaTests/                # XCTest suite
│       ├── LuminaRunTests.swift     # Integration tests (require real VM)
│       ├── ProtocolTests.swift      # Unit tests for vsock protocol parsing
│       └── DiskCloneTests.swift     # COW clone create/remove/orphan tests
└── .github/workflows/ci.yml        # Build + test on macOS
```

## Architecture

Two-layer API:
- **Layer 1 (Convenience):** `Lumina.run()` / `Lumina.stream()` — boot, exec, teardown in one call
- **Layer 2 (Lifecycle):** `VM` actor — explicit `boot()`, `exec()`, `shutdown()` for power users

Four internal components:
- **VM** — actor wrapping `VZVirtualMachine`, pinned to dedicated executor (thread affinity)
- **CommandRunner** — vsock protocol over port 1024, explicit `ConnectionState` state machine
- **ImageStore** — long-lived image cache at `~/.lumina/images/`
- **DiskClone** — per-run ephemeral COW clones at `~/.lumina/runs/<uuid>/`

### Architecture Rules

- `VM` is an actor with a dedicated executor. All `VZVirtualMachine` calls (start, stop, pause) MUST happen on that executor. Never call VZ methods from outside the actor.
- `CommandRunner` models connection state explicitly via `ConnectionState` enum — no implicit state transitions.
- `DiskClone` and `ImageStore` are separate concerns. DiskClone handles per-run ephemeral copies; ImageStore handles the long-lived cache. Do not merge them.
- No shared mutable state between concurrent runs. Each `Lumina.run()` creates its own VM actor, COW clone, and vsock connection.
- All public types must be `Sendable`.
- Zero external Swift package dependencies beyond `swift-argument-parser` (CLI only). The library target links only Apple frameworks (`Virtualization`).

### vsock Protocol

Newline-delimited JSON over `VZVirtioSocketDevice`, port 1024, max 64KB per message.
- Guest sends `{"type":"ready"}` on connect
- Host sends `{"type":"exec","cmd":"...","timeout":N,"env":{...}}`
- Guest streams `{"type":"output","stream":"stdout|stderr","data":"..."}` then `{"type":"exit","code":N}`

## Dev Commands

```bash
# Build
swift build

# Test (unit + integration — integration requires macOS + Apple Silicon)
swift test

# Test with verbose output
swift test --verbose

# Type check only (no link)
swift build 2>&1 | head -50   # Swift compiler is the type checker

# Build guest agent (cross-compile Go for linux/arm64)
cd Guest/lumina-agent && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -ldflags="-s -w" -o lumina-agent

# Build Alpine image
cd Guest && bash build-image.sh

# Run CLI
swift run lumina run "echo hello"
swift run lumina run --stream "make build"
```

## Testing Conventions

- Runner: `swift test` (XCTest)
- Location: `Tests/LuminaTests/`
- Unit tests: protocol parsing, type defaults, DiskClone paths, ConnectionState transitions
- Integration tests: full `Lumina.run()` with real VMs (require Apple Silicon + macOS host)
- Name test files `<Component>Tests.swift`
- Target 80% coverage on unit-testable code

## Key Patterns

**Adding a new VM configuration option:**
1. Add field to `RunOptions` and `VMOptions` in `Types.swift`
2. Wire it through `VMOptions(from:)` conversion
3. Apply it in `VM.boot()` where `VZVirtualMachineConfiguration` is built
4. Add CLI flag in `main.swift` via ArgumentParser
5. Add unit test for default value, integration test for behavior

**Adding a new protocol message type:**
1. Define the JSON shape in this doc and `CommandRunner.swift`
2. Add parsing case in CommandRunner's message handler
3. Add corresponding `OutputChunk` case if it surfaces to consumers
4. Add unit test in `ProtocolTests.swift`

## Proactive Checks

After editing Swift files in `Sources/` or `Tests/`:
- Run `swift build` to catch compilation errors
- Run unit tests only for fast feedback: `swift test --filter ProtocolTests` or `swift test --filter DiskCloneTests`
- Only run full `swift test` when changing integration-level code (VM, Lumina.swift) or before completing a task

After editing Go files in `Guest/lumina-agent/`:
- Run `cd Guest/lumina-agent && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -ldflags="-s -w" -o lumina-agent` to verify it compiles

Before completing any task:
- Run `swift build` (must succeed with zero errors)
- Run `swift test` (all tests must pass — unit AND integration)
- Verify no `Sendable` warnings — all public types must conform

Before committing:
- Run `swift build && swift test`
- Ensure commit message follows `<type>: <description>` format
- Do NOT commit until user approves

## Tooling Notes

- The `swift-lsp` plugin is enabled globally. Use LSP-powered tools (go-to-definition, find-references) when verifying call sites, especially for `VZVirtualMachine` thread-affinity checks.
