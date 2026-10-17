#!/usr/bin/env bash
# test-one-picker-mission-first.sh — INFRA-8224 (carries MISSION-028)
#
# The one-picker consolidation regression gate. After INFRA-8224 there is ONE
# ranking picker — scripts/dispatch/_pick_and_claim_gap.py — and _pick_gap.py is
# a thin shim that execs it with --dry-run. This test proves, on a fixture gap
# store (the JSON `chump gap list --json` emits, which is the picker's real
# input contract via GAP_JSON_FILE):
#
#   AC1: a P0 MISSION gap is picked OVER a P0 self-maintenance gap
#        (mission_rank breaks the tie within the P0 band).
#   AC2: a substrate P0 still beats a mission P1
#        (prio_rank is the primary key; the mission boost is bounded).
#   AC3: ONE picker, ONE answer — the _pick_gap.py shim and the canonical
#        picker's --dry-run produce byte-identical output, and the top of
#        --list agrees with --dry-run. This is the property that guarantees
#        #3055's class of bug (fix one picker, miss the other) cannot recur.
#
# Pure-Python + JSON fixtures: <2s, no network, no chump binary — same shape as
# the mission-picker / worker-no-spin gates, safe for the fast preflight loop.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CANON="$REPO_ROOT/scripts/dispatch/_pick_and_claim_gap.py"
SHIM="$REPO_ROOT/scripts/dispatch/_pick_gap.py"

echo "=== INFRA-8224 one-picker mission-first regression ==="
[[ -f "$CANON" ]] || { fail "canonical picker not at $CANON"; exit 1; }
[[ -f "$SHIM"  ]] || { fail "shim not at $SHIM"; exit 1; }
ok "canonical picker + shim present"

TMP="$(mktemp -d -t one-picker.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.chump-locks"

# Run a picker on $1 (gap-store JSON), remaining args forwarded as argv/flags.
# Rebalance is disabled and no mission override beyond MISSION-010 so the only
# thing under test is prio_rank + mission_rank.
run_pick() {
    local store="$1"; shift
    GAP_JSON_FILE="$store" \
    CHUMP_ACTIVE_MISSION=MISSION-010 \
    CHUMP_REPO="$TMP" \
    CHUMP_AMBIENT_LOG="$TMP/.chump-locks/ambient.jsonl" \
    CHUMP_REBALANCE=0 \
    FLEET_MODEL=sonnet \
    WORKER_INDEX=1 \
    WORKER_ID=one-picker-test \
      python3 "$@"
}

# ── Fixture store 1: P0 MISSION vs P0 self-maintenance ──────────────────────
cat > "$TMP/store1.json" <<'EOF'
[
  {"id":"INFRA-MAINT","domain":"INFRA","priority":"P0","effort":"s","status":"open",
   "created_at":1000,"depends_on":"[]",
   "acceptance_criteria":"[\"1. Self-maintenance substrate gap at P0.\"]",
   "title":"Self-maintenance substrate gap","outcome_id":null,"notes":"","description":""},
  {"id":"MISSION-KEY","domain":"MISSION","priority":"P0","effort":"s","status":"open",
   "created_at":1001,"depends_on":"[]",
   "acceptance_criteria":"[\"1. Mission P0 keystone gap.\"]",
   "title":"Mission P0 keystone","outcome_id":null,"notes":"","description":""}
]
EOF

canon1="$(run_pick "$TMP/store1.json" "$CANON" --dry-run)"
shim1="$(run_pick "$TMP/store1.json" "$SHIM")"
list1_top="$(run_pick "$TMP/store1.json" "$CANON" --list | head -1)"

if [[ "$canon1" == "MISSION-KEY" ]]; then
    ok "AC1: canonical picker picks P0 MISSION over P0 self-maintenance"
else
    fail "AC1: expected MISSION-KEY, got '$canon1'"
fi
if [[ "$shim1" == "$canon1" && "$list1_top" == "$canon1" ]]; then
    ok "AC3 (store1): shim == canonical --dry-run == --list[0] ('$canon1')"
else
    fail "AC3 (store1): divergence — canon='$canon1' shim='$shim1' list[0]='$list1_top'"
fi

# ── Fixture store 2: substrate P0 vs mission P1 (priority invariant) ─────────
cat > "$TMP/store2.json" <<'EOF'
[
  {"id":"INFRA-P0","domain":"INFRA","priority":"P0","effort":"s","status":"open",
   "created_at":1000,"depends_on":"[]",
   "acceptance_criteria":"[\"1. Substrate P0 gap.\"]",
   "title":"Substrate P0 gap","outcome_id":null,"notes":"","description":""},
  {"id":"MISSION-P1","domain":"MISSION","priority":"P1","effort":"s","status":"open",
   "created_at":999,"depends_on":"[]",
   "acceptance_criteria":"[\"1. Mission P1 gap filed slightly earlier.\"]",
   "title":"Mission P1 keystone","outcome_id":null,"notes":"","description":""}
]
EOF

canon2="$(run_pick "$TMP/store2.json" "$CANON" --dry-run)"
shim2="$(run_pick "$TMP/store2.json" "$SHIM")"
list2_top="$(run_pick "$TMP/store2.json" "$CANON" --list | head -1)"

if [[ "$canon2" == "INFRA-P0" ]]; then
    ok "AC2: substrate P0 still beats mission P1 (priority invariant preserved)"
else
    fail "AC2: expected INFRA-P0, got '$canon2' — mission boost over-rode priority"
fi
if [[ "$shim2" == "$canon2" && "$list2_top" == "$canon2" ]]; then
    ok "AC3 (store2): shim == canonical --dry-run == --list[0] ('$canon2')"
else
    fail "AC3 (store2): divergence — canon='$canon2' shim='$shim2' list[0]='$list2_top'"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ ${#FAILS[@]} -gt 0 ]]; then
    echo "Failed assertions:"
    for f in "${FAILS[@]}"; do echo "  - $f"; done
fi
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
