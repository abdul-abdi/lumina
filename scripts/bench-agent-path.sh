#!/usr/bin/env bash
# Quick agent-pathway benchmark harness — cold-boot + warm-exec.
# Not part of CI; used locally to capture release numbers for the
# v0.7.1 PR body.
set -euo pipefail

BIN="${BIN:-$(swift build -c release --show-bin-path)/lumina}"

if ! command -v jq >/dev/null 2>&1; then
    echo "error: jq required" >&2
    exit 1
fi

cold_iters=${COLD_ITERS:-8}
warm_iters=${WARM_ITERS:-20}

echo "lumina: $BIN"
echo "cold-boot iterations: $cold_iters"
echo "warm-exec iterations: $warm_iters"
echo ""

extract_ms() {
    printf '%s' "$1" | jq -r '
        select((.error // null) == null and (.exit_code // -1) == 0)
        | .duration_ms // empty
    '
}

p50p95p99() {
    # Read stdin numbers one per line, print "p50 p95 p99 min max n"
    awk '
        { a[NR]=$1; sum += $1 }
        END {
            n = NR
            if (n == 0) { print "0 0 0 0 0 0"; exit }
            asort(a)
            p50 = a[int(n*0.50 + 0.5)]
            p95 = a[int(n*0.95 + 0.5)]
            p99 = a[int(n*0.99 + 0.5)]
            if (p50 == "") p50 = a[n]
            if (p95 == "") p95 = a[n]
            if (p99 == "") p99 = a[n]
            printf "%d %d %d %d %d %d\n", p50, p95, p99, a[1], a[n], n
        }
    '
}

echo "── cold boot (lumina run 'true') ──"
cold_file=$(mktemp)
for i in $(seq 1 "$cold_iters"); do
    out=$("$BIN" run "true" 2>&1)
    ms=$(extract_ms "$out")
    if [ -z "$ms" ]; then
        echo "  iter $i: FAILED — $(printf '%s' "$out" | head -c 200)"
        continue
    fi
    echo "  iter $i: ${ms}ms"
    echo "$ms" >> "$cold_file"
done
printf "  cold: "
read p50 p95 p99 mn mx n < <(p50p95p99 < "$cold_file")
printf "P50=%dms  P95=%dms  P99=%dms  min=%dms  max=%dms  n=%d\n\n" "$p50" "$p95" "$p99" "$mn" "$mx" "$n"

echo "── warm session exec (one session, N execs) ──"
sid=$("$BIN" session start | jq -r '.sid')
trap "'$BIN' session stop '$sid' >/dev/null 2>&1 || true" EXIT
echo "  session: $sid"
warm_file=$(mktemp)
for i in $(seq 1 "$warm_iters"); do
    out=$("$BIN" exec "$sid" "true" 2>&1)
    ms=$(extract_ms "$out")
    if [ -z "$ms" ]; then
        echo "  iter $i: FAILED — $(printf '%s' "$out" | head -c 200)"
        continue
    fi
    # Quieter per-iter output on warm run (20+ iters).
    [ $((i % 5)) -eq 1 ] && echo "  iter $i: ${ms}ms"
    echo "$ms" >> "$warm_file"
done
printf "  warm: "
read p50 p95 p99 mn mx n < <(p50p95p99 < "$warm_file")
printf "P50=%dms  P95=%dms  P99=%dms  min=%dms  max=%dms  n=%d\n\n" "$p50" "$p95" "$p99" "$mn" "$mx" "$n"

"$BIN" session stop "$sid" >/dev/null 2>&1
echo "Done."
