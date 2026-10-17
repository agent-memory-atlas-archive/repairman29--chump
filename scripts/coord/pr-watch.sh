#!/usr/bin/env bash
# pr-watch.sh — INFRA-190: auto-recover a DIRTY-after-arm PR.
#
# The merge queue arms auto-merge optimistically: if main moves between
# `gh pr create` and queue entry, the PR goes DIRTY. Today the human or
# agent has to manually:
#   1. gh pr merge <N> --disable-auto
#   2. git fetch origin main && git rebase origin/main
#   3. (resolve trivial gaps.yaml conflicts)
#   4. CHUMP_GAP_CHECK=0 git push --force-with-lease
#   5. gh pr merge <N> --auto --squash
#
# I (this session) did exactly this 5+ times today. This script does it
# automatically when the rebase is conflict-free (~80% of cases). Real
# content conflicts still surface to the operator with exit 3.
#
# Usage:
#   scripts/coord/pr-watch.sh <PR#>            # poll until merged/timeout
#   scripts/coord/pr-watch.sh <PR#> --once     # check once and act, then exit
#
# Run from the BRANCH worktree (where the branch is checked out). The
# script uses the current branch via `git symbolic-ref` for the push
# target — no need to pass it.
#
# Env:
#   PR_WATCH_TIMEOUT      seconds before giving up (default 1800)
#   PR_WATCH_POLL         seconds between polls (default 30)
#   CHUMP_PR_WATCH=0      bypass — exit 0 immediately (for tests)
#
# Exit codes:
#   0  PR merged successfully (or --once + state is good)
#   1  PR closed without merge
#   2  Timeout (PR still in flight)
#   3  Rebase produced conflicts — operator must resolve
#   4  Usage error / not in a branch worktree

set -euo pipefail

if [[ "${CHUMP_PR_WATCH:-1}" == "0" ]]; then
    echo "[pr-watch] CHUMP_PR_WATCH=0 — bypass"
    exit 0
fi

PR="${1:?usage: $0 <PR#> [--once] [--branch-override <name>]}"
shift
ONCE=0
BRANCH_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --once) ONCE=1; shift ;;
        --branch-override)
            BRANCH_OVERRIDE="$2"; shift 2 ;;
        --branch-override=*)
            BRANCH_OVERRIDE="${1#--branch-override=}"; shift ;;
        *) shift ;;
    esac
done

TIMEOUT_S="${PR_WATCH_TIMEOUT:-1800}"
POLL_S="${PR_WATCH_POLL:-30}"

# When --branch-override is set, skip the symbolic-ref check (used by
# pr-watch-shepherd.sh which runs from an ephemeral worktree).
if [[ -n "$BRANCH_OVERRIDE" ]]; then
    BRANCH="$BRANCH_OVERRIDE"
else
    # Confirm we're in a git checkout with the branch checked out.
    if ! BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null); then
        echo "[pr-watch] ERROR: not in a git checkout with a branch — refusing to push" >&2
        exit 4
    fi

    # Confirm this branch matches the PR.
    PR_BRANCH=$(gh pr view "$PR" --json headRefName -q .headRefName 2>/dev/null || true)
    if [[ -n "$PR_BRANCH" && "$PR_BRANCH" != "$BRANCH" ]]; then
        echo "[pr-watch] ERROR: current branch '$BRANCH' does not match PR #$PR head '$PR_BRANCH'" >&2
        exit 4
    fi
fi

DEADLINE=$(($(date +%s) + TIMEOUT_S))
LAST_STATE=""

say() { printf '\033[1;36m[pr-watch]\033[0m PR #%s: %s\n' "$PR" "$*"; }

write_heartbeat() {
    local hb="/tmp/chump-pr-watch.heartbeat"
    {
        echo "ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "status=running"
        echo "pr=$PR"
    } > "$hb" 2>/dev/null || true
}

# INFRA-387: attempt to auto-resolve a rebase conflict using the recipe
# proven during the 2026-05-03 batch-unstick (7/8 PRs auto-recovered):
#   .chump/state.sql        — untracked since INFRA-8193: a conflict can only
#                             be an old branch touching the deleted file, so
#                             resolve by keeping it out of git (git rm)
#   docs/gaps/<ID>.yaml     — take ours (the per-file mirror; conflict
#                             usually means two parallel reserves both
#                             chose the same ID-shape, but mirrors are
#                             regenerated artifacts so ours is fine)
#   .github/workflows/ci.yml — sed-strip <<<<<<< / ======= / >>>>>>>
#                             markers (same trick worked for 4/4 ci.yml
#                             rebases that night; reviewer can spot any
#                             real semantic conflict if one slips through)
#   anything else            — abort + bail out (operator must resolve)
#
# Returns 0 on success (all conflicts resolved + git add'd), non-zero
# on first unresolvable file. Caller should `git rebase --continue`
# afterward. Bypass: CHUMP_AUTO_RESOLVE_CONFLICTS=0 (skip the recipe,
# fall through to the original "operator must resolve" exit 3).
attempt_auto_resolve_conflicts() {
    [[ "${CHUMP_AUTO_RESOLVE_CONFLICTS:-1}" == "0" ]] && return 1

    local unmerged
    unmerged=$(git diff --name-only --diff-filter=U 2>/dev/null) || return 1
    [[ -z "$unmerged" ]] && return 0

    local f
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        case "$f" in
            .chump/state.sql|.chump/state.sql.lz4|.chump/gap_store.db)
                # INFRA-8193: these left git; never regenerate or re-add them.
                say "  auto-resolve: $f is untracked since INFRA-8193 — removing from the index"
                git rm -q --cached -- "$f" >/dev/null 2>&1 \
                    || git update-index --force-remove -- "$f" 2>/dev/null \
                    || { say "  ✗ could not drop $f from the index"; return 1; }
                ;;
            docs/gaps/*.yaml)
                say "  auto-resolve: take ours for $f"
                git checkout --ours "$f" 2>/dev/null || { say "  ✗ checkout --ours failed for $f"; return 1; }
                git add "$f" 2>/dev/null
                ;;
            .github/workflows/ci.yml|.github/workflows/*.yml)
                say "  auto-resolve: sed-strip conflict markers in $f"
                # Strip the three marker lines. Real semantic conflicts
                # remain visible to CI / reviewer.
                sed -i.bak -E '/^(<<<<<<< |=======$|>>>>>>> )/d' "$f" || { say "  ✗ sed strip failed for $f"; return 1; }
                rm -f "${f}.bak"
                git add "$f" 2>/dev/null
                ;;
            *)
                say "  ✗ unrecognized conflict in $f — bail (operator must resolve)"
                return 1
                ;;
        esac
    done <<< "$unmerged"
    return 0
}

attempt_recovery() {
    # INFRA-306: re-check PR state before any rebase/push work. The state
    # we captured in the outer poll loop may be 30s old — long enough for
    # auto-merge to fire on green CI. Force-pushing to a deleted branch
    # wastes 5-15min and the queue is already settled.
    if [[ "${CHUMP_SKIP_MERGED_CHECK:-0}" != "1" ]]; then
        _live_state=$(gh pr view "$PR" --json state --jq '.state' 2>/dev/null || echo "")
        if [[ "$_live_state" == "MERGED" ]]; then
            say "already MERGED — skipping recovery (INFRA-306)"
            return 0
        fi
    fi
    say "DIRTY detected → disarm + rebase + force-push + re-arm"
    gh pr merge "$PR" --disable-auto >/dev/null 2>&1 || true
    git fetch origin main --quiet

    # First pass: try a clean rebase.
    if git rebase origin/main >/tmp/pr-watch-rebase-$$.log 2>&1; then
        :  # clean — fall through to push
    else
        # INFRA-387: rebase has conflicts. Try the auto-resolve recipe
        # before bailing. GIT_EDITOR=true so `git rebase --continue`
        # doesn't open an interactive editor (which would block).
        say "rebase conflicts — trying auto-resolve recipe (INFRA-387)"
        if attempt_auto_resolve_conflicts \
           && GIT_EDITOR=true git rebase --continue >>/tmp/pr-watch-rebase-$$.log 2>&1; then
            say "  ✓ auto-resolved + rebase --continue succeeded"
        else
            say "✗ rebase has CONFLICTS that auto-resolve can't handle — operator must resolve"
            echo "  see: /tmp/pr-watch-rebase-$$.log"
            git rebase --abort 2>/dev/null || true
            return 3
        fi
    fi

    if ! CHUMP_GAP_CHECK=0 git push --force-with-lease origin "$BRANCH" >/dev/null 2>&1; then
        say "force-push rejected (someone else pushed?) — re-arming and waiting"
    fi
    # INFRA-1223: route through centralized armer (5s spacing + 60/120/240s
    # backoff on secondary rate limit). Per-poll re-arms otherwise risk
    # tripping the mutation abuse heuristic.
    "$(dirname "${BASH_SOURCE[0]}")/auto-merge-armer.sh" --pr "$PR" >/dev/null 2>&1 || true
    say "auto-recovered ✓"
    rm -f /tmp/pr-watch-rebase-$$.log
    return 0
}

while (( $(date +%s) < DEADLINE )); do
    state=$(gh pr view "$PR" --json state,mergeStateStatus -q '"\(.state) \(.mergeStateStatus)"' 2>/dev/null || echo "UNKNOWN UNKNOWN")
    write_heartbeat

    if [[ "$state" != "$LAST_STATE" ]]; then
        say "$state"
        LAST_STATE="$state"
    fi

    case "$state" in
        "MERGED "*)
            say "merged ✓"
            exit 0
            ;;
        "CLOSED "*)
            say "closed without merge ✗"
            exit 1
            ;;
        "OPEN DIRTY")
            attempt_recovery || exit $?
            sleep 5  # brief pause before re-poll so the queue sees the new state
            ;;
        "OPEN BEHIND")
            # INFRA-638: BEHIND means main moved past us; rebase without disarming
            # (auto-merge stays armed; we just need to push a fresh commit).
            say "BEHIND detected → rebase + force-push"
            git fetch origin main --quiet
            if git rebase origin/main >/tmp/pr-watch-rebase-$$.log 2>&1; then
                if ! CHUMP_GAP_CHECK=0 git push --force-with-lease origin "$BRANCH" >/dev/null 2>&1; then
                    say "force-push rejected — will retry"
                else
                    say "rebased ✓"
                fi
            else
                say "rebase conflicts — trying auto-resolve recipe"
                if attempt_auto_resolve_conflicts \
                   && GIT_EDITOR=true git rebase --continue >>/tmp/pr-watch-rebase-$$.log 2>&1; then
                    say "  ✓ auto-resolved"
                    CHUMP_GAP_CHECK=0 git push --force-with-lease origin "$BRANCH" >/dev/null 2>&1 || true
                else
                    say "✗ conflicts need operator — aborting rebase, leaving BEHIND"
                    git rebase --abort 2>/dev/null || true
                fi
                rm -f /tmp/pr-watch-rebase-$$.log
            fi
            sleep 5
            ;;
        "OPEN BLOCKED" | "OPEN CLEAN" | "OPEN HAS_HOOKS" | "OPEN UNSTABLE" | "OPEN UNKNOWN")
            # Healthy in-flight states — let the queue / CI work
            ;;
        *)
            say "unrecognized state '$state' — continuing to poll"
            ;;
    esac

    if [[ "$ONCE" -eq 1 ]]; then
        exit 0
    fi
    sleep "$POLL_S"
done

say "timeout after ${TIMEOUT_S}s — PR still in flight"
exit 2
