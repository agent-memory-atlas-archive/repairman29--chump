#!/usr/bin/env bash
# test-pick-gap-cooldown.sh — INFRA-361 regression test for the rc=1
# cooldown behavior in _pick_gap.py.
#
# Pre-fix: a gap that just produced rc=1 from claude was immediately
# eligible for re-pick on the next cycle. Worker 4 was observed
# re-picking INFRA-340 6 times in 5 minutes. Post-fix: when worker.sh
# writes a cooldown record into $COOLDOWN_DIR/<GAP-ID>.json with
# until > now, _pick_gap.py excludes that gap from candidates until
# the timestamp expires.
#
# Network-free: exercises _pick_gap.py directly with a synthetic
# candidate set + temp cooldown dir.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PICKER="$REPO_ROOT/scripts/dispatch/_pick_gap.py"

[[ -f "$PICKER" ]] || { echo "FAIL: $PICKER missing"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/gaps.json" <<'EOF'
[
  {"id":"INFRA-100","domain":"INFRA","priority":"P1","effort":"xs","created_at":1000,"depends_on":"","status":"open","acceptance_criteria":"Implement the change and verify the behavior"},
  {"id":"INFRA-101","domain":"INFRA","priority":"P1","effort":"xs","created_at":1001,"depends_on":"","status":"open","acceptance_criteria":"Implement the change and verify the behavior"},
  {"id":"INFRA-102","domain":"INFRA","priority":"P1","effort":"s", "created_at":1002,"depends_on":"","status":"open","acceptance_criteria":"Implement the change and verify the behavior"}
]
EOF
mkdir -p "$TMP/cooldown"

run_picker() {
    GAP_JSON_FILE="$TMP/gaps.json" \
    FLEET_PRIORITY_FILTER="P0,P1" \
    FLEET_DOMAIN_FILTER="INFRA" \
    FLEET_EFFORT_FILTER="xs,s,m" \
    EXCLUDE_RE="^$" \
    ACTIVE_GAPS="" \
    WORKER_INDEX="1" \
    COOLDOWN_DIR="$TMP/cooldown" \
    python3 "$PICKER"
}

# ── Test 1: no cooldown → returns top candidate ─────────────────────────────
echo "Test 1: empty cooldown dir → worker 1 picks top candidate (INFRA-100)"
P=$(run_picker)
if [[ "$P" == "INFRA-100" ]]; then
    echo "  PASS"
else
    echo "  FAIL (expected INFRA-100, got $P)"
    exit 1
fi

# ── Test 2: cooldown record with until > now → that gap is skipped ──────────
echo "Test 2: cooldown record for INFRA-100 (until=now+3600) → picker skips to INFRA-101"
FUTURE=$(($(date +%s) + 3600))
cat >"$TMP/cooldown/INFRA-100.json" <<EOF
{"gap_id":"INFRA-100","rc":1,"until":$FUTURE,"agent":"4","ts":"test"}
EOF
P=$(run_picker)
if [[ "$P" == "INFRA-101" ]]; then
    echo "  PASS"
else
    echo "  FAIL (expected INFRA-101, got $P; cooldown should have masked INFRA-100)"
    exit 1
fi

# ── Test 3: expired cooldown → record auto-cleaned, gap re-eligible ────────
echo "Test 3: expired cooldown record (until=now-60) → INFRA-100 eligible again, record removed"
PAST=$(($(date +%s) - 60))
cat >"$TMP/cooldown/INFRA-100.json" <<EOF
{"gap_id":"INFRA-100","rc":1,"until":$PAST,"agent":"4","ts":"test"}
EOF
# Confirm record exists before run
[[ -f "$TMP/cooldown/INFRA-100.json" ]] || { echo "  FAIL setup"; exit 1; }
P=$(run_picker)
if [[ "$P" != "INFRA-100" ]]; then
    echo "  FAIL: expected INFRA-100 (cooldown expired), got $P"
    exit 1
fi
if [[ -f "$TMP/cooldown/INFRA-100.json" ]]; then
    echo "  FAIL: expired record should have been auto-cleaned, still present"
    exit 1
fi
echo "  PASS (gap re-eligible + expired record auto-cleaned)"

# ── Test 4: multiple cooldowns → picker skips to first non-cooled candidate ─
echo "Test 4: cooldowns on INFRA-100 + INFRA-101 → picker returns INFRA-102"
cat >"$TMP/cooldown/INFRA-100.json" <<EOF
{"gap_id":"INFRA-100","rc":1,"until":$FUTURE,"agent":"4","ts":"test"}
EOF
cat >"$TMP/cooldown/INFRA-101.json" <<EOF
{"gap_id":"INFRA-101","rc":1,"until":$FUTURE,"agent":"4","ts":"test"}
EOF
P=$(run_picker)
if [[ "$P" == "INFRA-102" ]]; then
    echo "  PASS"
else
    echo "  FAIL (expected INFRA-102, got $P)"
    exit 1
fi

# ── Test 5: malformed cooldown record → tolerated, no crash, gap eligible ──
echo "Test 5: malformed JSON in cooldown record → ignored gracefully"
rm -f "$TMP/cooldown"/*.json
echo "this is not json" >"$TMP/cooldown/INFRA-100.json"
P=$(run_picker)
if [[ "$P" == "INFRA-100" ]]; then
    echo "  PASS (malformed record ignored, gap still eligible)"
else
    echo "  FAIL (expected INFRA-100, got $P; malformed cooldown shouldn't mask)"
    exit 1
fi

# ── Test 6: missing COOLDOWN_DIR env var → no cooldown applied (back-compat) ─
echo "Test 6: missing COOLDOWN_DIR env → original behavior (no cooldown filtering)"
P=$(GAP_JSON_FILE="$TMP/gaps.json" FLEET_PRIORITY_FILTER="P0,P1" \
    FLEET_DOMAIN_FILTER="INFRA" FLEET_EFFORT_FILTER="xs,s,m" EXCLUDE_RE="^$" \
    ACTIVE_GAPS="" WORKER_INDEX="1" python3 "$PICKER")
if [[ "$P" == "INFRA-100" ]]; then
    echo "  PASS"
else
    echo "  FAIL (expected INFRA-100, got $P)"
    exit 1
fi

echo ""
echo "All cooldown tests passed."
