#!/usr/bin/env bash
# test-picker-priority.sh — INFRA-1258
#
# Verifies scripts/dispatch/_pick_gap.py consumes the planner-priority
# file .chump-locks/gap-priority.json (written by INFRA-1257) and picks
# the best-ranked gap rather than first-fit by (priority, effort, age).

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PICKER="$REPO_ROOT/scripts/dispatch/_pick_gap.py"

echo "=== INFRA-1258 picker-priority tests ==="
[[ -f "$PICKER" ]] || { fail "picker not at $PICKER"; exit 1; }
ok "picker present"

# Synthetic fixture dir.
TMP="$(mktemp -d -t picker-prio.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.chump-locks"

# Three open gaps, identical priority+effort+age so legacy sort can't pick
# a clear winner. Planner says C > B > A.
cat > "$TMP/gaps.json" <<'EOF'
[
  {"id":"INFRA-A","priority":"P1","effort":"s","status":"open","created_at":1000,"depends_on":"[]","acceptance_criteria":"[\"1. Fixture gap A for picker-priority testing.\"]"},
  {"id":"INFRA-B","priority":"P1","effort":"s","status":"open","created_at":1001,"depends_on":"[]","acceptance_criteria":"[\"1. Fixture gap B for picker-priority testing.\"]"},
  {"id":"INFRA-C","priority":"P1","effort":"s","status":"open","created_at":1002,"depends_on":"[]","acceptance_criteria":"[\"1. Fixture gap C for picker-priority testing.\"]"}
]
EOF

# Helper: run picker with the synthetic fixture rooted at $TMP.
run_picker() {
    GAP_JSON_FILE="$TMP/gaps.json" \
    CHUMP_REPO="$TMP" \
    CHUMP_AMBIENT_LOG="$TMP/.chump-locks/ambient.jsonl" \
    FLEET_MODEL=opus \
    WORKER_INDEX=1 \
    WORKER_ID=test-worker \
      python3 "$PICKER"
}

# ── Test 1: NO priority file → legacy first-fit (A) + stale-emit ─────────────
: > "$TMP/.chump-locks/ambient.jsonl"
picked="$(run_picker)"
if [[ "$picked" == "INFRA-A" ]]; then
    ok "no priority file: legacy first-fit picks INFRA-A"
else
    fail "no priority file: expected INFRA-A, got '$picked'"
fi
if grep -q '"kind": "picker_priority_stale".*"reason": "absent"' "$TMP/.chump-locks/ambient.jsonl"; then
    ok "absent priority file emits kind=picker_priority_stale reason=absent"
else
    fail "absent: ambient missing picker_priority_stale"
fi

# ── Test 2: fresh priority file ranks C > B > A → picker picks INFRA-C ──────
cat > "$TMP/.chump-locks/gap-priority.json" <<'EOF'
{
  "generated_at": "2026-05-14T12:00:00Z",
  "planner_version": "0.1.0",
  "weights_identity": "synthetic",
  "items": [
    {"rank": 1, "gap_id": "INFRA-C", "score": 99.0},
    {"rank": 2, "gap_id": "INFRA-B", "score": 50.0},
    {"rank": 3, "gap_id": "INFRA-A", "score": 10.0}
  ]
}
EOF
: > "$TMP/.chump-locks/ambient.jsonl"
picked="$(run_picker)"
if [[ "$picked" == "INFRA-C" ]]; then
    ok "fresh priority file: picks rank-1 INFRA-C (overrides legacy first-fit)"
else
    fail "fresh priority: expected INFRA-C, got '$picked'"
fi
if grep -q '"kind": "picker_used_priority"' "$TMP/.chump-locks/ambient.jsonl" \
   && grep -q '"gap_id": "INFRA-C"' "$TMP/.chump-locks/ambient.jsonl" \
   && grep -q '"planner_rank": 1' "$TMP/.chump-locks/ambient.jsonl"; then
    ok "picker emits kind=picker_used_priority with planner_rank"
else
    fail "fresh priority: ambient missing picker_used_priority emit"
fi

# ── Test 3: stale priority file (>2h old) → fall back, emit reason=stale ────
# Backdate the priority file 3h.
touch -t $(date -v-3H +%Y%m%d%H%M.%S 2>/dev/null || date -d '3 hours ago' +%Y%m%d%H%M.%S) \
    "$TMP/.chump-locks/gap-priority.json" 2>/dev/null || \
    python3 -c "import os, time; os.utime('$TMP/.chump-locks/gap-priority.json', (time.time()-10800, time.time()-10800))"
: > "$TMP/.chump-locks/ambient.jsonl"
picked="$(run_picker)"
if [[ "$picked" == "INFRA-A" ]]; then
    ok "stale priority file: falls back to legacy first-fit"
else
    fail "stale priority: expected INFRA-A, got '$picked'"
fi
if grep -q '"reason": "stale"' "$TMP/.chump-locks/ambient.jsonl"; then
    ok "stale priority file emits kind=picker_priority_stale reason=stale"
else
    fail "stale: ambient missing reason=stale"
fi

# ── Test 4: invalid JSON → fall back + emit reason=invalid ───────────────────
echo "not valid json {" > "$TMP/.chump-locks/gap-priority.json"
: > "$TMP/.chump-locks/ambient.jsonl"
picked="$(run_picker)"
if [[ "$picked" == "INFRA-A" ]]; then
    ok "invalid priority file: falls back"
else
    fail "invalid: expected INFRA-A, got '$picked'"
fi
if grep -q '"reason": "invalid"' "$TMP/.chump-locks/ambient.jsonl"; then
    ok "invalid priority file emits reason=invalid"
else
    fail "invalid: ambient missing reason=invalid"
fi

# ── Test 5: priority file has only some gaps; rest fall back to legacy ──────
cat > "$TMP/.chump-locks/gap-priority.json" <<'EOF'
{
  "generated_at": "2026-05-14T12:00:00Z",
  "planner_version": "0.1.0",
  "weights_identity": "synthetic",
  "items": [
    {"rank": 1, "gap_id": "INFRA-B", "score": 99.0}
  ]
}
EOF
: > "$TMP/.chump-locks/ambient.jsonl"
picked="$(run_picker)"
if [[ "$picked" == "INFRA-B" ]]; then
    ok "partial priority: ranked gap (B) outranks unranked siblings"
else
    fail "partial: expected INFRA-B, got '$picked'"
fi

# ── Test 6 (INFRA-8143): v0.2 JSON schema + claim-mode planner_rank tiebreak ─
cat > "$TMP/.chump-locks/gap-priority.json" <<'EOF'
{
  "version": "0.2",
  "generated_at": "2026-05-14T12:00:00Z",
  "planner_version": "0.1.0",
  "weights_identity": "synthetic",
  "items": [
    {"rank": 1, "gap_id": "INFRA-C", "score": 140.0, "priority": "P1", "effort": "s", "unblocks": 3, "domain": "INFRA", "title": "high unblock"},
    {"rank": 2, "gap_id": "INFRA-A", "score": 80.0, "priority": "P1", "effort": "s", "unblocks": 0, "domain": "INFRA", "title": "older low leverage"}
  ]
}
EOF
status_check="$(python3 -c "
import sys
sys.path.insert(0, '$REPO_ROOT/scripts/dispatch')
import _pick_and_claim_gap as p
ranks, status = p._load_planner_priority('$TMP')
assert status == 'ok', f'expected ok, got {status}'
assert ranks.get('INFRA-C') == 1, f'expected INFRA-C rank 1, got {ranks}'
print('ok')
")"
if [[ "$status_check" == "ok" ]]; then
    ok "INFRA-8143: _load_planner_priority parses v0.2 schema with status=ok"
else
    fail "INFRA-8143: _load_planner_priority failed ($status_check)"
fi
claim_preview_picked="$(
    GAP_JSON_FILE="$TMP/gaps.json" \
    CHUMP_REPO="$TMP" \
    REPO_ROOT="$TMP" \
    CHUMP_FLEET_DRY_RUN=1 \
    CHUMP_AFFINITY=0 \
    CHUMP_REBALANCE=0 \
    FLEET_MODEL=opus \
    WORKER_INDEX=1 \
    WORKER_ID=test-worker \
      python3 "$REPO_ROOT/scripts/dispatch/_pick_and_claim_gap.py"
)"
if [[ "$claim_preview_picked" == "INFRA-C" ]]; then
    ok "INFRA-8143: claim-mode tiebreak picks high-UNBLK INFRA-C ahead of older INFRA-A"
else
    fail "INFRA-8143: claim-mode expected INFRA-C, got '$claim_preview_picked'"
fi

echo
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
