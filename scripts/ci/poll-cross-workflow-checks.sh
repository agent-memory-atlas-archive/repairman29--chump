#!/usr/bin/env bash
# poll-cross-workflow-checks.sh — CREDIBLE-269 (SHIP-INFRA 1/7)
#
# audit.yml and integrations.yml (ACP protocol smoke test) are separate
# GitHub Actions workflows from ci.yml, so the `verified` aggregator job
# cannot pull their results via same-workflow `needs:`. This script polls
# the Checks API for a given commit SHA until every named check reaches a
# terminal state (or a timeout is hit), then prints one `name=result` line
# per check in the exact vocabulary scripts/ci/aggregator-verified.sh already
# understands (success | failure | cancelled | skipped).
#
# RESILIENT-1561: at --timeout-s, a check that was SEEN but is still
# queued/in_progress is reported as `in_progress` (aggregator-verified.sh
# classifies that PENDING, exit 2) — NOT `failure`. A heavy audit.yml still
# running is not a failed audit; reporting failure caused false-FAIL +
# rebase + full-rerun loops. A check that NEVER appeared at all (no check-run
# registered) is still reported `failure` (fail-closed: the "wedge waiting on
# a context that'll never post" mode).
#
# RESILIENT-1617: the `audit` aggregate job posts its own check-run only AFTER
# its shard matrix (audit-shard (N)) finishes — needs:-gated jobs get no
# check-run until their dependencies complete. So between poll start and audit
# completion there is NO check-run named `audit` at all, and RESILIENT-1561's
# fail-closed path mis-classified that still-running audit as `failure` on
# all-green PRs (e.g. #5565, 2026-10-17; and every push to main whose audit
# outlived the 120s grace). A lane is therefore ALSO counted as SEEN (and kept
# `in_progress`, never failed) when EITHER:
#   - a shard-style member check-run — one whose name starts with the lane name
#     followed by a space, `(`, or `-` (so `audit-shard (N)` belongs to the
#     `audit` lane) — is queued or in_progress, OR
#   - the lane's backing workflow run (audit.yml for `audit`) reports a run that
#     is not completed via `gh run list --workflow <wf> --commit <sha>`.
# Once the aggregate `audit` check-run finally posts, the exact-name match below
# resolves it to success/failure as usual.
#
# Usage:
#   poll-cross-workflow-checks.sh --sha SHA --check "name" [--check "name" ...] \
#       [--repo owner/repo] [--timeout-s N] [--interval-s N] [--snapshot]
#
# CREDIBLE-1554: --snapshot does exactly ONE Checks-API fetch and prints each
# lane's current classification with NO fail-close — any not-yet-terminal lane
# (seen-but-running OR never-seen) reads `in_progress` (which the aggregator
# classifies PENDING). The in-job wait and the single fail-on-timeout decision
# live in scripts/ci/verified-wait.sh, which loops this snapshot; a never-seen
# lane is PENDING here, never FAIL. The default (non-snapshot) mode keeps its
# own wait loop + fail-closed-at-timeout behavior for existing callers.
#
# Requires: gh CLI (authenticated via GH_TOKEN/GITHUB_TOKEN), jq.

set -euo pipefail

REPO="${GH_REPO:-repairman29/chump}"
SHA=""
CHECKS=()
TIMEOUT_S=600
INTERVAL_S=15
SNAPSHOT=0

usage() {
    grep '^#' "$0" | sed 's/^# \?//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sha)         SHA="$2"; shift 2 ;;
        --check)       CHECKS+=("$2"); shift 2 ;;
        --repo)        REPO="$2"; shift 2 ;;
        --timeout-s)   TIMEOUT_S="$2"; shift 2 ;;
        --interval-s)  INTERVAL_S="$2"; shift 2 ;;
        # CREDIBLE-1554: single-pass classification with NO fail-close. One
        # Checks-API fetch, then print each lane's current state (terminal
        # conclusion, or `in_progress` for anything not-yet-terminal — whether
        # seen-but-running OR genuinely never-seen). The wait + timeout decision
        # moves OUT of this script and INTO scripts/ci/verified-wait.sh, which
        # owns the 90-min in-job wait under a GitHub merge queue. --timeout-s /
        # --interval-s are ignored in snapshot mode.
        --snapshot)    SNAPSHOT=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *) echo "[poll-cross-workflow-checks] unknown arg: $1" >&2; exit 3 ;;
    esac
done

if [[ -z "$SHA" || ${#CHECKS[@]} -eq 0 ]]; then
    echo "[poll-cross-workflow-checks] ERROR: --sha and at least one --check are required" >&2
    exit 3
fi

deadline=$(( $(date +%s) + TIMEOUT_S ))
declare -A RESULT
declare -A SEEN
for c in "${CHECKS[@]}"; do RESULT["$c"]="in_progress"; SEEN["$c"]=0; done

fetch_check_runs() {
    gh api "repos/${REPO}/commits/${SHA}/check-runs" --paginate -q '.check_runs' 2>/dev/null || echo '[]'
}

# RESILIENT-1617: which workflow backs a cross-workflow lane whose aggregate
# check-run lags its shard matrix. Only the `audit` lane has this shape today
# (audit.yml: audit-shard matrix -> `audit` aggregate). Extend here if another
# lane gains the same needs:-gated aggregate pattern.
backing_workflow_for() {
    case "$1" in
        audit) echo "audit.yml" ;;
        *)     echo "" ;;
    esac
}

# A lane is SEEN-but-running when a shard-style member check-run — name starts
# with "<lane> ", "<lane>(" or "<lane>-" (so `audit-shard (N)` -> `audit`) — is
# queued or in_progress. startswith() is literal, so lane names containing jq
# regex metacharacters (e.g. the ACP lane's parentheses/slash) are safe.
lane_has_running_member() {
    local lane="$1" json="$2"
    echo "$json" | jq -e --arg n "$lane" '
        any(.[];
            ((.name | startswith($n + " "))
             or (.name | startswith($n + "("))
             or (.name | startswith($n + "-")))
            and (.status == "queued" or .status == "in_progress"))' >/dev/null 2>&1
}

# Fallback SEEN signal: the lane's backing workflow run for this SHA exists and
# is not completed. Covers the transient where all shards completed but the
# aggregate check-run has not posted yet (workflow still finishing).
backing_workflow_running() {
    local lane="$1" sha="$2" wf rows
    wf="$(backing_workflow_for "$lane")"
    [[ -n "$wf" ]] || return 1
    rows="$(gh run list --workflow "$wf" --commit "$sha" --json status --limit 20 2>/dev/null || echo '[]')"
    echo "$rows" | jq -e 'any(.[]; .status != "completed")' >/dev/null 2>&1
}

while true; do
    runs_json="$(fetch_check_runs)"
    all_terminal=1
    for c in "${CHECKS[@]}"; do
        # RESILIENT-338: a lane that failed then was retried to success must read
        # success. started_at ordering is unreliable across reruns, so pick ANY
        # completed run with conclusion=="success"; else fall back to the latest run.
        entry="$(echo "$runs_json" | jq -c --arg n "$c" '[.[] | select(.name == $n)] as $runs | ([$runs[] | select(.conclusion == "success")] | last) // ($runs | sort_by(.started_at) | last) // empty')"
        if [[ -z "$entry" ]]; then
            # RESILIENT-1617: no check-run named exactly "$c" yet. The audit
            # aggregate posts its check-run only after its shards finish, so
            # mark the lane SEEN-but-running (stays in_progress, never
            # fail-closed) when a shard member is queued/in_progress or the
            # backing workflow run has not completed. Otherwise genuinely unseen.
            if lane_has_running_member "$c" "$runs_json" || backing_workflow_running "$c" "$SHA"; then
                SEEN["$c"]=1
            fi
            all_terminal=0
            continue
        fi
        SEEN["$c"]=1
        status="$(echo "$entry" | jq -r '.status')"
        if [[ "$status" != "completed" ]]; then
            all_terminal=0
            continue
        fi
        conclusion="$(echo "$entry" | jq -r '.conclusion // ""')"
        case "$conclusion" in
            success)                            RESULT["$c"]="success" ;;
            failure|timed_out|action_required|stale) RESULT["$c"]="failure" ;;
            cancelled)                           RESULT["$c"]="cancelled" ;;
            skipped|neutral)                     RESULT["$c"]="skipped" ;;
            *)                                   RESULT["$c"]="failure" ;;
        esac
    done

    # CREDIBLE-1554: snapshot mode — print the current per-lane classification
    # after exactly ONE fetch and exit, WITHOUT the post-loop fail-close. Any
    # not-yet-terminal lane (seen-but-running OR genuinely never-seen) reads
    # `in_progress`, which aggregator-verified.sh classifies PENDING (exit 2).
    # verified-wait.sh loops this snapshot and owns the 90-min wait + the single
    # fail-on-timeout decision, so a lane that has not posted yet is PENDING
    # here, never FAIL — folding RESILIENT-1617's lane-seen rule into one place.
    if [[ "$SNAPSHOT" -eq 1 ]]; then
        for c in "${CHECKS[@]}"; do
            printf '%s=%s\n' "$c" "${RESULT[$c]}"
        done
        exit 0
    fi

    if [[ "$all_terminal" -eq 1 ]]; then
        break
    fi
    if [[ $(date +%s) -ge $deadline ]]; then
        echo "[poll-cross-workflow-checks] WARN: timed out after ${TIMEOUT_S}s waiting on: ${CHECKS[*]} (still-running lanes stay pending; never-seen lanes fail-closed)" >&2
        break
    fi
    sleep "$INTERVAL_S"
done

for c in "${CHECKS[@]}"; do
    # never-seen at timeout => fail-closed; seen-but-still-running => stays in_progress (PENDING)
    if [[ "${RESULT[$c]}" == "in_progress" && "${SEEN[$c]}" -eq 0 ]]; then
        RESULT["$c"]="failure"
    fi
    printf '%s=%s\n' "$c" "${RESULT[$c]}"
done
