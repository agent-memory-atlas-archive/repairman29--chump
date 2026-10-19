#!/usr/bin/env bash
# verified-wait.sh — CREDIBLE-1554 (PHASE-R R3)
#
# The in-job wait loop for the sole required `verified` check, under a GitHub
# native merge queue (umbrella CREDIBLE-1555). Replaces the old
# "poll-120s-then-aggregate-once" step pair in ci.yml's `verified` job.
#
# WHY: a merge queue removes a PR from the queue the instant a required check
# concludes FAILURE — there is no second pass. The previous verified job polled
# the cross-workflow lanes (audit, ACP smoke) for only 120s, far shorter than a
# real audit (15-40 min), so the first pass exited PENDING (aggregator exit 2 →
# job FAILURE) and relied on verified-recompute.yml re-running later. On a PR
# that heals; in a merge queue the ejection already happened. The first verdict
# must be the right one.
#
# WHAT: loop every --interval-s up to --timeout-s (default 90 min = the ruleset
# check_response_timeout), re-classifying every lane each pass via the existing
# decision core (scripts/ci/aggregator-verified.sh). Local lanes are passed as
# already-terminal needs.*.result strings; cross-workflow lanes are re-snapshot
# each pass via scripts/ci/poll-cross-workflow-checks.sh --snapshot (one fetch,
# no fail-close).
#
#   - PASS  (aggregator exit 0): every lane green or legitimately skipped — exit 0.
#   - FAIL  (aggregator exit 1): a REAL red lane (local or cross) — exit 1
#             immediately (short-circuit; no reason to keep waiting).
#   - PENDING (aggregator exit 2): at least one lane not yet terminal (running
#             OR never-seen) and nothing red — keep polling. This folds
#             RESILIENT-1617's lane-seen rule: a lane that has not posted a
#             check run yet is PENDING, never FAIL and never PASS, for the whole
#             wait. The ONLY way a still-pending lane becomes a FAILURE is the
#             timeout below.
#   - TIMEOUT: --timeout-s elapsed while still PENDING — conclude FAILURE with a
#             legible reason naming the lanes that never concluded, and exit 1.
#
# This behavior is IDENTICAL on pull_request and merge_group events (the event
# only changes the SHA ci.yml passes in via --sha). --event-name is logging-only.
#
# aggregator-verified.sh and poll-cross-workflow-checks.sh keep their existing
# exit codes and contracts; no new bypass/skip env var is introduced (the wait
# lives here, driven by CLI flags).
#
# Usage:
#   verified-wait.sh --sha SHA \
#       --lane "name=result" [--lane ...] \       # local (needs.*.result) lanes
#       --cross "check name" [--cross ...] \       # cross-workflow lanes to poll
#       [--pr N] [--event-name NAME] \
#       [--timeout-s N] [--interval-s N] [--repo owner/repo]
#
# Exit codes: 0=PASS  1=FAIL (real red lane OR timeout)  3=invocation error.
#
# Requires: gh CLI (authenticated via GH_TOKEN/GITHUB_TOKEN), jq — only when at
# least one --cross lane is given.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || { cd "$(dirname "$0")/../.." && pwd; })"
POLL="$REPO_ROOT/scripts/ci/poll-cross-workflow-checks.sh"
AGG="$REPO_ROOT/scripts/ci/aggregator-verified.sh"

SHA=""
PR=""
EVENT_NAME="${GITHUB_EVENT_NAME:-}"
TIMEOUT_S=5400      # 90 min — matches the ruleset check_response_timeout
INTERVAL_S=30
REPO="${GH_REPO:-repairman29/chump}"
LOCAL_LANES=()
CROSS_CHECKS=()

usage() { grep '^#' "$0" | sed 's/^# \?//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sha)         SHA="$2"; shift 2 ;;
        --pr)          PR="$2"; shift 2 ;;
        --event-name)  EVENT_NAME="$2"; shift 2 ;;
        --lane)        LOCAL_LANES+=("$2"); shift 2 ;;
        --cross)       CROSS_CHECKS+=("$2"); shift 2 ;;
        --timeout-s)   TIMEOUT_S="$2"; shift 2 ;;
        --interval-s)  INTERVAL_S="$2"; shift 2 ;;
        --repo)        REPO="$2"; shift 2 ;;
        -h|--help)     usage; exit 0 ;;
        *) echo "[verified-wait] unknown arg: $1" >&2; exit 3 ;;
    esac
done

if [[ -z "$SHA" ]]; then
    echo "[verified-wait] ERROR: --sha is required" >&2
    exit 3
fi
if [[ ${#LOCAL_LANES[@]} -eq 0 && ${#CROSS_CHECKS[@]} -eq 0 ]]; then
    echo "[verified-wait] ERROR: at least one --lane or --cross is required" >&2
    exit 3
fi

# Static poll argv (snapshot mode ignores timeout/interval).
POLL_ARGS=(--sha "$SHA" --repo "$REPO" --snapshot)
for c in "${CROSS_CHECKS[@]}"; do POLL_ARGS+=(--check "$c"); done

now_s() { date +%s; }

deadline=$(( $(now_s) + TIMEOUT_S ))
attempt=0

while true; do
    attempt=$((attempt + 1))

    # 1. Re-snapshot the cross-workflow lanes (one Checks-API fetch, no fail-close).
    cross_out=""
    if [[ ${#CROSS_CHECKS[@]} -gt 0 ]]; then
        cross_out="$(bash "$POLL" "${POLL_ARGS[@]}" 2>/dev/null || true)"
    fi

    # 2. Assemble the full lane set (local + cross) for the decision core.
    agg_args=()
    for l in "${LOCAL_LANES[@]}"; do agg_args+=(--lane "$l"); done
    pending_cross=()
    declare -A seen_cross=()
    if [[ -n "$cross_out" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            name="${line%%=*}"
            res="${line#*=}"
            seen_cross["$name"]=1
            agg_args+=(--lane "${name}=${res}")
            case "$res" in
                in_progress|queued|"") pending_cross+=("$name") ;;
            esac
        done <<< "$cross_out"
    fi
    # Fail-SAFE, never fail-OPEN: any declared cross lane the snapshot did not
    # emit (gh transient error, empty output) is treated as PENDING, NOT dropped
    # — dropping it would let the aggregator PASS without the audit/ACP verdict.
    for c in "${CROSS_CHECKS[@]}"; do
        if [[ -z "${seen_cross[$c]:-}" ]]; then
            agg_args+=(--lane "${c}=in_progress")
            pending_cross+=("$c")
        fi
    done
    agg_args+=(--pr "$PR" --sha "$SHA")

    # 3. Classify. Intermediate passes write ambient to /dev/null to avoid
    #    emitting a verified_aggregator_decision on every poll; the terminal
    #    verdict (below) emits once to the real log.
    set +e
    agg_out="$(CHUMP_AMBIENT_LOG=/dev/null bash "$AGG" "${agg_args[@]}" 2>&1)"
    rc=$?
    set -e

    case "$rc" in
        0)
            echo "$agg_out"
            bash "$AGG" "${agg_args[@]}" >/dev/null 2>&1 || true  # emit ambient once
            echo "[verified-wait] VERDICT=PASS — every lane green or legitimately skipped (event=${EVENT_NAME:-?} sha=${SHA} after ${attempt} poll(s))"
            exit 0
            ;;
        1)
            echo "$agg_out"
            bash "$AGG" "${agg_args[@]}" >/dev/null 2>&1 || true  # emit ambient once
            echo "[verified-wait] VERDICT=FAIL — a real red lane concluded failure (event=${EVENT_NAME:-?} sha=${SHA} after ${attempt} poll(s))" >&2
            exit 1
            ;;
        2)
            : ;;  # PENDING — fall through to the wait/timeout gate below
        *)
            echo "$agg_out" >&2
            echo "[verified-wait] ERROR: aggregator invocation error (exit $rc)" >&2
            exit 3
            ;;
    esac

    # 4. Still PENDING. Fail only once the wait window is exhausted.
    now=$(now_s)
    if [[ "$now" -ge "$deadline" ]]; then
        reason="${pending_cross[*]:-}"
        [[ -z "$reason" ]] && reason="<a lane never reached a terminal state>"
        echo "$agg_out"
        echo "[verified-wait] TIMEOUT: waited ${TIMEOUT_S}s (${attempt} poll(s)); lanes still PENDING at timeout: ${reason}; concluding FAILURE (event=${EVENT_NAME:-?} sha=${SHA})" >&2
        exit 1
    fi

    remaining=$(( deadline - now ))
    sleep_s="$INTERVAL_S"
    (( sleep_s > remaining )) && sleep_s="$remaining"
    (( sleep_s < 1 )) && sleep_s=1
    echo "[verified-wait] poll #${attempt}: PENDING (waiting on: ${pending_cross[*]:-<none named>}); ${remaining}s left, sleeping ${sleep_s}s"
    sleep "$sleep_s"
done
