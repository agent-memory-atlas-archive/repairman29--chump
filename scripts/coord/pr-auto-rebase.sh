#!/usr/bin/env bash
# scripts/coord/pr-auto-rebase.sh — INFRA-1777
#
# Auto-rebase any open PR whose ONLY blocker is "behind on main" and which
# already has auto-merge armed. Eliminates the manual `gh pr update-branch`
# step after every keystone-fix lands.
#
# Tonight's reproducer (2026-05-23 ~05:18Z):
#   PR #2381 + #2382 landed at 05:17/05:18Z. PRs #2377 + #2373 were DIRTY,
#   armed for auto-merge, and waiting on EXACTLY those allowlist additions.
#   The keystone-cascade detector (INFRA-1420) didn't fire because the
#   batch-fix commits had no `unblocks-cluster:` trailer. Operator ran
#   `gh pr update-branch 2377 2373` manually. That's the friction this
#   script eliminates.
#
# Usage:
#   bash scripts/coord/pr-auto-rebase.sh [--dry-run] [--max-per-hour N]
#
# Run periodically (every 3-5 min). Install via launchd plist:
#   scripts/setup/install-pr-auto-rebase-launchd.sh (follow-up gap)
#
# Telemetry:
#   kind=pr_auto_rebased         — successful rebase + push (via gh API)
#   kind=pr_auto_rebase_skipped  — cooldown / not-armed / not-behind
#   kind=pr_auto_rebase_failed   — BOTH gh API and local rebase failed (true conflict)
#   kind=pr_auto_rebase_fallback — gh API false-positive, local rebase succeeded (INFRA-1958)
#
# INFRA-1958 (2026-05-24): `gh pr update-branch` returns non-zero with false-positive
# "conflict" reports for PRs that local `git rebase origin/main` resolves cleanly with
# zero conflicts. On 2026-05-24, 8 PRs (#2514-#2543) wedged for hours on this bug while
# fleet throughput collapsed to ~0 merges/hour. Fix: when gh API reports conflict, try
# local rebase in /tmp worktree; if it succeeds, push --force-with-lease and continue.
# Only escalate to pr_auto_rebase_failed if local rebase ALSO fails.
#
# Bypass: CHUMP_PR_AUTO_REBASE_NO_FALLBACK=1 disables local-rebase fallback (trust gh API).
#
# INFRA-1811 (2026-07-26): the local-rebase fallback above was silent about
# WHICH merge drivers actually resolved the conflict, had no time budget (a
# hung rebase could wedge the daemon indefinitely), and didn't emit a
# structured conflict-file list on genuine failure for a future
# smart-rescuer agent to consume. This adds:
#   kind=pr_auto_rebase_recovered    — local rebase succeeded; driver names that fired
#   kind=pr_auto_rebase_unresolvable — local rebase still conflicted; conflict_files array
#   CHUMP_PR_AUTO_REBASE_LOCAL_TIMEOUT_S (default 120) — cap on the local rebase attempt

set -uo pipefail

# shellcheck source=../lib/orchestrator-log.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/orchestrator-log.sh"
orch_log_start "pr-auto-rebase.sh" "$@"
trap 'orch_log_end "pr-auto-rebase.sh" "$?"' EXIT

LOCAL_REBASE_TIMEOUT_S="${CHUMP_PR_AUTO_REBASE_LOCAL_TIMEOUT_S:-120}"

# Given a whitespace-separated list of changed file paths, return the sorted,
# deduped set of custom merge-driver names configured for those paths per
# .gitattributes (INFRA-310 drivers). Empty output if none apply.
resolve_merge_drivers() {
    local repo_root="$1"; shift
    local files=("$@")
    [[ -f "$repo_root/.gitattributes" ]] || return 0
    local f driver
    for f in "${files[@]}"; do
        [[ -z "$f" ]] && continue
        driver="$(cd "$repo_root" && git check-attr merge -- "$f" 2>/dev/null | awk -F': ' '{print $3}')"
        if [[ -n "$driver" && "$driver" != "unspecified" ]]; then
            printf '%s\n' "$driver"
        fi
    done | sort -u | paste -sd, -
}

DRY_RUN=0
MAX_PER_HOUR=4
for a in "$@"; do
    case "$a" in
    --dry-run) DRY_RUN=1 ;;
    --max-per-hour) shift; MAX_PER_HOUR="$1" ;;
    --max-per-hour=*) MAX_PER_HOUR="${a#*=}" ;;
    esac
done

# Locate repo + ambient log.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"
COOLDOWN_FILE="$REPO_ROOT/.chump-locks/pr-auto-rebase-cooldown.jsonl"
mkdir -p "$(dirname "$COOLDOWN_FILE")"
touch "$COOLDOWN_FILE"

emit() {
    # $1=kind  $2=pr  $3=extra-fields (json fragment, optional)
    local kind="$1" pr="$2" extra="${3:-}"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local line
    if [[ -n "$extra" ]]; then
        line="{\"ts\":\"$ts\",\"kind\":\"$kind\",\"pr\":$pr,$extra}"
    else
        line="{\"ts\":\"$ts\",\"kind\":\"$kind\",\"pr\":$pr}"
    fi
    printf '%s\n' "$line" >> "$AMBIENT"
}

# How many times in the last hour have we rebased this PR? Caps runaway loops.
cooldown_count() {
    local pr="$1"
    local cutoff
    # macOS date doesn't have --date easily; use perl one-liner for portability.
    cutoff="$(perl -e 'use POSIX qw(strftime); print strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time-3600))')"
    awk -v pr="$pr" -v cutoff="$cutoff" -F '"' '
        $0 ~ ("\"pr\":" pr "[,}]") {
            # Extract ts (second quoted field)
            if ($4 >= cutoff) c++
        }
        END { print (c ? c : 0) }
    ' "$COOLDOWN_FILE"
}

# Find DIRTY-or-BEHIND PRs with auto-merge armed.
PRS_JSON="$(gh pr list \
    --state open \
    --limit 60 \
    --json number,mergeStateStatus,autoMergeRequest 2>/dev/null || echo '[]')"

if [[ -z "$PRS_JSON" || "$PRS_JSON" == "[]" ]]; then
    echo "[pr-auto-rebase] no open PRs (or gh unavailable)"
    exit 0
fi

# Targets: armed + (DIRTY|BEHIND|BLOCKED).
# INFRA-1838: BLOCKED added to handle the case where CI ran against an older
# main and is now stale (today's 2026-05-23 cascade: 13 PRs sat BLOCKED for
# hours because the old filter only caught DIRTY/BEHIND). Cooldown
# (MAX_PER_HOUR) prevents runaway nudging of PRs that are BLOCKED for genuine
# CI failure reasons.
#
# Bypass: CHUMP_PR_AUTO_REBASE_SKIP_BLOCKED=1 reverts to pre-INFRA-1838
#         filter (DIRTY|BEHIND only) — for forensic debugging.
STATE_FILTER='.mergeStateStatus == "DIRTY" or .mergeStateStatus == "BEHIND" or .mergeStateStatus == "BLOCKED"'
if [[ "${CHUMP_PR_AUTO_REBASE_SKIP_BLOCKED:-0}" == "1" ]]; then
    STATE_FILTER='.mergeStateStatus == "DIRTY" or .mergeStateStatus == "BEHIND"'
fi
TARGETS="$(printf '%s' "$PRS_JSON" | jq -r '
    .[]
    | select(.autoMergeRequest != null)
    | select('"$STATE_FILTER"')
    | "\(.number)\t\(.mergeStateStatus)"
')"

if [[ -z "$TARGETS" ]]; then
    echo "[pr-auto-rebase] no armed PRs needing rebase (DIRTY/BEHIND/BLOCKED)"
    exit 0
fi

# INFRA-2225: queue-aware throttle. Under saturation (many PRs in flight,
# merges landing slowly) a serial daemon can't keep pace — 2026-05-29
# overnight saw 8 BEHIND PRs pile up with 25+ in flight. When in-flight
# count exceeds 15 AND the average gap between the last few merges exceeds
# 15 min, prioritize already-armed BEHIND PRs (cheap, mechanical unblocks)
# ahead of DIRTY/BLOCKED ones so the daemon clears the easy backlog first.
avg_merge_gap_min() {
    local merges ts=() i total=0 count=0 t1 t2 s1 s2 diff
    merges="$(gh pr list --state merged --limit 6 --json mergedAt -q '.[].mergedAt' 2>/dev/null | sort -r)"
    while IFS= read -r line; do
        [[ -n "$line" ]] && ts+=("$line")
    done <<< "$merges"
    if (( ${#ts[@]} < 2 )); then
        echo 0
        return
    fi
    for (( i=0; i<${#ts[@]}-1; i++ )); do
        t1="${ts[$i]}"; t2="${ts[$((i+1))]}"
        s1="$(date -u -d "$t1" +%s 2>/dev/null || date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$t1" +%s 2>/dev/null)"
        s2="$(date -u -d "$t2" +%s 2>/dev/null || date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$t2" +%s 2>/dev/null)"
        [[ -z "$s1" || -z "$s2" ]] && continue
        diff=$(( (s1 - s2) / 60 ))
        (( diff < 0 )) && continue
        total=$((total+diff))
        count=$((count+1))
    done
    if (( count == 0 )); then echo 0; else echo $(( total / count )); fi
}

INFLIGHT_COUNT="$(printf '%s' "$PRS_JSON" | jq 'length' 2>/dev/null || echo 0)"
AVG_MERGE_GAP_MIN="$(avg_merge_gap_min)"
THROTTLE_MODE=0
if [[ "${CHUMP_PR_AUTO_REBASE_NO_THROTTLE:-0}" != "1" ]] && (( INFLIGHT_COUNT > 15 )) && (( AVG_MERGE_GAP_MIN > 15 )); then
    THROTTLE_MODE=1
    echo "[pr-auto-rebase] THROTTLE: inflight=$INFLIGHT_COUNT avg_merge_gap_min=$AVG_MERGE_GAP_MIN — prioritizing BEHIND PRs"
    emit pr_auto_rebase_throttle 0 "\"inflight\":$INFLIGHT_COUNT,\"avg_merge_gap_min\":$AVG_MERGE_GAP_MIN"
    TARGETS="$(printf '%s\n' "$TARGETS" | awk -F'\t' '{print ($2=="BEHIND"?0:1)"\t"$0}' | sort -k1,1n | cut -f2- )"
fi

# INFRA-2225: bounded concurrency. The daemon used to rebase one PR at a
# time; under saturation (25+ PRs in flight) serial `gh pr update-branch`
# calls can't keep pace with the arrival rate. Batch up to MAX_CONCURRENT
# in parallel via background jobs, capped with `wait -n`.
MAX_CONCURRENT="${CHUMP_PR_AUTO_REBASE_MAX_CONCURRENT:-5}"
RESULTS_DIR="$(mktemp -d -t chump-rebase-results-XXXXXX)"
trap 'rm -rf "$RESULTS_DIR"; orch_log_end "pr-auto-rebase.sh" "$?"' EXIT

# Runs the full per-PR rebase flow (cooldown already checked by caller) and
# writes a one-word verdict (rebased|skipped|failed|deferred) to
# "$RESULTS_DIR/$PR" so the parent can tally after all jobs complete. Safe to
# background: all state it touches (COOLDOWN_FILE, AMBIENT, per-branch
# lockfiles) is either append-only or keyed per-PR/per-branch.
process_pr() {
    local PR="$1" STATE="$2"
    local RESULT_FILE="$RESULTS_DIR/$PR"
    orch_log_step "processing PR #$PR state=$STATE"

    # INFRA-1974 (H5 critique fix): per-branch advisory lock. Prevents this
    # daemon from racing an operator-initiated `git rebase origin/main` on
    # the same branch — observed live on 2026-05-25 04:51:46Z (PR #2566) and
    # again at 16:31:07Z (PR #2574) where the daemon's parallel rebase
    # produced a duplicate CI run that doubled the queue cost. Operator
    # rebases should take `flock -n .chump-locks/rebase-<branch>.lock`
    # before touching the branch; that's a follow-up gap. For now the
    # daemon side defers cleanly when the lock can't be acquired.
    #
    # Bypass: CHUMP_PR_AUTO_REBASE_NO_LOCK=1 reverts to pre-1974 behavior
    # (always rebase regardless of operator activity).
    local BRANCH BRANCH_SAFE LOCKFILE REBASE_OUTPUT_FILE WT
    local CHANGED_FILES=() REBASE_TIMED_OUT REBASE_EXIT_STATUS CONFLICT_FILES_JSON DRIVERS ts _prv

    BRANCH="$(gh pr view "$PR" --json headRefName -q .headRefName 2>/dev/null)"
    if [[ -z "$BRANCH" ]]; then
        echo "[pr-auto-rebase] WARN #$PR — could not resolve branch name; skipping"
        emit pr_auto_rebase_skipped "$PR" "\"reason\":\"branch_resolve_failed\""
        echo "skipped" > "$RESULT_FILE"
        return
    fi
    # Sanitize branch name for use in filename (e.g. chump/foo-bar → chump_foo-bar)
    BRANCH_SAFE="${BRANCH//\//_}"
    LOCKFILE="$REPO_ROOT/.chump-locks/rebase-${BRANCH_SAFE}.lock"
    if [[ "${CHUMP_PR_AUTO_REBASE_NO_LOCK:-0}" != "1" ]] && command -v flock >/dev/null 2>&1; then
        # Acquire lock in subshell so it auto-releases at scope exit. If we
        # can't get it in 1s, defer this PR — operator is rebasing.
        REBASE_OUTPUT_FILE="$(mktemp)"
        (
            exec 9>"$LOCKFILE"
            if ! flock -n -w 1 9; then
                echo "[pr-auto-rebase] DEFER #$PR — branch $BRANCH lock held (operator rebasing?)"
                emit pr_auto_rebase_deferred_for_operator "$PR" "\"reason\":\"lock_held\",\"branch\":\"$BRANCH\""
                exit 2  # signal deferred to outer
            fi
            # Lock held — do the rebase. Re-source the logic by exporting and
            # re-running the core action; simpler to just inline a redirect.
            true
        )
        if [[ $? -eq 2 ]]; then
            rm -f "$REBASE_OUTPUT_FILE"
            echo "deferred" > "$RESULT_FILE"
            return
        fi
        rm -f "$REBASE_OUTPUT_FILE"
        # Re-acquire the lock for the actual rebase action below. Subshell
        # above proved the lock is available; this scope holds it through
        # the gh API + local-rebase fallback.
        exec 9>"$LOCKFILE"
        flock -n 9 || {
            echo "[pr-auto-rebase] DEFER #$PR — lock taken between probe and acquire (rare race)"
            emit pr_auto_rebase_deferred_for_operator "$PR" "\"reason\":\"lock_race\",\"branch\":\"$BRANCH\""
            exec 9>&-
            echo "deferred" > "$RESULT_FILE"
            return
        }
    fi

    echo "[pr-auto-rebase] rebasing #$PR (state=$STATE)..."
    if gh pr update-branch "$PR" 2>&1 | tail -3; then
        echo "[pr-auto-rebase] OK #$PR"
        emit pr_auto_rebased "$PR" "\"prior_state\":\"$STATE\",\"trigger\":\"chump-pr-auto-rebase\""
        ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '{"ts":"%s","pr":%s,"state":"%s"}\n' "$ts" "$PR" "$STATE" >> "$COOLDOWN_FILE"
        echo "rebased" > "$RESULT_FILE"
    else
        # INFRA-1958: gh pr update-branch returns false-positive conflicts.
        # Try local rebase fallback before escalating to pr_auto_rebase_failed.
        if [[ "${CHUMP_PR_AUTO_REBASE_NO_FALLBACK:-0}" == "1" ]]; then
            echo "[pr-auto-rebase] FAIL #$PR — gh pr update-branch returned non-zero (fallback disabled by env)"
            emit pr_auto_rebase_failed "$PR" "\"prior_state\":\"$STATE\",\"fallback\":\"disabled\""
            echo "failed" > "$RESULT_FILE"
            if [[ "${CHUMP_PR_AUTO_REBASE_NO_LOCK:-0}" != "1" ]] && command -v flock >/dev/null 2>&1; then
                exec 9>&- 2>/dev/null || true
            fi
            return
        fi
        echo "[pr-auto-rebase] gh API reports conflict — trying local rebase fallback (INFRA-1958)..."
        BRANCH="$(gh pr view "$PR" --json headRefName -q .headRefName 2>/dev/null)"
        if [[ -z "$BRANCH" ]]; then
            echo "[pr-auto-rebase] FAIL #$PR — could not resolve branch name"
            emit pr_auto_rebase_failed "$PR" "\"prior_state\":\"$STATE\",\"fallback\":\"branch_resolve_failed\""
            echo "failed" > "$RESULT_FILE"
            if [[ "${CHUMP_PR_AUTO_REBASE_NO_LOCK:-0}" != "1" ]] && command -v flock >/dev/null 2>&1; then
                exec 9>&- 2>/dev/null || true
            fi
            return
        fi
        WT="$(mktemp -d -t chump-rebase-fb-XXXXXX)"
        # Fetch the branch fresh; ignore failures (older git may not support --quiet).
        git -C "$REPO_ROOT" fetch origin "$BRANCH" --quiet 2>/dev/null || true
        git -C "$REPO_ROOT" fetch origin main --quiet 2>/dev/null || true
        if git -C "$REPO_ROOT" worktree add "$WT" "origin/$BRANCH" >/dev/null 2>&1; then
            # Changed-file list (pre-rebase) — used both for driver-name
            # reporting on success and conflict-file reporting on failure.
            CHANGED_FILES=()
            while IFS= read -r _f; do
                [[ -n "$_f" ]] && CHANGED_FILES+=("$_f")
            done < <(cd "$WT" && git diff --name-only origin/main...HEAD 2>/dev/null)

            REBASE_TIMED_OUT=0
            if timeout "${LOCAL_REBASE_TIMEOUT_S}s" bash -c "cd '$WT' && git rebase origin/main" >/dev/null 2>&1; then
                # INFRA-1526: post-rebase hunk-drop check in fallback worktree.
                # Warn only (don't block push) — this is already a fallback recovery
                # path; emitting the event surfaces the drop for ops-audit without
                # stalling the rebase queue.
                _prv="$REPO_ROOT/scripts/coord/post-rebase-verify.sh"
                if [[ -x "$_prv" ]]; then
                    (cd "$WT" && CHUMP_AMBIENT="$AMBIENT" bash "$_prv") || \
                        echo "[pr-auto-rebase] WARN #$PR — post-rebase-verify found hunk drops (rebase_hunk_dropped emitted)"
                fi
                if (cd "$WT" && git push origin "HEAD:$BRANCH" --force-with-lease >/dev/null 2>&1); then
                    DRIVERS="$(resolve_merge_drivers "$REPO_ROOT" "${CHANGED_FILES[@]}")"
                    echo "[pr-auto-rebase] OK #$PR — local-rebase fallback succeeded (gh API was false-positive; drivers=${DRIVERS:-none})"
                    emit pr_auto_rebase_fallback "$PR" "\"prior_state\":\"$STATE\",\"trigger\":\"chump-pr-auto-rebase\",\"reason\":\"gh_api_false_positive\""
                    emit pr_auto_rebase_recovered "$PR" "\"prior_state\":\"$STATE\",\"drivers\":\"$DRIVERS\""
                    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
                    printf '{"ts":"%s","pr":%s,"state":"%s"}\n' "$ts" "$PR" "$STATE" >> "$COOLDOWN_FILE"
                    echo "rebased" > "$RESULT_FILE"
                else
                    echo "[pr-auto-rebase] FAIL #$PR — local rebase OK but push failed (lock contention?)"
                    emit pr_auto_rebase_failed "$PR" "\"prior_state\":\"$STATE\",\"fallback\":\"push_failed\""
                    echo "failed" > "$RESULT_FILE"
                fi
            else
                REBASE_EXIT_STATUS=$?
                if [[ "$REBASE_EXIT_STATUS" -eq 124 ]]; then
                    REBASE_TIMED_OUT=1
                fi
                # Capture unresolved-conflict file list before aborting.
                CONFLICT_FILES_JSON="$(cd "$WT" && git diff --name-only --diff-filter=U 2>/dev/null | \
                    jq -R -s -c 'split("\n") | map(select(length > 0))' 2>/dev/null || echo '[]')"
                # Abort any in-progress rebase before removing worktree
                (cd "$WT" && git rebase --abort >/dev/null 2>&1) || true
                if [[ "$REBASE_TIMED_OUT" -eq 1 ]]; then
                    echo "[pr-auto-rebase] FAIL #$PR — local rebase exceeded ${LOCAL_REBASE_TIMEOUT_S}s timeout"
                    emit pr_auto_rebase_failed "$PR" "\"prior_state\":\"$STATE\",\"fallback\":\"local_rebase_timeout\""
                    emit pr_auto_rebase_unresolvable "$PR" "\"prior_state\":\"$STATE\",\"reason\":\"timeout\",\"conflict_files\":$CONFLICT_FILES_JSON"
                else
                    echo "[pr-auto-rebase] FAIL #$PR — true conflict confirmed by local rebase (sibling rescue needed)"
                    emit pr_auto_rebase_failed "$PR" "\"prior_state\":\"$STATE\",\"fallback\":\"local_rebase_also_failed\""
                    emit pr_auto_rebase_unresolvable "$PR" "\"prior_state\":\"$STATE\",\"reason\":\"conflict\",\"conflict_files\":$CONFLICT_FILES_JSON"
                fi
                echo "failed" > "$RESULT_FILE"
            fi
            git -C "$REPO_ROOT" worktree remove "$WT" --force >/dev/null 2>&1 || true
        else
            echo "[pr-auto-rebase] FAIL #$PR — could not create worktree for fallback"
            emit pr_auto_rebase_failed "$PR" "\"prior_state\":\"$STATE\",\"fallback\":\"worktree_failed\""
            echo "failed" > "$RESULT_FILE"
        fi
        rm -rf "$WT" 2>/dev/null || true
    fi

    # INFRA-1974: release per-branch lock at end of iteration so the next
    # PR's iteration starts clean. The fd 9 was opened above with `exec`
    # which has loop-scope; close explicitly to release flock.
    if [[ "${CHUMP_PR_AUTO_REBASE_NO_LOCK:-0}" != "1" ]] && command -v flock >/dev/null 2>&1; then
        exec 9>&- 2>/dev/null || true
    fi
}

# INFRA-2225: dispatch loop. Cooldown check stays on the main thread (cheap,
# avoids racing writes to COOLDOWN_FILE for the same PR); the actual rebase
# work backgrounds into process_pr, capped at MAX_CONCURRENT in-flight jobs
# via `wait -n`.
REBASED=0
SKIPPED=0
FAILED=0
DEFERRED=0
JOBS_IN_FLIGHT=0
while IFS=$'\t' read -r PR STATE; do
    [[ -z "$PR" ]] && continue
    count="$(cooldown_count "$PR")"
    if (( count >= MAX_PER_HOUR )); then
        echo "[pr-auto-rebase] SKIP #$PR — cooldown ($count rebases in last hour, max=$MAX_PER_HOUR)"
        emit pr_auto_rebase_skipped "$PR" "\"reason\":\"cooldown\",\"count_last_hour\":$count"
        SKIPPED=$((SKIPPED+1))
        continue
    fi
    if (( DRY_RUN )); then
        echo "[pr-auto-rebase] DRY-RUN would rebase #$PR (state=$STATE, prior rebases this hour=$count)"
        continue
    fi

    process_pr "$PR" "$STATE" &
    JOBS_IN_FLIGHT=$((JOBS_IN_FLIGHT+1))
    if (( JOBS_IN_FLIGHT >= MAX_CONCURRENT )); then
        wait -n 2>/dev/null || wait
        JOBS_IN_FLIGHT=$((JOBS_IN_FLIGHT-1))
    fi
done <<< "$TARGETS"
wait

for f in "$RESULTS_DIR"/*; do
    [[ -f "$f" ]] || continue
    case "$(cat "$f" 2>/dev/null)" in
        rebased) REBASED=$((REBASED+1)) ;;
        skipped) SKIPPED=$((SKIPPED+1)) ;;
        failed) FAILED=$((FAILED+1)) ;;
        deferred) DEFERRED=$((DEFERRED+1)) ;;
    esac
done

echo "[pr-auto-rebase] done — rebased=$REBASED skipped=$SKIPPED failed=$FAILED deferred=$DEFERRED concurrency=$MAX_CONCURRENT throttle=$THROTTLE_MODE"
orch_log_step "done rebased=$REBASED skipped=$SKIPPED failed=$FAILED deferred=$DEFERRED"
exit 0
