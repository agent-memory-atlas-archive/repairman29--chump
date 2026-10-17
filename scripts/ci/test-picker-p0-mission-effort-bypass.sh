#!/usr/bin/env bash
# MISSION-047 regression guard (retargeted by CREDIBLE-1513 after RESILIENT-1138).
#
# A P0 + domain=MISSION gap with a too-big (or too-small) effort for the worker's
# tier must still be pickable, or it starves forever (MISSION-026's mechanism;
# MISSION-046 was the live victim). MISSION-047 originally asserted this for the
# haiku m/l/xl gate. RESILIENT-1138 retired the haiku/sonnet effort gates; the
# only effort gates left are the deepseek tiers (RESILIENT-612):
#     flash refuses m/l/xl, pro refuses xs/s/l/xl, both unless _is_p0_mission.
# This test asserts (a) the bypass is present in both pickers for both tiers,
# and (b) _pick_gap.py (no claim side-effect) INCLUDES a P0-MISSION/m gap for a
# flash worker while still EXCLUDING a non-mission P1/m gap (no regression), and
# a pro worker still excludes a non-mission P1/xs gap.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # scripts/
PICK="$ROOT/dispatch/_pick_gap.py"
PICK_CLAIM="$ROOT/dispatch/_pick_and_claim_gap.py"
[[ -f "$PICK" && -f "$PICK_CLAIM" ]] || { echo "FAIL: picker scripts not found"; exit 1; }

fails=0
ok()   { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; fails=$((fails+1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/cooldown"

# (a) Static: the canonical picker bypasses the deepseek-tier effort gates for
# P0-MISSION gaps. INFRA-8224 made _pick_gap.py a thin shim that execs the
# canonical picker with --dry-run, so the shim is checked for the exec, not for
# a copy of the gate (one picker, one gate).
if grep -q '_pick_and_claim_gap.py' "$PICK" && grep -q 'execv' "$PICK"; then
  ok "$(basename "$PICK"): shim execs the canonical picker"
else
  fail "$(basename "$PICK"): expected a thin shim that execs _pick_and_claim_gap.py"
fi
f="$PICK_CLAIM"
  if grep -q 'worker_model == "flash" and e in ("m", "l", "xl") and not _is_p0_mission' "$f"; then
    ok "$(basename "$f"): flash m/l/xl gate bypasses P0-MISSION"
  else
    fail "$(basename "$f"): flash gate MISSING the _is_p0_mission bypass"
  fi
  if grep -q 'worker_model == "pro" and e in ("xs", "s", "l", "xl") and not _is_p0_mission' "$f"; then
    ok "$(basename "$f"): pro xs/s/l/xl gate bypasses P0-MISSION"
  else
    fail "$(basename "$f"): pro gate MISSING the _is_p0_mission bypass"
  fi

run_pick() {  # $1=gap_json_file $2=FLEET_MODEL
  GAP_JSON_FILE="$1" \
  FLEET_MODEL="$2" \
  FLEET_PRIORITY_FILTER='P0,P1' \
  FLEET_EFFORT_FILTER='xs,s,m' \
  FLEET_DOMAIN_FILTER='' \
  EXCLUDE_RE='^$' \
  ACTIVE_GAPS='' \
  COOLDOWN_DIR="$tmp/cooldown" \
  WORKER_INDEX=1 WORKER_ID=1 \
  python3 "$PICK" 2>/dev/null
}

# (b1) A flash worker MUST pick a P0-MISSION effort=m gap (the bypass).
#      The P1/INFRA effort=m gap is correctly filtered out for flash, leaving the
#      P0-MISSION gap as the only candidate.
cat > "$tmp/gaps1.json" <<'JSON'
[
 {"id":"MISSION-9001","priority":"P0","domain":"MISSION","effort":"m","title":"MISSION: bypass test","depends_on":"[]","skills_required":"","required_model":"","created_at":1000,"status":"open","acceptance_criteria":"the picker includes this gap for a flash worker"},
 {"id":"INFRA-9002","priority":"P1","domain":"INFRA","effort":"m","title":"INFRA: flash should skip","depends_on":"[]","skills_required":"","required_model":"","created_at":2000,"status":"open","acceptance_criteria":"non-mission P1 m gap, flash must skip it"}
]
JSON
got="$(run_pick "$tmp/gaps1.json" flash)"
[[ "$got" == "MISSION-9001" ]] \
  && ok "flash worker PICKS the P0-MISSION effort=m gap (bypass works)" \
  || fail "flash picked '$got' (expected MISSION-9001 — bypass not effective)"

# (b2) No regression: a flash worker must still SKIP a non-mission P1 effort=m gap.
cat > "$tmp/gaps2.json" <<'JSON'
[
 {"id":"INFRA-9003","priority":"P1","domain":"INFRA","effort":"m","title":"INFRA: P1 m, flash must skip","depends_on":"[]","skills_required":"","required_model":"","created_at":1000,"status":"open","acceptance_criteria":"non-mission P1 m gap, flash must skip it"}
]
JSON
got2="$(run_pick "$tmp/gaps2.json" flash)"
[[ -z "$got2" ]] \
  && ok "flash worker still SKIPS a non-mission P1 effort=m gap (no regression)" \
  || fail "flash picked '$got2' (a P1/m gap should be excluded for flash)"

# (b3) pro refuses xs: a non-mission P1/xs gap is skipped, a P0-MISSION/xs is picked.
cat > "$tmp/gaps3.json" <<'JSON'
[
 {"id":"INFRA-9004","priority":"P1","domain":"INFRA","effort":"xs","title":"INFRA: P1 xs, pro must skip","depends_on":"[]","skills_required":"","required_model":"","created_at":1000,"status":"open","acceptance_criteria":"non-mission P1 xs gap, pro must skip it"}
]
JSON
got3="$(run_pick "$tmp/gaps3.json" pro)"
[[ -z "$got3" ]] \
  && ok "pro worker SKIPS a non-mission P1 effort=xs gap" \
  || fail "pro picked '$got3' (a P1/xs gap should be excluded for pro)"
cat > "$tmp/gaps4.json" <<'JSON'
[
 {"id":"MISSION-9005","priority":"P0","domain":"MISSION","effort":"xs","title":"MISSION: pro bypass test","depends_on":"[]","skills_required":"","required_model":"","created_at":1000,"status":"open","acceptance_criteria":"the picker includes this gap for a pro worker"}
]
JSON
got4="$(run_pick "$tmp/gaps4.json" pro)"
[[ "$got4" == "MISSION-9005" ]] \
  && ok "pro worker PICKS the P0-MISSION effort=xs gap (bypass works)" \
  || fail "pro picked '$got4' (expected MISSION-9005)"

echo ""
if [[ "$fails" -eq 0 ]]; then
  echo "PASS: test-picker-p0-mission-effort-bypass.sh (P0-MISSION gaps no longer starve under deepseek tiers)"
  exit 0
else
  echo "FAIL: test-picker-p0-mission-effort-bypass.sh ($fails assertion(s) failed)"
  exit 1
fi
