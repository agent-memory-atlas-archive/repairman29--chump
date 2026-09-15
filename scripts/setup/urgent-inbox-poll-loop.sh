#!/usr/bin/env bash
# scripts/setup/urgent-inbox-poll-loop.sh — INFRA-6444 (INFRA-2342 slice)
#
# Background polling loop for the global URGENT-INBOX
# (.chump-locks/URGENT-INBOX.jsonl). Complements the existing tool-triggered
# checks (SessionStart one-shot in session-start-urgent-inbox-poll.sh,
# PreToolUse in scripts/coord/inbox-check-urgent.sh) with a loop that keeps
# polling even while the session is idle between tool calls.
#
# AC1: started (backgrounded) from the SessionStart hook by
#      session-start-urgent-inbox-poll.sh.
# AC2: polls every CHUMP_URGENT_INBOX_POLL_INTERVAL_S seconds (default 5).
# AC3: a failed poll tick is logged to ambient.jsonl and the loop keeps
#      running — it never exits on a transient error.
#
# Usage:
#   scripts/setup/urgent-inbox-poll-loop.sh &         # run one loop, detached
#
# Env:
#   CHUMP_URGENT_INBOX_POLL_INTERVAL_S   default 5 (seconds between ticks)
#   CHUMP_URGENT_INBOX_POLL_LOOP_MAX_TICKS  default 0 (0 = run forever; >0 used by tests)

set -uo pipefail  # not -e — a bad tick must not kill the loop (AC3)

REPO_ROOT="${CHUMP_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
INTERVAL="${CHUMP_URGENT_INBOX_POLL_INTERVAL_S:-5}"
MAX_TICKS="${CHUMP_URGENT_INBOX_POLL_LOOP_MAX_TICKS:-0}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
INNER="$REPO_ROOT/scripts/coord/inbox-check-urgent.sh"

mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true

log_ambient() {
    printf '{"ts":"%s","kind":"%s","source":"urgent_inbox_poll_loop","interval_s":%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$INTERVAL" \
        >> "$AMBIENT" 2>/dev/null || true
}

log_ambient "urgent_inbox_poll_loop_started"

tick=0
while true; do
    if [[ -x "$INNER" ]]; then
        "$INNER" >/dev/null 2>/dev/null || log_ambient "urgent_inbox_poll_loop_error"
    fi
    tick=$((tick + 1))
    if [[ "$MAX_TICKS" -gt 0 && "$tick" -ge "$MAX_TICKS" ]]; then
        break
    fi
    sleep "$INTERVAL"
done

log_ambient "urgent_inbox_poll_loop_stopped"
exit 0
