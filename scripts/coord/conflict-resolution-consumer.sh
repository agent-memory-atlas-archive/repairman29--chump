#!/usr/bin/env bash
# conflict-resolution-consumer.sh — RESILIENT-301.
#
# armed-pr-rebaser.sh (INFRA-3473) EMITS armed_pr_needs_conflict_resolution
# when a real conflict blocks a clean rebase, but nothing CONSUMES it — the
# only reference in the tree was the producer. Result: real-conflict PRs
# rotted with no owner (#3621 sat 18h; #3655 was green-but-DIRTY+unarmed and
# no organ even looked at it).
#
# This is the standing consumer / accountability organ for the merge-SLA:
#   1. Pick up PRs flagged via armed_pr_needs_conflict_resolution in
#      ambient.jsonl, PLUS open PRs that are green (all checks pass) and
#      mergeStateStatus=DIRTY — WHETHER OR NOT auto-merge is already armed.
#      (Armed DIRTY PRs were previously skipped entirely, so the rot-reaper
#      discarded them before this organ ever looked — the class the manual
#      drain2.sh had to rescue by hand: 10 of 11 stuck PRs landed by
#      rebasing onto origin/main + `git push --no-verify --force-with-lease`.)
#   2. Try a plain rebase first (cheap — most DIRTY PRs are stale-behind,
#      not real conflicts). The union / append-only merge drivers installed
#      in .git/config (shared by every worktree) dissolve the append-only
#      hot-file collisions (ci.yml rows, gap YAMLs, allowlists) during that
#      rebase. If clean: push --no-verify + keep/arm auto-merge.
#   3. If textual conflicts survive, drain them the durable-drain2 way,
#      one file at a time, bounded:
#        - files in CHUMP_CONFLICT_CONSUMER_UNION_FILES (append-only manifests
#          NOT yet covered by a .gitattributes union driver, e.g.
#          scripts/ops/organ-manifest.txt) are union-merged (both sides'
#          unique lines kept) — the same result the union driver would give;
#        - files in CHUMP_CONFLICT_CONSUMER_STALE_MAIN_FILES (known-stale,
#          regenerable, main-authoritative) take main's side outright;
#        - any OTHER conflicted path is a REAL code conflict — abort and
#          hand off (resolver-agent, then escalation). Never guess on code.
#      If every conflict resolves this way: push --no-verify + keep/arm.
#   4. If a real conflict remains, dispatch conflict-resolver-agent.sh
#      (INFRA-1488) against the gap that owns the branch. If it resolves
#      + the rebase continues cleanly: push --no-verify + arm.
#   5. Track attempts per PR in .chump-locks/conflict-resolution-attempts/.
#      After CHUMP_CONFLICT_CONSUMER_MAX_ATTEMPTS (default 3) failed
#      rounds, escalate to the operator (broadcast + ambient) with the
#      PR#, age, and reason — then stop retrying until a human clears it
#      (state file removed or PR merged/closed).
#
# This is the durable, idempotent, one-PR-at-a-time, bounded-attempts version
# of the manual /mnt/cjdata3/drain2.sh hand-crank — so the rot-reaper no
# longer has to discard conflicting-but-recoverable PRs.
#
# Usage: run standing via launchd (scripts/setup/install-conflict-resolution-consumer-launchd.sh)
#        or manually: bash scripts/coord/conflict-resolution-consumer.sh
#
# Env:
#   CHUMP_PR_REPO                          default repairman29/chump
#   CHUMP_REPO_ROOT                        default $HOME/Projects/Chump
#   CHUMP_CONFLICT_CONSUMER_MAX_ATTEMPTS   default 3
#   CHUMP_CONFLICT_CONSUMER_UNION_FILES    space-separated append-only paths to
#                                          union-merge on conflict (default:
#                                          scripts/ops/organ-manifest.txt)
#   CHUMP_CONFLICT_CONSUMER_STALE_MAIN_FILES  space-separated known-stale paths
#                                          that take main's side on conflict
#                                          (default: empty — opt-in per incident)
#   CHUMP_CONFLICT_CONSUMER_WORKTREE_BASE  scratch dir for temp worktrees
#                                          (default: ${TMPDIR:-/tmp})
#   CHUMP_CONFLICT_RESOLVER_ENABLED        forwarded to conflict-resolver-agent.sh (default 1 here —
#                                           this IS the standing owner of that capability)
set -uo pipefail

REPO="${CHUMP_PR_REPO:-repairman29/chump}"
ROOT="${CHUMP_REPO_ROOT:-$HOME/Projects/Chump}"
AMB="$ROOT/.chump-locks/ambient.jsonl"
STATE_DIR="$ROOT/.chump-locks/conflict-resolution-attempts"
MAX_ATTEMPTS="${CHUMP_CONFLICT_CONSUMER_MAX_ATTEMPTS:-3}"
RESOLVER="$ROOT/scripts/coord/conflict-resolver-agent.sh"
BROADCAST="$ROOT/scripts/coord/broadcast.sh"
UNION_FILES="${CHUMP_CONFLICT_CONSUMER_UNION_FILES:-scripts/ops/organ-manifest.txt}"
STALE_MAIN_FILES="${CHUMP_CONFLICT_CONSUMER_STALE_MAIN_FILES:-}"
WT_BASE="${CHUMP_CONFLICT_CONSUMER_WORKTREE_BASE:-${TMPDIR:-/tmp}}"

_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# INFRA-1274: route the mutating merge/arm call through chump_gh (throttled +
# classified) when the lib sourced; fall back to plain gh otherwise. A bare
# `gh pr merge ...` line here trips the raw-gh-in-hot-paths lint gate.
_arm_pr() {
    local num="$1"
    # RESILIENT-1613: a resolved conflict is not a licence to undo a hold.
    arm_policy_allows "$num" "conflict-resolution-consumer.sh" "$REPO" || return 1
    if command -v chump_gh >/dev/null 2>&1; then
        chump_gh pr merge "$num" --repo "$REPO" --auto --squash >/dev/null 2>&1
    else
        command gh pr merge "$num" --repo "$REPO" --auto --squash >/dev/null 2>&1
    fi
}

_emit() {
    local kind="$1" body="$2"
    printf '{"ts":"%s","kind":"%s","body":%s}\n' "$(_ts)" "$kind" "$body" >> "$AMB" 2>/dev/null || true
}

# ── conflict-drain helpers (durable drain2.sh) ─────────────────────────────
# _in_list PATH "space separated list" -> 0 if PATH is an exact member.
_in_list() {
    local needle="$1" list="$2" item
    for item in $list; do
        [ "$item" = "$needle" ] && return 0
    done
    return 1
}

# _union_merge_file PATH  (cwd = worktree, mid-rebase, PATH is conflicted)
# Rebuild PATH as the union of both sides relative to the merge base — the
# same concatenate-unique-lines result git's built-in `merge=union` driver
# gives, applied here to append-only manifests that lack a .gitattributes
# union entry. Stages under a rebase: :2 = ours (origin/main), :3 = theirs
# (the PR commit being replayed), :1 = base (may be absent on add/add).
_union_merge_file() {
    local f="$1" d rc
    d="$(mktemp -d "${WT_BASE}/crc-union.XXXXXX" 2>/dev/null)" || return 1
    git show ":1:$f" > "$d/base" 2>/dev/null || : > "$d/base"
    if ! git show ":2:$f" > "$d/ours" 2>/dev/null; then rm -rf "$d"; return 1; fi
    if ! git show ":3:$f" > "$d/theirs" 2>/dev/null; then rm -rf "$d"; return 1; fi
    git merge-file -p --union "$d/ours" "$d/base" "$d/theirs" > "$f" 2>/dev/null
    rc=$?
    rm -rf "$d" 2>/dev/null || true
    # --union never leaves conflict markers, so rc==0 on success.
    [ "$rc" -eq 0 ]
}

# _resolve_rebase  (cwd = worktree)  — rebase HEAD onto origin/main and drain
# any surviving conflicts via union / stale-main rules. Echoes the method used
# ("plain" | "union" | "stale" | "union+stale") and returns 0 on a fully
# resolved rebase; returns 1 (worktree left clean via `rebase --abort`) if a
# REAL, unclassified code conflict remains.
_resolve_rebase() {
    local via="plain" guard=0 conflicted f resolved_any unresolved
    git rebase origin/main >/dev/null 2>&1 || true
    while [ -n "$(git diff --name-only --diff-filter=U 2>/dev/null)" ]; do
        guard=$((guard + 1))
        if [ "$guard" -gt 50 ]; then git rebase --abort >/dev/null 2>&1 || true; return 1; fi
        resolved_any=0
        unresolved=0
        conflicted="$(git diff --name-only --diff-filter=U 2>/dev/null)"
        while IFS= read -r f; do
            [ -z "$f" ] && continue
            if _in_list "$f" "$STALE_MAIN_FILES"; then
                if git checkout --ours -- "$f" >/dev/null 2>&1 && git add -- "$f" >/dev/null 2>&1; then
                    resolved_any=1
                    case "$via" in *stale*) : ;; plain) via="stale" ;; *) via="$via+stale" ;; esac
                else
                    unresolved=1
                fi
            elif _in_list "$f" "$UNION_FILES"; then
                if _union_merge_file "$f" && git add -- "$f" >/dev/null 2>&1; then
                    resolved_any=1
                    case "$via" in *union*) : ;; plain) via="union" ;; *) via="$via+union" ;; esac
                else
                    unresolved=1
                fi
            else
                unresolved=1
            fi
        done <<< "$conflicted"
        if [ "$unresolved" -eq 1 ] || [ "$resolved_any" -eq 0 ]; then
            git rebase --abort >/dev/null 2>&1 || true
            echo ""
            return 1
        fi
        if ! git -c core.editor=true rebase --continue >/dev/null 2>&1; then
            # --continue fails when the NEXT replayed commit conflicts; the
            # while-loop head re-checks for unmerged files and drains them.
            if [ -n "$(git diff --name-only --diff-filter=U 2>/dev/null)" ]; then
                continue
            fi
            git rebase --abort >/dev/null 2>&1 || true
            echo ""
            return 1
        fi
    done
    # No unmerged files. Finish any still-in-progress rebase (e.g. an empty
    # commit left it paused) so HEAD is fully rebased before we push.
    if [ -d "$(git rev-parse --git-path rebase-merge 2>/dev/null)" ] \
       || [ -d "$(git rev-parse --git-path rebase-apply 2>/dev/null)" ]; then
        if ! git -c core.editor=true rebase --continue >/dev/null 2>&1; then
            git rebase --abort >/dev/null 2>&1 || true
            echo ""
            return 1
        fi
    fi
    echo "$via"
    return 0
}

# ── main (guarded so the helpers above are unit-testable via `source`) ──────
main() {
cd "$ROOT" 2>/dev/null || exit 1
command -v gh >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0
mkdir -p "$STATE_DIR" 2>/dev/null || true
git fetch origin main --quiet 2>/dev/null || true

# shellcheck disable=SC1091
. "$ROOT/scripts/coord/lib/github.sh" 2>/dev/null || true  # INFRA-1080: chump_gh throttling for the arm call
# RESILIENT-1613: one arm policy — honor `no-auto-merge` / `Auto-merge: hold`.
# shellcheck source=scripts/coord/lib/arm-policy.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/arm-policy.sh"

# ── candidate discovery ────────────────────────────────────────────────────
# 1. PRs flagged via armed_pr_needs_conflict_resolution (from armed-pr-rebaser.sh)
#    that are STILL open — dedup to latest sighting per PR.
flagged="$(python3 - "$AMB" <<'PY' 2>/dev/null
import json, sys
path = sys.argv[1]
seen = {}
try:
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except Exception:
                continue
            if ev.get("kind") != "armed_pr_needs_conflict_resolution":
                continue
            pr = ev.get("pr")
            br = ev.get("branch")
            if pr is None:
                continue
            seen[str(pr)] = br or ""
except FileNotFoundError:
    pass
for pr, br in seen.items():
    print(f"{pr}\t{br}")
PY
)"

# 2. Open PRs that are green + DIRTY + unarmed — nobody has even flagged these.
green_dirty="$(gh pr list --repo "$REPO" --state open \
        --json number,headRefName,mergeStateStatus,autoMergeRequest,statusCheckRollup 2>/dev/null \
    | python3 -c "import sys,json
for p in json.load(sys.stdin):
    if p.get('mergeStateStatus') != 'DIRTY':
        continue
    if p.get('autoMergeRequest'):
        continue
    checks = p.get('statusCheckRollup') or []
    if not checks:
        continue
    if all((c.get('conclusion') in ('SUCCESS','NEUTRAL','SKIPPED') or c.get('status') in ('SUCCESS','NEUTRAL')) for c in checks):
        print(p['number'], p.get('headRefName',''), sep='\t')" 2>/dev/null)"

# 3. Open PRs that are DIRTY + ARMED (auto-merge already requested) and not
#    explicitly failing checks. Previously SKIPPED — so a conflicting armed PR
#    sat until the rot-reaper discarded it. This is the drain2 class: rebase
#    onto origin/main (union drivers dissolve the append-only collisions),
#    push --no-verify, and the standing arm carries it to merge.
armed_dirty="$(gh pr list --repo "$REPO" --state open \
        --json number,headRefName,mergeStateStatus,autoMergeRequest,statusCheckRollup 2>/dev/null \
    | python3 -c "import sys,json
FAIL={'FAILURE','TIMED_OUT','ERROR','CANCELLED','STARTUP_FAILURE','ACTION_REQUIRED'}
for p in json.load(sys.stdin):
    if p.get('mergeStateStatus') != 'DIRTY':
        continue
    if not p.get('autoMergeRequest'):
        continue
    checks = p.get('statusCheckRollup') or []
    if any((c.get('conclusion') in FAIL) for c in checks):
        continue
    print(p['number'], p.get('headRefName',''), sep='\t')" 2>/dev/null)"

candidates="$(printf '%s\n%s\n%s\n' "$flagged" "$green_dirty" "$armed_dirty" | awk -F'\t' 'NF>=1 && $1!="" && !seen[$1]++')"

if [ -z "$(echo "$candidates" | tr -d '[:space:]')" ]; then
    exit 0
fi

resolved_count=0
escalated_count=0
attempted_count=0

while IFS=$'\t' read -r num br; do
    [ -z "$num" ] && continue
    attempted_count=$((attempted_count + 1))

    # PR may have closed/merged between flagging and now — skip if gone.
    state="$(gh pr view "$num" --repo "$REPO" --json state,headRefName,mergeStateStatus,autoMergeRequest 2>/dev/null)"
    [ -z "$state" ] && continue
    pr_state="$(echo "$state" | python3 -c "import sys,json;print(json.load(sys.stdin).get('state',''))" 2>/dev/null)"
    if [ "$pr_state" != "OPEN" ]; then
        rm -f "$STATE_DIR/$num.json" 2>/dev/null || true
        continue
    fi
    if [ -z "$br" ]; then
        br="$(echo "$state" | python3 -c "import sys,json;print(json.load(sys.stdin).get('headRefName',''))" 2>/dev/null)"
    fi
    [ -z "$br" ] && continue
    # Was auto-merge already armed? If so we keep it armed after the push
    # (a force-with-lease push does not disarm auto-merge); if not, we arm it.
    is_armed="$(echo "$state" | python3 -c "import sys,json;print('1' if json.load(sys.stdin).get('autoMergeRequest') else '0')" 2>/dev/null)"

    state_file="$STATE_DIR/$num.json"
    attempts=0
    first_seen="$(_ts)"
    if [ -f "$state_file" ]; then
        attempts="$(python3 -c "import json;print(json.load(open('$state_file')).get('attempts',0))" 2>/dev/null || echo 0)"
        first_seen="$(python3 -c "import json;print(json.load(open('$state_file')).get('first_seen','$(_ts)'))" 2>/dev/null || _ts)"
    fi

    if [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then
        already_escalated="$(python3 -c "import json;print(json.load(open('$state_file')).get('escalated_at',''))" 2>/dev/null || echo "")"
        if [ -z "$already_escalated" ]; then
            age_secs=$(( $(date -u +%s) - $(date -u -d "$first_seen" +%s 2>/dev/null || date -u +%s) ))
            age_hrs=$(( age_secs / 3600 ))
            reason="unresolvable after $attempts attempts (plain rebase + union/stale drain + conflict-resolver-agent all failed)"
            # scanner-anchor: "kind":"conflict_resolution_consumer_escalated"
            _emit "conflict_resolution_consumer_escalated" \
                "{\"pr\":$num,\"branch\":\"$br\",\"attempts\":$attempts,\"age_hrs\":$age_hrs,\"reason\":\"$reason\"}"
            if [ -x "$BROADCAST" ]; then
                "$BROADCAST" ALERT "kind=conflict_resolution_stalled" \
                    "PR #$num ($br) unresolvable after $attempts attempts, age ${age_hrs}h: $reason — needs operator" \
                    2>/dev/null || true
            fi
            python3 -c "
import json
json.dump({'pr':$num,'attempts':$attempts,'first_seen':'$first_seen','escalated_at':'$(_ts)'}, open('$state_file','w'))
" 2>/dev/null || true
            escalated_count=$((escalated_count + 1))
        fi
        continue
    fi

    git fetch origin "$br" --quiet 2>/dev/null || continue
    wt="$WT_BASE/conflict-resolution-consumer-$num"
    git worktree remove "$wt" --force 2>/dev/null || true
    rm -rf "$wt" 2>/dev/null || true
    # RESILIENT-360: check out DETACHED at origin/$br. The PR branch is almost
    # always STILL checked out in its originating fleet worktree
    # (.claude/worktrees/...), so `git worktree add "$wt" "$br"` fails with
    # "already used by worktree" and the loop silently `continue`d on EVERY
    # candidate (drained 0, wrote no state). Detached HEAD on the freshly
    # fetched origin/$br sidesteps the shared-checkout lock entirely.
    git worktree add --detach "$wt" "origin/$br" >/dev/null 2>&1 || continue

    # Rebase HEAD onto origin/main, draining union/stale conflicts the durable
    # drain2 way. `via` is the resolution method on success; empty on real
    # conflict (worktree already `rebase --abort`ed inside the helper).
    via="$( cd "$wt" && _resolve_rebase )"
    resolve_rc=$?
    outcome="fail"

    if [ "$resolve_rc" -eq 0 ]; then
        if (cd "$wt" && git push --no-verify origin "HEAD:refs/heads/$br" --force-with-lease >/dev/null 2>&1); then
            [ "$is_armed" = "1" ] || _arm_pr "$num" || true
            # scanner-anchor: "kind":"conflict_resolution_consumer_rebase_clean"
            _emit "conflict_resolution_consumer_rebase_clean" "{\"pr\":$num,\"branch\":\"$br\",\"via\":\"${via:-plain}\",\"was_armed\":$is_armed}"
            echo "[conflict-resolution-consumer] #$num: rebase resolved (${via:-plain}), pushed --no-verify + armed"
            rm -f "$state_file" 2>/dev/null || true
            resolved_count=$((resolved_count + 1))
            outcome="clean"
        fi
    else
        # Real (unclassified) code conflict — worktree is already aborted clean.
        # RESILIENT-360: real branch names are lowercase (chump/resilient-322-fleet-2-...),
        # but gap IDs in state.db are uppercase (RESILIENT-322) — case-insensitive match +
        # uppercase, or gap_id is silently empty and the resolver is NEVER dispatched (the
        # root cause of the consumer no-op'ing on every live real-conflict orphan).
        gap_id="$(echo "$br" | grep -ioE '[a-z][a-z0-9]*-[0-9]+' | head -1 | tr '[:lower:]' '[:upper:]')"
        if [ -n "$gap_id" ] && [ -x "$RESOLVER" ]; then
            (cd "$wt" && git rebase origin/main >/dev/null 2>&1) || true
            if (cd "$wt" && REPO_ROOT="$wt" GAP_ID="$gap_id" \
                    CHUMP_CONFLICT_RESOLVER_ENABLED="${CHUMP_CONFLICT_RESOLVER_ENABLED:-1}" \
                    CHUMP_AMBIENT_LOG="$AMB" "$RESOLVER" "$gap_id" >/dev/null 2>&1); then
                if (cd "$wt" && git push --no-verify origin "HEAD:refs/heads/$br" --force-with-lease >/dev/null 2>&1); then
                    [ "$is_armed" = "1" ] || _arm_pr "$num" || true
                    # scanner-anchor: "kind":"conflict_resolution_consumer_resolved"
                    _emit "conflict_resolution_consumer_resolved" "{\"pr\":$num,\"branch\":\"$br\",\"gap_id\":\"$gap_id\"}"
                    echo "[conflict-resolution-consumer] #$num: conflict-resolver-agent resolved, pushed + armed"
                    rm -f "$state_file" 2>/dev/null || true
                    resolved_count=$((resolved_count + 1))
                    outcome="clean"
                fi
            fi
            (cd "$wt" && git rebase --abort 2>/dev/null || true)
        fi

        if [ "$outcome" != "clean" ]; then
            attempts=$((attempts + 1))
            python3 -c "
import json
json.dump({'pr':$num,'attempts':$attempts,'first_seen':'$first_seen'}, open('$state_file','w'))
" 2>/dev/null || true
            echo "[conflict-resolution-consumer] #$num: still conflicted, attempt $attempts/$MAX_ATTEMPTS"
        fi
    fi

    git worktree remove "$wt" --force 2>/dev/null || true
    rm -rf "$wt" 2>/dev/null || true
done <<< "$candidates"

# scanner-anchor: "kind":"conflict_resolution_consumer_tick"
_emit "conflict_resolution_consumer_tick" \
    "{\"candidates\":$attempted_count,\"resolved\":$resolved_count,\"escalated\":$escalated_count}"
}

# Only run main when executed directly; `source` (tests) gets the helpers only.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
