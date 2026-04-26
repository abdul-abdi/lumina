---
name: lumina
description: Use when working in the Lumina repository or when the user asks about Lumina's CLI, Desktop app, guest agent, VM runtime, or how agents should consume Lumina. Lumina is `subprocess.run()` for VMs on Apple Silicon — `lumina run` in ~680ms (default-await network), ~540ms with `--no-wait-network`, returns JSON on pipe, sandboxes untrusted code behind a real hardware isolation boundary. Triggers on /lumina, VM.swift, CommandRunner, lumina-agent, desktop-vms, session start, lumina exec, Virtualization.framework.
---

# Lumina (repository-local trigger)

The canonical agent guide lives at `AGENTS.md` at the repository root — it follows the [agents.md](https://agents.md) open standard and is authoritative for CLI contracts, the output envelope, error states, and agent-workflow patterns.

**Before answering any Lumina question, read `AGENTS.md` in full.** Then read `CLAUDE.md` (also repo root) for architecture, protocol messages, and the repository layout.

## When this skill is triggered, act as follows

1. If the user is using Lumina as a tool (`lumina run`, `lumina session start`, `lumina exec`): answer from `AGENTS.md`.
2. If the user is editing Lumina source: follow `CLAUDE.md`'s architecture rules:
   - `VM` is an actor with a dedicated executor; all `VZVirtualMachine` calls happen on it
   - Public types are `Sendable`
   - Warning budget is **0** — any new warning fails CI
   - Per-connection blocking reads go through `withCheckedContinuation` + GCD
   - Wire-protocol changes update both `Sources/Lumina/Protocol.swift` AND `Guest/lumina-agent/internal/protocol/protocol.go`, plus a test in `Tests/LuminaTests/ProtocolTests.swift`

## Key facts that are easy to forget

- **Desktop VMs and agent VMs are different things.** Desktop VMs boot via the EFI path with a framebuffer and have **no `lumina-agent` inside** — `lumina exec` does not work on them. Use agent sessions (`lumina session start`) for scripted execution.
- **vmnet NAT has a known DHCP race** that ad-hoc builds cannot work around (the workaround is `networkMode: bridged` which requires the `com.apple.vm.networking` entitlement, paid Developer Program only).
- **The unified exec envelope** (v0.6.0+) emits a single JSON object on pipe; legacy NDJSON is opt-in via `LUMINA_OUTPUT=ndjson` and is removed in v0.8.0.
- **PTY is distinct protocol**, not a flag — `pty_exec` has its own message type and handler map. One active PTY per session.
- **Cold boot P50 (v0.7.1)** measures ~680ms default-await (reliability guarantee) / ~540ms with `--no-wait-network` / ~390ms for `BootPhases.totalMs` alone on baked images, on M3 Pro release builds. CI gate: `AGENT_BOOT_P50_MAX_MS=2000`. Set `LUMINA_BOOT_TRACE=1` for the phase breakdown. An informational CI P99 trend (`.github/workflows/bench.yml`) appends JSONL rows to `gh-pages:metrics.jsonl` on push/weekly — read it for trend, not for single-commit deltas.
- **Network reliability is the default.** `configureNetwork` is awaited before exec — `curl`, `ping`, `apt`, DNS all work on the first packet. v0.7.1 made the wait cheap (~150ms on a healthy host, down from ~2.5s pre-hardening). Use `--no-wait-network` only when you know the command doesn't touch network in the first ~20ms.
- **Network metrics on RunResult (v0.7.1).** Piped `lumina run` envelopes may carry an optional `network_metrics.interfaces.<iface>.{rx_bytes, tx_bytes, rx_errors, tx_errors, rx_packets, tx_packets}` field — latest per-NIC snapshot captured during the run. Cumulative since interface-up, not per-command delta. Missing when the command exits before the 500ms first-sample tick. Treat as diagnostic, not contract.
- **Desktop tap-to-boot (v0.7.1).** Clicking a stopped/crashed VM in the library opens the window AND kicks off `boot()`. The "New VM" wizard auto-boots on completion. Agent Images section has grid/list parity with the VM library; tap-to-action there too. Live boot-phase waterfall renders during `.booting` from a 150ms poll of `vm.bootPhases`; post-mortem waterfall on `.crashed`.

## Where to look for specific topics

| Topic | File |
|---|---|
| CLI agent contract (stable flags, envelope, error states) | `AGENTS.md` |
| Architecture invariants, actor rules, wire messages | `CLAUDE.md` |
| CLI source | `Sources/lumina-cli/CLI.swift` |
| VM actor, boot paths | `Sources/Lumina/VM.swift` |
| Guest agent (Go, linux/arm64) | `Guest/lumina-agent/` |
| Desktop app | `Apps/LuminaDesktop/` + `Sources/LuminaDesktopKit/` |
| Release notes / v0.7.1 deltas, v0.8 runway | `ROADMAP.md` |

## Don't duplicate this content

If you find yourself about to write a long explanation of Lumina's CLI or architecture in a chat response, stop — point the user at `AGENTS.md` or `CLAUDE.md` instead. They are the source of truth; duplicating them here creates drift.
