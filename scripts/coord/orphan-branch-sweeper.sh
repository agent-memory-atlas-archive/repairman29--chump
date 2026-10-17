#!/usr/bin/env bash
# scripts/coord/orphan-branch-sweeper.sh — INFRA-1450 (2026-05-16),
#   paginate + merged-fast-path + stash-before-delete — ZERO-WASTE-136 (2026-10-17)
#
# Sweeps remote branches that have no open PR. Two disposition classes:
#
#   1. Fully merged into the base branch (default `main`) — deleted
#      *immediately*, no age wait. These are spent exhaust: every commit is
#      already on main, so nothing is lost.
#   2. Unmerged but older than CHUMP_ORPHAN_BRANCH_AGE_DAYS (default 14) —
#      the tip is first pushed to a durable `refs/stash/<branch>` ref on
#      origin and recorded in the stash manifest (per
#      docs/process/STASHED_WORK.md), *then* the branch is deleted. Nothing
#      unmerged is destroyed without a recoverable stash.
#
# Complements branch-reaper.sh (which covers merged/closed PRs by PR age) by
# handling refs that predate the delete-branch-on-merge setting or were closed
# without merging long ago.
#
# The branch listing is paginated (per_page=100, page=N loop) so repos with
# >100 remote branches are swept in full. (A stubbed `gh` can emulate the page
# loop in tests; real `gh --paginate` relies on Link headers a stub can't
# provide, hence the explicit page param.)
#
# Usage:
#   orphan-branch-sweeper.sh [--dry-run] [--apply] [--age-days N]
#
# Options:
#   --dry-run       Print candidates (by name) without deleting (DEFAULT)
#   --apply         Actually stash + delete branches
#   --age-days N    Override age threshold (default: CHUMP_ORPHAN_BRANCH_AGE_DAYS or 14)
#
# Protected (never deleted):
#   main, master, develop, staging, release/*, gh-readonly-queue/*
#   Custom: CHUMP_ORPHAN_BRANCH_PROTECT_REGEX (anchored ERE, applied to full name)
#
# Env:
#   CHUMP_ORPHAN_BRANCH_BASE   Base branch for the merged check (default: main)
#   CHUMP_STASH_MANIFEST       Stash manifest path
#                              (default: docs/process/STASHED_BRANCHES.md)
#
# Exit codes:
#   0 — success
#   1 — GitHub API error or usage error

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/repo-paths.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/repo-paths.sh"

AMBIENT="${CHUMP_AMBIENT_LOG:-${LOCK_DIR:-$REPO_ROOT/.chump-locks}/ambient.jsonl}"
SWEEP_RUN_ID="sweep-$$-$(date +%s)"

# ── Argument parsing ─────────────────────────────────────────────────────────
DRY_RUN=1
AGE_DAYS="${CHUMP_ORPHAN_BRANCH_AGE_DAYS:-14}"
BASE_BRANCH="${CHUMP_ORPHAN_BRANCH_BASE:-main}"
STASH_MANIFEST="${CHUMP_STASH_MANIFEST:-$REPO_ROOT/docs/process/STASHED_BRANCHES.md}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)  DRY_RUN=1 ;;
        --apply)    DRY_RUN=0 ;;
        --age-days) shift; AGE_DAYS="$1" ;;
        --help|-h)
            echo "Usage: orphan-branch-sweeper.sh [--dry-run|--apply] [--age-days N]"
            exit 0 ;;
        *) echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
    shift
done

# ── Resolve NWO ──────────────────────────────────────────────────────────────
NWO="$(git -C "$REPO_ROOT" remote get-url chump 2>/dev/null \
    | sed -E 's|.*github\.com[:/]||; s|\.git$||')"
if [[ -z "$NWO" ]]; then
    NWO="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null \
        | sed -E 's|.*github\.com[:/]||; s|\.git$||')"
fi
if [[ -z "$NWO" ]]; then
    echo "[orphan-sweeper] ERROR: cannot resolve GitHub NWO." >&2
    exit 1
fi

# ── Built-in protected patterns ───────────────────────────────────────────────
BUILTIN_PROTECT="^(main|master|develop|staging)$|^(release|gh-readonly-queue)/"
CUSTOM_PROTECT="${CHUMP_ORPHAN_BRANCH_PROTECT_REGEX:-}"

is_protected() {
    local branch="$1"
    if echo "$branch" | grep -qE "$BUILTIN_PROTECT"; then return 0; fi
    if [[ -n "$CUSTOM_PROTECT" ]] && echo "$branch" | grep -qE "$CUSTOM_PROTECT"; then return 0; fi
    return 1
}

# ── Age threshold in seconds ─────────────────────────────────────────────────
AGE_SECS=$(( AGE_DAYS * 86400 ))
NOW=$(date +%s)

echo "[orphan-sweeper] NWO=$NWO base=$BASE_BRANCH age_threshold=${AGE_DAYS}d mode=$([ "$DRY_RUN" -eq 1 ] && echo dry-run || echo APPLY)"

# ── Fetch open PR head refs (cache-first) ────────────────────────────────────
# Prefer local github_cache.db; fall back to gh api.
OPEN_HEADS=""
CACHE_DB="$REPO_ROOT/.chump/github_cache.db"
CACHE_LIB="$SCRIPT_DIR/../lib/github_cache.sh"
if [[ -f "$CACHE_DB" ]] && [[ -f "$CACHE_LIB" ]]; then
    # shellcheck source=../lib/github_cache.sh
    # shellcheck disable=SC1091
    source "$CACHE_LIB" 2>/dev/null || true
    OPEN_HEADS="$(cache_query_open_prs 2>/dev/null | awk -F'\t' '{print $3}' || true)"
fi
if [[ -z "$OPEN_HEADS" ]]; then
    OPEN_HEADS="$(gh api "repos/$NWO/pulls?state=open&per_page=100" \
        --jq '.[].head.ref' 2>/dev/null || true)"
fi

# Build a newline-delimited list of open PR head branches for grep lookup.
# (Avoid declare -A: macOS ships bash 3 which lacks associative arrays.)
OPEN_PR_HEADS_FILE="$(mktemp)"
trap 'rm -f "$OPEN_PR_HEADS_FILE"' EXIT
printf '%s\n' "$OPEN_HEADS" | grep -v '^$' > "$OPEN_PR_HEADS_FILE" || true

# ── Paginate all remote branches ─────────────────────────────────────────────
# Explicit page loop (not `gh --paginate`): fetch per_page=100 until a short
# page is returned. This is what lets a stubbed `gh` return a two-page listing
# in tests, and what fixes the "saw only 99 of 159 branches" one-page bug.
ALL_BRANCHES=""
page=1
while true; do
    PAGE="$(gh api "repos/$NWO/branches?per_page=100&page=$page" \
        --jq '.[].name' 2>/dev/null || true)"
    [[ -z "$PAGE" ]] && break
    ALL_BRANCHES="${ALL_BRANCHES}${PAGE}"$'\n'
    (( $(echo "$PAGE" | wc -l) < 100 )) && break
    (( page++ ))
done

CANDIDATES=0
MERGED_CANDIDATES=0
STASH_CANDIDATES=0
DELETED=0
MERGED_DELETED=0
STASHED=0
SKIPPED_OPEN_PR=0
SKIPPED_RECENT=0
SKIPPED_PROTECTED=0

# ── Stash manifest helpers ────────────────────────────────────────────────────
ensure_manifest() {
    [[ -f "$STASH_MANIFEST" ]] && return 0
    {
        echo "# Stashed branches manifest"
        echo
        echo "Machine-appended by \`scripts/coord/orphan-branch-sweeper.sh\` (ZERO-WASTE-136)."
        echo "Each row is an unmerged branch whose tip was pushed to a durable"
        echo "\`refs/stash/<branch>\` ref on origin before the branch was deleted."
        echo "Resume one: \`git fetch origin 'refs/stash/*:refs/stash/*'\` then"
        echo "\`git checkout -b resume/<name> refs/stash/<branch>\`. See"
        echo "docs/process/STASHED_WORK.md."
        echo
        echo "| stashed_at | stash_ref | branch | sha | last_commit_days |"
        echo "|---|---|---|---|---|"
    } > "$STASH_MANIFEST" 2>/dev/null || true
}

while IFS= read -r branch; do
    [[ -z "$branch" ]] && continue

    # Protected?
    if is_protected "$branch"; then
        (( SKIPPED_PROTECTED++ )) || true
        continue
    fi

    # Has open PR?
    if grep -qxF "$branch" "$OPEN_PR_HEADS_FILE" 2>/dev/null; then
        (( SKIPPED_OPEN_PR++ )) || true
        continue
    fi

    # ── Merged-into-base fast path ───────────────────────────────────────────
    # ahead_by == 0 means every commit on the branch is already on the base,
    # so the branch is spent exhaust — delete immediately, no age wait.
    AHEAD_BY="$(gh api "repos/$NWO/compare/$BASE_BRANCH...$branch" \
        --jq '.ahead_by' 2>/dev/null || true)"

    if [[ "$AHEAD_BY" == "0" ]]; then
        (( CANDIDATES++ )) || true
        (( MERGED_CANDIDATES++ )) || true
        echo "[orphan-sweeper] CANDIDATE (merged): $branch"
        [[ $DRY_RUN -eq 1 ]] && continue

        if gh api "repos/$NWO/git/refs/heads/$branch" -X DELETE --silent 2>/dev/null; then
            (( DELETED++ )) || true
            (( MERGED_DELETED++ )) || true
            echo "[orphan-sweeper] DELETED (merged): $branch"
            printf '{"ts":"%s","kind":"orphan_branch_deleted","branch":"%s","reason":"merged","last_commit_age_days":%d,"sweep_run_id":"%s"}\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$branch" 0 "$SWEEP_RUN_ID" \
                >> "$AMBIENT" 2>/dev/null || true
        else
            echo "[orphan-sweeper] WARN: failed to delete merged $branch" >&2
        fi
        continue
    fi

    # ── Unmerged: fetch tip SHA + last-commit date ───────────────────────────
    META="$(gh api "repos/$NWO/branches/$branch" \
        --jq '[.commit.sha, .commit.commit.committer.date] | @tsv' 2>/dev/null || true)"
    SHA="${META%%$'\t'*}"
    LAST_COMMIT_DATE="${META#*$'\t'}"
    if [[ -z "$META" ]] || [[ -z "$LAST_COMMIT_DATE" ]]; then
        echo "[orphan-sweeper] WARN: could not fetch commit meta for $branch — skipping." >&2
        continue
    fi
    COMMIT_TS=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$LAST_COMMIT_DATE" +%s 2>/dev/null \
        || date -d "$LAST_COMMIT_DATE" +%s 2>/dev/null || echo 0)
    AGE=$(( NOW - COMMIT_TS ))
    LAST_DAYS=$(( AGE / 86400 ))

    if (( AGE < AGE_SECS )); then
        (( SKIPPED_RECENT++ )) || true
        continue
    fi

    (( CANDIDATES++ )) || true
    (( STASH_CANDIDATES++ )) || true
    echo "[orphan-sweeper] CANDIDATE (unmerged, stash): $branch (last_commit ${LAST_DAYS}d ago)"

    if [[ $DRY_RUN -eq 1 ]]; then
        continue
    fi

    # Stash the tip to a durable origin ref BEFORE deleting (STASHED_WORK.md).
    STASH_REF="refs/stash/$branch"
    if gh api "repos/$NWO/git/refs" -X POST \
        -f "ref=$STASH_REF" -f "sha=$SHA" --silent 2>/dev/null; then
        ensure_manifest
        printf '| %s | %s | %s | %s | %d |\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$STASH_REF" "$branch" "$SHA" "$LAST_DAYS" \
            >> "$STASH_MANIFEST" 2>/dev/null || true
        (( STASHED++ )) || true
        echo "[orphan-sweeper] STASHED: $branch -> $STASH_REF"
        printf '{"ts":"%s","kind":"orphan_branch_stashed","branch":"%s","stash_ref":"%s","sha":"%s","last_commit_age_days":%d,"sweep_run_id":"%s"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$branch" "$STASH_REF" "$SHA" "$LAST_DAYS" "$SWEEP_RUN_ID" \
            >> "$AMBIENT" 2>/dev/null || true
    else
        echo "[orphan-sweeper] WARN: failed to stash $branch — NOT deleting (work preserved)." >&2
        continue
    fi

    # Delete the branch now that its tip is durably stashed.
    if gh api "repos/$NWO/git/refs/heads/$branch" -X DELETE --silent 2>/dev/null; then
        (( DELETED++ )) || true
        echo "[orphan-sweeper] DELETED (stashed): $branch"
        printf '{"ts":"%s","kind":"orphan_branch_deleted","branch":"%s","reason":"stashed","last_commit_age_days":%d,"sweep_run_id":"%s"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$branch" "$LAST_DAYS" "$SWEEP_RUN_ID" \
            >> "$AMBIENT" 2>/dev/null || true
    else
        echo "[orphan-sweeper] WARN: failed to delete $branch (tip stashed at $STASH_REF)" >&2
    fi
done <<< "$ALL_BRANCHES"

echo "[orphan-sweeper] done: candidates=$CANDIDATES (merged=$MERGED_CANDIDATES stash=$STASH_CANDIDATES) deleted=$DELETED (merged=$MERGED_DELETED stashed=$STASHED) skipped_open_pr=$SKIPPED_OPEN_PR skipped_recent=$SKIPPED_RECENT skipped_protected=$SKIPPED_PROTECTED"

printf '{"ts":"%s","kind":"orphan_branch_sweep_run","nwo":"%s","candidates":%d,"merged_candidates":%d,"stash_candidates":%d,"deleted":%d,"merged_deleted":%d,"stashed":%d,"skipped_open_pr":%d,"skipped_recent":%d,"dry_run":%s,"sweep_run_id":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$NWO" "$CANDIDATES" "$MERGED_CANDIDATES" "$STASH_CANDIDATES" \
    "$DELETED" "$MERGED_DELETED" "$STASHED" \
    "$SKIPPED_OPEN_PR" "$SKIPPED_RECENT" \
    "$([ "$DRY_RUN" -eq 1 ] && echo true || echo false)" \
    "$SWEEP_RUN_ID" >> "$AMBIENT" 2>/dev/null || true
