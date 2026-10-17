#!/usr/bin/env bash
# test-pick-and-claim-exclusion-reasons.sh — RESILIENT-1509
#
# Root cause: worker.sh ran _pick_and_claim_gap.py with stderr sent to
# /dev/null, so an empty cycle always logged a bare "no pickable gap" —
# indistinguishable from a crash, a failed claim, or an over-broad
# exclusion. The claimer now dumps a JSON per-exclusion-reason count to
# stderr whenever it returns without a gap. This asserts that dump exists
# and attributes exclusions to the right reason bucket.

set -euo pipefail
PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CLAIMER="$REPO_ROOT/scripts/dispatch/_pick_and_claim_gap.py"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LOCK_DIR="$TMP/locks"
mkdir -p "$LOCK_DIR"

AC='the gap is fixed and tested'

run() {
    GAP_JSON_FILE="$TMP/gaps.json" \
    CHUMP_LOCK_DIR="$LOCK_DIR" \
    CHUMP_SESSION_ID="test-session-$$" \
    CHUMP_REBALANCE=0 \
    WORKER_INDEX=1 WORKER_ID=1 \
    FLEET_PRIORITY_FILTER="P0,P1" FLEET_DOMAIN_FILTER="INFRA" FLEET_EFFORT_FILTER="xs,s,m" \
      python3 "$CLAIMER"
}

# All candidates excluded for distinct, attributable reasons: one P2 (fails
# priority filter), one with unresolved deps, one superseded. INFRA-200's
# blocker INFRA-999 must EXIST as genuine open work: a dangling dep id is
# treated as resolved (RESILIENT-1114), which would let INFRA-200 be picked.
# INFRA-999 itself is excluded by the domain filter (DOC, not INFRA).
cat > "$TMP/gaps.json" <<JSON
[
  {"id":"INFRA-100","status":"open","priority":"P2","effort":"s","domain":"INFRA","depends_on":"[]","acceptance_criteria":"$AC"},
  {"id":"INFRA-200","status":"open","priority":"P1","effort":"s","domain":"INFRA","depends_on":"[\"INFRA-999\"]","acceptance_criteria":"$AC"},
  {"id":"INFRA-300","status":"open","priority":"P1","effort":"s","domain":"INFRA","depends_on":"[]","acceptance_criteria":"$AC","notes":"SUPERSEDED by INFRA-301"},
  {"id":"INFRA-999","status":"open","priority":"P1","effort":"s","domain":"DOC","depends_on":"[]","acceptance_criteria":"$AC"}
]
JSON

stderr_file="$TMP/stderr"
out="$(run 2>"$stderr_file" || true)"
err="$(cat "$stderr_file")"

[[ -z "$out" ]] && pass "no gap claimed (all 4 excluded)" \
    || fail "expected no pick, got '$out'"

[[ -n "$err" ]] && pass "stderr is non-empty on the empty cycle (not silently swallowed)" \
    || fail "stderr was empty — the empty-cycle dump is missing"

echo "$err" | grep -q '"pick_empty_cycle": true' \
    && pass "stderr dump marks pick_empty_cycle" \
    || fail "stderr dump missing pick_empty_cycle marker: $err"

echo "$err" | grep -q '"priority_filter": 1' \
    && pass "priority_filter reason counted for INFRA-100 (P2 excluded by P0,P1 filter)" \
    || fail "priority_filter count missing/wrong: $err"

echo "$err" | grep -q '"unresolved_deps": 1' \
    && pass "unresolved_deps reason counted for INFRA-200" \
    || fail "unresolved_deps count missing/wrong: $err"

echo "$err" | grep -q '"superseded": 1' \
    && pass "superseded reason counted for INFRA-300" \
    || fail "superseded count missing/wrong: $err"

echo "$err" | grep -q '"domain_filter": 1' \
    && pass "domain_filter reason counted for INFRA-999 (DOC excluded by INFRA filter)" \
    || fail "domain_filter count missing/wrong: $err"

echo "$err" | grep -q '"total_gaps": 4' \
    && pass "total_gaps reflects full input size" \
    || fail "total_gaps missing/wrong: $err"

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
