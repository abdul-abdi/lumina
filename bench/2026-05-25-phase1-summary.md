# Phase 1 — Apple kernel as default (proof)

**Date:** 2026-05-25
**Host:** $(uname -mrs)
**Binary:** `~/Developer/lumina-lumi-port/.build/release/lumina` (built from `feat/lumi-port-2026-05-24`)
**Kernel paths:**
- Alpine (baseline): `vmlinuz` 70 MB Alpine virt
- Apple: `vmlinux-6.18.5-177` 15 MB from `~/Library/Application Support/com.apple.container/kernels/`

## Method

Each iter: `lumina run "true"`, extract `duration_ms` from JSON envelope. Cold meaning the daemon path is NOT used (no `lumina daemon serve`). VZ-side caches are warm from prior iters (typical agent workload).

## Results

| Metric              | Alpine baseline (5 iters) | Apple kernel (10 iters) | Delta            |
| ------------------- | ------------------------- | ----------------------- | ---------------- |
| P50                 | 276 ms                    | **196 ms**              | **-80 ms (-29%)** |
| P95                 | 331 ms (n=5, P100)        | **209 ms**              | -122 ms          |
| min                 | 272 ms                    | 184 ms                  | -88 ms           |
| max                 | 331 ms                    | 209 ms                  | -122 ms          |

## GOAL.md bar

- Warm-image cold ≤250 ms: **MET** (P50=196ms, P95=209ms; all 10 iters <250ms)

## Notes

The audit's 2026-04-26 baseline was 368ms P50 — the `perf/five-wins-2026-04-26` branch already shipped audit wins (boot-trace, network reliability, awaitNetworkReady=false default, etc.) that took it to 276ms before this change. So the kernel swap is a 76-80ms further reduction on top of those wins.

## Reversible

`~/.lumina/images/default/vmlinuz.pre-apple-20260525.bak` holds the 70 MB Alpine kernel. Restore with `cp -f ~/.lumina/images/default/vmlinuz.pre-apple-20260525.bak ~/.lumina/images/default/vmlinuz`.
