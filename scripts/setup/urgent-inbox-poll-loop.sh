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
# RESILIENT-1624: the loop is NOT immortal. Every tick it checks that its
# owning session is still alive and that its worktree still exists, and exits
# cleanly the moment either is gone. Before this fix the SessionStart hook
# daemonized the loop out of `claude -p`'s process group (nohup + disown), so
# INFRA-8198's process-group kill never reached it and every finished headless
# dispatch left an immortal poller with its cwd pinned inside the worktree —
# blocking the Class-D reaper (8 orphans / ~22 GB unreapable on cuphead
# 2026-10-18). The loop is now launched with cwd=/ (never pins a worktree) and
# given its session PID to watch.
#
# Usage:
#   scripts/setup/urgent-inbox-poll-loop.sh [PARENT_PID] &   # run one loop, detached
#
# Args:
#   $1  PARENT_PID  pid of the owning session (the SessionStart hook's PPID,
#       i.e. the `claude` process). When set, the loop exits within one tick of
#       that pid disappearing. Omitted/empty → no parent check (legacy behavior).
#
# Env:
#   CHUMP_REPO                           worktree root to watch (set by the hook
#                                        so git rev-parse isn't needed when cwd=/)
#   CHUMP_URGENT_INBOX_POLL_INTERVAL_S   default 5 (seconds between ticks)
#   CHUMP_URGENT_INBOX_POLL_LOOP_MAX_TICKS  default 0 (0 = run forever; >0 used by tests)

set -uo pipefail  # not -e — a bad tick must not kill the loop (AC3)

REPO_ROOT="${CHUMP_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
PARENT_PID="${1:-}"
WORKTREE="$REPO_ROOT"
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

# RESILIENT-1624: true when this loop has outlived its reason to run — its
# owning session is gone, or its worktree was removed out from under it.
session_or_worktree_gone() {
    if [[ -n "$PARENT_PID" ]] && ! kill -0 "$PARENT_PID" 2>/dev/null; then
        return 0
    fi
    if [[ -n "$WORKTREE" && ! -d "$WORKTREE" ]]; then
        return 0
    fi
    return 1
}

log_ambient "urgent_inbox_poll_loop_started"

tick=0
while true; do
    # RESILIENT-1624: check liveness at the top of every tick so the loop
    # exits within one tick of its session dying or its worktree vanishing.
    if session_or_worktree_gone; then
        break
    fi
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
