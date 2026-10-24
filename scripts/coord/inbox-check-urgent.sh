#!/usr/bin/env bash
# scripts/coord/inbox-check-urgent.sh — INFRA-2016 (the real keystone) + INFRA-2341
#
# Reads the GLOBAL urgent inbox (.chump-locks/URGENT-INBOX.jsonl) that
# every agent's PostToolUse + SessionStart hook chain checks, regardless of
# session resolution.
#
# Why a global inbox?
#   Investigation 2026-05-25T19:40Z found 8 of 10 curators with non-empty
#   inbox files had NEVER read them — cursor=empty. The existing inbox-poll
#   (INFRA-1860) only fires when an agent's CHUMP_SESSION_ID matches an
#   inbox file. Most curator sessions are operator-spawned standalone
#   Claude windows without CHUMP_SESSION_ID. So their session-keyed inbox
#   never gets polled. Messages were correctly delivered + dead-lettered.
#
# The fix: CRIT/EMERGENCY messages go to a GLOBAL inbox file. Every
# agent's hook reads from it. Bypasses session-resolution for the
# class of messages that MUST get through.
#
# INFRA-2341 — fix_trunk_priority_signal special-handling:
#   The fix-trunk-dispatcher writes a CRIT entry with kind=fix_trunk_priority_signal
#   when it claims a fix-trunk gap (signal mode, default). This helper detects
#   the kind tag and surfaces it above normal CRIT messages with a distinct
#   ** FIX-TRUNK PRIORITY SIGNAL ** banner so the operator's IDE session
#   pivots to clearing trunk red BEFORE continuing other work. Cursor advance
#   + the fix_trunk_session_acknowledged ambient emit are the "this signal
#   has been delivered" handshake — the same entry is not re-surfaced on
#   the next tool call. If multiple fix_trunk signals batch into one tick,
#   one fix_trunk_session_acknowledged event per gap_id is emitted.
#
# Output format (when global urgent inbox has unread):
#   <system-reminder>
#   ** INBOX URGENT (INFRA-2016 global) **
#   <inbox-interrupt urgency="..." from="..." kind="..." gap_id="..." ts="...">
#   body
#   </inbox-interrupt>
#   </system-reminder>
#
# State: .chump-locks/URGENT-INBOX.cursor stores byte offset
#
# Performance: <50ms on cold cache (single file stat + grep). Safe to
# call on every PostToolUse.

set -uo pipefail

if [[ "${CHUMP_INBOX_URGENT_DISABLE:-0}" == "1" ]]; then
    exit 0
fi

REPO_ROOT="${CHUMP_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
# INFRA-2341: allow override of inbox + cursor + ambient paths for hermetic tests.
URGENT_INBOX="${CHUMP_URGENT_INBOX:-$REPO_ROOT/.chump-locks/URGENT-INBOX.jsonl}"
CURSOR="${CHUMP_URGENT_INBOX_CURSOR:-$REPO_ROOT/.chump-locks/URGENT-INBOX.cursor}"

[[ -f "$URGENT_INBOX" ]] || exit 0  # no global urgent inbox = nothing to do

# Read cursor
LAST=0
[[ -f "$CURSOR" ]] && LAST="$(cat "$CURSOR" 2>/dev/null | head -1 | xargs)"
LAST="${LAST:-0}"

SIZE="$(wc -l < "$URGENT_INBOX" | xargs)"
[[ "$SIZE" -le "$LAST" ]] && exit 0  # no new urgent messages

# Read new messages
NEW="$(tail -n +"$((LAST + 1))" "$URGENT_INBOX" 2>/dev/null)"
[[ -z "$NEW" ]] && exit 0

# INFRA-2341: pre-scan NEW for fix_trunk_priority_signal entries.  Used both
# for the banner-elevation (printed once at the top of the system-reminder)
# and to emit one fix_trunk_session_acknowledged per gap_id.  The python here
# stays tiny so we don't double the cold-cache budget; one read of $NEW into
# stdin, two passes (kinds-list then full render below).
FIX_TRUNK_SIGNALS="$(printf '%s\n' "$NEW" | python3 -c '
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try: o = json.loads(line)
    except: continue
    if not isinstance(o, dict): continue
    if o.get("kind") == "fix_trunk_priority_signal":
        gap = o.get("gap_id") or "unknown"
        prio = o.get("priority") or "P0"
        wt = o.get("worktree") or ""
        print(f"{gap}\t{prio}\t{wt}")
' 2>/dev/null)"

# Format as system-reminder for Claude Code to surface
echo "<system-reminder>"
if [[ -n "$FIX_TRUNK_SIGNALS" ]]; then
    echo "** FIX-TRUNK PRIORITY SIGNAL (INFRA-2341) **"
    echo "** Trunk (main ci.yml) is RED.  The fix-trunk-dispatcher has claimed the"
    echo "** following gap(s) for trunk repair:"
    echo ""
    while IFS=$'\t' read -r gap prio wt; do
        [[ -z "$gap" ]] && continue
        printf '   %s  %s  worktree=%s\n' "$prio" "$gap" "$wt"
    done <<< "$FIX_TRUNK_SIGNALS"
    echo ""
    echo "** Canonical doctrine: docs/process/PR_RESCUE_PROCEDURE.md"
    echo ""
fi
echo "** INBOX URGENT (INFRA-2016 global) **"
echo "** This message was sent with urgency=CRIT or EMERGENCY. It bypasses"
echo "** session-keyed inboxes via the global urgent channel. Read + reply if it"
echo "** concerns your work; cursor will advance so you won't see it again."
echo ""
echo "$NEW" | python3 -c '
import json, sys
for line in sys.stdin:
    line = line.rstrip()
    if not line: continue
    try: o = json.loads(line)
    except: continue
    if not isinstance(o, dict): continue
    u = o.get("urgency","CRIT")
    sender = o.get("from") or o.get("session","unknown")
    ts = o.get("ts","")
    to = o.get("to","fleet-wide")
    kind = o.get("kind","")
    gap_id = o.get("gap_id","")
    body = (o.get("body") or o.get("reason") or o.get("gap") or "").strip()
    body = body.replace("&","&amp;").replace("<","&lt;").replace(">","&gt;")
    attrs = [f"urgency=\"{u}\"", f"from=\"{sender}\"", f"to=\"{to}\""]
    if kind:
        attrs.append(f"kind=\"{kind}\"")
    if gap_id:
        attrs.append(f"gap_id=\"{gap_id}\"")
    attrs.append(f"ts=\"{ts}\"")
    print(f"<inbox-interrupt {chr(32).join(attrs)}>")
    print(body)
    print("</inbox-interrupt>")
' 2>/dev/null
echo "</system-reminder>"

# Advance cursor
echo "$SIZE" > "$CURSOR.tmp" && mv "$CURSOR.tmp" "$CURSOR"

# Audit
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
COUNT="$(echo "$NEW" | wc -l | xargs)"
printf '{"ts":"%s","kind":"inbox_urgent_surfaced","source":"inbox_check_urgent","messages":%d,"new_cursor":%d}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$COUNT" "$SIZE" \
    >> "$AMBIENT" 2>/dev/null || true

# INFRA-2341: emit fix_trunk_session_acknowledged once per distinct gap_id
# surfaced this tick.  This is the operator-IDE handshake — it tells the
# sentinel + the 60-min operator-recall watchdog that the signal was
# delivered (not silently dropped into a closed-window inbox).
# scanner-anchor: "kind":"fix_trunk_session_acknowledged"
if [[ -n "$FIX_TRUNK_SIGNALS" ]]; then
    _ack_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    # Dedup gap_ids in case the same gap was signaled multiple times in this batch.
    while IFS=$'\t' read -r gap prio wt; do
        [[ -z "$gap" ]] && continue
        printf '{"ts":"%s","kind":"fix_trunk_session_acknowledged","source":"inbox_check_urgent","gap_id":"%s","priority":"%s","worktree":"%s"}\n' \
            "$_ack_ts" "$gap" "$prio" "$wt" \
            >> "$AMBIENT" 2>/dev/null || true
    done <<< "$(printf '%s\n' "$FIX_TRUNK_SIGNALS" | awk -F'\t' '!seen[$1]++')"
fi

exit 0
