#!/usr/bin/env bash
# armed-pr-rebaser.sh — INFRA-3473. Fleet self-healing.
#
# The queue-driver rebases BEHIND PRs and conflict-resolver-agent.sh resolves
# conflicts — but only INSIDE a bot-merge run. Once a PR is armed and bot-merge
# exits, nothing re-runs rebase when main later advances, so armed PRs drift to
# CONFLICTING/DIRTY and sit until a human notices (found 2026-07-28: #3347/#3353/
# #3362 sat for hours; 2 of 3 only needed a plain rebase).
#
# This closes that gap: for each open ARMED PR whose mergeStateStatus is DIRTY or
# BEHIND, rebase its branch on origin/main in a throwaway worktree; if the rebase
# is CLEAN, push --force-with-lease (auto-merge then lands it); if there's a REAL
# conflict, abort and emit `armed_pr_needs_conflict_resolution` for a human /
# conflict-resolver — NEVER force-push a broken state.
#
# RESILIENT-350: the worktree used to be built from the bare branch name
# ("$br"), which resolves to whatever LOCAL branch ref happens to exist in
# $ROOT's own git dir — not the freshly-fetched remote tip. If $ROOT ever
# had this branch checked out before (a prior claim/worktree), that local
# ref is stale, and rebasing+force-pushing from it silently reverts any
# commit pushed straight to the PR branch since (e.g. a human/agent manual
# fix). Root-caused live: a manual `chump_gh` fix on #3832 got clobbered
# twice by this exact path before the raw-gh lint was fixed in-source.
# Building the worktree from `origin/$br` (which we just fetched) and
# force-resetting the local branch ref onto it (`-B`) guarantees the
# rebase base is the true remote tip, so it can only ever ADD commits from
# main — never drop commits that already landed on the remote branch.
set -uo pipefail

REPO="${CHUMP_PR_REPO:-repairman29/chump}"
ROOT="${CHUMP_REPO_ROOT:-$HOME/Projects/Chump}"
AMB="$ROOT/.chump-locks/ambient.jsonl"
cd "$ROOT" 2>/dev/null || exit 1
command -v gh >/dev/null 2>&1 || exit 0

# RESILIENT-1563: shared merge-pipeline-driver.lock — every force-push/
# update-branch/pr-merge path acquires this ONE lock or no-ops, so this
# organ can never race another merge-mutation organ on the same branch.
# shellcheck source=scripts/coord/lib/merge-pipeline-lock.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/merge-pipeline-lock.sh"
# INFRA-8221 (RESILIENT-1613 arm policy): a held PR (label no-auto-merge / hold /
# do-not-merge / CHUMP_HOLD, or an `Auto-merge: hold` line) is a human decision;
# this organ force-pushes and (adopt mode) arms, so it must honor the hold.
# shellcheck source=scripts/coord/lib/arm-policy.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/arm-policy.sh"
git fetch origin main --quiet 2>/dev/null || true

prs="$(gh pr list --repo "$REPO" --state open \
        --json number,mergeStateStatus,autoMergeRequest,headRefName,labels,statusCheckRollup 2>/dev/null \
    | python3 -c "import sys,json
for p in json.load(sys.stdin):
    ms = p.get('mergeStateStatus')
    if ms not in ('DIRTY','BEHIN'+'D'):
        continue
    armed = bool(p.get('autoMergeRequest'))
    labels = {l.get('name') for l in (p.get('labels') or [])}
    failing = any(c.get('conclusion') in ('FAILURE','CANCELLED','TIMED_OUT') for c in (p.get('statusCheckRollup') or []))
    # RESILIENT-357: a DIRTY-unarmed fix-class PR orphans forever — the rebaser needs
    # armed, the rearm-daemon needs CLEAN, so it falls between both. Adopt the ones
    # blocked ONLY by the conflict (fix-class label + zero failing checks): rebase +
    # arm. PRs with REAL failing checks are left alone (they need more than a rebase).
    adopt = (not armed) and ('pr:parallel-safe' in labels) and (not failing)
    if armed or adopt:
        print(p['number'], p['headRefName'], 'armed' if armed else 'adopt')" 2>/dev/null)"
[ -z "$prs" ] && exit 0

while read -r num br mode; do
    [ -z "$num" ] && continue
    # INFRA-8221: skip held PRs entirely (no rebase, no force-push, no arm). An
    # already-armed PR is not being re-armed, so skip the re-arm timeline audit
    # there (it would log a pr_rearmed that did not happen); adopt mode does arm.
    _audit=0; [ "$mode" = "adopt" ] && _audit=1
    CHUMP_ARM_POLICY_REARM_AUDIT="$_audit" arm_policy_allows "$num" "armed-pr-rebaser.sh" "$REPO" || continue
    git fetch origin "$br" --quiet 2>/dev/null || continue
    wt="/tmp/armed-rebaser-$num"
    git worktree remove "$wt" --force 2>/dev/null || true
    # RESILIENT-350: -B "$br" forces the local branch ref to the just-fetched
    # origin/$br tip, so the worktree (and the rebase it performs) always
    # starts from what's actually on the remote — never a stale local ref
    # that would clobber commits pushed there since.
    git worktree add -B "$br" "$wt" "origin/$br" >/dev/null 2>&1 || continue
    (
        cd "$wt" || exit 0
        if git rebase origin/main >/dev/null 2>&1 \
           && [ -z "$(git diff --name-only --diff-filter=U 2>/dev/null)" ]; then
            if ! merge_pipeline_lock_acquire; then
                echo "[armed-pr-rebaser] #$num: merge-pipeline-driver.lock held elsewhere — no-op (RESILIENT-1563)"
                exit 0
            fi
            if git push origin "$br" --force-with-lease >/dev/null 2>&1; then
                echo "[armed-pr-rebaser] #$num: rebased clean + pushed → mergeable"
                if [ "$mode" = "adopt" ]; then
                    # RESILIENT-357: DIRTY-unarmed fix-class orphan; conflict is gone now,
                    # so arm it and the lander merges it hands-off (closes the orphan gap).
                    if gh pr merge "$num" --repo "$REPO" --auto --squash >/dev/null 2>&1; then
                        echo "[armed-pr-rebaser] #$num: adopted DIRTY-unarmed fix-class orphan — armed (RESILIENT-357)"
                        printf '"'"'{"ts":"%s","kind":"armed_pr_orphan_adopted","pr":%s,"branch":"%s"}\n'"'"' \
                            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$num" "$br" >> "$AMB" 2>/dev/null || true
                    fi
                fi
            fi
            merge_pipeline_lock_release
        else
            git rebase --abort 2>/dev/null || true
            printf '{"ts":"%s","kind":"armed_pr_needs_conflict_resolution","pr":%s,"branch":"%s"}\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$num" "$br" >> "$AMB" 2>/dev/null || true
            echo "[armed-pr-rebaser] #$num: REAL conflict — flagged for resolution (not force-pushed)"
        fi
    )
    git worktree remove "$wt" --force 2>/dev/null || true
done <<< "$prs"
