#!/usr/bin/env bash
# verified-wait.sh — CREDIBLE-1554 (PHASE-R R3)
#
# The in-job wait loop for the sole required `verified` check, under a GitHub
# native merge queue (umbrella CREDIBLE-1555). ci.yml's `verified` job runs this
# script as its SINGLE step (it replaced the old "poll-120s-then-aggregate-once"
# step pair); the wiring is pinned by scripts/ci/test-ci-verified-shape.sh.
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
# The SAME lane set is classified on the event SHA for EVERY event —
# pull_request, merge_group, push and workflow_dispatch alike (CREDIBLE-1554
# item 5, Chief-binding): the six local lanes plus the two cross-workflow lanes
# (audit, ACP) are one list, defined once at the call site and never mutated by
# event. --event-name selects only the WAIT BUDGET, not the lanes:
#   - pull_request / merge_group / push: the full --timeout-s (default 90 min =
#     the ruleset check_response_timeout), because a real audit takes 15-40 min
#     and the merge queue has no second pass.
#   - workflow_dispatch: a SHORT bounded window (DISPATCH_TIMEOUT_S, default
#     300s). A dispatch re-run (the INFRA-1395 grace window) is a manual probe,
#     not the authoritative pull_request/merge_group pass, so it must not block a
#     human for 90 min — but it STILL classifies the cross lanes on the SHA. The
#     cross-workflow runs for the real event already posted on that SHA
#     (required-check-monitor.sh dispatches ci.yml on the PR head), so a dispatch
#     that finds audit/ACP red, still running, or never-seen at the end of its
#     short window concludes FAILURE — never a silent PASS past an unseen or red
#     cross lane. An explicit --timeout-s always overrides the per-event default.
#
# aggregator-verified.sh and poll-cross-workflow-checks.sh keep their existing
# exit codes and contracts; no new bypass/skip env var is introduced (the wait
# and its per-event budget live here, driven by CLI flags).
#
# Usage:
#   verified-wait.sh --sha SHA \
#       --lane "name=result" [--lane ...] \       # local (needs.*.result) lanes
#       --cross "check name" [--cross ...] \       # cross-workflow lanes to poll
#       [--pr N] [--event-name NAME] \
#       [--timeout-s N] [--interval-s N] [--repo owner/repo]
#   verified-wait.sh --print-lanes --lane ... --cross ...   # print the lane set
#   verified-wait.sh --print-budget --event-name NAME --lane ...  # print the budget
#
# --print-lanes renders the single, event-invariant lane set (local names +
# cross names, origin-tagged, sorted) and exits 0 WITHOUT polling — the proof
# surface that the lane set is identical for every event (test-verified-wait.sh).
#
# --print-budget renders the resolved per-event wait budget as `BUDGET_S=<n>` and
# exits 0 WITHOUT --sha or polling — the proof surface that workflow_dispatch
# resolves to the short window (300s) and every other event to the full ruleset
# timeout (5400s) when no --timeout-s is given (test-verified-wait.sh item 3).
#
# Exit codes: 0=PASS  1=FAIL (real red lane OR timeout)  3=invocation error.
# --sha, --pr and --event-name are single-valued: a repeat of any of them is an
# invocation error (exit 3), never a silent last-value-wins override.
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
TIMEOUT_S=""        # resolved per-event after parse (item 5: budget, not lanes)
DEFAULT_TIMEOUT_S=5400    # 90 min — matches the ruleset check_response_timeout
DISPATCH_TIMEOUT_S=300    # short bounded window for workflow_dispatch probes
INTERVAL_S=30
REPO="${GH_REPO:-repairman29/chump}"
LOCAL_LANES=()
CROSS_CHECKS=()
PRINT_LANES=0
PRINT_BUDGET=0

usage() { grep '^#' "$0" | sed 's/^# \?//'; }

# once_flag — CREDIBLE-1554 repair 5: --sha, --pr and --event-name are
# single-valued. The parser below would otherwise keep the LAST value, so a
# second `--event-name "workflow_dispatch"` appended after the live
# ${{ github.event_name }} would silently hand merge_group the 300s dispatch
# window. Refuse a repeat as an invocation error (exit 3) instead of guessing.
SEEN_FLAGS=" "
once_flag() {
    if [[ "$SEEN_FLAGS" == *" --$1 "* ]]; then
        echo "[verified-wait] ERROR: --$1 given more than once (it is single-valued; a repeat would silently override the first)" >&2
        exit 3
    fi
    SEEN_FLAGS+="--$1 "
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sha)         once_flag sha;        SHA="$2"; shift 2 ;;
        --pr)          once_flag pr;         PR="$2"; shift 2 ;;
        --event-name)  once_flag event-name; EVENT_NAME="$2"; shift 2 ;;
        --lane)        LOCAL_LANES+=("$2"); shift 2 ;;
        --cross)       CROSS_CHECKS+=("$2"); shift 2 ;;
        --timeout-s)   TIMEOUT_S="$2"; shift 2 ;;
        --interval-s)  INTERVAL_S="$2"; shift 2 ;;
        --repo)        REPO="$2"; shift 2 ;;
        --print-lanes) PRINT_LANES=1; shift ;;
        --print-budget) PRINT_BUDGET=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *) echo "[verified-wait] unknown arg: $1" >&2; exit 3 ;;
    esac
done

if [[ ${#LOCAL_LANES[@]} -eq 0 && ${#CROSS_CHECKS[@]} -eq 0 ]]; then
    echo "[verified-wait] ERROR: at least one --lane or --cross is required" >&2
    exit 3
fi

# render_lane_set — the single, event-invariant rendering of the lane set
# `verified` requires (CREDIBLE-1554 item 5, Chief-binding): every local lane
# (name only; the needs.*.result value is stripped) plus every cross-workflow
# lane, one per line, origin-tagged, sorted. This is the one list the wait loop
# classifies, and it is identical for pull_request, merge_group, push and
# workflow_dispatch — no event path adds or drops a lane.
render_lane_set() {
    local l c
    {
        for l in "${LOCAL_LANES[@]+"${LOCAL_LANES[@]}"}"; do printf 'local=%s\n' "${l%%=*}"; done
        for c in "${CROSS_CHECKS[@]+"${CROSS_CHECKS[@]}"}"; do printf 'cross=%s\n' "$c"; done
    } | LC_ALL=C sort
}

# --print-lanes: emit the event-invariant lane set and exit (no --sha, no poll).
if [[ "$PRINT_LANES" -eq 1 ]]; then
    render_lane_set
    exit 0
fi

# Resolve the per-event wait BUDGET (item 5: the lane set is identical across
# events; only the budget differs). An explicit --timeout-s always wins; absent
# one, workflow_dispatch gets the short bounded window and every other event the
# full 90-min ruleset timeout. The cross lanes are NEVER dropped — a dispatch
# still classifies audit/ACP on the SHA and FAILs (never PASSes) if, at the end
# of its window, a cross lane is red, still running, or never-seen. Resolved
# before the --sha gate so --print-budget needs only --event-name.
if [[ -z "$TIMEOUT_S" ]]; then
    if [[ "$EVENT_NAME" == "workflow_dispatch" ]]; then
        TIMEOUT_S="$DISPATCH_TIMEOUT_S"
    else
        TIMEOUT_S="$DEFAULT_TIMEOUT_S"
    fi
fi
# The resolved budget is fixed from here on: it is what --print-budget prints,
# what every poll/verdict line prints, AND what the wait deadline below is
# computed from — one value, one place (CREDIBLE-1554 repair 5, item 3).
readonly TIMEOUT_S

# --print-budget: emit the resolved per-event wait budget and exit (no --sha, no
# poll) — the proof surface that workflow_dispatch resolves to the short window
# (300s) and every other event to the full ruleset timeout (5400s), item 3.
if [[ "$PRINT_BUDGET" -eq 1 ]]; then
    echo "BUDGET_S=$TIMEOUT_S"
    exit 0
fi

if [[ -z "$SHA" ]]; then
    echo "[verified-wait] ERROR: --sha is required" >&2
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
            echo "[verified-wait] VERDICT=PASS — every lane green or legitimately skipped (event=${EVENT_NAME:-?} budget=${TIMEOUT_S}s sha=${SHA} after ${attempt} poll(s))"
            exit 0
            ;;
        1)
            echo "$agg_out"
            bash "$AGG" "${agg_args[@]}" >/dev/null 2>&1 || true  # emit ambient once
            echo "[verified-wait] VERDICT=FAIL — a real red lane concluded failure (event=${EVENT_NAME:-?} budget=${TIMEOUT_S}s sha=${SHA} after ${attempt} poll(s))" >&2
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
        echo "[verified-wait] TIMEOUT: waited ${TIMEOUT_S}s (${attempt} poll(s)); lanes still PENDING at timeout: ${reason}; concluding FAILURE (event=${EVENT_NAME:-?} budget=${TIMEOUT_S}s sha=${SHA})" >&2
        exit 1
    fi

    remaining=$(( deadline - now ))
    sleep_s="$INTERVAL_S"
    (( sleep_s > remaining )) && sleep_s="$remaining"
    (( sleep_s < 1 )) && sleep_s=1
    echo "[verified-wait] poll #${attempt}: PENDING (waiting on: ${pending_cross[*]:-<none named>}); budget=${TIMEOUT_S}s, ${remaining}s left, sleeping ${sleep_s}s"
    sleep "$sleep_s"
done
