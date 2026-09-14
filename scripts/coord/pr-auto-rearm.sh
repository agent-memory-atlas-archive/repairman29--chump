#!/usr/bin/env bash
# scripts/coord/pr-auto-rearm.sh — INFRA-1907
#
# Safety-net daemon: sweep open PRs every 5 min; for any in BLOCKED state
# with auto-merge disarmed (autoMergeRequest == null), re-arm via
# `gh pr merge $pr --auto --squash`.
#
# Why: GitHub's auto-merge contract is per-tree. Force-push, update-branch,
# close+reopen, and branch-protection changes ALL silently disarm. Without
# a sweeper, PRs sit BLOCKED+OFF forever waiting for an operator to notice.
# Today's session lost 7 PRs to this exact pattern.
#
# Complements INFRA-1906 (pr-auto-rebase re-arms inline after its own
# update-branch). This daemon catches the OTHER disarm causes too.
#
# Throttle: same PR won't re-arm within 30 min (.chump-locks/pr-auto-rearm-state.jsonl)
# to avoid loops on a PR that's genuinely supposed to stay disarmed.
#
# Force-push intent (INFRA-1971): before re-evaluating a PR, check for a
# .chump-locks/force-push-intent-<branch_safe>.json marker file with mtime
# within the last 60s. If present, skip this PR to avoid closing it during
# a legitimate operator force-push (observed in PRs #2561 and #2566 on
# 2026-05-24/25). After the 60s TTL expires, normal re-arm logic resumes.
# Intent file written by scripts/dev/force-push-intent.sh.
# Bypass: CHUMP_PR_AUTO_REARM_NO_INTENT_CHECK=1.
#
# Bypass: CHUMP_PR_AUTO_REARM_DISABLED=1.

set -uo pipefail

# Quick bypass
[[ "${CHUMP_PR_AUTO_REARM_DISABLED:-0}" == "1" ]] && exit 0

# shellcheck source=../lib/orchestrator-log.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/orchestrator-log.sh"
orch_log_start "pr-auto-rearm.sh" "$@"
trap 'orch_log_end "pr-auto-rearm.sh" "$?"' EXIT

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
STATE="${CHUMP_PR_AUTO_REARM_STATE:-$REPO_ROOT/.chump-locks/pr-auto-rearm-state.jsonl}"
THROTTLE_MIN="${CHUMP_PR_AUTO_REARM_THROTTLE_MIN:-30}"
INTENT_TTL_SECS="${CHUMP_PR_AUTO_REARM_INTENT_TTL_SECS:-60}"
LOCKS_DIR="$REPO_ROOT/.chump-locks"
mkdir -p "$(dirname "$STATE")"
touch "$STATE"

# Compute cutoff: now - THROTTLE_MIN minutes (ISO-8601 UTC for string compare)
cutoff="$(perl -e 'use POSIX qw(strftime); print strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time - '"$THROTTLE_MIN"' * 60))' 2>/dev/null)"

# Last re-arm timestamp for this PR (within throttle window). Empty if none.
recent_rearm() {
    local pr="$1"
    awk -v pr="$pr" -v cutoff="$cutoff" -F'"' '
        $0 ~ ("\"pr\":" pr "[,}]") {
            # Extract ts (the second quoted string in the JSON line)
            if ($4 >= cutoff) { print $4; exit }
        }
    ' "$STATE"
}

# Check if a valid (within TTL) force-push intent file exists for a branch.
# Returns 0 (true) if intent is active, 1 (false) otherwise.
# Args: $1 = branch name (raw, with slashes)
force_push_intent_active() {
    local branch="$1"
    # Sanitize: replace / with _ to form filename
    local branch_safe="${branch//\//_}"
    local intent_file="$LOCKS_DIR/force-push-intent-${branch_safe}.json"
    [[ "${CHUMP_PR_AUTO_REARM_NO_INTENT_CHECK:-0}" == "1" ]] && return 1
    [[ -f "$intent_file" ]] || return 1
    # Check mtime within TTL using stat (integer seconds, compatible with macOS + Linux)
    local file_mtime now age
    # macOS: stat -f %m; Linux: stat -c %Y
    file_mtime="$(stat -f '%m' "$intent_file" 2>/dev/null || stat -c '%Y' "$intent_file" 2>/dev/null || echo 0)"
    now="$(date +%s)"
    age=$(( now - file_mtime ))
    if (( age < INTENT_TTL_SECS )); then
        return 0
    fi
    return 1
}

emit_deferred() {
    # scanner-anchor: "kind":"pr_auto_rearm_deferred_for_force_push_intent"
    local pr="$1" branch="$2"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","kind":"pr_auto_rearm_deferred_for_force_push_intent","pr":%s,"branch":"%s"}\n' \
        "$ts" "$pr" "$branch" >> "$AMBIENT"
}

emit() {
    local pr="$1" reason="${2:-}"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","kind":"pr_auto_rearmed","pr":%s,"prior_disarm_reason":"%s"}\n' \
        "$ts" "$pr" "$reason" >> "$AMBIENT"
}

record() {
    local pr="$1"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","pr":%s}\n' "$ts" "$pr" >> "$STATE"
}

# Query open PRs that are BLOCKED with auto-merge disarmed
PRS_JSON="$(gh pr list --state open --limit 60 \
    --json number,mergeStateStatus,autoMergeRequest 2>/dev/null || echo '[]')"

if [[ -z "$PRS_JSON" || "$PRS_JSON" == "[]" ]]; then
    echo "[pr-auto-rearm] no open PRs (or gh unavailable)"
    orch_log_step "no open PRs (or gh unavailable) — exiting"
    exit 0
fi

# Targets: state BLOCKED, autoMergeRequest is null (disarmed)
TARGETS="$(printf '%s' "$PRS_JSON" | jq -r '
    .[]
    | select(.mergeStateStatus == "BLOCKED")
    | select(.autoMergeRequest == null)
    | .number
')"

if [[ -z "$TARGETS" ]]; then
    echo "[pr-auto-rearm] no disarmed BLOCKED PRs (queue healthy)"
    orch_log_step "no disarmed BLOCKED PRs (queue healthy) — exiting"
    exit 0
fi

REARMED=0
THROTTLED=0
FAILED=0
DEFERRED=0
while IFS= read -r PR; do
    [[ -z "$PR" ]] && continue

    # Force-push intent check (INFRA-1971): resolve branch name and check for
    # a .chump-locks/force-push-intent-<branch_safe>.json marker within TTL.
    BRANCH=""
    if [[ "${CHUMP_PR_AUTO_REARM_NO_INTENT_CHECK:-0}" != "1" ]]; then
        BRANCH="$(gh pr view "$PR" --json headRefName --jq '.headRefName' 2>/dev/null || true)"
        if [[ -n "$BRANCH" ]] && force_push_intent_active "$BRANCH"; then
            echo "[pr-auto-rearm] DEFER #$PR — force-push intent active for branch '$BRANCH' (${INTENT_TTL_SECS}s grace window)"
            emit_deferred "$PR" "$BRANCH"
            DEFERRED=$((DEFERRED + 1))
            continue
        fi
    fi

    last="$(recent_rearm "$PR")"
    if [[ -n "$last" ]]; then
        echo "[pr-auto-rearm] SKIP #$PR — re-armed at $last (within ${THROTTLE_MIN}min throttle)"
        THROTTLED=$((THROTTLED + 1))
        continue
    fi
    echo "[pr-auto-rearm] re-arming #$PR..."
    orch_log_step "re-arming #$PR"
    if gh pr merge "$PR" --auto --squash >/dev/null 2>&1; then
        echo "[pr-auto-rearm] OK #$PR"
        orch_log_step "re-armed #$PR OK"
        emit "$PR" "blocked_disarmed_safety_sweep"
        record "$PR"
        REARMED=$((REARMED + 1))
    else
        echo "[pr-auto-rearm] FAIL #$PR — gh pr merge --auto returned non-zero"
        orch_log_step "re-arm FAILED #$PR"
        FAILED=$((FAILED + 1))
    fi
done <<< "$TARGETS"

echo "[pr-auto-rearm] done — rearmed=$REARMED throttled=$THROTTLED failed=$FAILED deferred=$DEFERRED"
orch_log_step "done rearmed=$REARMED throttled=$THROTTLED failed=$FAILED deferred=$DEFERRED"
exit 0
