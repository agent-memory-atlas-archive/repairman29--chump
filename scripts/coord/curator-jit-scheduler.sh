#!/usr/bin/env bash
# curator-jit-scheduler.sh — INFRA-1892
#
# Bash daemon that tails .chump-locks/ambient.jsonl, watches for curator
# DONE events (kind=gap_shipped or broadcast-event=DONE from
# curator-opus-* sessions), and auto-broadcasts the next-best gap from
# the prioritized backlog. Replaces the orchestrator-as-pebble-scheduler
# antipattern: the operator's planet-sized Opus session stops doing
# JIT routing and reverts to architectural judgment work.
#
# Composes existing primitives:
#   scripts/coord/broadcast.sh           — canonical curator-to-curator channel
#   scripts/dispatch/_pick_and_claim_gap.py --dry-run
#                                         — THE canonical fleet picker
#                                         (INFRA-8224; was _pick_gap.py, now its
#                                          deprecated shim; consumes GAP_JSON_FILE)
#   .chump-locks/ambient.jsonl           — event stream
#   .chump-locks/jit-scheduler-state.jsonl — throttle/dedup ledger (created here)
#
# Bypass:
#   CHUMP_JIT_SCHEDULER_DISABLED=1       — daemon exits 0 immediately
#
# Tunables:
#   CHUMP_JIT_DEDUP_WINDOW_S             default 3600  same-gap-same-curator cooldown
#   CHUMP_JIT_AMBIENT_LOG                override ambient.jsonl path (default
#                                         <repo>/.chump-locks/ambient.jsonl)
#   CHUMP_JIT_STATE_FILE                 override state ledger (default
#                                         <repo>/.chump-locks/jit-scheduler-state.jsonl)
#   CHUMP_JIT_PRIORITY_FILTER            forwarded to the canonical picker
#                                         (default "P0,P1" — JIT is for important work)
#   CHUMP_JIT_ONCE                       process current ambient state then exit
#                                         (used by CI smoke test)
#   CHUMP_JIT_SLEEP_S                    seconds between tail polls when --once is
#                                         unset and there are no new lines (default 5)
#
# Emits ambient events:
#   curator_jit_scheduled  {curator, gap_id, priority, lane}
#   curator_jit_skipped    {curator, reason}     # dedup hit / no candidate / active lease
#   curator_jit_no_gap     {curator}             # picker returned nothing
#
# Exit codes:
#   0 — normal (signal exit, --once done, or bypass)
#   2 — canonical picker missing or broadcast.sh missing (operator-fix needed)

set -uo pipefail

# ── bypass ────────────────────────────────────────────────────────────────
if [ "${CHUMP_JIT_SCHEDULER_DISABLED:-0}" = "1" ]; then
    echo "[curator-jit-scheduler] CHUMP_JIT_SCHEDULER_DISABLED=1 — exiting cleanly"
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
AMBIENT_LOG="${CHUMP_JIT_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
STATE_FILE="${CHUMP_JIT_STATE_FILE:-$REPO_ROOT/.chump-locks/jit-scheduler-state.jsonl}"
DEDUP_WINDOW_S="${CHUMP_JIT_DEDUP_WINDOW_S:-3600}"
PRIORITY_FILTER="${CHUMP_JIT_PRIORITY_FILTER:-P0,P1}"
SLEEP_S="${CHUMP_JIT_SLEEP_S:-5}"
RUN_ONCE="${CHUMP_JIT_ONCE:-0}"

BROADCAST_SH="$REPO_ROOT/scripts/coord/broadcast.sh"
# INFRA-8224: one picker — call the canonical picker in no-claim --dry-run mode
# (was _pick_gap.py, now its deprecated shim).
PICKER_PY="$REPO_ROOT/scripts/dispatch/_pick_and_claim_gap.py"
CHUMP_BIN="${CHUMP_BIN:-chump}"

[ -x "$BROADCAST_SH" ] || { echo "ERROR: broadcast.sh missing at $BROADCAST_SH" >&2; exit 2; }
[ -f "$PICKER_PY" ]    || { echo "ERROR: canonical picker missing at $PICKER_PY" >&2; exit 2; }

mkdir -p "$(dirname "$AMBIENT_LOG")" "$(dirname "$STATE_FILE")" 2>/dev/null

# ── ambient emit helper ───────────────────────────────────────────────────
emit() {
    local kind="$1"
    local fields="$2"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","kind":"%s",%s}\n' "$ts" "$kind" "$fields" >> "$AMBIENT_LOG"
}

# ── dedup ────────────────────────────────────────────────────────────────
# Returns 0 (true) iff (curator, gap_id) was broadcast within DEDUP_WINDOW_S.
already_scheduled_recently() {
    local curator="$1" gap_id="$2"
    [ -f "$STATE_FILE" ] || return 1
    local now
    now=$(date +%s)
    # Read newest entries first; awk picks the latest matching one.
    local last_ts
    last_ts=$(grep -F "\"curator\":\"$curator\"" "$STATE_FILE" 2>/dev/null \
              | grep -F "\"gap_id\":\"$gap_id\"" \
              | tail -1 \
              | python3 -c "
import sys, json
for line in sys.stdin:
    try:
        e = json.loads(line)
        print(e.get('unix_ts', 0))
    except: pass
" 2>/dev/null || echo 0)
    [ -n "$last_ts" ] || last_ts=0
    local age=$(( now - last_ts ))
    [ "$age" -lt "$DEDUP_WINDOW_S" ]
}

mark_scheduled() {
    local curator="$1" gap_id="$2"
    local unix_ts
    unix_ts=$(date +%s)
    printf '{"unix_ts":%d,"curator":"%s","gap_id":"%s"}\n' \
        "$unix_ts" "$curator" "$gap_id" >> "$STATE_FILE"
}

# ── pick next gap for a freed curator ─────────────────────────────────────
pick_next_gap() {
    local _curator="$1"  # unused in v0; v1 will lane-match on history
    local tmp_json
    tmp_json=$(mktemp -t chump-jit-gap-list.XXXXXX)
    trap 'rm -f "$tmp_json"' RETURN
    if ! "$CHUMP_BIN" gap list --status open --json > "$tmp_json" 2>/dev/null; then
        echo ""
        return
    fi
    # Active gaps: read lease files (skip self-lease via PID match if available).
    local active
    active=$(ls "$REPO_ROOT/.chump-locks/"claim-*.json 2>/dev/null \
             | python3 -c "
import sys, json, os
ids = []
for f in sys.stdin.read().split():
    try:
        with open(f) as h:
            d = json.load(h)
            g = d.get('gap_id')
            if g:
                ids.append(g)
    except: pass
print(' '.join(ids))
" 2>/dev/null || echo "")
    GAP_JSON_FILE="$tmp_json" \
        FLEET_PRIORITY_FILTER="$PRIORITY_FILTER" \
        FLEET_DOMAIN_FILTER="" \
        FLEET_EFFORT_FILTER="" \
        FLEET_MODEL="opus" \
        EXCLUDE_RE="" \
        ACTIVE_GAPS="$active" \
        python3 "$PICKER_PY" --dry-run 2>/dev/null
}

# ── process one event line ────────────────────────────────────────────────
# Returns the (curator-session, gap-id) tuple if this line is a curator DONE
# we should dispatch on; empty stdout otherwise.
extract_done_curator() {
    local line="$1"
    echo "$line" | python3 -c "
import sys, json
for raw in sys.stdin:
    try:
        e = json.loads(raw)
        kind = e.get('kind', '')
        event = e.get('event', '')
        session = e.get('session', '')
        # Two trigger forms:
        #   1. kind=gap_shipped  (canonical ship emit, future)
        #   2. event=DONE        (broadcast.sh DONE envelope, today)
        is_done = (kind == 'gap_shipped' or event == 'DONE')
        if is_done and session.startswith('curator-opus-'):
            print(session)
            sys.exit(0)
    except Exception:
        pass
" 2>/dev/null
}

handle_done() {
    local curator="$1"
    local next_gap
    next_gap=$(pick_next_gap "$curator")
    if [ -z "$next_gap" ]; then
        # scanner-anchor: "kind":"curator_jit_no_gap"
        emit "curator_jit_no_gap" "\"curator\":\"$curator\""
        return
    fi
    if already_scheduled_recently "$curator" "$next_gap"; then
        # scanner-anchor: "kind":"curator_jit_skipped"
        emit "curator_jit_skipped" "\"curator\":\"$curator\",\"gap_id\":\"$next_gap\",\"reason\":\"dedup_window\""
        return
    fi
    local title pri
    title=$("$CHUMP_BIN" gap show "$next_gap" --field title 2>/dev/null | head -c 100 || echo "")
    pri=$("$CHUMP_BIN" gap show "$next_gap" --field priority 2>/dev/null | head -c 4 || echo "P?")
    # Build the message + broadcast.
    local body
    body="JIT ASSIGNMENT: $next_gap $title ($pri) — your lane match. Spec at docs/gaps/$next_gap.yaml. Reply STUCK if blocked."
    if "$BROADCAST_SH" --to "$curator" WARN "$body" >/dev/null 2>&1; then
        mark_scheduled "$curator" "$next_gap"
        # scanner-anchor: "kind":"curator_jit_scheduled"
        emit "curator_jit_scheduled" "\"curator\":\"$curator\",\"gap_id\":\"$next_gap\",\"priority\":\"$pri\""
    else
        emit "curator_jit_skipped" "\"curator\":\"$curator\",\"gap_id\":\"$next_gap\",\"reason\":\"broadcast_failed\""
    fi
}

# ── main loop ─────────────────────────────────────────────────────────────
# Single-run mode (CI): process all current ambient lines once, exit.
if [ "$RUN_ONCE" = "1" ]; then
    [ -f "$AMBIENT_LOG" ] || { echo "[curator-jit-scheduler] no ambient log; nothing to do"; exit 0; }
    while IFS= read -r line; do
        curator=$(extract_done_curator "$line")
        [ -n "$curator" ] && handle_done "$curator"
    done < "$AMBIENT_LOG"
    exit 0
fi

# Daemon mode: tail-follow. Start at end of file; only react to NEW events.
trap 'echo "[curator-jit-scheduler] signal received; exiting"; exit 0' INT TERM HUP

echo "[curator-jit-scheduler] starting (ambient=$AMBIENT_LOG dedup_window=${DEDUP_WINDOW_S}s priority_filter=$PRIORITY_FILTER)"

# tail -F follows rotation; --max-unchanged-stats not portable. Use plain
# tail -n0 -F and read line by line in a while loop.
tail -n0 -F "$AMBIENT_LOG" 2>/dev/null | while IFS= read -r line; do
    curator=$(extract_done_curator "$line")
    [ -n "$curator" ] && handle_done "$curator"
done
