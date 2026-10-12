#!/usr/bin/env bash
# scripts/coord/post-push-integrity-watch.sh — INFRA-2026
#
# Daemon: detect "post-push PR auto-close" incidents where a stale-base force-push
# causes GitHub to auto-close a PR (the pushed SHA was already on main), then
# AUTO-REOPEN the PR, emit a WARN ambient event, and broadcast an URGENT-INBOX alert.
#
# Incident that motivated this (2026-05-25T19:00Z):
#   wizard pushed stale main HEAD to chump/infra-1974-claim via
#   `git push origin HEAD:chump/infra-1974-claim --force-with-lease` from a stale
#   worktree. GitHub auto-closed PR #2582 because the pushed SHA was already on main.
#   Manual recovery via git reflog + gh pr reopen worked but cost time + risked silent
#   data loss.
#
# Detection heuristic (runs every 60s via launchd):
#   1. Enumerate open+closed PRs on chump/<gap>-* branches updated in the last 120s
#   2. If any PR with a chump/* branch is CLOSED (not MERGED), and was closed within
#      120s of a push (detected by comparing closedAt vs git reflog push timestamps),
#      treat it as a stale-base auto-close incident.
#   3. Auto-reopen the PR, emit kind=post_push_auto_close_recovered to ambient.jsonl,
#      and broadcast CRIT to fleet-wide urgent inbox.
#
# Usage:
#   bash scripts/coord/post-push-integrity-watch.sh           # single-shot check
#   bash scripts/coord/post-push-integrity-watch.sh --dry-run # detect only, no reopen
#
# Install as daemon:
#   scripts/setup/install-post-push-integrity-launchd.sh
#
# Telemetry:
#   kind=post_push_auto_close_recovered — PR was auto-closed after push; reopened
#   kind=post_push_integrity_watch_ok   — scan ran, no incidents found
#   kind=post_push_integrity_watch_err  — gh API call failed or script error
#
# Environment:
#   CHUMP_POST_PUSH_WATCH_WINDOW_S  — how far back to look for closed PRs (default 120)
#   CHUMP_POST_PUSH_WATCH_BRANCH_RE — branch prefix pattern (default 'chump/')
#   CHUMP_REPO                      — repo root (default: git rev-parse --show-toplevel)
#
# scanner-anchor: "kind":"post_push_auto_close_recovered"
# scanner-anchor: "kind":"post_push_integrity_watch_ok"
# scanner-anchor: "kind":"post_push_integrity_watch_err"

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${CHUMP_REPO:-$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)}"
AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"
LOCK_DIR="$REPO_ROOT/.chump-locks"
mkdir -p "$LOCK_DIR"

DRY_RUN=0
WINDOW_S="${CHUMP_POST_PUSH_WATCH_WINDOW_S:-120}"
BRANCH_RE="${CHUMP_POST_PUSH_WATCH_BRANCH_RE:-chump/}"

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --help|-h) sed -n '2,35p' "$0" | sed 's/^# \?//'; exit 0 ;;
    esac
done

emit() {
    local kind="$1" payload="${2:-}"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ -n "$payload" ]]; then
        printf '{"ts":"%s","kind":"%s",%s}\n' "$ts" "$kind" "$payload" >> "$AMBIENT" 2>/dev/null || true
    else
        printf '{"ts":"%s","kind":"%s"}\n' "$ts" "$kind" >> "$AMBIENT" 2>/dev/null || true
    fi
}

log() { printf '[post-push-integrity-watch %s] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }

# Detect repo owner/name from git remote (for gh api calls).
REMOTE_URL=""
REMOTE_URL="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
if [[ -z "$REMOTE_URL" ]]; then
    log "ERROR: no git remote origin found; cannot check PR state"
    emit post_push_integrity_watch_err '"reason":"no_remote_origin"'
    exit 0
fi

# Extract owner/repo from SSH or HTTPS remote URLs using python3 (avoids
# bash ERE non-greedy issues across macOS/Linux zsh/bash variants).
# SSH:   git@github.com:owner/repo.git
# HTTPS: https://github.com/owner/repo.git
REPO_SLUG=""
REPO_SLUG="$(python3 -c "
import re, sys
url = '''$REMOTE_URL'''
m = re.search(r'github\.com[:/]([^/]+)/([^/.]+)', url)
if m:
    print(m.group(1) + '/' + m.group(2))
" 2>/dev/null || true)"

if [[ -z "$REPO_SLUG" ]]; then
    log "ERROR: could not extract owner/repo from remote: $REMOTE_URL"
    emit post_push_integrity_watch_err '"reason":"remote_parse_failed"'
    exit 0
fi

# Build cutoff ISO timestamp for closed-PR lookup.
# "closed within the last WINDOW_S seconds"
NOW_EPOCH="$(date +%s)"
CUTOFF_EPOCH=$((NOW_EPOCH - WINDOW_S))
CUTOFF_ISO="$(date -u -r "$CUTOFF_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$CUTOFF_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || python3 -c "import datetime; print(datetime.datetime.utcfromtimestamp($CUTOFF_EPOCH).strftime('%Y-%m-%dT%H:%M:%SZ'))")"

log "scanning for auto-closed PRs on ${BRANCH_RE}* branches (window=${WINDOW_S}s since $CUTOFF_ISO)"

# Check if gh is available.
if ! command -v gh &>/dev/null; then
    log "ERROR: gh CLI not found; cannot check PR state"
    emit post_push_integrity_watch_err '"reason":"gh_not_found"'
    exit 0
fi

# Use gh pr list with --state closed to find recently-closed chump/* PRs.
# We filter to PRs closed since CUTOFF_ISO.
# Output format: NUMBER\tBRANCH\tSTATE\tSTATE_REASON\tCLOSED_AT
CLOSED_PRS_JSON=""
# INFRA-2316 (2026-05-31): try with stateReason first; fall back without it
# on older gh CLI versions that don't recognize the field. The downstream
# state_reason extraction uses d.get('stateReason','') which gracefully
# returns "" when the field is absent — auto-close detection will miss
# the NOT_PLANNED signal in fallback mode but won't crash.
CLOSED_PRS_JSON="$(gh pr list \
    --repo "$REPO_SLUG" \
    --state closed \
    --limit 20 \
    --json number,headRefName,state,stateReason,closedAt,title,labels,mergedAt 2>/dev/null)" || \
CLOSED_PRS_JSON="$(gh pr list \
    --repo "$REPO_SLUG" \
    --state closed \
    --limit 20 \
    --json number,headRefName,state,closedAt,title,labels,mergedAt 2>/dev/null)" || {
    log "WARN: gh pr list failed (API issue); skipping this cycle"
    emit post_push_integrity_watch_err '"reason":"gh_pr_list_failed"'
    exit 0
}

if [[ -z "$CLOSED_PRS_JSON" || "$CLOSED_PRS_JSON" == "[]" ]]; then
    log "no closed PRs in recent window; OK"
    emit post_push_integrity_watch_ok '"checked":0,"incidents":0'
    exit 0
fi

# Parse closed PRs: find ones matching our branch pattern, closed by NOT_PLANNED
# (the stateReason GitHub sets when auto-closing via force-push with already-merged SHA),
# and closed within our window.
INCIDENTS=0
CHECKED=0

while IFS= read -r pr_json; do
    [[ -z "$pr_json" ]] && continue
    CHECKED=$((CHECKED + 1))

    pr_num="$(printf '%s' "$pr_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['number'])")"
    branch="$(printf '%s' "$pr_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['headRefName'])")"
    state_reason="$(printf '%s' "$pr_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('stateReason',''))")"
    closed_at="$(printf '%s' "$pr_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('closedAt',''))")"
    title="$(printf '%s' "$pr_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['title'])")"
    merged_at="$(printf '%s' "$pr_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('mergedAt') or '')")"
    labels_csv="$(printf '%s' "$pr_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(','.join(l.get('name','') for l in (d.get('labels') or [])))")"

    # Only care about chump/* branches.
    if [[ "$branch" != ${BRANCH_RE}* ]]; then
        continue
    fi

    # A MERGED PR is not an incident — never try to reopen it (a reopen call on a
    # merged PR just fails noisily). stateReason alone is unreliable here (gh
    # often reports "" for merges), so key on mergedAt, the authoritative field.
    if [[ "$state_reason" == "MERGED" || -n "$merged_at" ]]; then
        continue
    fi

    # TERMINAL-CLOSE LABEL guard (RESILIENT-311). The no-abandon janitor
    # (rot-reaper) deliberately closes CONFLICTING / required-check-failing PRs
    # and stamps them with the terminal label, having ALREADY re-queued their
    # gap so the fleet redoes the work clean. That is NOT a lost-work incident —
    # reopening the dead, unmergeable branch just resurrects rot. Before this
    # guard, the reaper closed #3792 every 30 min and THIS watcher reopened it
    # ~60s later: an infinite reap↔revive fight that rotted the PR open for 13h.
    # Skip any PR bearing the terminal label; the requeued gap is the recovery.
    TERMINAL_LABEL="${CHUMP_ROT_REAPER_LABEL:-rot-reaped}"
    if [[ ",$labels_csv," == *",$TERMINAL_LABEL,"* ]]; then
        log "SKIP reopen PR #$pr_num — labeled '$TERMINAL_LABEL' (intentional terminal close by the no-abandon janitor; gap already re-queued, a fresh PR will come)."
        continue
    fi

    # Check if closed within our window.
    if [[ -z "$closed_at" ]]; then
        continue
    fi
    CLOSED_EPOCH="$(python3 -c "
import datetime, sys
s = '$closed_at'.replace('Z', '+00:00')
try:
    dt = datetime.datetime.fromisoformat(s)
    print(int(dt.timestamp()))
except Exception as e:
    print(0)
")"
    if (( CLOSED_EPOCH < CUTOFF_EPOCH )); then
        # Closed before our window; skip.
        continue
    fi

    # ZERO-WASTE-027 follow-up: do NOT reopen a PR whose gap already SHIPPED.
    # This watchdog exists to rescue ACCIDENTAL stale-push auto-closes — it must
    # not fight an operator or curator intentionally closing a superseded
    # duplicate (e.g. the INFRA-3406 dupes #3244/#3249 whose real fix merged as
    # #3256). If the gap named in the title is done/shipped, the close was
    # deliberate; leave it closed. Mirrors closed-pr-watchdog.sh's guard, which
    # already skips done gaps. Without this, an intentional close is reopened
    # within WINDOW_S, looping forever.
    _gap_id="$(printf '%s' "$title" | grep -oE '[A-Z]+(-[A-Z]+)*-[0-9]+' | head -1)"
    if [[ -n "$_gap_id" ]] && command -v sqlite3 >/dev/null 2>&1 && [[ -f "$REPO_ROOT/.chump/state.db" ]]; then
        _gap_status="$(sqlite3 "$REPO_ROOT/.chump/state.db" \
            "SELECT status FROM gaps WHERE id='$_gap_id' LIMIT 1;" 2>/dev/null || true)"
        if [[ "$_gap_status" == "done" || "$_gap_status" == "shipped" || "$_gap_status" == "blocked" ]]; then
            log "SKIP reopen PR #$pr_num — gap $_gap_id is $_gap_status (intentional/terminal close: done, shipped, or operator-blocked — not a stale-push auto-close). INFRA-8111: a blocked gap's duplicate PRs must not be resurrected."
            continue
        fi
    fi

    # This is an incident: a chump/* PR was closed (not merged) within our window.
    INCIDENTS=$((INCIDENTS + 1))
    log "INCIDENT: PR #$pr_num branch=$branch state_reason=$state_reason closed_at=$closed_at"
    log "  title: $title"

    if [[ "$DRY_RUN" == "1" ]]; then
        log "  [dry-run] would reopen PR #$pr_num and emit CRIT alert"
        continue
    fi

    # Attempt to reopen the PR.
    REOPEN_OUT=""
    REOPEN_ERR=""
    if REOPEN_OUT="$(gh pr reopen "$pr_num" --repo "$REPO_SLUG" 2>&1)"; then
        log "  reopened PR #$pr_num successfully"
        REOPEN_STATUS="ok"
    else
        log "  WARN: gh pr reopen #$pr_num failed: $REOPEN_OUT"
        REOPEN_STATUS="failed"
    fi

    # Emit ambient event.
    SAFE_TITLE="$(printf '%s' "$title" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read().strip()))")"
    emit post_push_auto_close_recovered \
        "\"pr\":$pr_num,\"branch\":\"$branch\",\"state_reason\":\"$state_reason\",\"closed_at\":\"$closed_at\",\"reopen_status\":\"$REOPEN_STATUS\",\"title\":$SAFE_TITLE"

    # Broadcast CRIT to fleet-wide urgent inbox.
    BROADCAST_SCRIPT="$REPO_ROOT/scripts/coord/broadcast-urgent.sh"
    if [[ -x "$BROADCAST_SCRIPT" ]]; then
        BROADCAST_MSG="post-push auto-close detected: PR #$pr_num ($branch) was closed (${state_reason:-unknown}) after a push. ${REOPEN_STATUS}=reopen. Investigate stale-base force-push. title: $title"
        bash "$BROADCAST_SCRIPT" \
            --urgency CRIT \
            --from "post-push-integrity-watch" \
            --to fleet-wide \
            "$BROADCAST_MSG" || log "  WARN: broadcast-urgent.sh failed"
    else
        log "  WARN: broadcast-urgent.sh not found at $BROADCAST_SCRIPT; skipping broadcast"
    fi

done < <(printf '%s' "$CLOSED_PRS_JSON" | python3 -c "
import json, sys
prs = json.load(sys.stdin)
for pr in prs:
    print(json.dumps(pr))
")

if (( INCIDENTS == 0 )); then
    log "scan complete: checked=$CHECKED incidents=0"
    emit post_push_integrity_watch_ok "\"checked\":$CHECKED,\"incidents\":0"
else
    log "scan complete: checked=$CHECKED incidents=$INCIDENTS (recovery attempted)"
fi
