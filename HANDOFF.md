# Lumina Handoff

**Date:** 2026-04-05
**Branch:** main
**Repo:** https://github.com/abdul-abdi/lumina

## Goal

Lumina — `subprocess.run()` for virtual machines. Swift CLI/library wrapping Apple's Virtualization.framework. Boot Alpine Linux VM, run command, capture output, tear down.

## Current Status: v0.2.0 Ready

All priorities complete. `make build && make run ARGS='"echo hello"'` prints `hello` and exits 0. 25 unit tests + 4 integration tests pass.

## What's Done

### v0.1.0 (Core)
- `Sources/Lumina/` — VM actor (custom SerialExecutor), CommandRunner (vsock), InitrdPatcher (runtime initrd injection), ImageStore, ImagePuller, DiskClone, SerialConsole, Protocol, Types
- `Sources/lumina-cli/main.swift` — CLI: run (auto-pull), pull (--force), images, clean
- `Guest/lumina-agent/main.go` — Go guest agent with raw fd-based vsock (linux/arm64)
- `Makefile` — `make build` (build+codesign), `make run`, `make test`, `make test-integration`, `make install`

### v0.2.0 (This Session)

**Priority 1: Image Build Pipeline**
- `build-image.sh` decompresses vmlinuz to raw ARM64 Image (VZLinuxBootLoader on macOS 26 rejects EFI stub + gzip)
- Extracts vsock kernel modules from Alpine linux-virt package into `modules/` dir
- Bundles cross-compiled guest agent binary alongside kernel/initrd/rootfs
- CI workflow (`build-image.yml`) packages all files in release tarball
- `ImagePuller` default tag bumped to `lumina-v0.2.0`
- CLI version bumped to `0.2.0`

**Priority 2: CommandRunner Concurrency**
- NSLock guards all mutable state (`_connection`, `_inputHandle`, `_outputHandle`, `_state`)
- `beginExec()` check-and-transition is atomic (single lock acquisition, no TOCTOU)
- `readBuffer` reset under lock at exec start
- `ConnectionState.finished` renamed to `.failed` (terminal error semantics)

**Priority 3: Real Streaming**
- `CommandRunner.execStream()` yields `OutputChunk`s in real time via `AsyncThrowingStream`
- `Task.detached` reads from vsock, yields to stream continuation
- `OSAllocatedUnfairLock`-based cancellation flag with `onTermination` handler
- `VM.stream()` returns `execStream()` directly — no triple-wrapping
- Heartbeat messages ignored during streaming (just `continue`)

**Priority 4: Guest Agent Robustness**
- Command loop: `for scanner.Scan()` accepts multiple exec requests on same connection
- Heartbeat: 5-second keepalive when idle, paused via `context.WithCancel` during execution
- Write mutex (`sync.Mutex`) serializes all `conn.Write` calls (heartbeat + output goroutines)
- Clean shutdown on scanner EOF (host disconnects)

**Buffered Reader**
- Replaced byte-by-byte `readData(ofLength: 1)` with buffered `availableData` reader
- Critical finding: VZ vsock fds on macOS have pipe-like semantics — `readData(ofLength: N)` blocks until exactly N bytes arrive. `availableData` is the correct API.

### Key Technical Decisions
- **Raw kernel required** — VZLinuxBootLoader on macOS 26 rejects compressed vmlinuz (EFI stub + gzip). Must decompress to raw ARM64 Image format.
- **Custom SerialExecutor** — VM actor uses `VMExecutor` backed by the same DispatchQueue VZ requires.
- **InitrdPatcher** — Injects guest agent + vsock modules + custom init into Alpine initrd at runtime via concatenated cpio.
- **NSLock over Actor** — CommandRunner does blocking I/O (readLine). Can't use actor isolation. NSLock + @unchecked Sendable is the established pattern (same as SerialConsole).
- **availableData over readData** — VZ vsock fds have pipe semantics on macOS, not socket semantics. Discovered via integration test debugging.

### Tests
- `make test` — 25 unit tests (protocol, types, disk clone, image store, serial console, heartbeat, connection state)
- `make test-integration` — 4 e2e tests via CLI (echo, exit code, stderr, uname)
- `Tests/LuminaTests/IntegrationTests.swift` — 6 gated integration tests (can't run via `swift test` because SPM can't codesign test runners)

### Release
- `lumina-v0.1.0` at https://github.com/abdul-abdi/lumina/releases/tag/lumina-v0.1.0 (compressed vmlinuz, no agent/modules)
- `lumina-v0.2.0` — ready to tag. Image includes raw vmlinuz + agent + modules.

## What Needs Doing Next

### Tag and Publish v0.2.0
- Commit pending changes
- `git tag lumina-v0.2.0 && git push origin lumina-v0.2.0`
- CI will build image and create GitHub release
- Verify: `lumina pull && lumina run "echo hello"` works from clean install

### Future Work
- **Connect timeout** — No deadline on the ready-message read after vsock connection succeeds. If guest accepts but crashes before sending ready, host hangs. Add fd read deadline.
- **Streaming hash in ImagePuller** — Currently loads entire tarball into memory for SHA256. Use streaming hash for large images.
- **Guest agent partial writes** — `conn.Write()` return value not checked. Could theoretically lose data on partial writes.
- **insmod error visibility** — vsock module load failures silently swallowed (`2>/dev/null`). Should log failures.

## Architecture
```
lumina run "echo hello"
  -> ImageStore.resolve() -> ~/.lumina/images/default/
  -> DiskClone.create() -> APFS COW clone
  -> InitrdPatcher -> combined initrd (base + agent + modules + custom init)
  -> VM actor (custom SerialExecutor backed by DispatchQueue)
    -> VZVirtualMachine(config, queue: executor.queue)
    -> queue.async { vm.start { ... } }
    -> CommandRunner(socketDevice, queue)
      -> queue.async { socketDevice.connect(toPort: 1024) { ... } }
      -> Guest agent sends {"type":"ready"}
      -> Host sends {"type":"exec","cmd":"echo hello"}
      -> Guest streams {"type":"output","stream":"stdout","data":"hello\n"}
      -> Guest sends {"type":"exit","code":0}
    -> RunResult { stdout: "hello\n", exitCode: 0 }
  -> VM.shutdown() + DiskClone.remove()
  -> prints "hello", exit 0
```

## Review Notes (Hickey + Carmack)
- **Hickey:** Design is sound. Connection reuse model (state machine + guest loop) is clean composition. Heartbeat context cancellation is "the best part." Fixed: TOCTOU in beginExec, stream cancellation, triple-wrapping, state naming.
- **Carmack:** Found the integration test bug (readData vs availableData on VZ vsock fds). Fixed. Flagged connect timeout and partial write as future work.
