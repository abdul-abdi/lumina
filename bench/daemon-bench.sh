#!/usr/bin/env bash
# bench/daemon-bench.sh — measure lumina daemon warm-exec P50/P95/P99 vs cold path.
#
# Usage:
#   bench/daemon-bench.sh                 # uses .build/release/lumina
#   BIN=/path/to/lumina bench/daemon-bench.sh
#
# What it does:
#   1. Cold-path bench: 10 × `lumina run "true"`, no daemon.
#   2. Starts `lumina daemon serve --size 4`, waits for warm.
#   3. Warm-path bench: 20 × `lumina run --via-daemon "true"`.
#   4. ≥100-concurrent stress on daemon path.
#   5. Daemon stop.
#   6. Prints P50/P95/P99/min/max for both, plus concurrent pass/fail count.
#
# Requires: jq.
set -u

BIN="${BIN:-$(cd "$(dirname "$0")/.."; pwd)/.build/arm64-apple-macosx/release/lumina}"
if ! [ -x "$BIN" ]; then echo "error: $BIN not executable" >&2; exit 1; fi
if ! command -v jq >/dev/null 2>&1; then echo "error: jq required" >&2; exit 1; fi

echo "lumina:  $BIN"
echo "version: $($BIN --version)"
echo ""

# ── Cold path (no daemon) ─────────────────────────────────────────────
echo "── cold path (10 iters of \`lumina run 'true'\`) ──"
cold_file=$(mktemp)
for i in $(seq 1 10); do
    out=$("$BIN" run "true" 2>/dev/null)
    ms=$(printf '%s' "$out" | jq -r 'select((.error // null) == null) | .duration_ms // empty' 2>/dev/null)
    if [ -z "$ms" ]; then
        echo "  iter $i: FAILED — $(printf '%s' "$out" | head -c 200)"
        continue
    fi
    echo "  iter $i: ${ms}ms"
    echo "$ms" >> "$cold_file"
done
cold_p50=$(sort -n "$cold_file" | awk 'NR == int((NR_TOTAL = NR_TOTAL ? NR_TOTAL : NR) * 0.5 + 0.5)' 2>/dev/null || true)
# Simpler: just compute p50/p95/p99 via sort+awk in one go
echo ""
echo "  cold summary:"
sort -n "$cold_file" | awk '
    {a[NR] = $1}
    END {
        n = NR
        if (n == 0) exit
        p50 = a[int(n * 0.5 + 0.5)]
        p95 = a[int(n * 0.95 + 0.5)]
        p99 = a[int(n * 0.99 + 0.5)]
        printf "    P50=%dms  P95=%dms  P99=%dms  min=%dms  max=%dms  n=%d\n", p50, p95, p99, a[1], a[n], n
    }
'

# ── Daemon warm path ──────────────────────────────────────────────────
echo ""
echo "── starting \`lumina daemon serve --size 4\` ──"
# Use default socket path so `run --via-daemon` (which has no --socket flag) finds it.
SOCK="$HOME/.lumina/lumind.sock"
rm -f "$SOCK"
"$BIN" daemon serve --size 4 >/tmp/daemon-bench.log 2>&1 &
DAEMON_PID=$!
trap "kill -TERM $DAEMON_PID 2>/dev/null; rm -f $SOCK" EXIT

# Wait for "warm" message in log, max 30 seconds.
for _ in $(seq 1 150); do
    if grep -q "warm" /tmp/daemon-bench.log 2>/dev/null; then break; fi
    if ! kill -0 $DAEMON_PID 2>/dev/null; then
        echo "  ERROR: daemon process died during boot. Log:"
        tail -20 /tmp/daemon-bench.log
        exit 1
    fi
    sleep 0.2
done
echo "  daemon ready"
echo ""

echo "── warm path (20 iters of \`lumina run --via-daemon 'true'\`) ──"
warm_file=$(mktemp)
for i in $(seq 1 20); do
    out=$("$BIN" run --via-daemon "true" 2>/dev/null)
    ms=$(printf '%s' "$out" | jq -r 'select((.error // null) == null) | .duration_ms // empty' 2>/dev/null)
    if [ -z "$ms" ]; then
        echo "  iter $i: FAILED — $(printf '%s' "$out" | head -c 200)"
        continue
    fi
    [ $((i % 5)) -eq 1 ] && echo "  iter $i: ${ms}ms"
    echo "$ms" >> "$warm_file"
done
echo ""
echo "  warm summary:"
sort -n "$warm_file" | awk '
    {a[NR] = $1}
    END {
        n = NR
        if (n == 0) exit
        p50 = a[int(n * 0.5 + 0.5)]
        p95 = a[int(n * 0.95 + 0.5)]
        p99 = a[int(n * 0.99 + 0.5)]
        printf "    P50=%dms  P95=%dms  P99=%dms  min=%dms  max=%dms  n=%d\n", p50, p95, p99, a[1], a[n], n
    }
'

# ── Concurrent stress ─────────────────────────────────────────────────
echo ""
echo "── ≥100 concurrent (xargs -P 8 to match pool ceiling) ──"
stress_file=$(mktemp)
worker_script=$(mktemp /tmp/lumind-stress-worker-XXXXXX.sh)
cat > "$worker_script" <<WORKER
#!/usr/bin/env bash
i="\$1"
out=\$("$BIN" run --via-daemon "echo \$i" 2>/dev/null)
code=\$(printf '%s' "\$out" | jq -r '.exit_code // -1' 2>/dev/null)
[ "\$code" = "0" ] && echo OK >> "$stress_file" || echo FAIL >> "$stress_file"
WORKER
chmod +x "$worker_script"
# -P 8 is twice the pool size (=4) — caps pending refills, exercises queueing
# without overwhelming VZ slot ceiling.
seq 1 100 | xargs -P 8 -I{} "$worker_script" "{}"
rm -f "$worker_script"
ok=$(grep -c '^OK' "$stress_file" 2>/dev/null || echo 0)
fail=$(grep -c '^FAIL' "$stress_file" 2>/dev/null || echo 0)
echo "  ok=$ok fail=$fail / 100"

# ── Stop daemon ───────────────────────────────────────────────────────
echo ""
echo "── stopping daemon ──"
"$BIN" daemon stop 2>&1 | head -3
wait $DAEMON_PID 2>/dev/null

echo ""
echo "Done."
