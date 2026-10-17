#!/usr/bin/env bash
# INFRA-397 regression — _pick_gap.py must skip non-open gaps.
# Without the guard, `chump gap list --json` (which returns ALL statuses)
# would let workers pick done/in_progress gaps. Verified 2026-05-02 fleet
# logs: 6 workers picked the same already-closed INFRA-340 within 90s.

set -euo pipefail
PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PICKER="$REPO_ROOT/scripts/dispatch/_pick_gap.py"

tmp=$(mktemp)
trap "rm -f $tmp" EXIT

# Fixture: one done gap (must skip), one open gap (must pick), no deps.
cat > "$tmp" <<'JSON'
[
  {"id":"INFRA-100","status":"done","acceptance_criteria":"Implement the change and verify the behavior","priority":"P1","effort":"s","domain":"INFRA","depends_on":"[]"},
  {"id":"INFRA-200","status":"open","acceptance_criteria":"Implement the change and verify the behavior","priority":"P1","effort":"s","domain":"INFRA","depends_on":"[]"}
]
JSON

result=$(GAP_JSON_FILE="$tmp" FLEET_PRIORITY_FILTER=P0,P1 FLEET_EFFORT_FILTER=xs,s,m \
  python3 "$PICKER")

if [ "$result" = "INFRA-200" ]; then
  pass "picker returns the open gap, not the done one"
elif [ "$result" = "INFRA-100" ]; then
  fail "picker returned the DONE gap (regression — INFRA-397 missing)"
else
  fail "picker returned unexpected value: '$result'"
fi

# All-done fixture: must return nothing.
cat > "$tmp" <<'JSON'
[
  {"id":"INFRA-100","status":"done","acceptance_criteria":"Implement the change and verify the behavior","priority":"P1","effort":"s","domain":"INFRA","depends_on":"[]"},
  {"id":"INFRA-300","status":"in_progress","acceptance_criteria":"Implement the change and verify the behavior","priority":"P1","effort":"s","domain":"INFRA","depends_on":"[]"}
]
JSON

result=$(GAP_JSON_FILE="$tmp" FLEET_PRIORITY_FILTER=P0,P1 FLEET_EFFORT_FILTER=xs,s,m \
  python3 "$PICKER")

if [ -z "$result" ]; then
  pass "picker returns nothing when no open gaps exist"
else
  fail "picker returned '$result' when only done/in_progress gaps existed"
fi

# Stringified depends_on fixture: "[]" must be treated as no deps (was
# the silent-empty-queue bug — `"[]".strip()` is truthy → every gap got
# filtered out as "has dependencies").
cat > "$tmp" <<'JSON'
[{"id":"INFRA-400","status":"open","acceptance_criteria":"Implement the change and verify the behavior","priority":"P1","effort":"s","domain":"INFRA","depends_on":"[]"}]
JSON
result=$(GAP_JSON_FILE="$tmp" FLEET_PRIORITY_FILTER=P0,P1 FLEET_EFFORT_FILTER=xs,s,m \
  python3 "$PICKER")
if [ "$result" = "INFRA-400" ]; then
  pass "picker treats depends_on='[]' (string) as no-deps"
else
  fail "picker filtered out gap with stringified empty depends_on (got: '$result')"
fi

# Real dep-blocked gap must still be skipped. The blocker INFRA-100 must EXIST
# as open work (RESILIENT-1114: a dangling dep id is treated as resolved), and
# is excluded from picking via EXCLUDE_RE so only INFRA-500's gating is tested.
cat > "$tmp" <<'JSON'
[{"id":"INFRA-100","status":"open","acceptance_criteria":"Implement the change and verify the behavior","priority":"P1","effort":"s","domain":"INFRA","depends_on":"[]"},
{"id":"INFRA-500","status":"open","acceptance_criteria":"Implement the change and verify the behavior","priority":"P1","effort":"s","domain":"INFRA","depends_on":"[\"INFRA-100\"]"}]
JSON
result=$(GAP_JSON_FILE="$tmp" EXCLUDE_RE="^INFRA-100$" FLEET_PRIORITY_FILTER=P0,P1 FLEET_EFFORT_FILTER=xs,s,m \
  python3 "$PICKER")
if [ -z "$result" ]; then
  pass "picker still skips gap with real (unresolved) dependency"
else
  fail "picker returned dep-blocked gap: '$result'"
fi

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
