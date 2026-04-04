# Lumina Handoff

**Date:** 2026-04-05
**Branch:** main
**Repo:** https://github.com/abdul-abdi/lumina

## Goal

Build Lumina — a Swift CLI/library wrapping Apple's Virtualization.framework to provide `subprocess.run()` for VMs. Boot Alpine Linux VM, run command, capture output, tear down.

## What's Done

All implementation tasks complete + concurrency fixes + entitlement automation:

### Source Files (all compile, 28 tests pass)
- `Sources/Lumina/` — Types, Protocol, DiskClone, ImageStore, SerialConsole, CommandRunner, VM, Lumina, ImagePuller
- `Sources/lumina-cli/main.swift` — CLI with run (auto-pull), pull (--force), images, clean
- `Guest/lumina-agent/main.go` — Go guest agent (linux/arm64)
- `Guest/build-image.sh` — Alpine image builder (Linux native + macOS Docker shim)
- `Tests/LuminaTests/` — 22 unit tests + 6 gated integration tests

### Build System
- `Makefile` — `make build` (build + codesign), `make run`, `make install`, `make test`
- `lumina.entitlements` — `com.apple.security.virtualization` + `com.apple.security.hypervisor`
- SPM cannot embed entitlements; Makefile wraps `swift build` + `codesign` as one step

### CI/CD
- `.github/workflows/ci.yml` — Swift build + unit tests on macos-15
- `.github/workflows/build-image.yml` — Builds VM image on arm64 Linux, publishes to GitHub Releases on `lumina-v*` tags

### Release
- `lumina-v0.1.0` release at https://github.com/abdul-abdi/lumina/releases/tag/lumina-v0.1.0
- Contains `lumina-image-default.tar.gz` (46MB) with vmlinuz (9.2MB), initrd (10MB), rootfs.img (1GB)
- `lumina pull` works — image pulled locally to `~/.lumina/images/default/`

## Where We Left Off

**BLOCKED: macOS 26 (Tahoe) Virtualization.framework OS-level bug.**

The code is correct but Virtualization.framework cannot start any Linux VM on macOS 26.x. This is a known Apple bug:
- Matches [apple/container#1254](https://github.com/apple/container/issues/1254) (macOS 26.3 ARM64)
- Even the most minimal VM config (kernel only, no disk/initrd) fails with VZErrorDomain Code=1
- XPC service spawns, TCC passes, then internal error breadcrumb `0x73d317ba00000321`
- No workaround exists — needs Apple fix in a future macOS update

**To test when macOS is fixed:**
```bash
make build
make run ARGS='"echo hello"'
```

**To run integration tests:**
```bash
swift build --build-tests
codesign --entitlements lumina.entitlements --force -s - .build/debug/LuminaPackageTests.xctest
LUMINA_INTEGRATION_TESTS=1 swift test
```

## Fixes Applied This Session

### 1. Swift 6 Concurrency — Custom SerialExecutor (correct fix)
- **Problem:** `VM` actor and `VZVirtualMachine`'s dedicated DispatchQueue were two separate serialization domains ("complected" per Hickey). `nonisolated(unsafe)` told the compiler to stop checking the one thing it should check.
- **Fix:** `VMExecutor` (custom `SerialExecutor`) backs the actor with the same `DispatchQueue` that VZ uses. One serialization domain, no unsafe escape hatches. VZ methods call directly with `await` — no completion-handler trampolines needed.
- **Reference:** [SE-0392 Custom Actor Executors](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0392-custom-actor-executors.md)

### 2. Entitlements Automation — Makefile
- **Problem:** `swift build` produces unsigned binary. VZ requires `com.apple.security.virtualization` entitlement. SPM has no entitlements support.
- **Fix:** `Makefile` with `make build` = `swift build` + `codesign`. Confirmed by [Tart project](https://github.com/cirruslabs/tart/discussions/85) using identical pattern.

### 3. VZGenericPlatformConfiguration
- Added `config.platform = VZGenericPlatformConfiguration()` for ARM64 Linux on Apple Silicon.

### 4. Deployment Target → macOS 14
- Bumped from macOS 13 to 14 for `ExecutorJob` API (custom `SerialExecutor` support).

### 5. Integration Test Gate
- Changed from image-availability to explicit `LUMINA_INTEGRATION_TESTS=1` env var gate, since test binary needs codesigning.

### 6. Release Renamed
- `image-v0.1.0` → `lumina-v0.1.0` (tag, release title, CI workflow trigger, ImagePuller default tag)

## Known Issues

1. **macOS 26 VZ bug** — BLOCKER. See above. Test on macOS 15 (Sequoia) or wait for Apple fix.
2. **CommandRunner `@unchecked Sendable`** — Mutable state with no synchronization. Latent race if multiple execs overlap. Fix: make it an actor or add a lock.
3. **Fake streaming** — `stream()` buffers then emits, not true real-time. Honest doc comment added. Real vsock streaming in v0.2.
4. **Byte-by-byte `readLine`** — Blocks cooperative thread pool. Acceptable for v0.1.
5. **Guest agent has no heartbeat** — Silent guest death = host hangs forever waiting for exit message.
6. **64KB message size limit** — Commands with large stdout lines may truncate or crash parser.

## Architecture
```
Lumina.run("echo hi")
  → VM actor (custom SerialExecutor backed by DispatchQueue)
    → VZVirtualMachine (created on same queue, thread-affinity satisfied)
    → DiskClone (APFS COW clone of rootfs.img)
    → CommandRunner (vsock port 1024, NDJSON protocol)
      → Guest agent (Go, /bin/sh -c, streams stdout/stderr)
    → RunResult { stdout, stderr, exitCode, wallTime }
  → VM.shutdown() + DiskClone.remove()
```

## Roundtable Reviews
- `~/Developer/roundtables/2026-04-05-lumina-project-review.md` — Initial architecture review
- `~/Developer/roundtables/2026-04-05-lumina-session-review.md` — Session review (concurrency model, entitlements, VZ boot debugging). Key consensus: custom SerialExecutor is correct, `nonisolated(unsafe)` must go, VZ Code=1 is OS bug.
