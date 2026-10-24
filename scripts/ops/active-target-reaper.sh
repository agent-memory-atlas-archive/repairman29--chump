#!/usr/bin/env bash
# active-target-reaper.sh — Purge `target/` directories in linked worktrees
# that haven't been touched recently. Companion to stale-worktree-reaper.sh:
# that one removes worktrees whose branches are merged; this one keeps active
# worktrees on disk but reclaims their build cache when they go quiet.
#
# Why: each worktree's `target/` is 7-11 GB after `cargo clippy` / `cargo
# test`. With 20+ active worktrees that's 150+ GB. We've hit "disk full"
# mid-session twice. After-ship purge already runs in bot-merge.sh, but
# long-lived worktrees that haven't shipped yet (or that ran tests for
# review then sat) keep the cache forever.
#
# What it does (per worktree — scans .claude/worktrees/ AND /tmp/chump-*):
#   1. Skip if no target/ directory.
#   2. Skip if target/ mtime is fresher than --age-days (default 1d).
#   3. Skip if .chump-no-reap exists in the worktree (opt-out).
#   4. Skip if any active lease in .chump-locks/*.json names this worktree
#      AND target/ mtime is fresher than 1 day (active session).
#   5. Skip if any process has cwd inside the worktree (active cargo run?).
#   6. Otherwise rm -rf <worktree>/target.
#
# Usage:
#   ./scripts/ops/active-target-reaper.sh              # default: --dry-run
#   ./scripts/ops/active-target-reaper.sh --execute    # actually purge
#   ./scripts/ops/active-target-reaper.sh --execute --age-days 2
#
# Install every 4h via launchd:
#   ./scripts/setup/install-active-target-reaper-launchd.sh

set -euo pipefail

DRY_RUN=1
AGE_DAYS=1
# INFRA-1124: CHUMP_REAPER_SAFETY_CHECK=0 disables heartbeat+index safety checks
# (same knob as stale-worktree-reaper.sh; for testing only).
REAPER_SAFETY_CHECK="${CHUMP_REAPER_SAFETY_CHECK:-1}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --execute) DRY_RUN=0; shift ;;
        --age-days) AGE_DAYS="$2"; shift 2 ;;
        -h|--help)
            grep -E '^# ' "$0" | sed 's/^# //'
            exit 0
            ;;
        *) echo "unknown arg: $1" >&2; exit 64 ;;
    esac
done

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# When run from a linked worktree, hop to the main checkout via git-common-dir
# so we can see all sibling worktrees (the reaper's whole point).
if command -v git >/dev/null 2>&1; then
    common_dir=$(cd "$REPO" && git rev-parse --git-common-dir 2>/dev/null || true)
    if [[ -n "$common_dir" ]]; then
        # common_dir is .git or /abs/path/.git
        case "$common_dir" in
            /*) REPO="$(dirname "$common_dir")" ;;
            *)  REPO="$(cd "$REPO/$(dirname "$common_dir")" && pwd)" ;;
        esac
    fi
fi
# INFRA-1053: harness-agnostic base. Default keeps the .claude/worktrees/
# convention so reaping behavior is unchanged for existing operators.
WORKTREES_DIR="${CHUMP_WORKTREE_BASE:-$REPO/.claude/worktrees}"
REAPER_REPO_ROOT="$REPO"
export REAPER_REPO_ROOT

# INFRA-1211: shared worktree scanning + lease check + event emission lib.
# shellcheck source=scripts/lib/worktree-iter.sh
source "$(dirname "$0")/../lib/worktree-iter.sh"
# shellcheck source=scripts/lib/lease.sh
source "$(dirname "$0")/../lib/lease.sh"
REAPER_NAME="${REAPER_NAME:-active-target}"

AGE_SECONDS=$((AGE_DAYS * 86400))
NOW=$(date +%s)
RECLAIMED_BYTES=0
PURGED=0
SKIPPED=0

# Build list of candidate worktrees via shared lib (INFRA-1211).
CANDIDATE_DIRS=()
while IFS= read -r _wt; do
    CANDIDATE_DIRS+=("$_wt")
done < <(CHUMP_WORKTREE_BASE="$WORKTREES_DIR" scan_worktrees)

for wt in "${CANDIDATE_DIRS[@]+"${CANDIDATE_DIRS[@]}"}"; do
    [[ -d "$wt" ]] || continue
    wt="${wt%/}"
    target="$wt/target"

    if [[ ! -d "$target" ]]; then
        continue
    fi

    if [[ -e "$wt/.chump-no-reap" ]]; then
        echo "SKIP $wt — .chump-no-reap present"
        emit_reaper_event "target_reap_skipped" "$target" "no_reap_marker"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    target_mtime=$(stat -c %Y "$target" 2>/dev/null || stat -f %m "$target" 2>/dev/null || echo 0)
    age=$((NOW - target_mtime))

    if [[ $age -lt $AGE_SECONDS ]]; then
        age_days=$((age / 86400))
        echo "SKIP $wt — target/ touched ${age_days}d ago (< ${AGE_DAYS}d)"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # RESILIENT-1609: never reap the target/ of a worktree with a live bot-merge ship.
    if [[ "$REAPER_SAFETY_CHECK" == "1" ]] && declare -F wt_has_live_bot_merge >/dev/null 2>&1 && wt_has_live_bot_merge "$wt"; then
        echo "SKIP $wt — live bot-merge ship (${WT_LIVE_BOT_MERGE_DETAIL:-?})"
        emit_reaper_event "worktree_reaper_skipped_active" "$wt" "bot_merge_live"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # RESILIENT-1623: fail closed if wt_has_active_lease is unavailable.
    if [[ "$REAPER_SAFETY_CHECK" == "1" ]] && ! declare -F wt_has_active_lease >/dev/null 2>&1; then
        echo "SKIP $wt — wt_has_active_lease unavailable (lease lib missing)"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # INFRA-1124/1211: Active-lease check via shared lib — wt_has_active_lease
    # checks heartbeat freshness and handles /private/tmp macOS aliasing.
    if [[ "$REAPER_SAFETY_CHECK" == "1" ]] && wt_has_active_lease "$wt" "${CHUMP_LEASE_HEARTBEAT_TTL_S:-600}"; then
        echo "SKIP $wt — active lease with fresh heartbeat"
        emit_reaper_event "worktree_reap_protected" "$wt" "active_lease_heartbeat_fresh" \
            "\"ttl_s\":${CHUMP_LEASE_HEARTBEAT_TTL_S:-600}"
        emit_reaper_event "worktree_reaper_skipped_active" "$wt" "active_lease"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # INFRA-1124: belt-and-suspenders — skip if .git/index touched within 5 min.
    # Catches in-flight sessions whose lease has no worktree field (pre-fix leases)
    # or whose heartbeat expired but a commit is literally in progress.
    if [[ "$REAPER_SAFETY_CHECK" == "1" ]]; then
        _git_index=""
        if [[ -f "$wt/.git" ]]; then
            _gitdir=$(sed 's/^gitdir: //' "$wt/.git" 2>/dev/null || true)
            [[ -n "$_gitdir" && -f "$_gitdir/index" ]] && _git_index="$_gitdir/index"
        elif [[ -f "$wt/.git/index" ]]; then
            _git_index="$wt/.git/index"
        fi
        if [[ -n "$_git_index" ]]; then
            _idx_fresh=$(find "$_git_index" -mmin -5 2>/dev/null | head -1 || true)
            if [[ -n "$_idx_fresh" ]]; then
                echo "SKIP $wt — .git/index touched within 5 min (in-flight)"
                emit_reaper_event "worktree_reaper_skipped_active" "$wt" "git_index_fresh"
                SKIPPED=$((SKIPPED + 1))
                continue
            fi
        fi
    fi

    # Process check — skip if any process cwd is inside this worktree.
    if command -v lsof >/dev/null 2>&1; then
        if lsof -F n +D "$wt" 2>/dev/null | grep -q .; then
            echo "SKIP $wt — process has files open inside"
            emit_reaper_event "target_reap_skipped" "$target" "active_build"
            SKIPPED=$((SKIPPED + 1))
            continue
        fi
    fi

    size_bytes=$(du -sk "$target" 2>/dev/null | awk '{print $1 * 1024}' || echo 0)
    size_mb=$((size_bytes / 1024 / 1024))

    if [[ $DRY_RUN -eq 1 ]]; then
        echo "DRY-RUN would purge $target (${size_mb}MB, ${age} sec old)"
    else
        echo "PURGE $target (${size_mb}MB)"
        rm -rf "$target"
    fi
    PURGED=$((PURGED + 1))
    RECLAIMED_BYTES=$((RECLAIMED_BYTES + size_bytes))
done

reclaimed_mb=$((RECLAIMED_BYTES / 1024 / 1024))
mode="DRY-RUN"
[[ $DRY_RUN -eq 0 ]] && mode="EXECUTE"
echo ""
echo "[$mode] purged=$PURGED skipped=$SKIPPED reclaimed=${reclaimed_mb}MB"
