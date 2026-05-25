# Phase 4 — verification block (advisor-flagged gaps closed)

**Date:** 2026-05-25 (after initial PR open)

## Gap 1: ISO verb actually works, not just `--help`-registered

- `lumina iso inspect ~/.lumina/cache/alpine-efi.iso` → JSON: architecture arm64, distro Alpine virt, kernel/initramfs paths populated, recommended resources. ✅ Works.

## Gap 2: Apple-kernel virtio paths (network + fs)

- `lumina run --volume /tmp/volcheck:/host "ls /host && cat /host/marker"` → 230 ms, exit 0, contents read. **virtio_fs works under Apple kernel.** ✅
- `lumina run --wait-network "ip addr show eth0 | head -3; getent hosts apple.com"` → 2908 ms, exit 0, eth0 up, DNS resolves. **virtio_net works under Apple kernel.** ✅

## Gap 3: Desktop xcodebuild

- `cd Apps/LuminaDesktop && xcodegen generate && xcodebuild -scheme LuminaDesktop -configuration Debug -allowProvisioningUpdates CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO build`
- Result: `** BUILD SUCCEEDED **` — `/tmp/lumina-desktop-build/Build/Products/Debug/Lumina.app` produced. ✅

## Gap 4: lumi smoke contract (10/10 cold, 6/10 daemon)

`bench/lumi-smoke.sh`:

| Test                | Cold | Daemon                                                |
| ------------------- | ---- | ----------------------------------------------------- |
| 1 echo hello        | PASS | PASS                                                  |
| 2 exit 7            | PASS | PASS                                                  |
| 3 stderr split      | PASS | PASS                                                  |
| 4 stdin pipe        | PASS | FAIL (expected — daemon v1 protocol has no stdin op)  |
| 5 env vars          | PASS | PASS                                                  |
| 6 workdir           | PASS | PASS                                                  |
| 7 --copy upload     | PASS | FAIL (expected — daemon v1 has no transfer ops)       |
| 8 --download        | PASS | FAIL (expected — daemon v1 has no transfer ops)       |
| 9 --volume          | PASS | FAIL (expected — daemon v1 has no volume ops)         |
| 10 timeout          | PASS | PASS                                                  |
| **Total**           | **10/10** | **6/10 (4 documented v1-protocol limits)**            |

Sustained warm latency after 10-test daemon run: 1, 0, 1, 0, 0 ms.

## Gap 5: ≥100 concurrent honesty

Original claim "100/100 OK" was measured with `xargs -P 8 × N=100` (8 sustained, 100 invocations) — NOT N=100 simultaneous. PR body now reflects this. A separate test of `N=10 simultaneous on pool=10` wedged the daemon → filed as #33. Sustained P=8 / N=100 remains the verified case.

## Open issues filed during verification

- #31 — Pool reset-and-return optimization (enhancement).
- #33 — Daemon wedge when N-simultaneous ≥ pool size (bug).
