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
# Usage:
#   poll-cross-workflow-checks.sh --sha SHA --check "name" [--check "name" ...] \
#       [--repo owner/repo] [--timeout-s N] [--interval-s N]
#
# Requires: gh CLI (authenticated via GH_TOKEN/GITHUB_TOKEN), jq.

set -euo pipefail

REPO="${GH_REPO:-repairman29/chump}"
SHA=""
CHECKS=()
TIMEOUT_S=600
INTERVAL_S=15

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

while true; do
    runs_json="$(fetch_check_runs)"
    all_terminal=1
    for c in "${CHECKS[@]}"; do
        # RESILIENT-338: a lane that failed then was retried to success must read
        # success. started_at ordering is unreliable across reruns, so pick ANY
        # completed run with conclusion=="success"; else fall back to the latest run.
        entry="$(echo "$runs_json" | jq -c --arg n "$c" '[.[] | select(.name == $n)] as $runs | ([$runs[] | select(.conclusion == "success")] | last) // ($runs | sort_by(.started_at) | last) // empty')"
        if [[ -z "$entry" ]]; then
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
