#!/usr/bin/env bash
# worktree-prune.sh — clean up stale agent worktrees + lease files.
#
# After a multi-agent sprint we accumulate dozens of worktrees in
# .claude/worktrees/ that correspond to:
#   - Branches whose PRs already merged → safe to delete
#   - Branches whose PRs were closed without merge → safe to delete
#   - Branches still ahead of main with no PR yet → KEEP (active WIP)
#   - Lease files past their expires_at TTL → safe to delete
#
# This script does the boring sweep work safely: it never deletes a
# worktree that has uncommitted changes or untracked files (would lose
# work), never deletes a branch that's the local HEAD of a non-main
# worktree, and prints exactly what it would do under --dry-run.
#
# Usage:
#   scripts/coord/worktree-prune.sh                   # dry-run by default (safe)
#   scripts/coord/worktree-prune.sh --execute         # actually delete
#   scripts/coord/worktree-prune.sh --keep-merged     # only prune leases, leave worktrees
#
# Output is a per-worktree status table:
#   wt-name  branch  pr-state  reason  action
#
# Exits 0 if all OK, 1 if any worktree has uncommitted changes
# (those are flagged but not auto-deleted).

set -euo pipefail

DRY_RUN=1
KEEP_MERGED=0
# INFRA-1053: harness-agnostic base. Default preserves the
# .claude/worktrees/ convention (zero behavior change for existing operators).
WORKTREE_ROOT="${CHUMP_WORKTREE_BASE:-.claude/worktrees}"
# INFRA-1124: CHUMP_REAPER_SAFETY_CHECK=0 disables heartbeat+index safety checks.
REAPER_SAFETY_CHECK="${CHUMP_REAPER_SAFETY_CHECK:-1}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --execute)      DRY_RUN=0 ;;
        --keep-merged)  KEEP_MERGED=1 ;;
        -h|--help)
            sed -n '2,28p' "$0"
            exit 0
            ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
if [[ -z "$REPO_ROOT" ]]; then
    echo "error: not in a git repo" >&2
    exit 2
fi
# When run from inside a worktree, .claude/worktrees/ is at the MAIN repo,
# not the current worktree. Resolve to the main worktree path via
# git worktree list (the first entry is always the main one).
# INFRA-2641: awk's early `exit` closes stdin before `git worktree list`
# finishes writing on repos with many worktrees, so `git` gets SIGPIPE and
# the pipeline (under `set -o pipefail`) reports 141 instead of the printed
# value — tripping `set -e` and killing the whole script before it prunes
# anything. Reading to EOF (guarded by a "first match" flag) avoids the
# SIGPIPE race entirely.
MAIN_REPO="$(git worktree list --porcelain 2>/dev/null | awk '/^worktree / && !p {print $2; p=1}')"
if [[ -z "$MAIN_REPO" || ! -d "$MAIN_REPO/$WORKTREE_ROOT" ]]; then
    MAIN_REPO="$REPO_ROOT"
fi
cd "$MAIN_REPO"

# INFRA-1211: shared worktree scanning + lease check + event emission lib.
# shellcheck source=scripts/lib/worktree-iter.sh
# shellcheck disable=SC1091
source "$(dirname "$0")/../lib/worktree-iter.sh"
# shellcheck source=scripts/lib/lease.sh
# shellcheck disable=SC1091
source "$(dirname "$0")/../lib/lease.sh"
REAPER_NAME="${REAPER_NAME:-worktree-prune}"
REAPER_REPO_ROOT="$MAIN_REPO"
export REAPER_REPO_ROOT

# Returns 0 if wt_dir has a fresh active lease or a fresh .git/index.
# Delegates lease scanning to wt_has_active_lease() from worktree-iter.sh.
_prune_is_inflight() {
    local wt_dir="$1"
    [[ "$REAPER_SAFETY_CHECK" != "1" ]] && return 1
    # RESILIENT-1609: a live bot-merge ship (fresh .steps file or a process
    # whose cwd is this worktree) protects it even with no lease / idle index.
    if declare -F wt_has_live_bot_merge >/dev/null 2>&1 && wt_has_live_bot_merge "$wt_dir" "$MAIN_REPO/.chump-locks"; then
        emit_reaper_event "worktree_reaper_skipped_active" "$wt_dir" "bot_merge_live" \
            "\"detail\":\"${WT_LIVE_BOT_MERGE_DETAIL:-}\""
        return 0
    fi
    # RESILIENT-1623: fail closed if wt_has_active_lease is unavailable.
    if ! declare -F wt_has_active_lease >/dev/null 2>&1; then
        emit_reaper_event "worktree_reaper_skipped_active" "$wt_dir" "lease_lib_missing"
        return 0
    fi
    # Lease check via shared lib (replaces the old _PRUNE_ACTIVE_WORKTREES loop).
    if wt_has_active_lease "$wt_dir" 900; then
        emit_reaper_event "worktree_reaper_skipped_active" "$wt_dir" "active_lease"
        return 0
    fi
    # .git/index mtime check (belt-and-suspenders for pre-fix leases).
    # INFRA-1347: bumped from 5 → 30 minutes. Agents spend 10+ min in
    # cargo build between edits; 5 min was too tight and ate live work
    # twice during the 2026-05-15 session.
    local _gi=""
    if [[ -f "$wt_dir/.git" ]]; then
        local _gd; _gd=$(sed 's/^gitdir: //' "$wt_dir/.git" 2>/dev/null || true)
        [[ -n "$_gd" && -f "$_gd/index" ]] && _gi="$_gd/index"
    elif [[ -f "$wt_dir/.git/index" ]]; then
        _gi="$wt_dir/.git/index"
    fi
    if [[ -n "$_gi" ]]; then
        # CHUMP_REAPER_INDEX_MMIN: override threshold in minutes (default 30).
        # Set to "skip" (or "0") in CI tests to bypass this guard entirely so that
        # deeper checks like unpushed_commits can be exercised.
        local _mmin="${CHUMP_REAPER_INDEX_MMIN:-30}"
        if [[ "$_mmin" != "0" && "$_mmin" != "skip" ]]; then
            local _fresh; _fresh=$(find "$_gi" -mmin -"$_mmin" 2>/dev/null | head -1 || true)
            if [[ -n "$_fresh" ]]; then
                emit_reaper_event "worktree_reaper_skipped_active" "$wt_dir" "git_index_fresh"
                return 0
            fi
        fi
    fi
    return 1
}

# INFRA-1347: returns 0 if the worktree's branch has commits not yet
# pushed to its upstream. Distinct from `has_changes` (working-tree
# dirty) and `_prune_is_inflight` (lease / fresh index). Used by the
# CLOSED-PR and NO-PR case branches in §2 — those paths previously
# deleted worktrees with committed-but-unpushed local work.
_prune_has_unpushed_commits() {
    local wt_dir="$1"
    [[ "$REAPER_SAFETY_CHECK" != "1" ]] && return 1
    # RESILIENT-1638: delegate to shared wt_has_unpushed_commits predicate in worktree-iter.sh.
    if wt_has_unpushed_commits "$wt_dir" "origin"; then
        emit_reaper_event "worktree_reaper_skipped_active" "$wt_dir" "unpushed_commits"
        return 0
    fi
    return 1
}

if [[ $DRY_RUN -eq 1 ]]; then
    echo "[worktree-prune] DRY RUN (no changes will be made; pass --execute to delete)"
fi
echo

# ── 1. Stale lease files ─────────────────────────────────────────────────────
echo "── stale lease files (.chump-locks/*.json past expires_at) ──"
# INFRA-1224: migrated 22-line python3 expires_at parser → scripts/lib/lease.sh.
# INFRA-1347: was `git rev-parse --show-toplevel` which broke when the script
# runs against a synthetic fake-repo (CI test, recovery tools) — falls back
# to the script-relative path that already sourced lease.sh at line 70.
# shellcheck source=../lib/lease.sh
# shellcheck disable=SC1091
# (lease.sh already sourced above; no-op re-source is cheap and idempotent.)
source "$(dirname "$0")/../lib/lease.sh"
stale_count=0
while IFS= read -r lease; do
    [[ -f "$lease" ]] || continue
    if lease_is_expired "$lease"; then
        stale_count=$((stale_count + 1))
        if [[ $DRY_RUN -eq 1 ]]; then
            echo "  WOULD DELETE  $lease"
        else
            rm "$lease" && echo "  DELETED       $lease"
        fi
    fi
done < <(lease_iter)
echo "  ($stale_count stale leases found)"
echo

if [[ $KEEP_MERGED -eq 1 ]]; then
    echo "[worktree-prune] --keep-merged set, skipping worktree pruning"
    exit 0
fi

# ── 2. Worktrees whose PR is merged or closed without merge ──────────────────
echo "── worktree pruning ──"
printf "  %-30s %-40s %-12s %s\n" "WORKTREE" "BRANCH" "PR-STATE" "ACTION"
printf "  %-30s %-40s %-12s %s\n" "--------" "------" "--------" "------"

dirty_count=0
pruned_count=0
kept_count=0

if [[ ! -d "$WORKTREE_ROOT" ]]; then
    echo "  (no worktree root at $WORKTREE_ROOT)"
    exit 0
fi

# INFRA-1211: use shared worktree-scanning primitives.
for wt_dir in $(scan_worktrees --no-tmp); do
    [[ -d "$wt_dir" ]] || continue
    wt_name=$(basename "$wt_dir")

    # Get the branch this worktree is on
    branch=$(cd "$wt_dir" 2>/dev/null && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
    branch_short="${branch#refs/heads/}"

    # Check if there are uncommitted changes (tracked-file modifications)
    # INFRA-1211: Use shared wt_is_dirty logic if available.
    if wt_is_dirty "$wt_dir"; then
        # INFRA-1347: emit a GRANULAR skip reason — untracked-unignored files vs
        # dirty tracked files. INFRA-3431's wt_is_dirty consolidation collapsed
        # both to dirty_working_tree, dropping the untracked_unignored signal the
        # reaper-safety contract (and test-worktree-prune-protects-live-edits.sh)
        # relies on. If every porcelain entry is untracked ('??'), it's untracked-
        # unignored; otherwise a tracked modification is present.
        _wt_porcelain="$(git -C "$wt_dir" status --porcelain 2>/dev/null)"
        if [[ -z "$(grep -v '^??' <<<"$_wt_porcelain")" ]]; then
            _wt_skip_reason="untracked_unignored"
        else
            _wt_skip_reason="dirty_working_tree"
        fi
        printf "  %-30s %-40s %-12s %s\n" \
            "$wt_name" "$branch_short" "(dirty/untracked)" "KEEP — uncommitted changes or untracked files"
        dirty_count=$((dirty_count + 1))
        emit_reaper_event "worktree_reaper_skipped_active" "$wt_dir" "$_wt_skip_reason"
        continue
    fi

    # Find the PR for this branch (INFRA-1081: cache-first)
    _cache_json=""
    if command -v sqlite3 >/dev/null 2>&1 && [[ -f "$(dirname "$0")/lib/github_cache.sh" ]]; then
        # If github_cache.sh is sourced, _cache_db_path is available.
        # But we need to make sure it's actually defined or use the fallback.
        _db=""
        if command -v _cache_db_path >/dev/null 2>&1; then
            _db="$(_cache_db_path)"
        else
            _db="${MAIN_REPO}/.chump/github_cache.db"
        fi
        if [[ -f "$_db" ]]; then
            _cache_json="$(sqlite3 "$_db" "SELECT raw_payload_json FROM pr_state WHERE head_ref = '$branch_short' ORDER BY updated_at_api DESC LIMIT 1")"
        fi
    fi

    if [[ -n "${_cache_json:-}" ]]; then
        pr_state=$(printf '%s' "$_cache_json" | python3 -c "import json, sys; print(json.load(sys.stdin).get('state', ''))" 2>/dev/null || echo "?")
        pr_num=$(printf '%s' "$_cache_json" | python3 -c "import json, sys; print(json.load(sys.stdin).get('number', ''))" 2>/dev/null || echo "")
    else
        pr_state=$(gh pr list --state all --head "$branch_short" --json state \
            -q '.[0].state // "(none)"' 2>/dev/null || echo "?")
        pr_num=$(gh pr list --state all --head "$branch_short" --json number \
            -q '.[0].number // ""' 2>/dev/null || echo "")
    fi

    case "$pr_state" in
        MERGED)
            if _prune_is_inflight "$wt_dir"; then
                action="KEEP — in-flight (active lease or fresh .git/index)"
                kept_count=$((kept_count + 1))
            elif _prune_has_unpushed_commits "$wt_dir"; then
                action="KEEP — unpushed local commits (PR #$pr_num merged)"
                kept_count=$((kept_count + 1))
            else
                action="PRUNE"
                pruned_count=$((pruned_count + 1))
                if [[ $DRY_RUN -eq 0 ]]; then
                    git worktree remove "$wt_dir" --force >/dev/null 2>&1 || true
                    git branch -D "$branch_short" >/dev/null 2>&1 || true
                    action="PRUNED"
                else
                    action="WOULD PRUNE (merged PR #$pr_num)"
                fi
            fi
            ;;
        CLOSED)
            if _prune_is_inflight "$wt_dir"; then
                action="KEEP — in-flight (active lease or fresh .git/index)"
                kept_count=$((kept_count + 1))
            elif _prune_has_unpushed_commits "$wt_dir"; then
                # INFRA-1347: PR closed without merge — but local has commits
                # never pushed. Refuse delete; operator decides keep vs salvage.
                action="KEEP — unpushed local commits (PR #$pr_num closed)"
                kept_count=$((kept_count + 1))
            else
                action="PRUNE"
                pruned_count=$((pruned_count + 1))
                if [[ $DRY_RUN -eq 0 ]]; then
                    git worktree remove "$wt_dir" --force >/dev/null 2>&1 || true
                    git branch -D "$branch_short" >/dev/null 2>&1 || true
                    action="PRUNED"
                else
                    action="WOULD PRUNE (closed PR #$pr_num)"
                fi
            fi
            ;;
        OPEN)
            action="KEEP — PR #$pr_num still open"
            kept_count=$((kept_count + 1))
            ;;
        *)
            # No PR. RESILIENT-1638: shared wt_has_unpushed_commits check.
            ahead=0
            if wt_has_unpushed_commits "$wt_dir" "origin"; then
                ahead="${WT_UNPUSHED_COUNT:-1}"
            fi
            if [[ "$ahead" -gt 0 ]]; then
                action="KEEP — $ahead WIP commits, no PR yet"
                kept_count=$((kept_count + 1))
                # INFRA-1347: emit a structured reason so the audit
                # trail surfaces what saved the worktree (operators ask
                # "why didn't the reaper take it?" — answer: unpushed work).
                emit_reaper_event "worktree_reaper_skipped_active" "$wt_dir" "unpushed_commits"
            elif _prune_is_inflight "$wt_dir"; then
                action="KEEP — in-flight (active lease or fresh .git/index)"
                kept_count=$((kept_count + 1))
            else
                action="PRUNE"
                pruned_count=$((pruned_count + 1))
                if [[ $DRY_RUN -eq 0 ]]; then
                    git worktree remove "$wt_dir" --force >/dev/null 2>&1 || true
                    git branch -D "$branch_short" >/dev/null 2>&1 || true
                    action="PRUNED"
                else
                    action="WOULD PRUNE (no PR, no commits ahead)"
                fi
            fi
            ;;
    esac

    printf "  %-30s %-40s %-12s %s\n" \
        "$wt_name" "$branch_short" "$pr_state" "$action"
done

echo
echo "── summary ──"
echo "  pruned:  $pruned_count worktree(s)"
echo "  kept:    $kept_count worktree(s) (open PR or WIP)"
echo "  dirty:   $dirty_count worktree(s) (uncommitted or untracked — investigate manually)"
echo "  leases:  $stale_count stale lease(s)"

if [[ $DRY_RUN -eq 1 ]]; then
    echo
    echo "  Re-run with --execute to actually delete."
fi

if [[ $dirty_count -gt 0 ]]; then
    exit 1
fi
exit 0
