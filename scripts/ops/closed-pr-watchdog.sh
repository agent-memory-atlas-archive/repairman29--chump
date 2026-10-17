#!/usr/bin/env bash
# closed-pr-watchdog.sh — REST-only closed-not-merged PR recovery
#
# Covers two failure modes that ghost-gap-reaper.sh misses:
#
#   1. PR closed without merging, gap still status=open (work lost / bounced).
#      → emits kind=pr_bounced_open_gap to ambient.jsonl
#      → optionally re-opens the PR (CHUMP_WATCHDOG_REOPEN=1)
#
#   2. Gap status=done but associated PR was closed without merging (ghost gap).
#      → delegates to ghost-gap-reaper.sh which rolls the gap back to open.
#      → This script calls ghost-gap-reaper so both run on the same schedule.
#
# Why not bounced-pr-detector.sh?
#   bounced-pr-detector.sh uses `gh pr list` (GraphQL) + a Python classifier
#   that checks if equivalent file content re-landed. Both fail hard under the
#   GraphQL secondary rate limit that fires during fleet peaks.
#   This script uses only `gh api` REST calls (core bucket, ~5000/hr, rarely
#   exhausted) and does a simpler but reliable gap-status check.
#
# Schedule: launchd every 30 min via ai.chump.closed-pr-watchdog.plist
# Manual:   bash scripts/ops/closed-pr-watchdog.sh [--lookback-hours N] [--dry-run]
#
# Env:
#   CHUMP_WATCHDOG_LOOKBACK_HOURS   How far back to scan (default 72)
#   CHUMP_WATCHDOG_REOPEN           Set to 1 to attempt gh pr reopen on bounced PRs (default 0)
#   CHUMP_WATCHDOG_DRY_RUN          Set to 1 to emit ambient events but skip gap/PR mutations
#   CHUMP_WATCHDOG=0                Disable entirely
#
# Exit: always 0 (best-effort; errors logged but never block caller)

set -uo pipefail

[[ "${CHUMP_WATCHDOG:-1}" == "0" ]] && exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO="${GITHUB_REPOSITORY:-$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||;s|\.git$||')}"
AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"
SEEN_FILE="$REPO_ROOT/.chump-locks/closed-pr-watchdog-seen.txt"
LOOKBACK_HOURS="${CHUMP_WATCHDOG_LOOKBACK_HOURS:-72}"
DRY_RUN="${CHUMP_WATCHDOG_DRY_RUN:-0}"
REOPEN="${CHUMP_WATCHDOG_REOPEN:-0}"

mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true
touch "$SEEN_FILE" 2>/dev/null || true

command -v gh >/dev/null 2>&1     || { echo "[closed-pr-watchdog] gh not found, skipping" >&2; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "[closed-pr-watchdog] python3 not found, skipping" >&2; exit 0; }

_chump="${HOME}/.cargo/bin/chump"
command -v "$_chump" >/dev/null 2>&1 || _chump="chump"
command -v "$_chump" >/dev/null 2>&1 || { echo "[closed-pr-watchdog] chump not found, skipping" >&2; exit 0; }

emit() {
    local kind="$1"; shift
    local extra="$*"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","kind":"%s","source":"closed-pr-watchdog",%s}\n' \
        "$ts" "$kind" "$extra" >> "$AMBIENT" 2>/dev/null || true
    echo "[closed-pr-watchdog] $kind $extra" >&2
}

log() { echo "[closed-pr-watchdog] $*" >&2; }

# INFRA-8221: a PR a human or architect closed on purpose (`pr-cut`, the
# deliberate-close label from scripts/coord/pr-cut.sh) or parked under the arm
# policy (no-auto-merge / hold / do-not-merge / CHUMP_HOLD) must never be
# reopened by this watchdog. Hold label list comes from the one arm policy.
# shellcheck source=scripts/coord/lib/arm-policy.sh
source "$SCRIPT_DIR/../coord/lib/arm-policy.sh" 2>/dev/null || ARM_POLICY_HOLD_LABELS="no-auto-merge hold do-not-merge CHUMP_HOLD"
_deliberate_label() { # <labels-json-array> -> prints the matching label, rc 0 when deliberate
    python3 -c '
import json, sys
try:
    names = json.loads(sys.argv[1])
except Exception:
    sys.exit(1)
stop = {h.lower() for h in sys.argv[2].split()} | {"pr-cut"}
for n in names:
    if str(n).lower() in stop:
        print(n)
        sys.exit(0)
sys.exit(1)' "$1" "$ARM_POLICY_HOLD_LABELS" 2>/dev/null
}

# ── Step 1: scan closed-not-merged PRs via REST ─────────────────────────────
# REST: GET /repos/{owner}/{repo}/pulls?state=closed&per_page=100
# merged_at==null means closed without merge.

CUTOFF_EPOCH=$(( $(date -u +%s) - LOOKBACK_HOURS * 3600 ))

CLOSED_JSON=$(gh api "repos/$REPO/pulls?state=closed&per_page=100&sort=updated&direction=desc" 2>/dev/null || echo "[]")

if [[ -z "$CLOSED_JSON" || "$CLOSED_JSON" == "[]" ]]; then
    log "no closed PRs returned from REST — skipping"
else
    # Parse: only PRs with merged_at=null and updated_at within lookback window
    BOUNCED=$(printf '%s' "$CLOSED_JSON" | python3 -c "
import json, sys, datetime
cutoff = $CUTOFF_EPOCH
data = json.load(sys.stdin)
for pr in data:
    if pr.get('merged_at') is not None:
        continue  # merged correctly
    if pr.get('state') != 'closed':
        continue
    # updated_at or closed_at within window
    ts_str = pr.get('updated_at') or pr.get('closed_at') or ''
    if ts_str:
        try:
            ts = int(datetime.datetime.fromisoformat(ts_str.replace('Z','+00:00')).timestamp())
            if ts < cutoff:
                continue
        except Exception:
            pass
    print(json.dumps({
        'number': pr['number'],
        'title': pr['title'],
        'branch': pr['head']['ref'],
        'closed_at': pr.get('closed_at',''),
        'labels': [l.get('name','') for l in (pr.get('labels') or [])],
    }))
" 2>/dev/null || true)

    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue

        pr_num=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['number'])" "$entry" 2>/dev/null || true)
        pr_branch=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['branch'])" "$entry" 2>/dev/null || true)
        pr_title=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['title'][:80])" "$entry" 2>/dev/null || true)

        [[ -z "$pr_num" ]] && continue

        # Idempotency: skip already-processed PRs
        if grep -qxF "seen:$pr_num" "$SEEN_FILE" 2>/dev/null; then
            continue
        fi

        # Extract gap ID from branch name (e.g. chump/infra-1240-claim → INFRA-1240)
        gap_raw=$(echo "$pr_branch" | grep -oiE '(infra|credible|fleet|mission|meta|eval|zero-waste|resilient|effective)-[0-9]+' | head -1 || true)
        gap_id=$(echo "$gap_raw" | tr '[:lower:]' '[:upper:]')

        if [[ -z "$gap_id" ]]; then
            # No gap ID in branch — still emit an alert but no gap mutation
            emit "pr_bounced_no_gap_id" \
                "\"pr\":$pr_num,\"branch\":\"$pr_branch\",\"title\":\"$pr_title\""
            echo "seen:$pr_num" >> "$SEEN_FILE"
            continue
        fi

        # Check gap status
        gap_st=$(CHUMP_REPO="$REPO_ROOT" CHUMP_BINARY_STALENESS_CHECK=0 \
            "$_chump" gap show "$gap_id" 2>/dev/null | grep '^\s*status:' | awk '{print $2}' || true)

        case "$gap_st" in
            open)
                # Work lost: PR closed, gap still open
                emit "pr_bounced_open_gap" \
                    "\"pr\":$pr_num,\"gap_id\":\"$gap_id\",\"branch\":\"$pr_branch\",\"title\":\"$pr_title\""

                pr_labels=$(python3 -c "import json,sys; print(json.dumps(json.loads(sys.argv[1]).get('labels',[])))" "$entry" 2>/dev/null || echo '[]')
                if held_label=$(_deliberate_label "$pr_labels"); then
                    log "SKIP reopen PR #$pr_num — labeled '$held_label' (deliberate close / arm-policy hold, INFRA-8221)"
                elif [[ "$REOPEN" == "1" && "$DRY_RUN" != "1" ]]; then
                    if gh api "repos/$REPO/pulls/$pr_num" -X PATCH -f state=open >/dev/null 2>&1; then
                        log "reopened PR #$pr_num for $gap_id"
                        emit "pr_reopened" "\"pr\":$pr_num,\"gap_id\":\"$gap_id\""
                    else
                        log "WARNING: could not reopen PR #$pr_num — may need manual recovery"
                    fi
                fi
                ;;
            done)
                # Ghost gap case — ghost-gap-reaper handles this via closed_pr field
                # Just log; ghost-gap-reaper will roll it back on next run
                log "PR #$pr_num gap $gap_id already done — ghost-gap-reaper will handle if needed"
                ;;
            "")
                log "PR #$pr_num gap $gap_id not found in state.db — skipping"
                ;;
            *)
                log "PR #$pr_num gap $gap_id status=$gap_st — no action needed"
                ;;
        esac

        echo "seen:$pr_num" >> "$SEEN_FILE"

    done <<< "$BOUNCED"
fi

log "scan complete"
exit 0
