# Lumina Handoff

**Date:** 2026-04-05
**Branch:** main
**Repo:** https://github.com/abdul-abdi/lumina

## Goal

Build Lumina — a Swift CLI/library wrapping Apple's Virtualization.framework to provide `subprocess.run()` for VMs. Boot Alpine Linux VM, run command, capture output, tear down.

## What's Done

All 13 implementation tasks complete + post-review fixes + `lumina pull` pipeline:

### Source Files (all compile, 28 tests pass)
- `Sources/Lumina/` — Types, Protocol, DiskClone, ImageStore, SerialConsole, CommandRunner, VM, Lumina, ImagePuller
- `Sources/lumina-cli/main.swift` — CLI with run (auto-pull), pull (--force), images, clean
- `Guest/lumina-agent/main.go` — Go guest agent (linux/arm64)
- `Guest/build-image.sh` — Alpine image builder (Linux native + macOS Docker shim)
- `Tests/LuminaTests/` — 22 unit tests + 6 gated integration tests

### CI/CD
- `.github/workflows/ci.yml` — Swift build + unit tests on macos-15
- `.github/workflows/build-image.yml` — Builds VM image on arm64 Linux, publishes to GitHub Releases on `image-v*` tags

### Release
- `image-v0.1.0` release exists at https://github.com/abdul-abdi/lumina/releases/tag/image-v0.1.0
- Contains `lumina-image-default.tar.gz` (46MB) with proper vmlinuz (8.8MB), initrd (9.6MB), rootfs.img (1GB)
- `lumina pull` code works but image has NOT been pulled locally yet

## Where We Left Off

**No image exists locally.** The old broken image was cleaned, the fixed release is on GitHub, but `lumina pull --force` was interrupted before it could download. Need to:

1. `lumina pull` (or `lumina pull --force` if old broken image still exists) to download the fixed image
2. `lumina run "echo hello"` to test full VM boot + exec + teardown
3. If boot fails, debug via serial console (VM.serialOutput property exists, but CLI --verbose flag was removed — may need to re-add or print serial on error)

## Known Issues to Watch For

1. **VZVirtualMachine threading** — VM actor uses a dedicated DispatchQueue. If boot fails with threading errors, may need to run VZ operations on MainActor instead.
2. **vsock connection** — CommandRunner retries 40x at 50ms intervals (2s total). If guest agent takes longer to start, increase retries.
3. **initrd compatibility** — The initrd is Alpine's `initramfs-virt`. VZLinuxBootLoader needs it to be compatible with the kernel. If boot hangs, try without initrd (set `initialRamdiskURL` to nil and use `root=/dev/vda rw` kernel cmdline).
4. **CommandRunner is blocking** — `readLine` is byte-by-byte synchronous FileHandle reads. Will block the cooperative thread pool. Acceptable for v0.1 but monitor.
5. **`defer { Task { shutdown } }`** — Orphaned effect pattern in Lumina.run(). VM cleanup may not complete if process exits immediately. Works for CLI, problematic for library use.
6. **CI workflow (ci.yml)** — macos-15 runner may need Swift 6 toolchain setup step if it ships with Swift 5.x.

## Post-Review Fixes Already Applied
- Timeout propagated from RunOptions → VM.exec() → CommandRunner → guest agent
- Pipe FileHandles closed in shutdownVM()
- Unused --verbose flag removed from CLI
- ImagePuller has robust error handling (network, 404, rate limit, corruption, missing files)

## What Failed / What We Learned
- Build script originally used `find` with `-o` to locate initrd — matched wrong 6-byte file. Fixed by referencing known paths (`$BOOT_ROOT/boot/initramfs-virt`).
- initrd had root-only permissions (`-rw-------`), broke tar packaging. Fixed with `chmod 644` before tar.
- macOS CI needed macos-15 (macos-14 has Swift 5.10, we need Swift 6.0+).
- Image build CI uses `ubuntu-24.04-arm` for native aarch64 chroot.

## Architecture (for context)
```
Lumina.run("echo hi")
  → VM actor (boot VZVirtualMachine on dedicated DispatchQueue)
    → DiskClone (APFS COW clone of rootfs.img)
    → CommandRunner (vsock port 1024, NDJSON protocol)
      → Guest agent (Go, /bin/sh -c, streams stdout/stderr)
    → RunResult { stdout, stderr, exitCode, wallTime }
  → VM.shutdown() + DiskClone.remove()
```

## Roundtable Review
Full persona review saved at `~/Developer/roundtables/2026-04-05-lumina-project-review.md` (Karpathy, PG, Hickey, Carmack). Key consensus: architecture is right, `lumina pull` was critical missing piece (now done), pooling is next priority for agent use.
