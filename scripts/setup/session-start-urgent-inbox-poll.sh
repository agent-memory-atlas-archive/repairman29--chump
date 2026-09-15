#!/usr/bin/env bash
# scripts/setup/session-start-urgent-inbox-poll.sh — INFRA-4987 (INFRA-2342 slice)
#
# SessionStart hook: polls the global URGENT-INBOX (.chump-locks/URGENT-INBOX.jsonl)
# at session start, not just on every PreToolUse call. This closes the gap where
# a CRIT/EMERGENCY message sent while no session was active would only surface
# once the new session's first tool call fired scripts/coord/inbox-check-urgent.sh.
#
# Called by .claude/settings.json → hooks.SessionStart
# Delegates the actual read/format/cursor-advance logic to
# scripts/coord/inbox-check-urgent.sh (INFRA-2016/INFRA-2341) so there is one
# canonical urgent-inbox reader, not two divergent implementations.
#
# Exit: always 0 (never blocks Claude Code startup).

set -uo pipefail

REPO_ROOT="${CHUMP_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[[ -z "$REPO_ROOT" ]] && exit 0

AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true

# AC2: log that the polling hook is active, every session start, regardless
# of whether there happen to be unread urgent messages right now.
# scanner-anchor: "kind":"urgent_inbox_session_start_poll_active"
printf '{"ts":"%s","kind":"urgent_inbox_session_start_poll_active","source":"session_start_urgent_inbox_poll"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$AMBIENT" 2>/dev/null || true
echo "[session-start] URGENT-INBOX polling hook active (INFRA-4987)" >&2

INNER="$REPO_ROOT/scripts/coord/inbox-check-urgent.sh"
if [[ -x "$INNER" ]]; then
    "$INNER" 2>/dev/null || true
fi

# AC1: also start a background loop that keeps polling the URGENT-INBOX
# while the session is idle between tool calls (INFRA-6444, INFRA-2342 slice).
# Guarded by a pidfile so repeated SessionStart fires (e.g. /clear) don't
# stack up duplicate loops.
LOOP_SCRIPT="$REPO_ROOT/scripts/setup/urgent-inbox-poll-loop.sh"
LOOP_PIDFILE="$REPO_ROOT/.chump-locks/urgent-inbox-poll-loop.pid"
if [[ -x "$LOOP_SCRIPT" && "${CHUMP_URGENT_INBOX_POLL_LOOP_DISABLE:-0}" != "1" ]]; then
    mkdir -p "$(dirname "$LOOP_PIDFILE")" 2>/dev/null || true
    EXISTING_PID=""
    [[ -f "$LOOP_PIDFILE" ]] && EXISTING_PID="$(cat "$LOOP_PIDFILE" 2>/dev/null | head -1 | xargs)"
    if [[ -z "$EXISTING_PID" ]] || ! kill -0 "$EXISTING_PID" 2>/dev/null; then
        nohup "$LOOP_SCRIPT" >/dev/null 2>/dev/null &
        echo "$!" > "$LOOP_PIDFILE" 2>/dev/null || true
        disown 2>/dev/null || true
    fi
fi

exit 0
