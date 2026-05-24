# GOAL — Port lumi's foundational bets into lumina

**Started:** 2026-05-24
**Owner:** abdullahi (driven by Claude Code, long-running session)
**Source decisions:** `~/Brain/wiki/synthesis/lumina-five-lens-audit-2026-04-26.md` + `~/Developer/lumi/CLAUDE.md`

## North Star

Make lumina concretely, measurably better — in performance, code surface, agent UX, human UX (Desktop), and ISO booting — by adopting the architectural bets validated in `lumi` (Scenario C of the five-lens audit), without losing what lumina already does well.

## The bets (locked, from lumi)

1. **No actor.** VZ thread affinity satisfied by `DispatchQueue` passed to `VZVirtualMachine(configuration:queue:)`. `UncheckedSendable<T>` (4-line struct) is the Swift 6 escape hatch. Drop the `VM` actor as a state holder.
2. **Functions over places.** Eliminate `CommandRunner` / `SessionServer` / `Pool` / `DiskClone` as classes where the work is naturally a function over arguments returning a result. Classes only where identity/lifetime is real (the warm-pool daemon).
3. **One verb, two paths.** `lumina run "cmd"` always works. If `lumind` (daemon) is up, exec on a warm VM (~5–10 ms). If not, cold boot (≤250 ms warm-image, ≤500 ms truly cold). Kill the `session start/exec/stop` split as the public surface — the daemon IS the session.
4. **Flat wire shape.** Collapse the 27 typed messages to two value-shapes: one `Command` (op + id + payload map) host→guest, one `Event` (event + id + payload map) guest→host. Reflected in **one** Protocol file. Unknown keys ignored for forward compat.
5. **Warm-pool daemon (`lumind`).** N hot VMs kept ready; `lumina run` claims one, runs, returns it (or destroys if dirty). N pool slots = N concurrent boots naturally.

## Non-negotiable additions on top of lumi

- **Desktop GUI stays.** `Apps/` (LuminaDesktopKit + the SwiftUI app) is in scope, must keep building, must keep its tests green. Boot waterfall, session snapshot, etc. lumi-style protocol changes must be reflected in the Desktop layer, not deleted.
- **ISO booting as a first-class verb.** `lumina iso <path>` already exists on `feat/iso-cli-2026-05-09` (one-step boot/inspect/ls, `--os` auto-detect for windows/macos/linux, `--bypass-tpm-check` autounattend sidecar for Win11). Plus `fix/iso-boot-windows-kali` has auto-preseed for Debian/Kali + first-boot fixes. Goal: **merge both branches in**, ensure they survive the actor→DispatchQueue migration, expose the verb through both CLI and Desktop. (lumi explicitly punts ISO — lumina must keep it.)
- **Backwards-compat shim, briefly.** Old `lumina session start/exec/stop` keeps working via thin wrapper over the daemon for one minor version (deprecation warning), then removed. Hard cut at v0.9.0.

## Concrete proof bar (all must be true before declaring "super better")

| Metric / artifact                                 | Baseline (2026-04-26 measured) | Target                                   |
| ------------------------------------------------- | ------------------------------ | ---------------------------------------- |
| Warm-image cold `lumina run "echo"` P50           | 368 ms                         | **≤ 250 ms**                             |
| Truly-cold first `lumina run "uname -a"` P50      | 596 ms                         | **≤ 500 ms**                             |
| Warm-pool / daemon exec P50                       | 31 ms (session path)           | **≤ 10 ms**                              |
| 5-way concurrent `lumina run` succeeds            | works, pool=4 ceiling          | works, scales to pool size               |
| `Sources/Lumina` host LOC                         | 8 344                          | **≤ 4 500** (without losing Desktop)     |
| All 12 lumi smoke tests pass on lumina            | n/a                            | **PASS**                                 |
| `lumina boot --iso <linux.iso>` boots + exits     | manual / lumina-iso-cli only   | **single verb, works**                   |
| `lumina boot --ipsw <macos.ipsw>` boots           | manual / lumina-iso-cli only   | **single verb, works**                   |
| Desktop app builds + LuminaDesktopKit tests green | green                          | **STILL green**                          |
| Boot-waterfall in Desktop shows new phase markers | works                          | **STILL works on new protocol**          |
| Real agent workflow (Claude Code task w/ sandbox) | works on old path              | **works on new path, faster wall-clock** |
| Agent-feedback issues filed for found bugs/limits | n/a                            | **Filed on abdul-abdi/lumina**           |
| Brain docs: decision page + learnings             | n/a                            | **Written**                              |

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
