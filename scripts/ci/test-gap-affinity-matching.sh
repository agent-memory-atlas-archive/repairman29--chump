#!/usr/bin/env bash
# INFRA-314: gap affinity matching — workers prefer gaps matching their skills.
# Verifies that scoring correctly routes gaps to workers with matching skills/backend/machine.

set -euo pipefail
PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PICKER="$REPO_ROOT/scripts/dispatch/_pick_and_claim_gap.py"

tmp=$(mktemp)
lock_dir=$(mktemp -d)
trap "rm -f $tmp; rm -rf $lock_dir" EXIT

# Helper: run picker with given env vars and return result
run_picker() {
  rm -f "$lock_dir"/.gap-*.lock "$lock_dir"/*.json
  GAP_JSON_FILE="$tmp" CHUMP_LOCK_DIR="$lock_dir" CHUMP_SESSION_ID="test-session" "$@" python3 "$PICKER"
}

# Test 1: Skill requirement filtering.
# Two gaps: one requires "rust,sqlite", one requires "go".
# Worker has "rust,sqlite" — should pick the first gap, skip the second.
cat > "$tmp" <<'JSON'
[
  {"id":"INFRA-314-A","status":"open","priority":"P2","effort":"s","domain":"INFRA","depends_on":"[]","skills_required":"[\"rust\",\"sqlite\"]","preferred_backend":"","preferred_machine":"","created_at":1000},
  {"id":"INFRA-314-B","status":"open","priority":"P2","effort":"s","domain":"INFRA","depends_on":"[]","skills_required":"[\"go\"]","preferred_backend":"","preferred_machine":"","created_at":1001}
]
JSON

result=$(FLEET_PRIORITY_FILTER=P2 FLEET_EFFORT_FILTER=s WORKER_SKILLS="rust,sqlite" run_picker)

if [ "$result" = "INFRA-314-A" ]; then
  pass "worker with rust,sqlite picks gap with rust,sqlite requirement"
elif [ "$result" = "INFRA-314-B" ]; then
  fail "worker picked gap requiring 'go' when they only have 'rust,sqlite' (hard filter broken)"
else
  fail "unexpected result: '$result' (expected INFRA-314-A)"
fi

# Test 2: Worker without required skills gets nothing when it opts into the
# hard filter (WORKER_SKILLS_HARD=1, INFRA-8176). The default is soft: see
# scripts/ci/test-picker-soft-skill-open-pr.sh.
cat > "$tmp" <<'JSON'
[
  {"id":"INFRA-314-C","status":"open","priority":"P2","effort":"s","domain":"INFRA","depends_on":"[]","skills_required":"[\"macos\",\"syspolicyd\"]","preferred_backend":"","preferred_machine":"","created_at":1000}
]
JSON

result=$(FLEET_PRIORITY_FILTER=P2 FLEET_EFFORT_FILTER=s WORKER_SKILLS="rust,sqlite" WORKER_SKILLS_HARD=1 run_picker)

if [ -z "$result" ]; then
  pass "worker without required skills gets nothing (WORKER_SKILLS_HARD=1)"
else
  fail "worker without required skills picked gap: '$result'"
fi

# Test 3: Affinity scoring — backend match.
# Two gaps: one prefers claude, one prefers local-llm.
# Worker backend=claude should pick the first (backend match = +3 points).
cat > "$tmp" <<'JSON'
[
  {"id":"INFRA-314-D","status":"open","priority":"P2","effort":"s","domain":"INFRA","depends_on":"[]","skills_required":"","preferred_backend":"claude","preferred_machine":"","created_at":1000},
  {"id":"INFRA-314-E","status":"open","priority":"P2","effort":"s","domain":"INFRA","depends_on":"[]","skills_required":"","preferred_backend":"local-llm","preferred_machine":"","created_at":1001}
]
JSON

result=$(FLEET_PRIORITY_FILTER=P2 FLEET_EFFORT_FILTER=s WORKER_BACKEND="claude" run_picker)

if [ "$result" = "INFRA-314-D" ]; then
  pass "worker backend=claude prefers gap with preferred_backend=claude"
elif [ "$result" = "INFRA-314-E" ]; then
  fail "worker picked non-preferred backend gap"
else
  fail "unexpected result: '$result'"
fi

# Test 4: Affinity scoring — machine match.
# Two gaps: one prefers macbook, one prefers pi-mesh.
# Worker machine=macbook should pick the first (machine match = +2 points).
cat > "$tmp" <<'JSON'
[
  {"id":"INFRA-314-F","status":"open","priority":"P2","effort":"s","domain":"INFRA","depends_on":"[]","skills_required":"","preferred_backend":"","preferred_machine":"macbook","created_at":1000},
  {"id":"INFRA-314-G","status":"open","priority":"P2","effort":"s","domain":"INFRA","depends_on":"[]","skills_required":"","preferred_backend":"","preferred_machine":"pi-mesh","created_at":1001}
]
JSON

result=$(FLEET_PRIORITY_FILTER=P2 FLEET_EFFORT_FILTER=s WORKER_MACHINE="macbook" run_picker)

if [ "$result" = "INFRA-314-F" ]; then
  pass "worker machine=macbook prefers gap with preferred_machine=macbook"
elif [ "$result" = "INFRA-314-G" ]; then
  fail "worker picked non-preferred machine gap"
else
  fail "unexpected result: '$result'"
fi

# Test 5: Skill match scoring.
# Two gaps with same priority/effort.
# Gap 1: no required skills, no affinity.
# Gap 2: requires "rust" (worker has it = +1 point).
# Worker with rust should prefer gap 2.
cat > "$tmp" <<'JSON'
[
  {"id":"INFRA-314-H","status":"open","priority":"P2","effort":"s","domain":"INFRA","depends_on":"[]","skills_required":"","preferred_backend":"","preferred_machine":"","created_at":1000},
  {"id":"INFRA-314-I","status":"open","priority":"P2","effort":"s","domain":"INFRA","depends_on":"[]","skills_required":"[\"rust\"]","preferred_backend":"","preferred_machine":"","created_at":1001}
]
JSON

result=$(FLEET_PRIORITY_FILTER=P2 FLEET_EFFORT_FILTER=s WORKER_SKILLS="rust" run_picker)

if [ "$result" = "INFRA-314-I" ]; then
  pass "worker prefers gap matching their skills (rust skill match)"
elif [ "$result" = "INFRA-314-H" ]; then
  fail "worker picked gap with no skill affinity instead of rust-match gap"
else
  fail "unexpected result: '$result'"
fi

# Test 6: CHUMP_AFFINITY=0 bypass disables affinity matching.
# Two gaps: one requires "macos" (P3), one requires "rust" (P2).
# Worker has "rust" only.
# With affinity ENABLED: worker should skip macos gap (hard filter) and pick rust gap.
# With affinity DISABLED (CHUMP_AFFINITY=0): both should be eligible, rust wins by priority.
cat > "$tmp" <<'JSON'
[
  {"id":"INFRA-314-J","status":"open","priority":"P3","effort":"s","domain":"INFRA","depends_on":"[]","skills_required":"[\"macos\"]","preferred_backend":"","preferred_machine":"","created_at":1000},
  {"id":"INFRA-314-K","status":"open","priority":"P2","effort":"s","domain":"INFRA","depends_on":"[]","skills_required":"[\"rust\"]","preferred_backend":"","preferred_machine":"","created_at":1001}
]
JSON

# With affinity ENABLED (default), worker should skip J and pick K.
result=$(FLEET_PRIORITY_FILTER=P2,P3 FLEET_EFFORT_FILTER=s WORKER_SKILLS="rust" CHUMP_AFFINITY=1 run_picker)

if [ "$result" = "INFRA-314-K" ]; then
  pass "affinity ENABLED: worker picks matching-skill gap (K), ignores non-matching (J)"
else
  fail "affinity ENABLED: expected INFRA-314-K, got '$result'"
fi

# With affinity DISABLED (CHUMP_AFFINITY=0), both gaps should be eligible, pick by priority.
result=$(FLEET_PRIORITY_FILTER=P2,P3 FLEET_EFFORT_FILTER=s WORKER_SKILLS="rust" CHUMP_AFFINITY=0 run_picker)

if [ "$result" = "INFRA-314-K" ]; then
  pass "affinity DISABLED (CHUMP_AFFINITY=0): both gaps eligible, K picked by priority (P2 > P3)"
else
  fail "affinity DISABLED: expected INFRA-314-K, got '$result'"
fi

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
