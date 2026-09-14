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

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
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

exit 0
