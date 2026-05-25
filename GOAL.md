# GOAL — Port lumi's foundational bets into lumina

**Started:** 2026-05-24
**Owner:** abdullahi (driven by Claude Code, long-running session)
**Source decisions:** `~/Brain/wiki/synthesis/lumina-five-lens-audit-2026-04-26.md` + `~/Developer/lumi/CLAUDE.md`

## North Star

Make lumina concretely, measurably better — in performance, code surface, agent UX, human UX (Desktop), and ISO booting — by adopting the architectural bets validated in `lumi` (Scenario C of the five-lens audit), without losing what lumina already does well.

## The bets (revised after investigation)

1. **Apple kernel as default (biggest perf lever, zero code).** `Guest/fetch-apple-kernel.sh` exists. Current `~/.lumina/images/default/vmlinuz` is 70MB Alpine virt; Apple's is 15MB with `CONFIG_MODULES=n` + virtio built-in. Decision `lumina-apple-kernel-dependency.md`: ~7-8× cold-boot speedup. **Verify this alone hits ≤250ms cold target — if it does, perf scope shrinks dramatically.**
2. **`lumind` warm-pool daemon as an additive verb.** Port lumi's `Pool.swift` pattern as `lumina serve` / `lumina daemon`. Don't delete `SessionServer` yet — additive change. Goal: ≤10 ms warm exec on the daemon path. Then deprecate `SessionServer` once daemon proves out.
3. **Merge ISO branches.** `feat/iso-cli-2026-05-09` + `fix/iso-boot-windows-kali` both auto-merge clean into this branch. Brings `lumina iso <path>` verb (Linux/Windows/macOS auto-detect, Win11 TPM bypass via autounattend.xml, Debian/Kali auto-preseed).
4. **VM actor → struct (LOC cleanup, NOT perf).** Lumina's `VM.swift:142` already pins to `DispatchQueue` via `VMExecutor`. Removing the `actor` wrapper saves LOC and clarifies intent, but does NOT improve perf. Keep this for last and only if it does not regress the documented constraints (vz-cancel flock leak, MAC persistence, 200-way concurrent dispatch, `pendingDelegate`-before-start).
5. **Protocol flatten (LOC cleanup, optional).** 27 typed cases → flat `Command`/`Event` value-shapes with growable payload maps. Keep `pty_exec` distinct per decision `lumina-pty-distinct-message-type.md`. Tackle only after 1-3 land.

**Rule for actor removal:** Keep `actor` where identity is real (Pool, Network, VM-with-state). Drop `actor` only where it's a thin queue wrapper. Lumi itself keeps `actor PoolState` — copy that judgment.

## Non-negotiable additions on top of lumi

- **Desktop GUI stays.** `Apps/` (LuminaDesktopKit + the SwiftUI app) is in scope, must keep building, must keep its tests green. Boot waterfall, session snapshot, etc. lumi-style protocol changes must be reflected in the Desktop layer, not deleted.
- **ISO booting as a first-class verb.** `lumina iso <path>` already exists on `feat/iso-cli-2026-05-09` (one-step boot/inspect/ls, `--os` auto-detect for windows/macos/linux, `--bypass-tpm-check` autounattend sidecar for Win11). Plus `fix/iso-boot-windows-kali` has auto-preseed for Debian/Kali + first-boot fixes. Goal: **merge both branches in**, ensure they survive the actor→DispatchQueue migration, expose the verb through both CLI and Desktop. (lumi explicitly punts ISO — lumina must keep it.)
- **Backwards-compat shim, briefly.** Old `lumina session start/exec/stop` keeps working via thin wrapper over the daemon for one minor version (deprecation warning), then removed. Hard cut at v0.9.0.

## Concrete proof bar (all must be true before declaring "super better")

| Metric / artifact                                 | Baseline (2026-04-26 measured) | Target                                                                       |
| ------------------------------------------------- | ------------------------------ | ---------------------------------------------------------------------------- |
| Warm-image cold `lumina run "echo"` P50           | 368 ms                         | **≤ 250 ms**                                                                 |
| Truly-cold first `lumina run "uname -a"` P50      | 596 ms                         | **≤ 500 ms**                                                                 |
| Warm-pool / daemon exec P50                       | 31 ms (session path)           | **≤ 10 ms**                                                                  |
| 5-way concurrent `lumina run` succeeds            | works, pool=4 ceiling          | works, scales to pool size                                                   |
| `Sources/Lumina` host LOC                         | 8 500                          | **≤ 6 500** (Desktop+macOS+ISO kept; ≤4500 needs feature cuts user rejected) |
| All 12 lumi smoke tests pass on lumina            | n/a                            | **PASS**                                                                     |
| `lumina iso <linux.iso>` boots + exits            | manual / lumina-iso-cli only   | **single verb, works**                                                       |
| `lumina iso <win11.iso> --bypass-tpm-check`       | manual                         | **autounattend sidecar, works**                                              |
| `lumina iso <macos.ipsw>` boots                   | manual / lumina-iso-cli only   | **single verb, works**                                                       |
| ≥100 concurrent `lumina run` succeeds             | 200-way verified on session    | **≥100 verified on daemon, no regression**                                   |
| Desktop app builds + LuminaDesktopKit tests green | green                          | **STILL green**                                                              |
| Boot-waterfall in Desktop shows new phase markers | works                          | **STILL works on new protocol**                                              |
| Real agent workflow (Claude Code task w/ sandbox) | works on old path              | **works on new path, faster wall-clock**                                     |
| Agent-feedback issues filed for found bugs/limits | n/a                            | **Filed on abdul-abdi/lumina**                                               |
| Brain docs: decision page + learnings             | n/a                            | **Written**                                                                  |

## Out of scope (decided now, not deferred)

- VM-to-VM networking changes (NetworkSwitch stays as-is).
- Named volumes API churn (VolumeStore stays).
- Pool semantics on top of warm-pool — the warm pool IS the new Pool. The old `PoolTests.swift` migrates or dies.
- Renaming binaries/packages (`lumina` stays `lumina`).

## Execution plan path

`docs/superpowers/plans/2026-05-24-lumi-bets-into-lumina.md` (to be written after parallel investigations complete; see TaskList).

## Worktree strategy

All work happens in `../lumina-lumi-port` (git worktree off `main`, branch `feat/lumi-port`). Main checkout stays untouched until merge.

## Success = the user runs `lumina run "echo hello"`, gets ≤ 250 ms cold and ≤ 10 ms warm, sees Desktop still working, and can `lumina boot --iso ubuntu.iso` from one binary.
