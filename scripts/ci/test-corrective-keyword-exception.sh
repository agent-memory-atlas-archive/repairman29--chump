#!/usr/bin/env bash
# test-corrective-keyword-exception.sh — META-937 (META-823 slice) regression test.
#
# During a waste-SLO-breach pause (.chump/fleet-paused), worker.sh sets
# FLEET_REQUIRE_TITLE_SUBSTR=corrective before invoking the picker+claimer so
# that ONLY gaps whose title contains the "corrective" keyword remain
# pickable — a regular gap must NOT be returned, while a corrective gap must
# still be claimable. This test exercises that filter directly against
# _pick_and_claim_gap.py.
#
# Network-free: exercises _pick_and_claim_gap.py directly with a synthetic
# candidate set + temp lock dir (mirrors test-pick-and-claim-dep-resolution.sh).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PICKER="$REPO_ROOT/scripts/dispatch/_pick_and_claim_gap.py"

[[ -f "$PICKER" ]] || { echo "FAIL: $PICKER missing"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

run_picker() {
    local gaps_file="$1" session="$2" lock_dir="$3" require_substr="$4"
    CHUMP_SESSION_ID="$session" \
    GAP_JSON_FILE="$gaps_file" \
    CHUMP_LOCK_DIR="$lock_dir" \
    FLEET_PRIORITY_FILTER="P0,P1" \
    FLEET_DOMAIN_FILTER="INFRA" \
    FLEET_EFFORT_FILTER="xs,s,m" \
    FLEET_MODEL="haiku" \
    EXCLUDE_RE="^$" \
    WORKER_INDEX="1" \
    FLEET_REQUIRE_TITLE_SUBSTR="$require_substr" \
    python3 "$PICKER" 2>/dev/null || true
}

# ── Test 1: during a pause (require_substr=corrective), a regular gap is
#            withheld even though it's otherwise fully pickable ────────────
echo "Test 1: regular gap is NOT returned when FLEET_REQUIRE_TITLE_SUBSTR=corrective"
cat >"$TMP/gaps-regular.json" <<'EOF'
[
  {"id":"INFRA-910","domain":"INFRA","title":"Add retry logic to the webhook receiver","priority":"P1","effort":"s","created_at":1000,"depends_on":"","status":"open"}
]
EOF
lock_dir_1="$TMP/locks-1"
mkdir -p "$lock_dir_1"
pick=$(run_picker "$TMP/gaps-regular.json" "session-1" "$lock_dir_1" "corrective")
if [[ -z "$pick" ]]; then
    echo "  PASS (regular gap correctly withheld during waste-SLO pause)"
else
    echo "  FAIL (expected no pick, got: '$pick')"
    exit 1
fi

# ── Test 2: a gap tagged "corrective" IS returned during the same pause ─────
echo "Test 2: corrective-keyword gap IS returned when FLEET_REQUIRE_TITLE_SUBSTR=corrective"
cat >"$TMP/gaps-corrective.json" <<'EOF'
[
  {"id":"INFRA-911","domain":"INFRA","title":"Corrective: reduce waste-tally false positives in ambient scan","priority":"P1","effort":"s","created_at":1000,"depends_on":"","status":"open"}
]
EOF
lock_dir_2="$TMP/locks-2"
mkdir -p "$lock_dir_2"
pick=$(run_picker "$TMP/gaps-corrective.json" "session-2" "$lock_dir_2" "corrective")
if [[ "$pick" == "INFRA-911" ]]; then
    echo "  PASS (claimed INFRA-911; corrective keyword bypasses the pause filter)"
else
    echo "  FAIL (expected INFRA-911, got: '$pick')"
    exit 1
fi

# ── Test 3: outside a pause (require_substr unset/empty), both gap types are
#            pickable — the filter is a no-op when the fleet isn't paused ──
echo "Test 3: regular gap IS returned when FLEET_REQUIRE_TITLE_SUBSTR is unset"
lock_dir_3="$TMP/locks-3"
mkdir -p "$lock_dir_3"
pick=$(run_picker "$TMP/gaps-regular.json" "session-3" "$lock_dir_3" "")
if [[ "$pick" == "INFRA-910" ]]; then
    echo "  PASS (regular gap pickable when no pause filter is active)"
else
    echo "  FAIL (expected INFRA-910, got: '$pick')"
    exit 1
fi

echo ""
echo "All corrective-keyword exception tests passed."
