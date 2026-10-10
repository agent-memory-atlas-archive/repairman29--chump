#!/usr/bin/env bash
# scripts/coord/lib/pr_rebase.sh — RESILIENT-622 (RESILIENT-083 slice)
#
# Shared rebase helper: checks the target branch's "strict" (require
# up-to-date-before-merge) branch-protection flag via a short-TTL
# file-based cache, and only runs `gh pr update-branch --rebase` when
# strict=true. Skips (exit 0, no rebase) when strict=false — rebasing a
# PR whose base branch doesn't require it is wasted churn.
#
# Usage (executable):
#   scripts/coord/lib/pr_rebase.sh <pr-number> <owner/repo> [base-branch]
#
# Usage (sourced by other daemons):
#   source "$(dirname "$0")/lib/pr_rebase.sh"
#   pr_rebase_if_strict <pr-number> <owner/repo> [base-branch]
#
# Env:
#   CHUMP_PR_REBASE_CACHE_DIR   — cache dir (default: <repo>/.chump-locks/branch-protection-cache)
#   CHUMP_PR_REBASE_CACHE_TTL_S — cache TTL seconds (default: 60)

set -euo pipefail

_PR_REBASE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# branch_protection_strict <owner/repo> <base-branch>
# stdout: "true" or "false"
# Cache: file-based, TTL 60s default, one file per repo+branch pair.
branch_protection_strict() {
    local repo="${1:?branch_protection_strict <owner/repo> <base-branch>}"
    local base="${2:?branch_protection_strict <owner/repo> <base-branch>}"

    local repo_root
    repo_root="$(cd "$_PR_REBASE_LIB_DIR/../../.." && pwd)"
    local cache_dir="${CHUMP_PR_REBASE_CACHE_DIR:-$repo_root/.chump-locks/branch-protection-cache}"
    local ttl_s="${CHUMP_PR_REBASE_CACHE_TTL_S:-60}"
    mkdir -p "$cache_dir"

    local cache_key
    cache_key="$(printf '%s' "${repo}_${base}" | tr '/ ' '__')"
    local cache_file="$cache_dir/${cache_key}.json"

    local now
    now=$(date +%s)

    if [ -f "$cache_file" ]; then
        local cached_ts cached_val
        cached_ts=$(sed -n 's/.*"ts":\([0-9]*\).*/\1/p' "$cache_file" 2>/dev/null || echo "")
        cached_val=$(sed -n 's/.*"strict":\([a-z]*\).*/\1/p' "$cache_file" 2>/dev/null || echo "")
        if [ -n "$cached_ts" ] && [ -n "$cached_val" ]; then
            local age=$(( now - cached_ts ))
            if [ "$age" -lt "$ttl_s" ]; then
                printf '%s\n' "$cached_val"
                return 0
            fi
        fi
    fi

    local strict="false"
    local protection_json
    protection_json=$(gh api "repos/${repo}/branches/${base}/protection" 2>/dev/null || echo '{}')
    if grep -q '"strict":[[:space:]]*true' <<< "$protection_json"; then
        strict="true"
    fi

    printf '{"ts":%s,"strict":%s}\n' "$now" "$strict" > "$cache_file"
    printf '%s\n' "$strict"
}

# pr_rebase_now <pr-number> <owner/repo>
# Unconditional rebase; for callers (pr-shepherd-daemon) that already applied
# their own strict/merge-queue gate.
pr_rebase_now() {
    local pr="${1:?pr_rebase_now <pr-number> <owner/repo>}"
    local repo="${2:?pr_rebase_now <pr-number> <owner/repo>}"
    CHUMP_GH_CALL_CRITICALITY=background gh pr update-branch "$pr" --rebase --repo "$repo"
}

# pr_rebase_if_strict <pr-number> <owner/repo> [base-branch]
pr_rebase_if_strict() {
    local pr="${1:?pr_rebase_if_strict <pr-number> <owner/repo> [base-branch]}"
    local repo="${2:?pr_rebase_if_strict <pr-number> <owner/repo> [base-branch]}"
    local base="${3:-main}"

    local strict
    strict=$(branch_protection_strict "$repo" "$base")

    if [ "$strict" = "true" ]; then
        echo "[pr_rebase] strict=true for ${repo}@${base} — rebasing PR #${pr}"
        gh pr update-branch "$pr" --rebase --repo "$repo"
    else
        echo "[pr_rebase] strict=false for ${repo}@${base} — skipping rebase for PR #${pr}"
        return 0
    fi
}

# Only run main-flow logic when executed directly (not sourced).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    if [ "${1:-}" = "--now" ]; then
        shift
        [ "$#" -ge 2 ] || { echo "usage: pr_rebase.sh --now <pr-number> <owner/repo>" >&2; exit 1; }
        pr_rebase_now "$@"
        exit $?
    fi
    if [ "$#" -lt 2 ]; then
        echo "usage: pr_rebase.sh [--now] <pr-number> <owner/repo> [base-branch]" >&2
        exit 1
    fi
    pr_rebase_if_strict "$@"
fi
