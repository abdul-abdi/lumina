#!/usr/bin/env bash
# Lumina stress suite — push v0.6.0 primitives until something breaks.
# Not part of CI; run by hand to find ceilings and validate durability.
#
# Usage: ./tests/stress.sh [path-to-lumina]

set -uo pipefail
LUMINA="${1:-$HOME/.local/bin/lumina}"
export LUMINA_FORMAT=json

PASS=0
FAIL=0
FAILURES=()

pass() { PASS=$((PASS + 1)); echo "  PASS $1"; }
fail() { FAIL=$((FAIL + 1)); FAILURES+=("$1: $2"); echo "  FAIL $1: $2"; }
section() { echo; echo "=== $1 ==="; }

cleanup_all() {
  for sid in $($LUMINA session list 2>/dev/null | jq -r '.[].sid' 2>/dev/null); do
    $LUMINA session stop "$sid" 2>/dev/null || true
  done
  pkill -f "_session-serve" 2>/dev/null || true
  rm -rf ~/.lumina/sessions/* 2>/dev/null || true
  sleep 5
}
trap cleanup_all EXIT
cleanup_all

echo "Binary: $LUMINA ($($LUMINA --version 2>&1 | tail -1))"

# ───────────────────────────────────────────────────────────────
section "S1. CONCURRENT DISPOSABLE VMs — find the ceiling"
# ───────────────────────────────────────────────────────────────
# Memory per VM = 1GB (RunOptions default). Claim in CLAUDE.md: 10×512MB ok
# on 18GB M3 Pro. We use 1GB to mirror `run` default — expect ceiling lower.
for COUNT in 4 6 8; do
  cleanup_all
  PIDS=()
  RUN_ID=$(date +%s)_$COUNT
  for i in $(seq 1 $COUNT); do
    $LUMINA run --timeout 60s "echo cvm_${i} && sleep 2 && echo done_${i}" \
      > /tmp/lumina-stress-$RUN_ID-$i.json 2>/dev/null &
    PIDS+=($!)
  done
  OK_COUNT=0
  for i in $(seq 1 $COUNT); do
    wait ${PIDS[$((i-1))]} 2>/dev/null || true
    OUT=$(cat /tmp/lumina-stress-$RUN_ID-$i.json)
    if echo "$OUT" | jq -e ".exit_code == 0 and (.stdout | test(\"cvm_$i\")) and (.stdout | test(\"done_$i\"))" >/dev/null 2>&1; then
      OK_COUNT=$((OK_COUNT + 1))
    fi
  done
  if [ "$OK_COUNT" = "$COUNT" ]; then
    pass "S1.${COUNT} $COUNT concurrent VMs all succeeded"
  else
    fail "S1.${COUNT} $COUNT concurrent VMs" "only $OK_COUNT/$COUNT succeeded"
  fi
done
rm -f /tmp/lumina-stress-*.json

# ───────────────────────────────────────────────────────────────
section "S2. HIGH-THROUGHPUT STDOUT via run (100K lines)"
# ───────────────────────────────────────────────────────────────
cleanup_all
START=$(date +%s)
OUT=$($LUMINA run --timeout 90s "seq 1 100000" 2>/dev/null)
ELAPSED=$(( $(date +%s) - START ))
LINES=$(echo "$OUT" | jq -r '.stdout' | grep -c "^[0-9]" || true)
LAST=$(echo "$OUT" | jq -r '.stdout' | awk 'NF' | tail -1)
EXIT=$(echo "$OUT" | jq -r '.exit_code')
if [ "$EXIT" = "0" ] && [ "$LINES" -ge 100000 ] && [ "$LAST" = "100000" ]; then
  pass "S2.1 100K lines in ${ELAPSED}s (last=$LAST, lines=$LINES)"
else
  fail "S2.1 100K lines" "exit=$EXIT lines=$LINES last=$LAST elapsed=${ELAPSED}s"
fi

# ───────────────────────────────────────────────────────────────
section "S3. SESSION CHURN — rapid start/stop cycles"
# ───────────────────────────────────────────────────────────────
cleanup_all
CYCLES=15
OK=true
CYCLE_FAIL=""
for i in $(seq 1 $CYCLES); do
  SID=$($LUMINA session start 2>&1 | jq -r '.sid' 2>/dev/null)
  if [ -z "$SID" ] || [ "$SID" = "null" ]; then
    OK=false; CYCLE_FAIL="start $i"; break
  fi
  OUT=$($LUMINA exec "$SID" "echo churn_$i" 2>&1)
  if ! echo "$OUT" | grep -q "churn_$i"; then
    OK=false; CYCLE_FAIL="exec $i: $OUT"; break
  fi
  $LUMINA session stop "$SID" >/dev/null 2>&1
done
$OK && pass "S3.1 $CYCLES session start/exec/stop cycles" || fail "S3.1 session churn" "$CYCLE_FAIL"

# ───────────────────────────────────────────────────────────────
section "S4. MANY SEQUENTIAL EXECS ON ONE SESSION (stateless survival)"
# ───────────────────────────────────────────────────────────────
# Note: the session IPC socket is single-client, so true host-level concurrency
# requires the library API (already covered by swift integration tests). This
# stress just hammers sequential execs fast and checks the session stays healthy.
cleanup_all
SID=$($LUMINA session start 2>/dev/null | jq -r '.sid')
FAILS=0
for i in $(seq 1 50); do
  OUT=$($LUMINA exec "$SID" "echo burst_$i" 2>/dev/null)
  echo "$OUT" | jq -e ".stdout | test(\"burst_$i\")" >/dev/null 2>&1 || FAILS=$((FAILS + 1))
done
$LUMINA session stop "$SID" >/dev/null 2>&1
if [ "$FAILS" = "0" ]; then
  pass "S4.1 50 sequential execs all returned correct output"
else
  fail "S4.1 sequential exec burst" "$FAILS/50 failed"
fi

# ───────────────────────────────────────────────────────────────
section "S5. SUSTAINED SESSION — 3 min of periodic execs"
# ───────────────────────────────────────────────────────────────
cleanup_all
SID=$($LUMINA session start 2>/dev/null | jq -r '.sid')
END=$(( $(date +%s) + 180 ))
COUNT=0
FAILS=0
while [ "$(date +%s)" -lt "$END" ]; do
  COUNT=$((COUNT + 1))
  OUT=$($LUMINA exec "$SID" "date +%s && echo ping_$COUNT" 2>/dev/null)
  if ! echo "$OUT" | grep -q "ping_$COUNT"; then
    FAILS=$((FAILS + 1))
  fi
  sleep 1
done
# Check the session is still alive and responsive
FINAL=$($LUMINA exec "$SID" "echo final_ok" 2>/dev/null)
$LUMINA session stop "$SID" >/dev/null 2>&1
if [ "$FAILS" = "0" ] && echo "$FINAL" | grep -q "final_ok"; then
  pass "S5.1 session survived $COUNT execs over 3 min"
else
  fail "S5.1 session survival" "$FAILS/$COUNT execs failed, final=$FINAL"
fi

# ───────────────────────────────────────────────────────────────
section "S6. PORT FORWARD — lifecycle churn (start+probe+stop x5)"
# ───────────────────────────────────────────────────────────────
# Don't rerun the full nc bytes-through-forward flow here — e2e 17.1 covers
# that already. Stress instead the repeated lifecycle: start a session with
# --forward, confirm the host listener appears, stop, confirm it's gone.
cleanup_all
OK=0
for i in 1 2 3 4 5; do
  HOST_PORT=$((34400 + i))
  SID=$($LUMINA session start --forward "${HOST_PORT}:3000" 2>/dev/null | jq -r '.sid')
  [ -z "$SID" ] || [ "$SID" = "null" ] && continue
  # The listener should be up immediately.
  UP="no"
  for a in 1 2 3; do
    nc -z -w 1 127.0.0.1 $HOST_PORT 2>/dev/null && UP="yes" && break
    sleep 1
  done
  $LUMINA session stop "$SID" >/dev/null 2>&1
  sleep 2
  DOWN="no"
  nc -z -w 1 127.0.0.1 $HOST_PORT 2>/dev/null || DOWN="yes"
  if [ "$UP" = "yes" ] && [ "$DOWN" = "yes" ]; then
    OK=$((OK + 1))
  fi
done
if [ "$OK" = "5" ]; then
  pass "S6.1 5 --forward start/stop cycles — listener up + down each time"
else
  fail "S6.1 port forward lifecycle" "only $OK/5 cycles clean"
fi

# ───────────────────────────────────────────────────────────────
# RESULTS
# ───────────────────────────────────────────────────────────────
echo
echo "═══════════════════════════════════════════════"
echo "  STRESS PASS: $PASS   FAIL: $FAIL"
echo "═══════════════════════════════════════════════"
if [ "$FAIL" -gt 0 ]; then
  echo
  echo "Failures:"
  for f in "${FAILURES[@]}"; do
    echo "  - $f"
  done
  exit 1
fi
exit 0
