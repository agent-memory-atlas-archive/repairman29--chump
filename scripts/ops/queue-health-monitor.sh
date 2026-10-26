#!/usr/bin/env bash
# queue-health-monitor.sh — INFRA-052
#
# Hourly check for known queue/agent failure modes that otherwise sit
# silently for hours. Writes JSONL to .chump/health.jsonl (one record
# per check pass) plus a human-readable alerts log at .chump/alerts.log.
#
# Detects:
#   1. PRs OPEN > 45 min with non-passing required checks (BLOCKED/DIRTY/BEHIND).
#   2. Active session leases > 90 min since last commit by that session.
#   3. Linked worktrees > 5 GB (target/ bloat — disk pressure precursor).
#
# Designed to be quiet on a healthy queue (single "ok" line in health.jsonl)
# and noisy on a sick one (alerts.log gets ALERT lines + ambient.jsonl
# gets one ALERT event per finding so sibling agents see it in their
# next FLEET-019 SessionStart digest).
#
# Usage:
#   scripts/ops/queue-health-monitor.sh             # live run
#   scripts/ops/queue-health-monitor.sh --dry-run   # print findings; no jsonl/alerts/ambient writes
#   scripts/ops/queue-health-monitor.sh --quiet     # suppress stdout (launchd default)
#
# Environment:
#   QUEUE_HEALTH_PR_STUCK_MIN   minutes a PR can be OPEN+BLOCKED before alert
#                                (default: 45)
#   QUEUE_HEALTH_AGENT_SILENT_MIN  minutes a lease can have no commits before
#                                  alert (default: 90)
#   QUEUE_HEALTH_WORKTREE_MAX_GB worktree size in GB before alert (default: 5)
#   QUEUE_HEALTH_REPO            repo for gh pr list (default: derived from origin)
#
# Exit codes:
#   0  clean (no alerts) OR alerts found and written (script always succeeds
#      so launchd doesn't restart-spam)

set -euo pipefail

DRY_RUN=0
QUIET=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --quiet)   QUIET=1; shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

PR_STUCK_MIN="${QUEUE_HEALTH_PR_STUCK_MIN:-45}"
AGENT_SILENT_MIN="${QUEUE_HEALTH_AGENT_SILENT_MIN:-90}"
WORKTREE_MAX_GB="${QUEUE_HEALTH_WORKTREE_MAX_GB:-5}"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
_GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then
    MAIN_REPO="$REPO_ROOT"
else
    MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"
fi
LOCK_DIR="${QUEUE_HEALTH_LOCK_DIR_OVERRIDE:-$MAIN_REPO/.chump-locks}"
CHUMP_DIR="$MAIN_REPO/.chump"
HEALTH_JSONL="$CHUMP_DIR/health.jsonl"
ALERTS_LOG="$CHUMP_DIR/alerts.log"
EMIT="$REPO_ROOT/scripts/dev/ambient-emit.sh"
[[ -x "$EMIT" ]] || EMIT="$MAIN_REPO/scripts/dev/ambient-emit.sh"

mkdir -p "$CHUMP_DIR"

# INFRA-1211: shared worktree scanning lib.
# shellcheck source=scripts/lib/worktree-iter.sh
source "$(dirname "$0")/../lib/worktree-iter.sh"
REAPER_NAME="${REAPER_NAME:-queue-health}"
REAPER_REPO_ROOT="$MAIN_REPO"
export REAPER_REPO_ROOT

say()  { [[ "$QUIET" -eq 1 ]] || printf '\033[1;36m[queue-health]\033[0m %s\n' "$*"; }
warn() { [[ "$QUIET" -eq 1 ]] || printf '\033[1;33m[queue-health]\033[0m %s\n' "$*" >&2; }

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
NOW_EPOCH="$(date +%s)"

ALERT_COUNT=0
ALERT_DETAILS=()

emit_alert() {
    local kind="$1"
    local msg="$2"
    ALERT_COUNT=$((ALERT_COUNT + 1))
    ALERT_DETAILS+=("$kind: $msg")
    if [[ "$DRY_RUN" -eq 1 ]]; then
        say "ALERT (dry-run) $kind: $msg"
        return 0
    fi
    printf '%s\t%s\t%s\n' "$TS" "$kind" "$msg" >> "$ALERTS_LOG"
    if [[ -x "$EMIT" ]]; then
        # Truncate long messages so a single alert doesn't blow the digest budget.
        local short="${msg:0:200}"
        CHUMP_AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}" "$EMIT" ALERT "kind=$kind" "note=$short" 2>/dev/null || true
    fi
}

# ── Check 1: stuck PRs (with INFRA-230 resolution tracking) ──────────────────
# Maintain a small state file at .chump/pr-stuck-state.json mapping PR# →
# first-alert-ts. On each run:
#   - Currently-stuck PR not in state  → emit pr_stuck + add to state
#   - Currently-stuck PR already in state → silent (don't re-alert)
#   - PR in state that is no longer stuck (landed or unblocked) → emit
#     pr_resolved + remove from state
# This closes the audit loop so operators can correlate "stuck X min ago"
# with "resolved Y min later" instead of seeing immortal pr_stuck history.
PR_STATE_FILE="$CHUMP_DIR/pr-stuck-state.json"
[[ -f "$PR_STATE_FILE" ]] || echo '{}' > "$PR_STATE_FILE"

if command -v gh >/dev/null; then
    say "checking PR queue (stuck > ${PR_STUCK_MIN} min, BLOCKED/DIRTY)..."
    PR_JSON="$(gh pr list --state open --limit 50 --json number,title,createdAt,updatedAt,mergeStateStatus,autoMergeRequest 2>/dev/null || echo '[]')"

    # Compute new + resolved transitions in python; emit shell-readable lines
    # like "STUCK <line>" or "RESOLVED <line>". Then dispatch in shell so the
    # ALERT path stays in one place.
    TRANSITIONS="$(printf '%s' "$PR_JSON" | NOW_EPOCH="$NOW_EPOCH" STUCK_MIN="$PR_STUCK_MIN" PR_STATE_FILE="$PR_STATE_FILE" DRY_RUN="$DRY_RUN" python3 -c '
import json, os, sys
from datetime import datetime, timezone

data = json.loads(sys.stdin.read() or "[]")
now = int(os.environ["NOW_EPOCH"])
stuck_min = int(os.environ["STUCK_MIN"])
state_path = os.environ["PR_STATE_FILE"]
dry_run = os.environ["DRY_RUN"] == "1"

try:
    state = json.load(open(state_path))
except Exception:
    state = {}

currently_stuck = {}  # pr# -> formatted line
for pr in data:
    s = pr.get("mergeStateStatus") or "UNKNOWN"
    if s in ("CLEAN", "MERGEABLE", "UNKNOWN"):
        continue
    updated = pr.get("updatedAt") or pr.get("createdAt") or ""
    try:
        ts = datetime.fromisoformat(updated.replace("Z", "+00:00")).timestamp()
    except Exception:
        continue
    age_min = int((now - ts) / 60)
    if age_min < stuck_min:
        continue
    auto = (pr.get("autoMergeRequest") or {}).get("mergeMethod") or "off"
    title = (pr.get("title", "") or "")[:80]
    num = str(pr.get("number", "?"))
    currently_stuck[num] = "#{} {} auto={} age={}m {}".format(num, s, auto, age_min, title)

# Emit STUCK for newly-stuck (not in state)
for num, line in currently_stuck.items():
    if num not in state:
        state[num] = {"first_alert_ts": now, "line": line}
        print("STUCK " + line)

# Emit RESOLVED for previously-stuck no longer in currently_stuck
resolved_nums = [n for n in list(state.keys()) if n not in currently_stuck]
for num in resolved_nums:
    entry = state.pop(num)
    duration_min = int((now - entry["first_alert_ts"]) / 60)
    line = entry.get("line", "#{}".format(num))
    print("RESOLVED #{} after {}m: {}".format(num, duration_min, line))

# Persist updated state (skip in dry-run so observers can re-run safely)
if not dry_run:
    with open(state_path, "w") as f:
        json.dump(state, f, indent=2)
')"

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        case "$line" in
            "STUCK "*)    emit_alert "pr_stuck"    "${line#STUCK }" ;;
            "RESOLVED "*) emit_alert "pr_resolved" "${line#RESOLVED }" ;;
        esac
    done <<<"$TRANSITIONS"
fi

# ── Check 1.5: INFRA-103 — serializing PRs blocking parallel-safe PRs ────────
# If there are open auto-merge PRs labeled 'pr:serializing' AND there are also
# open auto-merge PRs labeled 'pr:parallel-safe', the serializing PRs are
# gating the parallel-safe ones unnecessarily. Alert so humans/agents can
# reorder, expedite, or split the serializing PR.
if command -v gh >/dev/null; then
    say "checking for serializing PRs blocking parallel-safe PRs (INFRA-103)…"
    _ser_count=0
    _par_count=0
    _ser_prs=""
    _par_prs=""
    if gh label list --limit 100 2>/dev/null | grep -q "pr:serializing"; then
        _ser_prs="$(gh pr list --state open --label "pr:serializing" --json number,title --jq '.[] | "#\(.number) \(.title[:60])"' 2>/dev/null || true)"
        _ser_count="$(printf '%s\n' "$_ser_prs" | grep -c '#' 2>/dev/null || true)"
    fi
    if gh label list --limit 100 2>/dev/null | grep -q "pr:parallel-safe"; then
        _par_prs="$(gh pr list --state open --label "pr:parallel-safe" --json number,title --jq '.[] | "#\(.number) \(.title[:60])"' 2>/dev/null || true)"
        _par_count="$(printf '%s\n' "$_par_prs" | grep -c '#' 2>/dev/null || true)"
    fi
    if [[ "$_ser_count" -gt 0 && "$_par_count" -gt 0 ]]; then
        _ser_list="$(printf '%s\n' "$_ser_prs" | tr '\n' '|' | sed 's/|$//')"
        emit_alert "serializing_blocking_parallel" "serializing_count=${_ser_count} parallel_safe_count=${_par_count} serializing_prs=${_ser_list:0:200}"
    fi
fi

# ── Check 2: silent agents (lease present, no recent commits) ────────────────
say "checking active leases for silent agents (no commits > ${AGENT_SILENT_MIN} min)..."
shopt -s nullglob
for lease in "$LOCK_DIR"/*.json; do
    sess_id="$(basename "$lease" .json)"
    [[ "$sess_id" == ".wt-session-id" ]] && continue
    # Lease taken_at is informational; what matters is "did this session commit anything recently?"
    # We approximate by greppping ambient.jsonl for the most recent commit/file_edit by this session.
    # If ambient has no entries for this session in the silent window, raise.
    if [[ -f "$LOCK_DIR/ambient.jsonl" ]]; then
        last_event_ts="$(grep -F "\"session\":\"$sess_id\"" "$LOCK_DIR/ambient.jsonl" 2>/dev/null \
            | tail -1 \
            | python3 -c "import json,sys; line=sys.stdin.read().strip(); print(json.loads(line).get('ts','')) if line else print('')" 2>/dev/null || true)"
    else
        last_event_ts=""
    fi
    if [[ -z "$last_event_ts" ]]; then
        # No ambient activity at all — measure from lease taken_at instead.
        last_event_ts="$(python3 -c "import json; print(json.load(open('$lease')).get('taken_at',''))" 2>/dev/null || true)"
    fi
    [[ -z "$last_event_ts" ]] && continue
    last_epoch="$(python3 -c "from datetime import datetime; print(int(datetime.fromisoformat('$last_event_ts'.replace('Z','+00:00')).timestamp()))" 2>/dev/null || echo 0)"
    [[ "$last_epoch" == 0 ]] && continue
    age_min=$(( (NOW_EPOCH - last_epoch) / 60 ))
    if (( age_min >= AGENT_SILENT_MIN )); then
        gap_id="$(python3 -c "import json; print(json.load(open('$lease')).get('gap_id','?'))" 2>/dev/null || echo '?')"

        # INFRA-491: dedupe silent_agent alerts at the emitter. Pre-fix
        # the watcher fired this alert every cycle (hourly) for as
        # long as the lease lingered — a single 12h-stuck session
        # showed as 12 silent_agent events. INFRA-489 deduped at the
        # consumer (waste-tally), but accumulating noise in ambient.jsonl
        # also bloats peripheral-vision tail glances and rotation log
        # archives. Fix: per-session sidecar marker; skip re-emission
        # if marker is fresh.
        #
        # Threshold: SILENT_REALERT_MIN (default 360min = 6h). After
        # that the session has materially worsened (6h → 12h+), so we
        # re-alert with the new age.
        marker="/tmp/chump-silent-alerted-${sess_id}.ts"
        realert_min="${SILENT_REALERT_MIN:-360}"
        skip=0
        if [[ -f "$marker" ]]; then
            marker_mtime="$(stat -c %Y "$marker" 2>/dev/null || stat -f %m "$marker" 2>/dev/null || echo 0)"
            marker_age_min=$(( (NOW_EPOCH - marker_mtime) / 60 ))
            if (( marker_age_min < realert_min )); then
                skip=1
            fi
        fi
        if (( skip == 0 )); then
            emit_alert "silent_agent" "session=$sess_id gap=$gap_id last_event_age=${age_min}m"
            : > "$marker" 2>/dev/null || true
        fi
    fi
done
shopt -u nullglob

# ── Check 3: fat worktrees ────────────────────────────────────────────────────
# INFRA-1211: use scan_worktrees() from worktree-iter.sh (--no-tmp: managed
# worktree dirs only; /tmp/chump-* are ephemeral and separately reaped by
# prune-worktrees.sh).
say "checking worktrees for size > ${WORKTREE_MAX_GB} GB..."
while IFS= read -r wt; do
    [[ -d "$wt" ]] || continue
    # du -sk gives KB; convert to GB.
    kb="$(du -sk "$wt" 2>/dev/null | awk '{print $1}')"
    [[ -z "$kb" ]] && continue
    gb=$(python3 -c "print(round($kb / 1024 / 1024, 2))" 2>/dev/null || echo 0)
    over=$(python3 -c "print(1 if $gb > $WORKTREE_MAX_GB else 0)" 2>/dev/null || echo 0)
    if [[ "$over" == "1" ]]; then
        emit_alert "fat_worktree" "path=${wt%/} size_gb=${gb} (run scripts/ops/stale-worktree-reaper.sh --execute or rm -rf <worktree>/target/)"
    fi
done < <(CHUMP_WORKTREE_BASE="${CHUMP_WORKTREE_BASE:-$MAIN_REPO/.claude/worktrees}" scan_worktrees --no-tmp)

# ── Check 4: stale bot-merge health files (INFRA-119) ────────────────────────
# bot-merge.sh writes .chump-locks/bot-merge-<pid>.health every 30s while
# running. A file whose last_heartbeat_at is > BOT_MERGE_STALE_MIN minutes
# old means bot-merge either died without cleanup or is truly hung.
BOT_MERGE_STALE_MIN="${QUEUE_HEALTH_BOT_MERGE_STALE_MIN:-5}"
say "checking bot-merge health files (stale > ${BOT_MERGE_STALE_MIN} min)..."
shopt -s nullglob
for hf in "$LOCK_DIR"/bot-merge-*.health; do
    [[ -f "$hf" ]] || continue
    hf_data="$(python3 -c "
import json, sys
try:
    print(json.dumps(json.load(open(sys.argv[1]))))
except Exception as e:
    print('{}')
" "$hf" 2>/dev/null || echo '{}')"
    last_hb="$(printf '%s' "$hf_data" | python3 -c "
import json,sys
d=json.loads(sys.stdin.read() or '{}')
print(d.get('last_heartbeat_at',''))
" 2>/dev/null || true)"
    [[ -z "$last_hb" ]] && continue
    age_min="$(python3 -c "
from datetime import datetime, timezone
import sys
try:
    ts = datetime.fromisoformat(sys.argv[1].replace('Z','+00:00'))
    print(int((datetime.now(timezone.utc) - ts).total_seconds() / 60))
except Exception:
    print(-1)
" "$last_hb" 2>/dev/null || echo -1)"
    [[ "$age_min" -lt 0 ]] && continue
    if (( age_min >= BOT_MERGE_STALE_MIN )); then
        hf_pid="$(printf '%s' "$hf_data" | python3 -c "import json,sys; print(json.loads(sys.stdin.read() or '{}').get('pid','?'))" 2>/dev/null || echo '?')"
        hf_step="$(printf '%s' "$hf_data" | python3 -c "import json,sys; print(json.loads(sys.stdin.read() or '{}').get('current_step','?'))" 2>/dev/null || echo '?')"
        emit_alert "bot_merge_hung" "pid=${hf_pid} step=${hf_step} last_heartbeat_age=${age_min}m health_file=$(basename "$hf")"
    fi
done
shopt -u nullglob

# ── Check 5: expired lease files (INFRA-115 — server-side TTL reaper) ────────
# Lease files declare an expires_at timestamp. Today nothing actually reaps
# them server-side once expired — gap-preflight.sh ignores them client-side
# but the file persists indefinitely. Under high parallelism (or a Pi that
# crashed mid-claim), stale leases accumulate and confuse other agents.
# Reap any lease whose expires_at is more than LEASE_GRACE_MIN minutes past.
# (5-min grace lets clock skew + final-act commit cleanup race without us
# yanking a still-completing agent's lease.)
LEASE_GRACE_MIN="${QUEUE_HEALTH_LEASE_GRACE_MIN:-5}"
say "checking lease files for expired (>${LEASE_GRACE_MIN} min past expires_at)..."
shopt -s nullglob
for lease in "$LOCK_DIR"/*.json; do
    [[ -f "$lease" ]] || continue
    sess_id="$(basename "$lease" .json)"
    [[ "$sess_id" == ".wt-session-id" ]] && continue
    expires_at="$(python3 -c "
import json, sys
try:
    print(json.load(open(sys.argv[1])).get('expires_at',''))
except Exception:
    print('')
" "$lease" 2>/dev/null || true)"
    [[ -z "$expires_at" ]] && continue
    age_min="$(python3 -c "
from datetime import datetime, timezone
import sys
try:
    ts = datetime.fromisoformat(sys.argv[1].replace('Z','+00:00'))
    print(int((datetime.now(timezone.utc) - ts).total_seconds() / 60))
except Exception:
    print(-9999)
" "$expires_at" 2>/dev/null || echo -9999)"
    [[ "$age_min" -lt "$LEASE_GRACE_MIN" ]] && continue
    # This lease is past its declared TTL + grace. Reap.
    gap_id="$(python3 -c "
import json, sys
try:
    print(json.load(open(sys.argv[1])).get('gap_id', json.load(open(sys.argv[1])).get('purpose','?')))
except Exception:
    print('?')
" "$lease" 2>/dev/null || echo '?')"
    if [[ "$DRY_RUN" -eq 0 ]]; then
        rm -f "$lease"
        # INFRA-491: clear the silent_agent dedup marker now that the
        # lease is gone. Future sessions that reuse this ID start
        # fresh (no inherited dedup state from a prior abandoned
        # session).
        rm -f "/tmp/chump-silent-alerted-${sess_id}.ts" 2>/dev/null || true
    fi
    emit_alert "lease_expired_server" "session=${sess_id} gap=${gap_id} expired=${age_min}m_ago lease_file=$(basename "$lease") (reaped)"
done
shopt -u nullglob

# ── Write health.jsonl record ────────────────────────────────────────────────
# Pass alerts via env so we don't have to escape them through nested heredocs.
ALERTS_JOINED=""
if [[ "${#ALERT_DETAILS[@]}" -gt 0 ]]; then
    ALERTS_JOINED="$(printf '%s\n' "${ALERT_DETAILS[@]}")"
fi
RECORD="$(
    TS="$TS" \
    ALERT_COUNT="$ALERT_COUNT" \
    ALERTS_JOINED="$ALERTS_JOINED" \
    PR_STUCK_MIN="$PR_STUCK_MIN" \
    AGENT_SILENT_MIN="$AGENT_SILENT_MIN" \
    WORKTREE_MAX_GB="$WORKTREE_MAX_GB" \
    python3 -c '
import json, os
alerts_text = os.environ.get("ALERTS_JOINED", "")
alerts = [l.strip() for l in alerts_text.splitlines() if l.strip()]
print(json.dumps({
    "ts": os.environ["TS"],
    "alert_count": int(os.environ["ALERT_COUNT"]),
    "alerts": alerts,
    "thresholds": {
        "pr_stuck_min": int(os.environ["PR_STUCK_MIN"]),
        "agent_silent_min": int(os.environ["AGENT_SILENT_MIN"]),
        "worktree_max_gb": float(os.environ["WORKTREE_MAX_GB"]),
    },
}))
'
)"
if [[ "$DRY_RUN" -eq 0 ]]; then
    printf '%s\n' "$RECORD" >> "$HEALTH_JSONL"
fi

if [[ "$ALERT_COUNT" -gt 0 ]]; then
    say "${ALERT_COUNT} alert(s) written to $ALERTS_LOG"
else
    say "ok — no alerts"
fi

exit 0
