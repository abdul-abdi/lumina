#!/usr/bin/env bash
# bench/lumi-smoke.sh — the 12 lumi smoke tests, adapted to lumina.
# Source: ~/Developer/lumi/Tests/smoke.sh (CC: same 10 cases, plus warm-pool).
#
# Usage:
#   ./bench/lumi-smoke.sh             # cold path (no daemon)
#   ./bench/lumi-smoke.sh --with-pool # via warm-pool daemon (lumina daemon serve)
set -u

BIN="${BIN:-$HOME/Developer/lumina-lumi-port/.build/arm64-apple-macosx/release/lumina}"
[ -x "$BIN" ] || { echo "binary missing: $BIN" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 2; }

POOL=0
DAEMON_PID=""
RUN_FLAGS=""
trap 'cleanup' EXIT
cleanup() {
    if [ -n "$DAEMON_PID" ]; then
        "$BIN" daemon stop >/dev/null 2>&1 || true
        kill -TERM "$DAEMON_PID" 2>/dev/null || true
        wait "$DAEMON_PID" 2>/dev/null || true
    fi
}

if [ "${1:-}" = "--with-pool" ]; then
    POOL=1
    RUN_FLAGS="--via-daemon"
    rm -f "$HOME/.lumina/lumind.sock"
    "$BIN" daemon serve --size 4 >/tmp/lumina-smoke-daemon.log 2>&1 &
    DAEMON_PID=$!
    for _ in $(seq 1 80); do
        grep -q "ready" /tmp/lumina-smoke-daemon.log 2>/dev/null && break
        sleep 0.2
    done
    echo "## via daemon (size=4)"
else
    echo "## direct (no daemon)"
fi

mkdir -p /tmp/lumina-smoke
printf 'uploaded-data\n' > /tmp/lumina-smoke/in.txt
mkdir -p /tmp/lumina-smoke/data
printf 'shared-host-data\n' > /tmp/lumina-smoke/data/file.txt

PASS=0
FAIL=0
record() {
    if [ "$3" = 1 ]; then
        PASS=$((PASS+1))
        printf " %2d %-20s PASS\n" "$1" "$2"
    else
        FAIL=$((FAIL+1))
        printf " %2d %-20s FAIL\n" "$1" "$2"
    fi
}

# 1. echo hello
out=$("$BIN" run $RUN_FLAGS "echo hello" 2>/dev/null)
echo "$out" | jq -e '.stdout=="hello\n" and .exit_code==0' >/dev/null 2>&1
record 1 "echo hello" "$([ $? -eq 0 ] && echo 1 || echo 0)"

# 2. exit code
out=$("$BIN" run $RUN_FLAGS "exit 7" 2>/dev/null)
echo "$out" | jq -e '.exit_code==7' >/dev/null 2>&1
record 2 "exit 7" "$([ $? -eq 0 ] && echo 1 || echo 0)"

# 3. stderr separation
out=$("$BIN" run $RUN_FLAGS 'echo to_err 1>&2' 2>/dev/null)
echo "$out" | jq -e '.stderr=="to_err\n"' >/dev/null 2>&1
record 3 "stderr split" "$([ $? -eq 0 ] && echo 1 || echo 0)"

# 4. stdin pipe
n=$(printf 'one\ntwo\nthree' | "$BIN" run $RUN_FLAGS "wc -l" 2>/dev/null | jq -r '.stdout' | tr -d ' \n')
[ "$n" = 2 ]
record 4 "stdin pipe" "$([ $? -eq 0 ] && echo 1 || echo 0)"

# 5. env vars
out=$("$BIN" run $RUN_FLAGS -e A=1 -e B=2 'echo $A-$B' 2>/dev/null)
echo "$out" | jq -e '.stdout=="1-2\n"' >/dev/null 2>&1
record 5 "env vars" "$([ $? -eq 0 ] && echo 1 || echo 0)"

# 6. workdir
out=$("$BIN" run $RUN_FLAGS --workdir /tmp 'pwd' 2>/dev/null)
echo "$out" | jq -e '.stdout=="/tmp\n"' >/dev/null 2>&1
record 6 "workdir" "$([ $? -eq 0 ] && echo 1 || echo 0)"

# 7. --copy upload (NOTE: --via-daemon drops --copy in v1 protocol)
if [ "$POOL" = 1 ]; then
    record 7 "--copy upload" "SKIP — daemon v1 has no transfer ops"
else
    out=$("$BIN" run --copy /tmp/lumina-smoke/in.txt:/tmp/x "cat /tmp/x" 2>/dev/null)
    echo "$out" | jq -e '.stdout=="uploaded-data\n"' >/dev/null 2>&1
    record 7 "--copy upload" "$([ $? -eq 0 ] && echo 1 || echo 0)"
fi

# 8. --download
if [ "$POOL" = 1 ]; then
    record 8 "--download" "SKIP — daemon v1 has no transfer ops"
else
    rm -f /tmp/lumina-smoke/os
    "$BIN" run --download /etc/os-release:/tmp/lumina-smoke/os "true" >/dev/null 2>&1
    [ -s /tmp/lumina-smoke/os ]
    record 8 "--download" "$([ $? -eq 0 ] && echo 1 || echo 0)"
fi

# 9. --volume
if [ "$POOL" = 1 ]; then
    record 9 "--volume" "SKIP — daemon v1 has no volume ops"
else
    out=$("$BIN" run --volume /tmp/lumina-smoke/data:/host "cat /host/file.txt" 2>/dev/null)
    echo "$out" | jq -e '.stdout=="shared-host-data\n"' >/dev/null 2>&1
    record 9 "--volume" "$([ $? -eq 0 ] && echo 1 || echo 0)"
fi

# 10. timeout — lumi throws .error="timeout"; lumina uses grace-window
# kill that lets the guest return a signal-killed exit (exit_code=-1 or
# a negative value). Either form is a pass — same observable outcome.
out=$("$BIN" run $RUN_FLAGS --timeout 1s "sleep 3" 2>/dev/null)
echo "$out" | jq -e '(.error=="timeout") or (.exit_code != null and .exit_code < 0)' >/dev/null 2>&1
record 10 "timeout" "$([ $? -eq 0 ] && echo 1 || echo 0)"

echo ""
echo "## $PASS passed, $FAIL failed"

if [ "$POOL" = 1 ]; then
    echo ""
    echo "## sustained warm latency (5 samples after smoke)"
    for i in 1 2 3 4 5; do
        out=$("$BIN" run --via-daemon "true" 2>/dev/null)
        ms=$(echo "$out" | jq -r '.duration_ms')
        echo "   ${ms}ms"
        sleep 0.2
    done
fi

exit $FAIL
