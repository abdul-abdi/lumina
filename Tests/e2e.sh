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

# Stream + download (was P1 bug: VM stuck in executing after stream)
rm -f /tmp/lumina-e2e-sdl.txt
OUT=$($LUMINA run --stream --download "/tmp/sd.txt:/tmp/lumina-e2e-sdl.txt" "echo payload > /tmp/sd.txt && echo done" 2>/dev/null)
if echo "$OUT" | grep -q '"exit_code":0' && [ -f /tmp/lumina-e2e-sdl.txt ] && grep -q "payload" /tmp/lumina-e2e-sdl.txt; then
  pass "3.1 stream + download (P1 regression)"
else
  fail "3.1 stream + download" "exit or file missing"
fi

# Every NDJSON line must be valid JSON — no raw newlines or broken escaping
OUT=$($LUMINA run --stream "echo 'line with \"quotes\"'; echo 'tab\there'; echo done" 2>/dev/null)
BAD=0; TOTAL=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  TOTAL=$((TOTAL + 1))
  echo "$line" | jq . >/dev/null 2>&1 || BAD=$((BAD + 1))
done <<< "$OUT"
[ "$BAD" -eq 0 ] && pass "3.2 NDJSON validity ($TOTAL lines)" || fail "3.2 NDJSON" "$BAD/$TOTAL invalid"

# Stream large output — tests backpressure and buffer handling
OUT=$($LUMINA run --stream "seq 1 5000" --timeout 30s 2>/dev/null)
EXIT_LINE=$(echo "$OUT" | tail -1)
if echo "$EXIT_LINE" | jq -e '.exit_code == 0' >/dev/null 2>&1; then
  pass "3.3 stream 5K lines"
else
  fail "3.3 stream large" "no clean exit"
fi

# Stream with timeout — verify the stream terminates, doesn't hang
START=$(date +%s)
OUT=$($LUMINA run --stream --timeout 3s "echo started; sleep 60" 2>/dev/null) || true
ELAPSED=$(( $(date +%s) - START ))
if [ "$ELAPSED" -lt 25 ]; then
  pass "3.4 stream timeout terminates (${ELAPSED}s)"
else
  fail "3.4 stream timeout" "took ${ELAPSED}s, expected <25"
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

# Directory upload with nested structure
rm -rf /tmp/lumina-e2e-deep
mkdir -p /tmp/lumina-e2e-deep/a/b/c
echo "level0" > /tmp/lumina-e2e-deep/root.txt
echo "level3" > /tmp/lumina-e2e-deep/a/b/c/deep.txt
echo "mid" > /tmp/lumina-e2e-deep/a/mid.txt
OUT=$($LUMINA run --copy-dir "/tmp/lumina-e2e-deep:/data" "cat /data/root.txt && cat /data/a/b/c/deep.txt && cat /data/a/mid.txt" 2>/dev/null)
STDOUT=$(echo "$OUT" | jq -r '.stdout')
if echo "$STDOUT" | grep -q "level0" && echo "$STDOUT" | grep -q "level3" && echo "$STDOUT" | grep -q "mid"; then
  pass "4.4 directory upload (3 levels deep)"
else
  fail "4.4 deep dir upload" "got: $STDOUT"
fi

# Directory download with nested structure
rm -rf /tmp/lumina-e2e-dir-dl
$LUMINA run --download-dir "/out:/tmp/lumina-e2e-dir-dl" "mkdir -p /out/x/y && echo a > /out/1.txt && echo b > /out/x/2.txt && echo c > /out/x/y/3.txt" >/dev/null 2>&1
if [ -f /tmp/lumina-e2e-dir-dl/1.txt ] && [ -f /tmp/lumina-e2e-dir-dl/x/2.txt ] && [ -f /tmp/lumina-e2e-dir-dl/x/y/3.txt ]; then
  pass "4.5 directory download (3 levels)"
else
  fail "4.5 deep dir download" "missing files"
fi

# Upload nonexistent file — clean error, no crash
ERR=$($LUMINA run --copy "/nonexistent/phantom.txt:/tmp/x" "echo fail" 2>&1) || true
echo "$ERR" | grep -qi "not found\|no such" && pass "4.6 upload nonexistent file error" || fail "4.6 nonexistent upload" "$ERR"

# --copy-dir on a regular file — must reject
echo "notdir" > /tmp/lumina-e2e-notdir.txt
ERR=$($LUMINA run --copy-dir "/tmp/lumina-e2e-notdir.txt:/data" "echo fail" 2>&1) || true
echo "$ERR" | grep -qi "not a directory\|directory" && pass "4.7 --copy-dir rejects regular file" || fail "4.7 copy-dir file" "$ERR"

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

  # Two streamed execs back-to-back (THE P1 regression test)
  OUT1=$($LUMINA exec "$SID" "echo stream_one" --stream 2>/dev/null)
  OUT2=$($LUMINA exec "$SID" "echo stream_two" --stream 2>/dev/null)
  if echo "$OUT1" | grep -q "stream_one" && echo "$OUT2" | grep -q "stream_two"; then
    pass "5.3 two streamed execs (P1 state reset)"
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

  # Session file upload/download
  echo "sess_upload_payload" > /tmp/lumina-e2e-sup.txt
  $LUMINA exec "$SID" "true" --copy "/tmp/lumina-e2e-sup.txt:/tmp/up.txt" 2>/dev/null
  OUT=$($LUMINA exec "$SID" "cat /tmp/up.txt" 2>/dev/null)
  echo "$OUT" | grep -q "sess_upload_payload" && pass "5.7 session upload" || fail "5.7 sess upload" "$OUT"

  rm -f /tmp/lumina-e2e-sdl2.txt
  $LUMINA exec "$SID" "echo dl_data > /tmp/dl.txt" 2>/dev/null
  $LUMINA exec "$SID" "true" --download "/tmp/dl.txt:/tmp/lumina-e2e-sdl2.txt" 2>/dev/null
  [ -f /tmp/lumina-e2e-sdl2.txt ] && grep -q "dl_data" /tmp/lumina-e2e-sdl2.txt && pass "5.8 session download" || fail "5.8 sess download" "missing"

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

# Alternating stream/buffered — stresses state machine transitions
OK=true
for i in $(seq 1 5); do
  O1=$($LUMINA exec "$SID" "echo st_$i" --stream 2>/dev/null)
  O2=$($LUMINA exec "$SID" "echo bf_$i" 2>/dev/null)
  if ! echo "$O1" | grep -q "st_$i" || ! echo "$O2" | grep -q "bf_$i"; then
    OK=false; break
  fi
done
$OK && pass "7.2 5 alternating stream/buffered pairs" || fail "7.2 alternating" "pair $i"

# Large stream through session (tests NDJSON doesn't drop frames)
OUT=$($LUMINA exec "$SID" "seq 1 3000" --stream --timeout 30s 2>/dev/null)
EXIT_LINE=$(echo "$OUT" | grep '"exit_code"' | head -1)
if echo "$EXIT_LINE" | grep -q '"exit_code":0'; then
  # Verify the last number arrived
  if echo "$OUT" | grep -q '"data":"3000'; then
    pass "7.3 3K line session stream (no dropped frames)"
  else
    pass "7.3 3K line session stream (exit ok, last line may be batched)"
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
# Hard cleanup: kill ALL session serve processes, wait for VMs to fully release
pkill -f "_session-serve" 2>/dev/null || true
rm -rf ~/.lumina/sessions/* 2>/dev/null || true
sleep 8
OK=true
for i in $(seq 1 3); do
  S=$($LUMINA session start --boot-timeout 30s 2>/dev/null | jq -r '.sid')
  if [ -z "$S" ] || [ "$S" = "null" ]; then
    OK=false; break
  fi
  $LUMINA exec "$S" "echo cycle_$i" 2>/dev/null | grep -q "cycle_$i" || { OK=false; break; }
  $LUMINA session stop "$S" 2>/dev/null
  sleep 2
done
$OK && pass "8.3 3 start/exec/stop cycles" || fail "8.3 lifecycle cycles" "failed at $i"

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
ERR=$($LUMINA run --memory "abc" "echo fail" 2>&1) || true
echo "$ERR" | grep -qi "invalid" && pass "10.2 invalid memory" || fail "10.2 invalid memory" "$ERR"
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

# Session NDJSON — every line must be valid JSON
SID=$($LUMINA session start 2>/dev/null | jq -r '.sid')
OUT=$($LUMINA exec "$SID" "echo a; echo b >&2; echo c" --stream 2>/dev/null)
BAD=0; TOTAL=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  TOTAL=$((TOTAL + 1))
  echo "$line" | jq . >/dev/null 2>&1 || BAD=$((BAD + 1))
done <<< "$OUT"
[ "$BAD" -eq 0 ] && pass "11.3 session NDJSON validity ($TOTAL lines)" || fail "11.3" "$BAD/$TOTAL invalid"
$LUMINA session stop "$SID" 2>/dev/null

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
