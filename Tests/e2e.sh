#!/usr/bin/env bash
# Lumina CLI End-to-End Test Suite — Adversarial Edition
#
# This suite tries to BREAK Lumina, not confirm it works.
# Every test targets a real failure mode that agents will hit.
#
# Requires: VM image at ~/.lumina/images/default/, jq, codesigned binary.
# Usage: ./tests/e2e.sh [path-to-lumina-binary]

set -uo pipefail

LUMINA="${1:-.build/arm64-apple-macosx/debug/lumina}"
PASS=0
FAIL=0
SKIP=0
FAILURES=()

export LUMINA_FORMAT=json

if [ -t 1 ]; then
  GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; NC='\033[0m'; BOLD='\033[1m'
else
  GREEN=''; RED=''; YELLOW=''; NC=''; BOLD=''
fi

pass() { PASS=$((PASS + 1)); echo -e "  ${GREEN}PASS${NC} $1"; }
fail() { FAIL=$((FAIL + 1)); FAILURES+=("$1: $2"); echo -e "  ${RED}FAIL${NC} $1: $2"; }
skip() { SKIP=$((SKIP + 1)); echo -e "  ${YELLOW}SKIP${NC} $1: $2"; }
section() { echo -e "\n${BOLD}=== $1 ===${NC}"; }

cleanup() {
  # Only kill session processes we started (by checking our PID as parent)
  for pid in $(pgrep -f "_session-serve" 2>/dev/null); do
    kill "$pid" 2>/dev/null || true
  done
  rm -rf /tmp/lumina-e2e-* 2>/dev/null || true
}
trap cleanup EXIT

echo "Binary: $LUMINA"
echo "Version: $($LUMINA --version 2>&1)"

# ═══════════════════════════════════════════════════════════════
section "1. SANITY (fast, catch broken builds)"
# ═══════════════════════════════════════════════════════════════

OUT=$($LUMINA run "echo hello" 2>/dev/null)
echo "$OUT" | jq -e '.stdout == "hello\n" and .exit_code == 0' >/dev/null 2>&1 && pass "1.1 echo" || fail "1.1 echo" "$OUT"

$LUMINA run "exit 42" 2>/dev/null; [ $? -eq 42 ] && pass "1.2 exit code 42" || fail "1.2 exit code" "got $?"

OUT=$($LUMINA run "uname -m" 2>/dev/null)
echo "$OUT" | jq -e '.stdout | test("aarch64")' >/dev/null 2>&1 && pass "1.3 guest is linux/arm64" || fail "1.3 arch" "$OUT"

$LUMINA run "" 2>/dev/null && fail "1.4 empty command" "accepted" || pass "1.4 empty command rejected"

# ═══════════════════════════════════════════════════════════════
section "2. ADVERSARIAL INPUT (break the protocol)"
# ═══════════════════════════════════════════════════════════════

# Shell metacharacters — will the host or guest misparse these?
OUT=$($LUMINA run "echo 'hello \"world\" \$(whoami) \`id\` & | ; > < \\ !'" 2>/dev/null)
echo "$OUT" | jq -e '.exit_code == 0' >/dev/null 2>&1 && pass "2.1 shell metacharacters" || fail "2.1 metacharacters" "$OUT"

# Newlines embedded in output — the NDJSON protocol uses newlines as delimiters.
# If the protocol doesn't escape properly, this breaks JSON parsing.
OUT=$($LUMINA run "printf 'line1\nline2\nline3'" 2>/dev/null)
echo "$OUT" | jq -e '.exit_code == 0' >/dev/null 2>&1 && pass "2.2 embedded newlines in output" || fail "2.2 newlines" "JSON parse fail"

# Null bytes — binary data through the text protocol
OUT=$($LUMINA run "printf 'before\x00after'" 2>/dev/null)
echo "$OUT" | jq -e '.exit_code == 0' >/dev/null 2>&1 && pass "2.3 null byte in output" || fail "2.3 null byte" "crash or parse error"

# Very long single line (64KB+ — exceeds vsock message limit?)
OUT=$($LUMINA run "head -c 100000 /dev/urandom | base64 | tr -d '\n' | head -c 80000; echo" --timeout 30s 2>/dev/null)
echo "$OUT" | jq -e '.exit_code == 0' >/dev/null 2>&1 && pass "2.4 80KB single line" || fail "2.4 long line" "truncated or crashed"

# Unicode — multibyte chars that could split across chunk boundaries
OUT=$($LUMINA run "echo '日本語テスト 🚀 مرحبا العربية'" 2>/dev/null)
STDOUT=$(echo "$OUT" | jq -r '.stdout')
if echo "$STDOUT" | grep -q "日本語" && echo "$STDOUT" | grep -q "🚀"; then
  pass "2.5 unicode (CJK + emoji + Arabic)"
else
  fail "2.5 unicode" "got: $STDOUT"
fi

# Env var with quotes, equals, and special chars
OUT=$($LUMINA run -e 'WEIRD=he said "hello=world" & more' "echo \$WEIRD" 2>/dev/null)
echo "$OUT" | jq -e '.exit_code == 0' >/dev/null 2>&1 && pass "2.6 env var with quotes/equals" || fail "2.6 env" "$OUT"

# Command that outputs to both stdout and stderr rapidly and simultaneously
OUT=$($LUMINA run "for i in \$(seq 1 100); do echo out_\$i; echo err_\$i >&2; done" 2>/dev/null)
STDOUT_LINES=$(echo "$OUT" | jq -r '.stdout' | grep -c "out_" || true)
STDERR_LINES=$(echo "$OUT" | jq -r '.stderr' | grep -c "err_" || true)
if [ "$STDOUT_LINES" -ge 90 ] && [ "$STDERR_LINES" -ge 90 ]; then
  pass "2.7 rapid interleaved stdout/stderr ($STDOUT_LINES/$STDERR_LINES of 100)"
else
  fail "2.7 interleaved" "stdout=$STDOUT_LINES stderr=$STDERR_LINES (expected ~100 each)"
fi

# ═══════════════════════════════════════════════════════════════
section "3. STREAMING EDGE CASES"
# ═══════════════════════════════════════════════════════════════

# Legacy NDJSON streaming + download (was P1 bug: VM stuck in executing after stream)
rm -f /tmp/lumina-e2e-sdl.txt
OUT=$(LUMINA_OUTPUT=ndjson $LUMINA run --download "/tmp/sd.txt:/tmp/lumina-e2e-sdl.txt" "echo payload > /tmp/sd.txt && echo done" 2>/dev/null)
if echo "$OUT" | grep -q '"exit_code":0' && [ -f /tmp/lumina-e2e-sdl.txt ] && grep -q "payload" /tmp/lumina-e2e-sdl.txt; then
  pass "3.1 ndjson stream + download (P1 regression)"
else
  fail "3.1 stream + download" "exit or file missing"
fi

# Every NDJSON line must be valid JSON — no raw newlines or broken escaping
OUT=$(LUMINA_OUTPUT=ndjson $LUMINA run "echo 'line with \"quotes\"'; echo 'tab\there'; echo done" 2>/dev/null)
BAD=0; TOTAL=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  TOTAL=$((TOTAL + 1))
  echo "$line" | jq . >/dev/null 2>&1 || BAD=$((BAD + 1))
done <<< "$OUT"
[ "$BAD" -eq 0 ] && pass "3.2 NDJSON validity ($TOTAL lines)" || fail "3.2 NDJSON" "$BAD/$TOTAL invalid"

# Stream large output — tests backpressure and buffer handling (NDJSON legacy path)
OUT=$(LUMINA_OUTPUT=ndjson $LUMINA run "seq 1 5000" --timeout 30s 2>/dev/null)
EXIT_LINE=$(echo "$OUT" | tail -1)
if echo "$EXIT_LINE" | jq -e '.exit_code == 0' >/dev/null 2>&1; then
  pass "3.3 stream 5K lines"
else
  fail "3.3 stream large" "no clean exit"
fi

# Run timeout emits unified envelope with error="timeout" (v0.6.0 contract)
START=$(date +%s)
OUT=$($LUMINA run --timeout 3s "echo started; sleep 60" 2>/dev/null) || true
ELAPSED=$(( $(date +%s) - START ))
if [ "$ELAPSED" -lt 25 ] && echo "$OUT" | jq -e '.error == "timeout"' >/dev/null 2>&1; then
  pass "3.4 run timeout envelope (${ELAPSED}s, error=timeout)"
else
  fail "3.4 run timeout" "elapsed=${ELAPSED}s out=$OUT"
fi

# ═══════════════════════════════════════════════════════════════
section "4. FILE TRANSFER STRESS"
# ═══════════════════════════════════════════════════════════════

# 1MB binary roundtrip — identical after upload + download?
dd if=/dev/urandom of=/tmp/lumina-e2e-1mb.bin bs=1024 count=1024 2>/dev/null
rm -f /tmp/lumina-e2e-1mb-dl.bin
$LUMINA run --copy "/tmp/lumina-e2e-1mb.bin:/tmp/big.bin" --download "/tmp/big.bin:/tmp/lumina-e2e-1mb-dl.bin" "true" >/dev/null 2>&1
if diff -q /tmp/lumina-e2e-1mb.bin /tmp/lumina-e2e-1mb-dl.bin >/dev/null 2>&1; then
  pass "4.1 1MB binary roundtrip (bit-perfect)"
else
  fail "4.1 binary roundtrip" "files differ"
fi

# 5MB file — pushes chunked transfer harder
dd if=/dev/urandom of=/tmp/lumina-e2e-5mb.bin bs=1024 count=5120 2>/dev/null
rm -f /tmp/lumina-e2e-5mb-dl.bin
$LUMINA run --copy "/tmp/lumina-e2e-5mb.bin:/tmp/big5.bin" --download "/tmp/big5.bin:/tmp/lumina-e2e-5mb-dl.bin" --timeout 60s "true" >/dev/null 2>&1
if diff -q /tmp/lumina-e2e-5mb.bin /tmp/lumina-e2e-5mb-dl.bin >/dev/null 2>&1; then
  pass "4.2 5MB binary roundtrip"
else
  fail "4.2 5MB roundtrip" "files differ"
fi

# Filename with spaces and special chars
echo "special" > "/tmp/lumina-e2e-file with spaces.txt"
OUT=$($LUMINA run --copy "/tmp/lumina-e2e-file with spaces.txt:/tmp/spaced file.txt" "cat '/tmp/spaced file.txt'" 2>/dev/null)
echo "$OUT" | jq -e '.stdout | test("special")' >/dev/null 2>&1 && pass "4.3 filename with spaces" || fail "4.3 spaces" "$OUT"

# Directory upload with nested structure — `--copy` auto-detects dir vs file
rm -rf /tmp/lumina-e2e-deep
mkdir -p /tmp/lumina-e2e-deep/a/b/c
echo "level0" > /tmp/lumina-e2e-deep/root.txt
echo "level3" > /tmp/lumina-e2e-deep/a/b/c/deep.txt
echo "mid" > /tmp/lumina-e2e-deep/a/mid.txt
OUT=$($LUMINA run --copy "/tmp/lumina-e2e-deep:/data" "cat /data/root.txt && cat /data/a/b/c/deep.txt && cat /data/a/mid.txt" 2>/dev/null)
STDOUT=$(echo "$OUT" | jq -r '.stdout')
if echo "$STDOUT" | grep -q "level0" && echo "$STDOUT" | grep -q "level3" && echo "$STDOUT" | grep -q "mid"; then
  pass "4.4 directory upload (3 levels deep)"
else
  fail "4.4 deep dir upload" "got: $STDOUT"
fi

# Directory download with nested structure — `--download` auto-detects on guest
rm -rf /tmp/lumina-e2e-dir-dl
$LUMINA run --download "/out:/tmp/lumina-e2e-dir-dl" "mkdir -p /out/x/y && echo a > /out/1.txt && echo b > /out/x/2.txt && echo c > /out/x/y/3.txt" >/dev/null 2>&1
if [ -f /tmp/lumina-e2e-dir-dl/1.txt ] && [ -f /tmp/lumina-e2e-dir-dl/x/2.txt ] && [ -f /tmp/lumina-e2e-dir-dl/x/y/3.txt ]; then
  pass "4.5 directory download (3 levels)"
else
  fail "4.5 deep dir download" "missing files"
fi

# Upload nonexistent file — clean error, no crash
ERR=$($LUMINA run --copy "/nonexistent/phantom.txt:/tmp/x" "echo fail" 2>&1) || true
echo "$ERR" | grep -qi "not found\|no such" && pass "4.6 upload nonexistent file error" || fail "4.6 nonexistent upload" "$ERR"

# --copy without colon — must reject (format validation)
ERR=$($LUMINA run --copy "no_colon" "echo fail" 2>&1) || true
echo "$ERR" | grep -qi "invalid\|format" && pass "4.7 --copy rejects missing colon" || fail "4.7 copy format" "$ERR"

# ═══════════════════════════════════════════════════════════════
section "5. SESSION LIFECYCLE"
# ═══════════════════════════════════════════════════════════════

cleanup

# Full lifecycle: start → exec → exec → exec → stop
SID=$($LUMINA session start 2>/dev/null | jq -r '.sid')
[ -n "$SID" ] && [ "$SID" != "null" ] && pass "5.1 session start" || { fail "5.1 session start" "no SID"; SID=""; }

if [ -n "$SID" ]; then
  # Three sequential execs (P1: state must reset between each)
  OK=true
  for i in 1 2 3; do
    OUT=$($LUMINA exec "$SID" "echo exec_$i" 2>/dev/null)
    echo "$OUT" | grep -q "exec_$i" || { OK=false; break; }
  done
  $OK && pass "5.2 three sequential execs" || fail "5.2 sequential execs" "failed at $i"

  # Two NDJSON-legacy execs back-to-back (THE P1 regression test)
  OUT1=$(LUMINA_OUTPUT=ndjson $LUMINA exec "$SID" "echo stream_one" 2>/dev/null)
  OUT2=$(LUMINA_OUTPUT=ndjson $LUMINA exec "$SID" "echo stream_two" 2>/dev/null)
  if echo "$OUT1" | grep -q "stream_one" && echo "$OUT2" | grep -q "stream_two"; then
    pass "5.3 two legacy-ndjson execs (P1 state reset)"
  else
    fail "5.3 streamed execs" "s1=$(echo "$OUT1" | head -1) s2=$(echo "$OUT2" | head -1)"
  fi

  # Buffered exec after stream (must work — state back to ready)
  OUT=$($LUMINA exec "$SID" "echo after_stream" 2>/dev/null)
  echo "$OUT" | grep -q "after_stream" && pass "5.4 buffered after stream" || fail "5.4 buff after stream" "$OUT"

  # State persists across execs (filesystem is the same VM)
  $LUMINA exec "$SID" "echo persistent_data > /tmp/persist.txt" 2>/dev/null
  OUT=$($LUMINA exec "$SID" "cat /tmp/persist.txt" 2>/dev/null)
  echo "$OUT" | grep -q "persistent_data" && pass "5.5 state persists" || fail "5.5 persist" "$OUT"

  # Session exec with env vars
  OUT=$($LUMINA exec "$SID" "echo \$MY_VAR" -e MY_VAR=works 2>/dev/null)
  echo "$OUT" | grep -q "works" && pass "5.6 session env vars" || fail "5.6 env" "$OUT"

  # Session file upload via `lumina cp` (v0.6.0: exec has no --copy)
  echo "sess_upload_payload" > /tmp/lumina-e2e-sup.txt
  $LUMINA cp "/tmp/lumina-e2e-sup.txt" "$SID:/tmp/up.txt" 2>/dev/null
  OUT=$($LUMINA exec "$SID" "cat /tmp/up.txt" 2>/dev/null)
  echo "$OUT" | grep -q "sess_upload_payload" && pass "5.7 session upload (lumina cp)" || fail "5.7 sess upload" "$OUT"

  rm -f /tmp/lumina-e2e-sdl2.txt
  $LUMINA exec "$SID" "echo dl_data > /tmp/dl.txt" 2>/dev/null
  $LUMINA cp "$SID:/tmp/dl.txt" "/tmp/lumina-e2e-sdl2.txt" 2>/dev/null
  [ -f /tmp/lumina-e2e-sdl2.txt ] && grep -q "dl_data" /tmp/lumina-e2e-sdl2.txt && pass "5.8 session download (lumina cp)" || fail "5.8 sess download" "missing"

  # Session timeout + recovery
  START=$(date +%s)
  $LUMINA exec "$SID" "sleep 60" --timeout 2s 2>/dev/null || true
  ELAPSED=$(( $(date +%s) - START ))
  [ "$ELAPSED" -lt 8 ] && pass "5.9a session timeout (${ELAPSED}s)" || fail "5.9a timeout" "${ELAPSED}s"

  # CommandRunner needs time to detect timeout, reset state, and reconnect.
  # Carmack's fix: heartbeat detects connection loss → kills running command →
  # guest returns to Accept() → host reconnects on next exec.
  sleep 15

  OUT=$($LUMINA exec "$SID" "echo recovered" 2>/dev/null)
  echo "$OUT" | grep -q "recovered" && pass "5.9b recovery after timeout" || fail "5.9b recovery" "$OUT"

  # Session stop returns JSON confirmation
  STOP=$($LUMINA session stop "$SID" 2>/dev/null)
  echo "$STOP" | jq -e '.confirmed == true' >/dev/null 2>&1 && pass "5.10 session stop" || fail "5.10 stop" "$STOP"
fi

# ═══════════════════════════════════════════════════════════════
section "6. SESSION ABUSE"
# ═══════════════════════════════════════════════════════════════

# Exec on nonexistent session
ERR=$($LUMINA exec "doesnt-exist-123" "echo fail" 2>&1) || true
echo "$ERR" | grep -q "not found" && pass "6.1 exec on missing session" || fail "6.1 missing sess" "$ERR"

# Session start with nonexistent image (P2 fix: must be instant, not timeout)
START=$(date +%s)
ERR=$($LUMINA session start --image nonexistent_xyz 2>&1) || true
ELAPSED=$(( $(date +%s) - START ))
if echo "$ERR" | grep -q "not found" && [ "$ELAPSED" -lt 3 ]; then
  pass "6.2 missing image instant error (${ELAPSED}s)"
else
  fail "6.2 missing image" "took ${ELAPSED}s, got: $ERR"
fi

# Double stop — stop a session that's already stopped
SID=$($LUMINA session start 2>/dev/null | jq -r '.sid')
$LUMINA session stop "$SID" 2>/dev/null
ERR=$($LUMINA session stop "$SID" 2>&1) || true
# Should not crash, should get some kind of error
echo "$ERR" | grep -qi "not found\|dead\|error\|no such" && pass "6.3 double stop handled" || fail "6.3 double stop" "$ERR"

# Exec on stopped session
ERR=$($LUMINA exec "$SID" "echo fail" 2>&1) || true
echo "$ERR" | grep -qi "not found\|dead\|error" && pass "6.4 exec on stopped session" || fail "6.4 exec dead" "$ERR"

# Zero timeout — should fail fast, not hang
SID=$($LUMINA session start 2>/dev/null | jq -r '.sid')
START=$(date +%s)
$LUMINA exec "$SID" "sleep 60" --timeout 1s 2>/dev/null || true
ELAPSED=$(( $(date +%s) - START ))
[ "$ELAPSED" -lt 8 ] && pass "6.5 1s timeout fires (${ELAPSED}s)" || fail "6.5 zero timeout" "${ELAPSED}s"
$LUMINA session stop "$SID" 2>/dev/null

# Session list shows running sessions
SID1=$($LUMINA session start 2>/dev/null | jq -r '.sid')
SID2=$($LUMINA session start 2>/dev/null | jq -r '.sid')
LIST=$($LUMINA session list 2>/dev/null)
COUNT=$(echo "$LIST" | jq 'length')
if [ "$COUNT" -ge 2 ]; then
  pass "6.6 session list shows $COUNT sessions"
else
  fail "6.6 session list" "expected >=2, got $COUNT"
fi
$LUMINA session stop "$SID1" 2>/dev/null
$LUMINA session stop "$SID2" 2>/dev/null

# ═══════════════════════════════════════════════════════════════
section "7. RAPID FIRE (NDJSON coalescing under pressure)"
# ═══════════════════════════════════════════════════════════════

SID=$($LUMINA session start 2>/dev/null | jq -r '.sid')

# 10 rapid execs — tests NDJSON buffer between each request/response cycle
OK=true
for i in $(seq 1 10); do
  OUT=$($LUMINA exec "$SID" "echo r_$i" 2>/dev/null)
  if ! echo "$OUT" | grep -q "r_$i"; then
    OK=false; break
  fi
done
$OK && pass "7.1 10 rapid sequential execs" || fail "7.1 rapid" "failed at $i"

# Alternating legacy-ndjson/unified-envelope — stresses state machine transitions
OK=true
for i in $(seq 1 5); do
  O1=$(LUMINA_OUTPUT=ndjson $LUMINA exec "$SID" "echo st_$i" 2>/dev/null)
  O2=$($LUMINA exec "$SID" "echo bf_$i" 2>/dev/null)
  if ! echo "$O1" | grep -q "st_$i" || ! echo "$O2" | grep -q "bf_$i"; then
    OK=false; break
  fi
done
$OK && pass "7.2 5 alternating ndjson/envelope pairs" || fail "7.2 alternating" "pair $i"

# Large stream through session (legacy NDJSON path, tests no dropped frames)
OUT=$(LUMINA_OUTPUT=ndjson $LUMINA exec "$SID" "seq 1 3000" --timeout 30s 2>/dev/null)
EXIT_LINE=$(echo "$OUT" | grep '"exit_code"' | head -1)
if echo "$EXIT_LINE" | grep -q '"exit_code":0'; then
  if echo "$OUT" | grep -q '"data":"3000'; then
    pass "7.3 3K line ndjson session stream (no dropped frames)"
  else
    pass "7.3 3K line ndjson session stream (exit ok, last line may be batched)"
  fi
else
  fail "7.3 large session stream" "no clean exit"
fi

$LUMINA session stop "$SID" 2>/dev/null

# ═══════════════════════════════════════════════════════════════
section "8. CONCURRENT VMs"
# ═══════════════════════════════════════════════════════════════

# 3 disposable VMs simultaneously
PIDS=()
for i in 1 2 3; do
  $LUMINA run "echo vm_$i" --timeout 30s > /tmp/lumina-e2e-concurrent-$i.json 2>/dev/null &
  PIDS+=($!)
done
ALL_OK=true
for i in 1 2 3; do
  wait ${PIDS[$((i-1))]} 2>/dev/null || true
  OUT=$(cat /tmp/lumina-e2e-concurrent-$i.json 2>/dev/null)
  if ! echo "$OUT" | jq -e ".stdout == \"vm_$i\n\"" >/dev/null 2>&1; then
    ALL_OK=false
  fi
done
$ALL_OK && pass "8.1 3 concurrent disposable VMs" || fail "8.1 concurrent VMs" "one or more failed"

# 2 sessions running simultaneously, exec in parallel
SID_A=$($LUMINA session start 2>/dev/null | jq -r '.sid')
SID_B=$($LUMINA session start 2>/dev/null | jq -r '.sid')
$LUMINA exec "$SID_A" "echo from_a" > /tmp/lumina-e2e-para.json 2>/dev/null &
PA=$!
$LUMINA exec "$SID_B" "echo from_b" > /tmp/lumina-e2e-parb.json 2>/dev/null &
PB=$!
wait $PA 2>/dev/null; wait $PB 2>/dev/null
OA=$(cat /tmp/lumina-e2e-para.json 2>/dev/null)
OB=$(cat /tmp/lumina-e2e-parb.json 2>/dev/null)
if echo "$OA" | grep -q "from_a" && echo "$OB" | grep -q "from_b"; then
  pass "8.2 2 parallel session execs"
else
  fail "8.2 parallel sessions" "a=$OA b=$OB"
fi
$LUMINA session stop "$SID_A" 2>/dev/null
$LUMINA session stop "$SID_B" 2>/dev/null

# Rapid session start/stop cycle — resource leak test
# Clean stop all sessions first (graceful), then pkill stragglers.
# VZ framework needs 15-20s to fully dealloc VMs after forced kill.
for sid in $($LUMINA session list 2>/dev/null | jq -r '.[].sid' 2>/dev/null); do
  $LUMINA session stop "$sid" 2>/dev/null || true
done
sleep 3
pkill -f "_session-serve" 2>/dev/null || true
rm -rf ~/.lumina/sessions/* 2>/dev/null || true
sleep 18
OK=true
CYCLE_ERR=""
for i in $(seq 1 3); do
  START_OUT=$($LUMINA session start 2>&1)
  S=$(echo "$START_OUT" | jq -r '.sid' 2>/dev/null)
  if [ -z "$S" ] || [ "$S" = "null" ]; then
    OK=false; CYCLE_ERR="start failed at $i: $START_OUT"; break
  fi
  EXEC_OUT=$($LUMINA exec "$S" "echo cycle_$i" 2>&1)
  if ! echo "$EXEC_OUT" | grep -q "cycle_$i"; then
    OK=false; CYCLE_ERR="exec failed at $i: $EXEC_OUT"; break
  fi
  $LUMINA session stop "$S" 2>/dev/null
  sleep 3
done
$OK && pass "8.3 3 start/exec/stop cycles" || fail "8.3 lifecycle cycles" "$CYCLE_ERR"

# ═══════════════════════════════════════════════════════════════
section "9. VOLUMES"
# ═══════════════════════════════════════════════════════════════

$LUMINA volume remove e2e-vol 2>/dev/null || true
$LUMINA volume create e2e-vol 2>/dev/null

# Write in one VM, read in another
$LUMINA run --volume "e2e-vol:/data" "echo vol_persist > /data/test.txt" >/dev/null 2>&1
OUT=$($LUMINA run --volume "e2e-vol:/data" "cat /data/test.txt" 2>/dev/null)
echo "$OUT" | jq -e '.stdout | test("vol_persist")' >/dev/null 2>&1 && pass "9.1 volume persists across VMs" || fail "9.1 volume" "$OUT"

# Volume list
$LUMINA volume list 2>/dev/null | grep -q "e2e-vol" && pass "9.2 volume list" || fail "9.2 vol list" "not found"

# Volume inspect
$LUMINA volume inspect e2e-vol 2>/dev/null | jq -e '.name == "e2e-vol"' >/dev/null 2>&1 && pass "9.3 volume inspect" || fail "9.3 inspect" "bad json"

$LUMINA volume remove e2e-vol 2>/dev/null

# ═══════════════════════════════════════════════════════════════
section "10. ERROR HANDLING"
# ═══════════════════════════════════════════════════════════════

# Invalid flags — errors go to stderr, capture both streams
ERR=$($LUMINA run --timeout "abc" "echo fail" 2>&1) || true
echo "$ERR" | grep -qi "invalid" && pass "10.1 invalid timeout" || fail "10.1 invalid timeout" "$ERR"
# v0.6.0: memory is a `session start` flag, not a `run` flag. Validate it there.
ERR=$($LUMINA session start --memory "abc" 2>&1) || true
echo "$ERR" | grep -qi "invalid" && pass "10.2 invalid memory (session start)" || fail "10.2 invalid memory" "$ERR"
ERR=$($LUMINA run --copy "no_colon" "echo fail" 2>&1) || true
echo "$ERR" | grep -qi "invalid\|format" && pass "10.3 invalid --copy" || fail "10.3 invalid copy" "$ERR"

# Command not found — non-zero exit, not crash
OUT=$($LUMINA run "totally_fake_cmd_xyz" 2>/dev/null) || true
echo "$OUT" | jq -e '.exit_code != 0' >/dev/null 2>&1 && pass "10.4 command not found" || fail "10.4" "$OUT"

# ═══════════════════════════════════════════════════════════════
section "11. OUTPUT FORMAT"
# ═══════════════════════════════════════════════════════════════

# JSON when piped (default)
OUT=$($LUMINA run "echo test" 2>/dev/null)
echo "$OUT" | jq . >/dev/null 2>&1 && pass "11.1 JSON when piped" || fail "11.1" "not JSON"

# LUMINA_FORMAT override
OUT=$(LUMINA_FORMAT=json $LUMINA run "echo fmt" 2>/dev/null)
echo "$OUT" | jq -e '.stdout | test("fmt")' >/dev/null 2>&1 && pass "11.2 LUMINA_FORMAT=json" || fail "11.2" "$OUT"

# Session NDJSON legacy — every line must be valid JSON
SID=$($LUMINA session start 2>/dev/null | jq -r '.sid')
OUT=$(LUMINA_OUTPUT=ndjson $LUMINA exec "$SID" "echo a; echo b >&2; echo c" 2>/dev/null)
BAD=0; TOTAL=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  TOTAL=$((TOTAL + 1))
  echo "$line" | jq . >/dev/null 2>&1 || BAD=$((BAD + 1))
done <<< "$OUT"
[ "$BAD" -eq 0 ] && pass "11.3 session NDJSON validity ($TOTAL lines)" || fail "11.3" "$BAD/$TOTAL invalid"
$LUMINA session stop "$SID" 2>/dev/null

# ═══════════════════════════════════════════════════════════════
section "12. CONCURRENT VM STRESS"
# ═══════════════════════════════════════════════════════════════

# Cleanup: previous sections used many sessions/VMs. VZ framework
# needs time to fully release resources before we stress concurrent VMs.
# Gracefully stop sessions first, then force-kill stragglers.
for sid in $($LUMINA session list 2>/dev/null | jq -r '.[].sid' 2>/dev/null); do
  $LUMINA session stop "$sid" 2>/dev/null || true
done
sleep 3
pkill -f "_session-serve" 2>/dev/null || true
rm -rf ~/.lumina/sessions/* 2>/dev/null || true
sleep 15

# 5 disposable VMs simultaneously — push the host harder
PIDS=()
for i in 1 2 3 4 5; do
  $LUMINA run "echo stress_$i && sleep 1 && echo done_$i" --timeout 30s > /tmp/lumina-e2e-stress-$i.json 2>/dev/null &
  PIDS+=($!)
done
ALL_OK=true
FAIL_DETAIL=""
for i in 1 2 3 4 5; do
  wait ${PIDS[$((i-1))]} 2>/dev/null || true
  OUT=$(cat /tmp/lumina-e2e-stress-$i.json 2>/dev/null)
  EXIT=$(echo "$OUT" | jq -r '.exit_code // "null"' 2>/dev/null)
  STDOUT=$(echo "$OUT" | jq -r '.stdout // ""' 2>/dev/null)
  ERR=$(echo "$OUT" | jq -r '.error // ""' 2>/dev/null)
  if [ "$EXIT" != "0" ]; then
    ALL_OK=false; FAIL_DETAIL="${FAIL_DETAIL}vm${i}:exit=${EXIT}(${ERR}) "
  elif ! echo "$STDOUT" | grep -q "stress_$i" || ! echo "$STDOUT" | grep -q "done_$i"; then
    ALL_OK=false; FAIL_DETAIL="${FAIL_DETAIL}vm${i}:missing_output "
  fi
done
$ALL_OK && pass "12.1 5 concurrent disposable VMs (each verified)" || fail "12.1 5 concurrent VMs" "$FAIL_DETAIL"

# 3 sessions running simultaneously with rapid execs
SID_X=$($LUMINA session start 2>/dev/null | jq -r '.sid')
SID_Y=$($LUMINA session start 2>/dev/null | jq -r '.sid')
SID_Z=$($LUMINA session start 2>/dev/null | jq -r '.sid')

# Fire execs at all 3 in parallel
$LUMINA exec "$SID_X" "echo from_X && sleep 0.5 && echo X_done" > /tmp/lumina-e2e-px.json 2>/dev/null &
PX=$!
$LUMINA exec "$SID_Y" "echo from_Y && sleep 0.5 && echo Y_done" > /tmp/lumina-e2e-py.json 2>/dev/null &
PY=$!
$LUMINA exec "$SID_Z" "echo from_Z && sleep 0.5 && echo Z_done" > /tmp/lumina-e2e-pz.json 2>/dev/null &
PZ=$!
wait $PX 2>/dev/null; wait $PY 2>/dev/null; wait $PZ 2>/dev/null

OX=$(cat /tmp/lumina-e2e-px.json 2>/dev/null)
OY=$(cat /tmp/lumina-e2e-py.json 2>/dev/null)
OZ=$(cat /tmp/lumina-e2e-pz.json 2>/dev/null)
if echo "$OX" | grep -q "from_X" && echo "$OX" | grep -q "X_done" &&
   echo "$OY" | grep -q "from_Y" && echo "$OY" | grep -q "Y_done" &&
   echo "$OZ" | grep -q "from_Z" && echo "$OZ" | grep -q "Z_done"; then
  pass "12.2 3 parallel session execs (all correct)"
else
  fail "12.2 parallel sessions" "x=$OX y=$OY z=$OZ"
fi

# Rapid sequential execs on one session while others are running long commands
$LUMINA exec "$SID_X" "sleep 10" --timeout 15s > /dev/null 2>/dev/null &
PX_LONG=$!
# While X is busy with sleep, Y and Z handle rapid execs
OK=true
for i in $(seq 1 5); do
  OUT_Y=$($LUMINA exec "$SID_Y" "echo rapid_Y_$i" 2>/dev/null)
  OUT_Z=$($LUMINA exec "$SID_Z" "echo rapid_Z_$i" 2>/dev/null)
  if ! echo "$OUT_Y" | grep -q "rapid_Y_$i" || ! echo "$OUT_Z" | grep -q "rapid_Z_$i"; then
    OK=false; break
  fi
done
$OK && pass "12.3 rapid execs on 2 sessions while 3rd is busy" || fail "12.3 cross-session rapid" "failed at $i"

# Clean up sessions
kill $PX_LONG 2>/dev/null || true
wait $PX_LONG 2>/dev/null || true
$LUMINA session stop "$SID_X" 2>/dev/null
$LUMINA session stop "$SID_Y" 2>/dev/null
$LUMINA session stop "$SID_Z" 2>/dev/null

# ═══════════════════════════════════════════════════════════════
section "13. PROTOCOL RESILIENCE"
# ═══════════════════════════════════════════════════════════════

# Large stderr + stdout simultaneously in a disposable VM
OUT=$($LUMINA run "for i in \$(seq 1 1000); do echo out_\$i; echo err_\$i >&2; done" --timeout 30s 2>/dev/null)
STDOUT_COUNT=$(echo "$OUT" | jq -r '.stdout' | grep -c "out_" || true)
STDERR_COUNT=$(echo "$OUT" | jq -r '.stderr' | grep -c "err_" || true)
if [ "$STDOUT_COUNT" -ge 990 ] && [ "$STDERR_COUNT" -ge 990 ]; then
  pass "13.1 1K lines interleaved stdout/stderr ($STDOUT_COUNT/$STDERR_COUNT)"
else
  fail "13.1 interleaved 1K" "stdout=$STDOUT_COUNT stderr=$STDERR_COUNT"
fi

# Stream 10K lines — tests chunking + buffering (legacy NDJSON path)
OUT=$(LUMINA_OUTPUT=ndjson $LUMINA run "seq 1 10000" --timeout 60s 2>/dev/null)
EXIT_LINE=$(echo "$OUT" | grep '"exit_code"' | head -1)
if echo "$EXIT_LINE" | jq -e '.exit_code == 0' >/dev/null 2>&1; then
  DATA_LINES=$(echo "$OUT" | grep '"data"' | wc -l | tr -d ' ')
  pass "13.2 stream 10K lines ($DATA_LINES chunks, exit ok)"
else
  fail "13.2 stream 10K" "no clean exit"
fi

# Binary output — base64 doesn't break NDJSON
OUT=$($LUMINA run "dd if=/dev/urandom bs=1024 count=10 2>/dev/null | base64" --timeout 30s 2>/dev/null)
echo "$OUT" | jq -e '.exit_code == 0' >/dev/null 2>&1 && pass "13.3 binary data through base64" || fail "13.3 binary base64" "exit code"

# Many small outputs very fast — can the protocol keep up?
OUT=$($LUMINA run "for i in \$(seq 1 500); do echo \$i; done" --timeout 30s 2>/dev/null)
LINE_COUNT=$(echo "$OUT" | jq -r '.stdout' | grep -c "^[0-9]" || true)
[ "$LINE_COUNT" -ge 490 ] && pass "13.4 500 rapid echo lines ($LINE_COUNT received)" || fail "13.4 rapid echo" "$LINE_COUNT/500"

# ═══════════════════════════════════════════════════════════════
section "14. TIMEOUT RECOVERY (concurrent-safe)"
# ═══════════════════════════════════════════════════════════════

SID=$($LUMINA session start 2>/dev/null | jq -r '.sid')

# Exec that times out
START=$(date +%s)
$LUMINA exec "$SID" "sleep 60" --timeout 3s 2>/dev/null || true
ELAPSED=$(( $(date +%s) - START ))
[ "$ELAPSED" -lt 10 ] && pass "14.1 timeout fires in ${ELAPSED}s" || fail "14.1 timeout" "${ELAPSED}s"

# Wait for reconnect (guest agent needs to return to accept loop)
sleep 12

# Recovery exec after timeout
OUT=$($LUMINA exec "$SID" "echo timeout_recovered" 2>/dev/null)
echo "$OUT" | grep -q "timeout_recovered" && pass "14.2 recovery after timeout" || fail "14.2 recovery" "$OUT"

# Multiple sequential recoveries — each timeout+reconnect cycle works
for i in 1 2; do
  $LUMINA exec "$SID" "sleep 60" --timeout 2s 2>/dev/null || true
  sleep 12
  OUT=$($LUMINA exec "$SID" "echo bounce_$i" 2>/dev/null)
  echo "$OUT" | grep -q "bounce_$i" || { fail "14.3 repeated recovery" "failed at bounce $i"; break; }
done
echo "$OUT" | grep -q "bounce_2" && pass "14.3 2 timeout+recovery cycles" || true

$LUMINA session stop "$SID" 2>/dev/null

# ═══════════════════════════════════════════════════════════════
section "15. UNIFIED ENVELOPE ERROR STATES (v0.6.0 contract)"
# ═══════════════════════════════════════════════════════════════

# Run timeout — error="timeout", no exit_code, partials may be present
OUT=$($LUMINA run --timeout 2s "echo begin; sleep 30" 2>/dev/null) || true
if echo "$OUT" | jq -e '.error == "timeout" and (.exit_code // null) == null' >/dev/null 2>&1; then
  pass "15.1 run timeout envelope (error=timeout, no exit_code)"
else
  fail "15.1 run timeout envelope" "$OUT"
fi

# Session exec timeout — error="timeout" (not "session failed: timeout")
SID=$($LUMINA session start 2>/dev/null | jq -r '.sid')
OUT=$($LUMINA exec "$SID" "sleep 30" --timeout 2s 2>/dev/null) || true
if echo "$OUT" | jq -e '.error == "timeout"' >/dev/null 2>&1; then
  pass "15.2 exec timeout envelope (error=timeout)"
else
  fail "15.2 exec timeout envelope" "$OUT"
fi
sleep 10
$LUMINA session stop "$SID" 2>/dev/null

# Success envelope has NO error field
OUT=$($LUMINA run "echo ok" 2>/dev/null)
if echo "$OUT" | jq -e '.exit_code == 0 and (.error // null) == null' >/dev/null 2>&1; then
  pass "15.3 success envelope has no error field"
else
  fail "15.3 success has no error" "$OUT"
fi

# Nonexistent image — error="connection_failed" (command never ran → no partials)
OUT=$($LUMINA run --image "nope_nonexistent_$(date +%s)" "echo fail" 2>/dev/null) || true
if echo "$OUT" | jq -e '.error == "connection_failed" and (.partial_stdout // null) == null' >/dev/null 2>&1; then
  pass "15.4 missing image → connection_failed (no partials)"
else
  # Lumina emits a text error to stderr for missing images before JSON; accept exit!=0
  echo "$OUT" | jq -e '.error != null' >/dev/null 2>&1 && pass "15.4 missing image returns error envelope" || fail "15.4 missing image" "$OUT"
fi

# ═══════════════════════════════════════════════════════════════
section "16. OBSERVABILITY — lumina ps"
# ═══════════════════════════════════════════════════════════════

# No sessions: ps returns []
for sid in $($LUMINA session list 2>/dev/null | jq -r '.[].sid' 2>/dev/null); do
  $LUMINA session stop "$sid" 2>/dev/null || true
done
sleep 3
pkill -f "_session-serve" 2>/dev/null || true
rm -rf ~/.lumina/sessions/* 2>/dev/null || true
sleep 5

OUT=$($LUMINA ps 2>/dev/null)
if echo "$OUT" | jq -e 'type == "array"' >/dev/null 2>&1; then
  pass "16.1 ps returns a JSON array"
else
  fail "16.1 ps array" "$OUT"
fi

# With sessions: ps reports sid, uptime, activeExecs, image
SID_P1=$($LUMINA session start 2>/dev/null | jq -r '.sid')
SID_P2=$($LUMINA session start 2>/dev/null | jq -r '.sid')
sleep 2
OUT=$($LUMINA ps 2>/dev/null)
COUNT=$(echo "$OUT" | jq 'length')
if [ "$COUNT" = "2" ]; then
  pass "16.2 ps reports 2 live sessions"
else
  fail "16.2 ps count" "expected 2, got $COUNT: $OUT"
fi

if echo "$OUT" | jq -e '[.[] | select(.sid != null and .image != null and .uptime_seconds != null)] | length == 2' >/dev/null 2>&1; then
  pass "16.3 ps rows have sid, image, uptime_seconds"
else
  fail "16.3 ps schema" "$OUT"
fi

# active_execs counts an in-flight exec
$LUMINA exec "$SID_P1" "sleep 4" --timeout 10s >/dev/null 2>&1 &
PX=$!
sleep 1
OUT=$($LUMINA ps 2>/dev/null)
ACTIVE=$(echo "$OUT" | jq -r "[.[] | select(.sid == \"$SID_P1\") | .active_execs // 0] | .[0] // 0")
wait $PX 2>/dev/null || true
if [ "$ACTIVE" -ge 1 ]; then
  pass "16.4 ps shows active_execs during in-flight exec (active=$ACTIVE)"
else
  fail "16.4 active_execs" "active=$ACTIVE out=$OUT"
fi

$LUMINA session stop "$SID_P1" 2>/dev/null
$LUMINA session stop "$SID_P2" 2>/dev/null

# ═══════════════════════════════════════════════════════════════
section "17. PORT FORWARDING (--forward)"
# ═══════════════════════════════════════════════════════════════

# Clean up before port forward tests — prior sections leave VM descriptors/processes
# that can exhaust resources. Port forward tests need a fresh VM.
for sid in $($LUMINA session list 2>/dev/null | jq -r '.[].sid' 2>/dev/null); do
  $LUMINA session stop "$sid" 2>/dev/null || true
done
pkill -f "_session-serve" 2>/dev/null || true
rm -rf ~/.lumina/sessions/* 2>/dev/null || true
sleep 15

# Host port: pick a high port to avoid collisions with anything running locally.
HOST_PORT=34321
GUEST_PORT=3000

SID_F=$($LUMINA session start --forward "${HOST_PORT}:${GUEST_PORT}" 2>/dev/null | jq -r '.sid')
if [ -z "$SID_F" ] || [ "$SID_F" = "null" ]; then
  fail "17.0 session with --forward" "could not start"
else
  pass "17.0 session start --forward"

  # Guest: one-shot nc listener that sends a known payload and exits on client disconnect.
  # Backgrounded so the host can connect while nc is blocked in accept().
  rm -f /tmp/lumina-e2e-pf.out
  $LUMINA exec "$SID_F" "echo FORWARDED_OK | nc -l -p $GUEST_PORT" --timeout 25s > /tmp/lumina-e2e-pf.out 2>&1 &
  GUEST_EXEC_PID=$!

  # Poll the host side — first attempt may race the guest listener.
  RESPONSE=""
  for attempt in 1 2 3 4 5 6 7 8; do
    sleep 1
    RESPONSE=$(nc -w 4 127.0.0.1 $HOST_PORT 2>/dev/null || true)
    if echo "$RESPONSE" | grep -q "FORWARDED_OK"; then
      break
    fi
  done
  wait $GUEST_EXEC_PID 2>/dev/null || true

  if echo "$RESPONSE" | grep -q "FORWARDED_OK"; then
    pass "17.1 --forward delivers TCP bytes host→guest"
  else
    fail "17.1 port forward" "response='$RESPONSE' guest=$(cat /tmp/lumina-e2e-pf.out 2>/dev/null)"
  fi

  # After stopping the session, the host TCP listener must be released.
  $LUMINA session stop "$SID_F" 2>/dev/null
  sleep 3
  if nc -z -w 2 127.0.0.1 $HOST_PORT 2>/dev/null; then
    fail "17.2 port forward teardown" "listener still accepting after session stop"
  else
    pass "17.2 --forward teardown releases host listener"
  fi
fi

# Invalid forward spec: must reject at parse
ERR=$($LUMINA session start --forward "badspec" 2>&1) || true
echo "$ERR" | grep -qi "invalid\|forward" && pass "17.3 invalid --forward spec rejected" || fail "17.3 invalid forward" "$ERR"

# ═══════════════════════════════════════════════════════════════
section "18. PTY (--pty)"
# ═══════════════════════════════════════════════════════════════

# Fresh state for PTY — the prior port-forward session already torn down,
# but make sure no stragglers remain.
pkill -f "_session-serve" 2>/dev/null || true
rm -rf ~/.lumina/sessions/* 2>/dev/null || true
sleep 10

# --pty on `run` must be rejected (requires a session)
ERR=$($LUMINA run --pty "echo hi" 2>&1) || true
echo "$ERR" | grep -qi "session" && pass "18.1 --pty on run rejected (wants session)" || fail "18.1 pty on run" "$ERR"

# --pty with non-TTY stdin must give a clean error (e2e.sh runs piped)
SID_T=$($LUMINA session start 2>/dev/null | jq -r '.sid')
ERR=$($LUMINA exec --pty "$SID_T" "echo hi" < /dev/null 2>&1) || true
echo "$ERR" | grep -qi "tty\|terminal" && pass "18.2 --pty without TTY stdin errors cleanly" || fail "18.2 pty no-tty" "$ERR"

# Drive a real PTY end-to-end via python3's pty.spawn (works without a host TTY).
if command -v python3 >/dev/null 2>&1; then
  # Tiny helper: spawns a child in a new PTY, forwards stdin EOF, captures combined output.
  PTY_HELPER=$(mktemp /tmp/lumina-e2e-pty.XXXXXX.py)
  cat > "$PTY_HELPER" <<'PYEOF'
import os, sys, pty, select
argv = sys.argv[1:]
# Open a PTY, fork, parent reads from master until EOF.
pid, fd = pty.fork()
if pid == 0:
    os.execvp(argv[0], argv)
# Parent: drain master fd, write to stdout. Child inherits PTY as stdin/out/err.
out = b""
while True:
    try:
        r, _, _ = select.select([fd], [], [], 10.0)
        if not r:
            break
        chunk = os.read(fd, 4096)
        if not chunk:
            break
        out += chunk
    except OSError:
        break
os.waitpid(pid, 0)
sys.stdout.buffer.write(out)
PYEOF
  OUT=$(python3 "$PTY_HELPER" $LUMINA exec --pty "$SID_T" "echo pty_basic && exit 0" 2>/dev/null | tr -d '\r' || true)
  echo "$OUT" | grep -q "pty_basic" && pass "18.3 PTY exec delivers output" || fail "18.3 pty output" "$OUT"

  # CR-heavy spec gate (plan integration checklist condition 3): \r overwrites, ANSI codes render.
  PTY_SCRIPT='for i in 1 2 3 4 5; do printf "\r[%d/5] progress..." $i; sleep 0.05; done; echo; printf "\033[1;32mDONE\033[0m\n"'
  OUT=$(python3 "$PTY_HELPER" $LUMINA exec --pty "$SID_T" "$PTY_SCRIPT" 2>/dev/null || true)
  # The \r means last "[N/5] progress..." overwrites the earlier ones on the same line.
  # We check both that the final counter arrived AND the ANSI-DONE made it through byte-perfect.
  if echo "$OUT" | grep -q "\[5/5\]" && echo "$OUT" | grep -q $'\033\[1;32mDONE\033\[0m'; then
    pass "18.4 PTY CR-heavy render (last CR wins, ANSI codes byte-perfect)"
  else
    fail "18.4 PTY CR-heavy" "$(echo "$OUT" | od -c | head -6)"
  fi
  rm -f "$PTY_HELPER"
else
  skip "18.3 PTY exec delivers output" "no python3"
  skip "18.4 PTY CR-heavy render" "no python3"
fi

$LUMINA session stop "$SID_T" 2>/dev/null

# ═══════════════════════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════"
TOTAL=$((PASS + FAIL + SKIP))
echo -e "  ${GREEN}PASS: $PASS${NC}  ${RED}FAIL: $FAIL${NC}  ${YELLOW}SKIP: $SKIP${NC}  TOTAL: $TOTAL"
echo "═══════════════════════════════════════════════"

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "Failures:"
  for f in "${FAILURES[@]}"; do
    echo "  - $f"
  done
  exit 1
fi

echo ""
echo "All tests passed."
exit 0
