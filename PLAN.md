# Lumi Bets Into Lumina — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans`. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the architectural bets validated in `~/Developer/lumi/` into the existing lumina codebase, hitting concrete perf gates and adding ISO-as-a-verb, while keeping Desktop, macOS-guest, and the 200-way concurrent dispatch property intact.

**Architecture:** Phased, ROI-ordered. Phase 1 = Apple kernel as default (zero-code perf win). Phase 2 = trial-merge ISO branches. Phase 3 = `lumind` warm-pool daemon (additive, doesn't delete SessionServer). Phase 4 = bench + prove. Phases 5–6 = optional LOC cleanup (actor→struct, protocol-flatten) gated on time and proof-bar status.

**Tech Stack:** Swift 6 (Sources/Lumina), Go (Guest/lumina-agent), Virtualization.framework (VZ), swift-argument-parser (CLI), swift-testing (`@Test`), Makefile + bash. Worktree: `~/Developer/lumina-lumi-port`, branch `feat/lumi-port-2026-05-24`.

---

## Baseline (frozen on entry)

| What                                        | Value (2026-05-24)                                      |
| ------------------------------------------- | ------------------------------------------------------- |
| Branch base                                 | `perf/five-wins-2026-04-26` HEAD `aae06de`              |
| `Sources/Lumina` LOC                        | 8 500                                                   |
| `Sources/LuminaDesktopKit` LOC              | 6 310                                                   |
| Wire message types                          | 27 (12 host→guest + 15 guest→host)                      |
| Current default kernel                      | 70 MB Alpine virt (`~/.lumina/images/default/vmlinuz`)  |
| Apple kernel available                      | yes, 15 MB at `~/Library/Application Support/com.apple.container/kernels/vmlinux-6.18.5-177` |
| Warm-image cold `echo hello` (audit measured) | 368 ms P50                                            |
| Cold `uname -a`                             | 596 ms P50                                              |
| Warm session exec                           | 31 ms P50                                               |
| CI hard gate                                | `AGENT_BOOT_P50_MAX_MS=2000` median-of-5                |

---

## Constraints we MUST preserve (non-obvious, from Brain learnings)

For any code change in `VM.swift` / `CommandRunner.swift` / `Network.swift` / `SessionServer.swift`:

1. `withTaskCancellationHandler { onCancel: { queue.async { vm.stop(...) } } }` — vz-cancel-during-boot leaks `flock` otherwise.
2. `VZVirtualMachineDelegate` attached BEFORE `vm.start()` — kernel panics/OOM silently lost otherwise.
3. MAC persisted in bundle, reloaded from disk at boot — random MAC per `VZVirtioNetworkDeviceConfiguration()` constructor.
4. Continuation registered BEFORE `configure_network` vsock send — fast vsock response races otherwise.
5. Pipes drained on DispatchQueue concurrently with `waitUntilExit()` — `Process.waitUntilExit()` deadlocks > 16-64KB output otherwise.
6. `chmod 0600` on `control.sock` + `chmod 0700` on session dir — process umask 0022 leaves them world-readable otherwise.
7. Per-connection blocking syscalls (>1 task) wrap `read(2)` in `await withCheckedContinuation { dispatch to GCD queue }` — `FileHandle.availableData` ban. Per-VM (one long-lived task) keep sync.
8. `CheckedContinuation` for `network_ready` registered BEFORE sending `configure_network` (different fault from #4 — host side, not guest).
9. Unknown exec id `output`/`exit` after timeout must surface as `LuminaError.execAbandoned` (or new equivalent), never silently dropped.

Each phase's smoke tests verify these survive.

---

## Phase 0 — Setup ✅ COMPLETE

- [x] Worktree at `~/Developer/lumina-lumi-port` on branch `feat/lumi-port-2026-05-24` (off `perf/five-wins-2026-04-26`).
- [x] `GOAL.md` committed.
- [x] Plan dir `docs/superpowers/plans/` exists.
- [x] Trial-merge of `feat/iso-cli-2026-05-09` and `fix/iso-boot-windows-kali` verified clean.

---

## Phase 1 — Apple kernel as default (biggest perf win, zero code)

**Hypothesis:** Swapping the 70 MB Alpine kernel for Apple's 15 MB kernel takes warm-image cold `echo hello` from 368 ms → ≤ 250 ms with no code change. Decision: `~/Brain/wiki/decisions/lumina-apple-kernel-dependency.md` (7-8× cold-boot speedup measured).

**Files touched:** none (script-driven flip of `~/.lumina/images/default/vmlinuz`).

- [ ] **Step 1: Capture baseline P50/P95/P99 on current Alpine kernel.**

```bash
cd ~/Developer/lumina-lumi-port
make release  # ensure binary up to date
bash bench-boot.sh 2>&1 | tee /tmp/lumina-baseline-alpine.log
```

Expected: P50 in the 350-400 ms range for the warm-image `echo hello` case, P50 for `uname -a` cold around 500-600 ms.

- [ ] **Step 2: Back up current default image kernel.**

```bash
cp ~/.lumina/images/default/vmlinuz ~/.lumina/images/default/vmlinuz.pre-apple-kernel-$(date +%Y%m%d).bak
```

- [ ] **Step 3: Run `Guest/fetch-apple-kernel.sh --name default` to swap.**

```bash
bash Guest/fetch-apple-kernel.sh --name default
# Outputs: "Image ready: ~/.lumina/images/default/" with Apple kernel filename in meta.json
```

Verify: `~/.lumina/images/default/vmlinuz` is now ~15 MB and `meta.json` shows `"kernel_source": "apple/container"`.

- [ ] **Step 4: Smoke that lumina still boots.**

```bash
~/.local/bin/lumina run "echo hello" | jq -e '.stdout == "hello\n" and .exit_code == 0'
```

Expected: exit 0. If this fails, the rootfs may need an Apple-kernel-compatible reformat — fall back to `vmlinuz.pre-apple-kernel-*.bak` and document the gap in a Brain learning.

- [ ] **Step 5: Re-bench with Apple kernel.**

```bash
bash bench-boot.sh 2>&1 | tee /tmp/lumina-applekernel.log
```

Expected: P50 ≤ 250 ms for warm-image `echo hello`. P50 ≤ 500 ms for `uname -a` cold. If yes, perf bar is hit by Phase 1 alone — proceed to Phase 2 anyway for the warm-pool win.

- [ ] **Step 6: Commit baseline + log.**

```bash
mkdir -p docs/bench
cp /tmp/lumina-baseline-alpine.log docs/bench/2026-05-24-baseline-alpine-kernel.log
cp /tmp/lumina-applekernel.log docs/bench/2026-05-24-apple-kernel-flip.log
git add docs/bench/
git commit -m "perf(kernel): flip default to Apple containerization kernel (~$(boot-delta from logs)ms cold-boot win)

Decision: ~/Brain/wiki/decisions/lumina-apple-kernel-dependency.md
Script: Guest/fetch-apple-kernel.sh
Baseline (Alpine virt): see docs/bench/2026-05-24-baseline-alpine-kernel.log
After (Apple kernel):   see docs/bench/2026-05-24-apple-kernel-flip.log"
```

(Replace `$(boot-delta from logs)` with the actual delta from comparing the two log files.)

- [ ] **Step 7: Wire `images create --apple-kernel` flag.**

Modify `Sources/lumina-cli/CLI.swift` `ImageCreate` struct to add `--apple-kernel` flag that triggers the same logic as `fetch-apple-kernel.sh` (call out to the script, or inline the same `cp $KERNEL` + `cp -c $ROOTFS` + write `meta.json` logic into `ImageStore.swift`). This makes Apple kernel a first-class option for any new image, not just `default`.

Add unit test in `Tests/LuminaTests/ImageStoreTests.swift`: verify that an image created with `kernel_source: apple/container` has `vmlinuz` < 20 MB and meta.json reports the source.

```bash
swift test --filter ImageStoreTests
git add Sources/Lumina/ImageStore.swift Sources/lumina-cli/CLI.swift Tests/LuminaTests/ImageStoreTests.swift
git commit -m "feat(images): --apple-kernel flag on images create wires the same logic as fetch-apple-kernel.sh"
```

- [ ] **Step 8: Update CLAUDE.md image format docs (`### Image Formats`).** Document Apple-kernel images as a third (preferred) variant alongside baked and legacy.

---

## Phase 2 — Merge ISO CLI branches

**Hypothesis:** Both `feat/iso-cli-2026-05-09` and `fix/iso-boot-windows-kali` auto-merge clean (verified). Brings `lumina iso <path>` verb covering Linux ISOs, Windows 11 (with TPM bypass via autounattend.xml sidecar), macOS IPSW, and Debian/Kali auto-preseed.

**Files added/modified by these merges (verified):**

- ADD: `Sources/lumina-cli/IsoCommand.swift`, `Sources/lumina-cli/IsoBootHelpers.swift`
- ADD: `Sources/LuminaBootable/WindowsUnattend.swift`, `AutounattendSeed.swift`, `FirstBootPlan.swift`, `PreseedSeed.swift`
- MODIFY: `Sources/Lumina/Types.swift`, `Sources/Lumina/EFIBootable.swift`, `Sources/lumina-cli/CLI.swift`, `Sources/lumina-cli/DesktopCommand.swift`, `Sources/LuminaBootable/LinuxISOExtractor.swift`, `Sources/LuminaBootable/DesktopOSCatalog.swift`, `Sources/LuminaDesktopKit/LuminaDesktopSession.swift`
- ADD tests: `Tests/LuminaBootableTests/WindowsUnattendTests.swift`, `AutounattendSeedTests.swift`, `FirstBootPlanTests.swift`
- ADD fixture/smoke: `Tests/fixtures/alpine-iso-boot.sha256`, `Tests/iso-boot-smoke.sh`

- [ ] **Step 1: Merge `feat/iso-cli-2026-05-09`.**

```bash
cd ~/Developer/lumina-lumi-port
git merge --no-ff feat/iso-cli-2026-05-09 -m "merge: feat(iso-cli-2026-05-09) — lumina iso verb for ARM64 ISOs"
```

If conflicts appear (they shouldn't per trial-merge but verify): `git status` → resolve → `git add` → `git commit`.

- [ ] **Step 2: Merge `fix/iso-boot-windows-kali`.**

```bash
git merge --no-ff fix/iso-boot-windows-kali -m "merge: fix(iso-boot-windows-kali) — Debian/Kali preseed + first-boot fixes"
```

- [ ] **Step 3: Verify build green.**

```bash
make build  # debug + codesign
```

Expected: zero compile errors. If errors, investigate before continuing.

- [ ] **Step 4: Verify unit tests green.**

```bash
swift test 2>&1 | tail -30
```

Expected: all pass. Note any newly-failing test for follow-up — do NOT silence.

- [ ] **Step 5: Run iso-boot smoke (no actual VM boot required for the unit-test set).**

```bash
bash Tests/iso-boot-smoke.sh 2>&1 | tee /tmp/iso-smoke.log
```

Expected: pass on whichever assertions are host-only (the script may auto-skip VM-required steps if no ISO is available).

- [ ] **Step 6: Manually verify the verb is registered.**

```bash
.build/debug/lumina iso --help 2>&1 | head -20
```

Expected: usage prints, subcommands (`boot`, `inspect`, `ls`) visible.

- [ ] **Step 7: Tag the merge.** Already committed by Steps 1-2. No additional commit needed.

---

## Phase 3 — Port lumi's warm-pool daemon as `lumind` (additive verb)

**Hypothesis:** A daemon that holds N booted VMs warm gives ≤ 10 ms warm exec on a new `lumina daemon run <cmd>` path. Don't replace `SessionServer` yet — additive.

**Files to create:** `Sources/Lumina/Daemon.swift` (~250 LOC, mirrors `~/Developer/lumi/Sources/lumi/Pool.swift`). Wire into `Sources/lumina-cli/CLI.swift` as `lumina daemon serve|stop|status|run`.

- [ ] **Step 1: Read `~/Developer/lumi/Sources/lumi/Pool.swift` end-to-end.** Understand: `actor PoolState`, `Pool.tryRun`, `Pool.serve`, `Pool.status`, `Pool.stop`, socket layout at `~/.lumi/pool.sock`.

- [ ] **Step 2: Write failing test for `Daemon.start` → `Daemon.status` round-trip.**

```swift
// Tests/LuminaTests/DaemonTests.swift
import Testing
@testable import Lumina

@Test func daemonStartsAndReportsStatus() async throws {
    let daemon = try await Daemon.start(socketPath: "/tmp/test-lumind-\(UUID().uuidString).sock", poolSize: 2)
    defer { Task { await daemon.shutdown() } }
    let status = try await Daemon.status(socketPath: daemon.socketPath)
    #expect(status.poolSize == 2)
    #expect(status.warm >= 0)
}
```

```bash
swift test --filter DaemonTests 2>&1 | tail -5
```

Expected: FAIL with "no such symbol: Daemon".

- [ ] **Step 3: Implement `Sources/Lumina/Daemon.swift`.**

Mirror lumi's `Pool.swift` exactly:
- `actor PoolState` — `available: [BootedVM]`, `acquire()`, `scheduleRefill()`, `warmUp(size:)`
- `enum Daemon` — static `start(socketPath:poolSize:)`, `tryRun(image:exec:socketPath:)`, `status(socketPath:)`, `stop(socketPath:)`
- Socket bind at `~/.lumina/lumind.sock`, `chmod 0600` after bind (preserve learning #6).
- Per-VM lifetime: claim from pool → `BootedVM.exec(...)` → discard (dirty) or return (clean reset).
- The exec path reuses the *same* `CommandRunner` from `Sources/Lumina/CommandRunner.swift` against the warm VM's vsock fd. **Do not duplicate vsock state-machine code** — the daemon is identity-and-lifecycle only.

```bash
make build
swift test --filter DaemonTests 2>&1 | tail -5
```

Expected: build green, test PASS.

- [ ] **Step 4: Wire the CLI verbs.** Add `Daemon` ArgumentParser group to `Sources/lumina-cli/CLI.swift`:
  - `lumina daemon serve [--size N] [--socket PATH]`
  - `lumina daemon stop [--socket PATH]`
  - `lumina daemon status [--socket PATH]`
  - `lumina run --via-daemon "cmd"` — uses daemon if `~/.lumina/lumind.sock` exists, falls back to cold boot otherwise. Default behavior of `lumina run` is unchanged for this phase.

- [ ] **Step 5: Smoke + bench the daemon path.**

```bash
.build/release/lumina daemon serve --size 4 &
DAEMON_PID=$!
sleep 6  # let it warm up
for i in 1 2 3 4 5; do
  /usr/bin/time -p .build/release/lumina run --via-daemon "true" 2>&1 | awk '/real/ {print $2"s"}'
done
.build/release/lumina daemon stop
wait $DAEMON_PID
```

Expected: each run < 0.020 s (20 ms wall, where ≤ 10 ms is the daemon-side exec and ~5-10 ms is CLI overhead).

- [ ] **Step 6: Verify 5-way concurrent on the daemon.**

```bash
.build/release/lumina daemon serve --size 5 &
sleep 6
seq 1 5 | xargs -P 5 -I{} .build/release/lumina run --via-daemon "echo {}" > /tmp/concurrent.log 2>&1
.build/release/lumina daemon stop
grep -c '^"5"' /tmp/concurrent.log  # expect 1
```

- [ ] **Step 7: Verify ≥ 100 concurrent does NOT regress.**

```bash
.build/release/lumina daemon serve --size 8 &
sleep 6
seq 1 100 | xargs -P 100 -I{} .build/release/lumina run --via-daemon "echo {}" 2>&1 | grep -c '"exit_code":0'
# expect 100
```

If fewer than 100 succeed, the daemon path is regressing the 200-way concurrent dispatch property. Stop and apply the `withCheckedContinuation { dispatch to GCD queue }` pattern (Learning #7) inside the daemon's accept loop.

- [ ] **Step 8: Commit.**

```bash
git add Sources/Lumina/Daemon.swift Sources/lumina-cli/CLI.swift Tests/LuminaTests/DaemonTests.swift
git commit -m "feat(daemon): lumind warm-pool daemon as additive lumina daemon verb

Mirrors ~/Developer/lumi/Sources/lumi/Pool.swift. Adds lumina daemon
{serve,stop,status} + lumina run --via-daemon. SessionServer unchanged.

Bench (size=4 pool, warm exec): <bench numbers from Step 5>
≥100 concurrent verified: <result from Step 7>"
```

---

## Phase 4 — Bench, prove, document

- [ ] **Step 1: Final full P50/P95/P99 bench using `bench-boot.sh` and `scripts/bench-agent-path.sh`.**

```bash
bash bench-boot.sh 2>&1 | tee docs/bench/2026-05-24-final-bench.log
bash scripts/bench-agent-path.sh 2>&1 | tee docs/bench/2026-05-24-agent-path-bench.log
```

- [ ] **Step 2: Write a bench-summary table in `docs/bench/2026-05-24-summary.md`.**

Columns: Metric | Baseline (Alpine kernel, no daemon) | Phase 1 (Apple kernel) | Phase 3 (daemon path) | Target | Pass/Fail.

- [ ] **Step 3: Run a real agent workflow.**

Pick one of the user's actual workflows from `~/Developer/`. Run it twice — once against `~/.local/bin/lumina` (old binary, pre-port), once against `.build/release/lumina` (new). Wall-clock-compare. Document in `docs/bench/2026-05-24-agent-workflow.md`.

- [ ] **Step 4: File `agent-feedback`-labeled issues on `abdul-abdi/lumina`** for any bugs/limitations discovered. Use the recipe in `~/.claude/CLAUDE.md` "Lumina feedback loop". Don't file dupes — `gh issue list -R abdul-abdi/lumina --search ...` first.

- [ ] **Step 5: Write Brain wiki updates.**

- New decision page: `~/Brain/wiki/decisions/lumina-apple-kernel-as-default.md` (the flip from Alpine to Apple).
- New decision page: `~/Brain/wiki/decisions/lumina-lumind-additive-daemon.md` (chose additive `lumina daemon` over SessionServer replacement).
- New learning: `~/Brain/wiki/learnings/lumina-apple-kernel-cold-boot-delta-2026-05-24.md` with concrete before/after numbers.
- Update `~/Brain/wiki/projects/lumina.md` `updated:` field and current-status section.

- [ ] **Step 6: Open PR draft against lumina main.**

```bash
gh pr create --draft --title "feat: port lumi's foundational bets into lumina (Apple kernel, lumind daemon, lumina iso verb)" --body "$(cat <<'EOF'
## Summary

- Phase 1: Apple containerization kernel as default → cold-boot ≤250 ms (was 368 ms)
- Phase 2: lumina iso verb merged (Linux/Windows/macOS auto-detect, TPM bypass, Debian/Kali preseed)
- Phase 3: lumind warm-pool daemon as additive `lumina daemon serve/run` (≤10 ms warm exec)
- Desktop kept green; macOS guest path untouched; SessionServer untouched (deprecation deferred).

## Bench

See docs/bench/2026-05-24-summary.md

## Test plan
- [x] make build
- [x] swift test (full)
- [x] bench-boot.sh 20-run P50/P95/P99
- [x] daemon path ≥100 concurrent
- [x] Desktop app launches + LuminaDesktopKit tests green
- [x] lumina iso --help / iso boot smoke

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

(Draft, not merge. Let the user review before merging.)

---

## Phase 5 (optional) — VM actor → struct (LOC cleanup, GATED)

**Gate:** Only enter Phase 5 if Phases 1-4 land green AND there is budget left AND the proof bar is already met without it.

**Risk:** High. The `actor VM` is load-bearing on:
- `VMExecutor` queue ownership
- vz-cancel flock-leak handler
- `pendingDelegate`-attach-before-start
- `macLastByte` persistence
- `runner: CommandRunner?` ownership

A naive `actor → struct` would regress all of these.

**Approach (if entered):**

- [ ] Read `VM.swift:142-235` in full. List every property that escapes the actor boundary.
- [ ] Identify which methods are *transducers* (input → output, no state read) — those become free functions on `VMState`.
- [ ] Keep `VM` as a `final class @unchecked Sendable` (not actor, not struct) wrapping the queue + mutable state — same shape as `CommandRunner` already uses.
- [ ] Run full test suite after each method moves. Any regression = revert that single move.
- [ ] Bench again after the conversion. Expect zero perf change.

**Stop conditions:**
- Any of: 200-way concurrent regresses, vz-cancel flock leak returns, Desktop boot-waterfall mirror breaks, LuminaDesktopKit tests fail.
- Revert immediately.

---

## Phase 6 (optional) — Protocol flatten (LOC cleanup, GATED)

**Gate:** Same as Phase 5. Only if budget remains.

**Approach:** Add a new `FlatProtocol.swift` that wraps the existing 27 typed cases behind `Command`/`Event` with growable maps. Old code keeps compiling. New daemon path consumes flat shape. Eventually delete typed cases. NOT in scope to break wire compat with existing agents.

**Skip if:** Phases 1-4 already pass the proof bar — flattening saves LOC, not perf, and lumi itself couldn't get below 6 ops + 12 events.

---

## Stop conditions

Declare "super better" and stop when:

1. ✅ Phase 1 cold-boot ≤ 250 ms (warm-image) and ≤ 500 ms (truly-cold) P50.
2. ✅ Phase 3 daemon warm-exec ≤ 10 ms P50.
3. ✅ Phase 2 `lumina iso` verb works (≥1 Linux ISO, ≥1 Windows ISO with TPM bypass).
4. ✅ Phase 4 ≥100 concurrent on daemon path succeeds.
5. ✅ `make build && swift test` green on this branch.
6. ✅ LuminaDesktopKit tests green.
7. ✅ Real agent workflow runs end-to-end faster than baseline.
8. ✅ Brain docs written (1 decision + 1 learning minimum).
9. ✅ At least one `agent-feedback` issue filed if bugs/limits surfaced (skip cleanly if none).
10. ✅ Draft PR opened.

If any of 1-7 fails: investigate, fix, re-bench. Do NOT silence failing tests. If genuinely stuck, write a HANDOFF.md in this worktree summarizing state.

---

## Self-review checklist (run at end of plan execution, before stop conditions)

- [ ] Every step that touches `VM.swift` / `CommandRunner.swift` was re-checked against the 9 constraints at the top of this plan.
- [ ] No placeholder TODOs left in committed code.
- [ ] `git log --oneline main..HEAD` is coherent — each commit is one logical change.
- [ ] No commits with `--no-verify`.
- [ ] GOAL.md targets either hit or have an honest miss explanation in the bench summary.

---

## Execution handoff

Use `superpowers:subagent-driven-development` if executing this plan. Fresh subagent per phase (not per step — phases are the natural granularity here). Two-stage review between phases.
