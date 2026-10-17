#!/usr/bin/env bash
# pr-repair-rebase.sh — INFRA-727: rebase open fleet PRs with CI failures
# onto latest main and force-push to trigger CI re-run.
#
# Many fleet CI failures are caused by stale branches missing fixes already
# on main (clippy lint waves, test fixture updates, etc.). A rebase picks
# up those fixes and CI re-runs cleanly.
#
# Runs as part of the worker loop (before picking a new gap) or standalone.
# For each open PR with failing required checks:
#   1. Skip if PR is less than PR_REPAIR_MIN_AGE_S old (default 600s)
#   2. Skip if branch was already rebased recently (cooldown)
#   3. Checkout branch, rebase onto origin/main
#   4. If rebase succeeds (no conflicts): force-push → CI re-runs
#   5. If rebase has conflicts: skip (needs manual fix or fleet gap)
#   6. Arm auto-merge if not already armed
#
# Exit codes:
#   0  ran cleanly (repaired 0+ PRs)
#   1  precondition failure
#
# Env:
#   CHUMP_PR_REPAIR=0            bypass — exit 0 immediately
#   PR_REPAIR_MAX_PRS            max PRs to process per run (default 5)
#   PR_REPAIR_MIN_AGE_S          skip PRs younger than this (default 600)
#   PR_REPAIR_COOLDOWN_S         cooldown per branch (default 1800)

set -euo pipefail

if [[ "${CHUMP_PR_REPAIR:-1}" == "0" ]]; then
    exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$REPO_ROOT" ]]; then
    echo "[pr-repair] not in a git checkout" >&2
    exit 1
fi
cd "$REPO_ROOT"

# RESILIENT-1613: one arm policy — honor `no-auto-merge` / `Auto-merge: hold`.
# shellcheck source=scripts/coord/lib/arm-policy.sh
source "$(dirname "${BASH_SOURCE[0]}")/../coord/lib/arm-policy.sh"

command -v gh >/dev/null 2>&1 || { echo "[pr-repair] gh CLI not found" >&2; exit 1; }

MAX_PRS="${PR_REPAIR_MAX_PRS:-5}"
MIN_AGE_S="${PR_REPAIR_MIN_AGE_S:-600}"
COOLDOWN_S="${PR_REPAIR_COOLDOWN_S:-1800}"
COOLDOWN_DIR="$REPO_ROOT/.chump-locks/pr-repair-cooldown"
mkdir -p "$COOLDOWN_DIR"

COMMON_DIR="$(git rev-parse --git-common-dir 2>/dev/null)"
if [[ "$COMMON_DIR" == ".git" || "$COMMON_DIR" == "$REPO_ROOT/.git" ]]; then
    MAIN_REPO="$REPO_ROOT"
else
    MAIN_REPO="$(cd "$COMMON_DIR/.." && pwd)"
fi
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$MAIN_REPO/.chump-locks/ambient.jsonl}"

log() { echo "[pr-repair] $*" >&2; }

now_epoch() { date +%s; }

_now=$(now_epoch)
repaired=0
skipped_young=0
skipped_cooldown=0
skipped_conflict=0
processed=0

# Required checks — only consider PRs where these fail
REQUIRED_CHECKS="test|audit|ACP protocol smoke test|clippy|cargo-test"

# Get open PRs with their branch names and creation times
prs_json="$(gh pr list --state open --limit 50 \
    --json number,headRefName,createdAt,autoMergeRequest \
    2>/dev/null || echo '[]')"

# Filter to PRs that have failing checks
while IFS='|' read -r pr_num branch created_at has_auto_merge; do
    [[ -z "$pr_num" ]] && continue
    (( processed >= MAX_PRS )) && break

    # Skip PRs younger than MIN_AGE_S
    created_epoch="$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$created_at" +%s 2>/dev/null || echo 0)"
    if (( created_epoch == 0 )); then
        # fallback: try GNU date
        created_epoch="$(date -d "$created_at" +%s 2>/dev/null || echo 0)"
    fi
    age=$(( _now - created_epoch ))
    if (( age < MIN_AGE_S )); then
        skipped_young=$((skipped_young + 1))
        continue
    fi

    # Check if any required check is failing
    checks_output="$(gh pr checks "$pr_num" 2>&1 || true)"
    has_failure=0
    while IFS= read -r check_line; do
        check_name="$(echo "$check_line" | awk -F'\t' '{print $1}')"
        check_status="$(echo "$check_line" | awk -F'\t' '{print $2}')"
        if [[ "$check_status" == "fail" ]] && echo "$check_name" | grep -qE "$REQUIRED_CHECKS"; then
            has_failure=1
            break
        fi
    done <<< "$checks_output"

    if (( has_failure == 0 )); then
        continue
    fi

    # Check cooldown
    cooldown_file="$COOLDOWN_DIR/${pr_num}.ts"
    if [[ -f "$cooldown_file" ]]; then
        last_try="$(cat "$cooldown_file" 2>/dev/null || echo 0)"
        if (( _now - last_try < COOLDOWN_S )); then
            skipped_cooldown=$((skipped_cooldown + 1))
            continue
        fi
    fi

    log "PR #$pr_num ($branch) has failing required checks — attempting rebase"
    processed=$((processed + 1))

    # Record cooldown immediately (even if rebase fails)
    echo "$_now" > "$cooldown_file"

    # Fetch latest main
    git fetch origin main --quiet 2>/dev/null || true

    # Create ephemeral worktree for the rebase
    _wt_name="pr-repair-${pr_num}"
    # INFRA-1053: harness-agnostic base. Default keeps .claude/worktrees/.
    _wt_path="${CHUMP_WORKTREE_BASE:-$REPO_ROOT/.claude/worktrees}/$_wt_name"

    # Clean up any leftover worktree from a prior run
    if [[ -d "$_wt_path" ]]; then
        git worktree remove "$_wt_path" --force 2>/dev/null || rm -rf "$_wt_path"
    fi

    # Fetch the PR branch
    git fetch origin "$branch" --quiet 2>/dev/null || {
        log "  SKIP: could not fetch origin/$branch"
        continue
    }

    # Create worktree at the PR branch
    if ! git worktree add "$_wt_path" "origin/$branch" --detach 2>/dev/null; then
        log "  SKIP: could not create worktree for $branch"
        continue
    fi

    # Attempt rebase
    rebase_ok=0
    (
        cd "$_wt_path" || exit 1
        git checkout -B "$branch" "origin/$branch" 2>/dev/null || exit 1
        if git rebase origin/main 2>/dev/null; then
            exit 0
        else
            git rebase --abort 2>/dev/null || true
            exit 1
        fi
    ) && rebase_ok=1

    if (( rebase_ok == 1 )); then
        # Force-push the rebased branch
        if (cd "$_wt_path" && git push --force-with-lease origin "$branch" 2>/dev/null); then
            log "  OK: rebased and pushed $branch — CI will re-run"
            repaired=$((repaired + 1))

            # Arm auto-merge if not already armed.
            # INFRA-1223: route through centralized armer (5s spacing +
            # secondary-rate-limit backoff). Repair loops are a common
            # path to user-account mutation-limit penalties.
            # RESILIENT-1613: this push-then-arm pair is the 30-min-cooldown
            # re-armer that undid the architect's 02:27Z disarm of #5494 at
            # 02:52:37Z (force-push 02:52:27Z). A rebase repairs a branch; it
            # never overrides a hold. (The armer re-checks; this keeps the log
            # honest instead of claiming an arm that did not happen.)
            if [[ "$has_auto_merge" == "false" ]]; then
                if arm_policy_allows "$pr_num" "pr-repair-rebase.sh"; then
                    "${REPO_ROOT}/scripts/coord/auto-merge-armer.sh" --pr "$pr_num" 2>/dev/null || true
                    log "  armed auto-merge on #$pr_num"
                else
                    log "  #$pr_num held (no-auto-merge / Auto-merge: hold) — rebased, NOT armed"
                fi
            fi
        else
            log "  FAIL: rebase succeeded but push failed for $branch"
        fi
    else
        log "  SKIP: rebase conflict on $branch — needs manual fix"
        skipped_conflict=$((skipped_conflict + 1))
    fi

    # Clean up worktree
    git worktree remove "$_wt_path" --force 2>/dev/null || rm -rf "$_wt_path"

done < <(echo "$prs_json" | python3 -c "
import sys, json
prs = json.load(sys.stdin)
for p in prs:
    am = 'true' if p.get('autoMergeRequest') else 'false'
    print(f\"{p['number']}|{p['headRefName']}|{p['createdAt']}|{am}\")
" 2>/dev/null)

# Emit ambient event
_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"ts":"%s","event":"pr_repair_run","kind":"pr_repair","repaired":%d,"skipped_young":%d,"skipped_cooldown":%d,"skipped_conflict":%d,"processed":%d}\n' \
    "$_ts" "$repaired" "$skipped_young" "$skipped_cooldown" "$skipped_conflict" "$processed" \
    >> "$AMBIENT_LOG"

if (( repaired > 0 )); then
    log "repaired $repaired PR(s) via rebase"
fi

exit 0
