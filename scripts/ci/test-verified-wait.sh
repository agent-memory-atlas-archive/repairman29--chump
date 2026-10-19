#!/usr/bin/env bash
# test-verified-wait.sh — CREDIBLE-1554 (PHASE-R R3)
#
# Proves scripts/ci/verified-wait.sh — the in-job wait loop for the sole
# required `verified` check under a GitHub native merge queue — reaches the
# RIGHT FIRST verdict by stubbing the Checks API (`gh`) with canned JSON.
#
# Under a merge queue a merge_group is ejected the instant a required check
# concludes FAILURE, so the verdict must be correct on the first conclusion:
#   - a lane still running OR never-seen is PENDING (keep polling), NEVER FAIL;
#   - FAILURE only on a real red lane or on the timeout;
#   - SUCCESS only when every lane is green or legitimately skipped.
#
# Matrix (each run for BOTH pull_request and merge_group event types, since the
# wait behavior must be identical — the event only changes the SHA ci.yml feeds
# in via --sha):
#   1. in_progress then success        -> PASS   (exit 0)
#   2. in_progress then failure         -> FAIL   (exit 1, real red, not timeout)
#   3. never-seen  then success         -> PASS   (exit 0)   folds RESILIENT-1617
#   4. never-seen  until timeout        -> FAIL   (exit 1, TIMEOUT reason)
#   5. real red LOCAL lane              -> FAIL   (exit 1) short-circuits, no wait
#
# Run locally: bash scripts/ci/test-verified-wait.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WAIT="$REPO_ROOT/scripts/ci/verified-wait.sh"

[[ -x "$WAIT" ]] || { echo "FATAL: $WAIT not found or not executable"; exit 2; }

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== CREDIBLE-1554 verified-wait.sh in-job-wait guard ==="
echo

# Each scenario provides a gh() stub that is exported so the child `bash
# poll-cross-workflow-checks.sh` process inherits it. A shared counter file
# (CNT) lets a stub return different JSON on successive polls.
CNT="$(mktemp)"
export CNT
reset_cnt() { echo 0 > "$CNT"; }
bump_cnt()  { local n; n=$(($(cat "$CNT") + 1)); echo "$n" > "$CNT"; echo "$n"; }

# Representative SHAs for each event type (merge_group feeds github.sha; a PR
# feeds pull_request.head.sha — verified-wait takes whichever as --sha).
declare -A SHAS=( [pull_request]=prsha0000 [merge_group]=mergesha000 )

# Run verified-wait with a cross `audit` lane + all-green local lanes (unless a
# scenario overrides LOCAL_OVERRIDE). Captures combined stdout+stderr + exit.
run_wait() {
    local event="$1" timeout="$2" interval="$3"; shift 3
    local extra_local=("$@")
    local sha="${SHAS[$event]}"
    local lanes=(--lane "fast-checks=success" --lane "test=success")
    lanes+=("${extra_local[@]}")
    OUT="$(GH_REPO="owner/repo" bash "$WAIT" \
        --sha "$sha" --pr 999 --event-name "$event" \
        "${lanes[@]}" \
        --cross "audit" \
        --timeout-s "$timeout" --interval-s "$interval" 2>&1)"
    RC=$?
}

for EVENT in pull_request merge_group; do
    echo "--- event: $EVENT ---"

    # 1. in_progress then success -> PASS
    reset_cnt
    gh() {
        if [[ "${1:-}" == "run" ]]; then echo '[]'; return 0; fi
        local n; n="$(bump_cnt)"
        if [[ "$n" -lt 2 ]]; then
            echo '[{"name":"audit","status":"in_progress","started_at":"2026-10-19T00:00:00Z"}]'
        else
            echo '[{"name":"audit","status":"completed","conclusion":"success","started_at":"2026-10-19T00:00:00Z"}]'
        fi
    }
    export -f gh bump_cnt
    run_wait "$EVENT" 15 1
    if [[ "$RC" -eq 0 ]] && echo "$OUT" | grep -q "VERDICT=PASS"; then
        ok "[$EVENT] in_progress->success => PASS (exit 0)"
    else
        bad "[$EVENT] in_progress->success: rc=$RC out=<<$OUT>>"
    fi

    # 2. in_progress then failure -> FAIL (real red, not a timeout)
    reset_cnt
    gh() {
        if [[ "${1:-}" == "run" ]]; then echo '[]'; return 0; fi
        local n; n="$(bump_cnt)"
        if [[ "$n" -lt 2 ]]; then
            echo '[{"name":"audit","status":"in_progress","started_at":"2026-10-19T00:00:00Z"}]'
        else
            echo '[{"name":"audit","status":"completed","conclusion":"failure","started_at":"2026-10-19T00:00:00Z"}]'
        fi
    }
    export -f gh bump_cnt
    run_wait "$EVENT" 15 1
    if [[ "$RC" -eq 1 ]] && echo "$OUT" | grep -q "real red lane" && ! echo "$OUT" | grep -q "TIMEOUT"; then
        ok "[$EVENT] in_progress->failure => FAIL real-red (exit 1, not timeout)"
    else
        bad "[$EVENT] in_progress->failure: rc=$RC out=<<$OUT>>"
    fi

    # 3. never-seen then success -> PASS (no check-run + no audit.yml run on
    #    the first poll => in_progress/PENDING, NEVER fail-closed; RESILIENT-1617)
    reset_cnt
    gh() {
        if [[ "${1:-}" == "run" ]]; then echo '[]'; return 0; fi
        local n; n="$(bump_cnt)"
        if [[ "$n" -lt 2 ]]; then
            echo '[]'
        else
            echo '[{"name":"audit","status":"completed","conclusion":"success","started_at":"2026-10-19T00:00:00Z"}]'
        fi
    }
    export -f gh bump_cnt
    run_wait "$EVENT" 15 1
    if [[ "$RC" -eq 0 ]] && echo "$OUT" | grep -q "VERDICT=PASS"; then
        ok "[$EVENT] never-seen->success => PASS (exit 0, never fail-closed early)"
    else
        bad "[$EVENT] never-seen->success: rc=$RC out=<<$OUT>>"
    fi

    # 4. never-seen until timeout -> FAIL with a timeout reason
    gh() { if [[ "${1:-}" == "run" ]]; then echo '[]'; else echo '[]'; fi; }
    export -f gh
    run_wait "$EVENT" 2 1
    if [[ "$RC" -eq 1 ]] && echo "$OUT" | grep -q "TIMEOUT"; then
        ok "[$EVENT] never-seen->timeout => FAIL with TIMEOUT reason (exit 1)"
    else
        bad "[$EVENT] never-seen->timeout: rc=$RC out=<<$OUT>>"
    fi

    # 5. real red LOCAL lane short-circuits immediately (exit 1, no 90-min wait),
    #    even while the cross lane is still in_progress.
    gh() {
        if [[ "${1:-}" == "run" ]]; then echo '[]'; return 0; fi
        echo '[{"name":"audit","status":"in_progress","started_at":"2026-10-19T00:00:00Z"}]'
    }
    export -f gh
    start=$(date +%s)
    run_wait "$EVENT" 60 5 --lane "clippy=failure"
    elapsed=$(( $(date +%s) - start ))
    if [[ "$RC" -eq 1 ]] && echo "$OUT" | grep -q "real red lane" && [[ "$elapsed" -lt 10 ]]; then
        ok "[$EVENT] red local lane short-circuits FAIL (exit 1, ${elapsed}s, no wait)"
    else
        bad "[$EVENT] red local short-circuit: rc=$RC elapsed=${elapsed}s out=<<$OUT>>"
    fi
done

rm -f "$CNT"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
