#!/usr/bin/env bash
# scripts/ci/test-urgent-inbox-poll-loop.sh — INFRA-6444 (INFRA-2342 slice)
#
# Validates the background URGENT-INBOX polling loop:
#   1. Loop runs multiple ticks at the configured interval (bounded via
#      CHUMP_URGENT_INBOX_POLL_LOOP_MAX_TICKS so the test terminates).
#   2. Started/stopped lifecycle events land in ambient.jsonl (AC1/AC2).
#   3. A failing inner poll is logged as an error tick and the loop keeps
#      running to completion rather than aborting (AC3).
#   4. session-start-urgent-inbox-poll.sh backgrounds the loop and writes
#      a pidfile, and does not double-spawn on a second SessionStart fire.

set -uo pipefail
PASS=0; FAIL=0; FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-6444 urgent-inbox-poll-loop tests ==="

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LOOP="$REPO_ROOT/scripts/setup/urgent-inbox-poll-loop.sh"
SESSION_START="$REPO_ROOT/scripts/setup/session-start-urgent-inbox-poll.sh"
[[ -x "$LOOP" && -x "$SESSION_START" ]] || { echo "FATAL: scripts not executable"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset CHUMP_REPO

FAKE="$TMP/repo"
mkdir -p "$FAKE/.chump-locks"

# --- Test 1/2: loop runs bounded ticks, logs start + stop ---
env CHUMP_REPO="$FAKE" \
    CHUMP_AMBIENT_LOG="$FAKE/.chump-locks/ambient.jsonl" \
    CHUMP_URGENT_INBOX_POLL_INTERVAL_S=0 \
    CHUMP_URGENT_INBOX_POLL_LOOP_MAX_TICKS=3 \
    bash "$LOOP" >/dev/null 2>&1

if grep -q '"kind":"urgent_inbox_poll_loop_started"' "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "loop emits urgent_inbox_poll_loop_started"
else
    fail "loop did not emit urgent_inbox_poll_loop_started"
fi

if grep -q '"kind":"urgent_inbox_poll_loop_stopped"' "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "loop emits urgent_inbox_poll_loop_stopped after MAX_TICKS"
else
    fail "loop did not emit urgent_inbox_poll_loop_stopped"
fi

# --- Test 3: a failing inner poll is logged, loop still completes ---
rm -f "$FAKE/.chump-locks/ambient.jsonl"
BROKEN_COORD="$FAKE/scripts/coord"
mkdir -p "$BROKEN_COORD"
cat > "$BROKEN_COORD/inbox-check-urgent.sh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$BROKEN_COORD/inbox-check-urgent.sh"

env CHUMP_REPO="$FAKE" \
    CHUMP_AMBIENT_LOG="$FAKE/.chump-locks/ambient.jsonl" \
    CHUMP_URGENT_INBOX_POLL_INTERVAL_S=0 \
    CHUMP_URGENT_INBOX_POLL_LOOP_MAX_TICKS=2 \
    bash "$LOOP" >/dev/null 2>&1
LOOP_EXIT=$?

if [[ "$LOOP_EXIT" -eq 0 ]]; then
    ok "loop exits 0 even when every inner poll fails"
else
    fail "loop exited non-zero ($LOOP_EXIT) on inner poll failure"
fi

if grep -q '"kind":"urgent_inbox_poll_loop_error"' "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "failing inner poll is logged as urgent_inbox_poll_loop_error"
else
    fail "failing inner poll was not logged"
fi

if grep -q '"kind":"urgent_inbox_poll_loop_stopped"' "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "loop still reaches its bounded stop after errors (AC3: errors don't crash the loop)"
else
    fail "loop did not reach its bounded stop after errors"
fi

# --- Test 4: SessionStart hook backgrounds the loop + writes a pidfile ---
rm -rf "$FAKE/.chump-locks"
mkdir -p "$FAKE/.chump-locks"
FAKE_SETUP="$FAKE/scripts/setup"
mkdir -p "$FAKE_SETUP"
cat > "$FAKE_SETUP/urgent-inbox-poll-loop.sh" <<'EOF'
#!/usr/bin/env bash
sleep 5
EOF
chmod +x "$FAKE_SETUP/urgent-inbox-poll-loop.sh"

env CHUMP_REPO="$FAKE" \
    CHUMP_AMBIENT_LOG="$FAKE/.chump-locks/ambient.jsonl" \
    bash "$SESSION_START" >/dev/null 2>&1

sleep 0.3
PIDFILE="$FAKE/.chump-locks/urgent-inbox-poll-loop.pid"
if [[ -f "$PIDFILE" ]]; then
    PID1="$(cat "$PIDFILE")"
    if kill -0 "$PID1" 2>/dev/null; then
        ok "SessionStart hook backgrounds the loop and writes a live pidfile"
    else
        fail "pidfile PID $PID1 is not a live process"
    fi
else
    fail "SessionStart hook did not write a pidfile"
fi

# Second SessionStart fire while the loop is still alive must NOT spawn a second loop.
env CHUMP_REPO="$FAKE" \
    CHUMP_AMBIENT_LOG="$FAKE/.chump-locks/ambient.jsonl" \
    bash "$SESSION_START" >/dev/null 2>&1
PID2="$(cat "$PIDFILE" 2>/dev/null)"
if [[ "$PID1" == "$PID2" ]]; then
    ok "second SessionStart fire does not double-spawn the loop"
else
    fail "second SessionStart fire spawned a duplicate loop (pid $PID1 -> $PID2)"
fi

kill "$PID1" 2>/dev/null || true

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
    printf '  - %s\n' "${FAILS[@]}"
    exit 1
fi
exit 0
