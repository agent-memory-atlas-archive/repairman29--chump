#!/usr/bin/env bash
# test-pillar-balance-alerts.sh — INFRA-902
#
# Verifies scripts/ops/pillar-balance-check.sh:
#  - alert schema (pillar_balance_alert / pillar_balance_overweight fields)
#  - floor threshold (< 2 pickable → starved alert)
#  - overweight threshold (> 50% of pickable pool → overweight alert)
#  - exit codes (0 when balanced, non-zero when any alert fired)
#  - ambient.jsonl emission + mkdir -p when .chump-locks/ doesn't exist yet
#  - `chump gap audit-priorities` wiring (AC 5)

set -uo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/scripts/ops/pillar-balance-check.sh"

echo "=== INFRA-902 pillar-balance-check.sh test ==="
echo

if [[ ! -x "$SCRIPT" ]]; then
    fail "scripts/ops/pillar-balance-check.sh missing or not executable"
    echo
    echo "=== Results: $PASS passed, $FAIL failed ==="
    exit 1
fi

# Resolve target dir via cargo metadata (INFRA-481: shared target-dir).
TARGET_DIR=$(cargo metadata --no-deps --manifest-path "$REPO_ROOT/Cargo.toml" \
    --format-version 1 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('target_directory',''))" \
    2>/dev/null || echo "")
BIN="${CHUMP_BIN:-}"
if [[ -z "$BIN" || ! -x "$BIN" ]]; then
    BIN="${TARGET_DIR:+$TARGET_DIR/debug/chump}"
    BIN="${BIN:-${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump}"
fi
if [[ ! -x "$BIN" ]]; then
    echo "  [build] cargo build --bin chump (quiet)..."
    cargo build --bin chump --manifest-path "$REPO_ROOT/Cargo.toml" -q 2>&1 | tail -5
    TARGET_DIR=$(cargo metadata --no-deps --manifest-path "$REPO_ROOT/Cargo.toml" \
        --format-version 1 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('target_directory',''))" \
        2>/dev/null || echo "")
    BIN="${TARGET_DIR:+$TARGET_DIR/debug/chump}"
    BIN="${BIN:-${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump}"
fi
if [[ ! -x "$BIN" ]]; then
    fail "chump binary not found after build — skipping functional tests"
    echo
    echo "=== Results: $PASS passed, $FAIL failed ==="
    exit 1
fi

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# CREDIBLE-1519: this fixture drives gap reserve via per-call CHUMP_STATE_DB and
# never sets CHUMP_REPO/CHUMP_HOME, so the RESILIENT-069 farmer gate resolves
# repo_root to the cwd (a paused host's .chump/fleet-paused) and oauth to the
# host ~/.chump — both RED-block the seeds. --force would bypass the pillar
# gate under test, so pin CHUMP_HOME at a hermetic temp dir instead (honored by
# src/farmer_status.rs for oauth + repo_root for sentinel/heartbeat).
export CHUMP_HOME="$TMPDIR_BASE"

# INFRA-1149: gap-reserve title-similarity gate would otherwise block the 2nd+
# gap in a pillar (near-identical fixture titles) and starve every pillar
# unconditionally — export the bypass for the whole fixture run.
export CHUMP_GAP_RESERVE_NO_SIMILARITY=1

# Reserve N gaps tagged with a pillar prefix into an isolated fixture DB.
# CREDIBLE/RESILIENT/MISSION domains at P0/P1 require --evidence (CREDIBLE-106)
# — pass --no-evidence-required so the fixture doesn't need real evidence text.
reserve_gap() {
    local pillar="$1" n="$2" db="$3"
    local evidence_flag=""
    if [[ "$pillar" == "CREDIBLE" || "$pillar" == "RESILIENT" ]]; then
        evidence_flag="--no-evidence-required"
    fi
    CHUMP_STATE_DB="$db" "$BIN" gap reserve --domain INFRA \
        --title "${pillar}: fixture gap ${n} $$" \
        --priority P1 --effort s --no-outcome-required $evidence_flag \
        >/dev/null 2>&1
}

# ── Test 1: starved pillar (0 gaps) emits pillar_balance_alert with correct schema ──
DB1="$TMPDIR_BASE/t1.db"
AMB1="$TMPDIR_BASE/t1-ambient.jsonl"
reserve_gap EFFECTIVE 1 "$DB1"
reserve_gap EFFECTIVE 2 "$DB1"
CHUMP_STATE_DB="$DB1" CHUMP_AMBIENT_LOG="$AMB1" CHUMP_BIN="$BIN" \
    "$SCRIPT" --json > "$TMPDIR_BASE/t1.out" 2>/dev/null
EXIT1=$?
if grep -q '"kind": "pillar_balance_alert"' "$TMPDIR_BASE/t1.out" || grep -q '"kind":"pillar_balance_alert"' "$TMPDIR_BASE/t1.out"; then
    ok "starved pillar (CREDIBLE=0) emits pillar_balance_alert"
else
    fail "starved pillar did not emit pillar_balance_alert: $(cat "$TMPDIR_BASE/t1.out")"
fi

# ── Test 2: alert schema has pillar, count, floor fields ──
if python3 -c "
import json
d = json.load(open('$TMPDIR_BASE/t1.out'))
alerts = [a for a in d['alerts'] if a['kind'] == 'pillar_balance_alert']
assert alerts, 'no starved alerts'
a = alerts[0]
assert 'pillar' in a and 'count' in a and 'floor' in a
assert a['floor'] == 2
" 2>"$TMPDIR_BASE/t2.err"; then
    ok "pillar_balance_alert schema has pillar/count/floor=2"
else
    fail "pillar_balance_alert schema check failed: $(cat "$TMPDIR_BASE/t2.err")"
fi

# ── Test 3: exit code non-zero when alerts fired ──
if [[ "$EXIT1" -ne 0 ]]; then
    ok "exit code non-zero when starved-pillar alert fires"
else
    fail "expected non-zero exit code when alert fires, got $EXIT1"
fi

# ── Test 4: ambient.jsonl gets the alert line appended, dir auto-created ──
rm -rf "$TMPDIR_BASE/newlocks"
DB4="$TMPDIR_BASE/t4.db"
reserve_gap EFFECTIVE 1 "$DB4"
CHUMP_STATE_DB="$DB4" CHUMP_AMBIENT_LOG="$TMPDIR_BASE/newlocks/ambient.jsonl" CHUMP_BIN="$BIN" \
    "$SCRIPT" --json >/dev/null 2>&1 || true
if [[ -f "$TMPDIR_BASE/newlocks/ambient.jsonl" ]]; then
    ok "ambient.jsonl directory auto-created (mkdir -p) when missing"
else
    fail "ambient.jsonl was not created — mkdir -p guard missing"
fi
if grep -q 'pillar_balance_alert' "$TMPDIR_BASE/newlocks/ambient.jsonl" 2>/dev/null; then
    ok "alert line appended to ambient.jsonl"
else
    fail "alert line missing from ambient.jsonl"
fi

# ── Test 5: overweight pillar (>50% of pickable pool) emits pillar_balance_overweight ──
DB5="$TMPDIR_BASE/t5.db"
AMB5="$TMPDIR_BASE/t5-ambient.jsonl"
for i in 1 2 3 4 5; do reserve_gap EFFECTIVE "$i" "$DB5"; done
reserve_gap CREDIBLE 1 "$DB5"
reserve_gap RESILIENT 1 "$DB5"
reserve_gap RESILIENT 2 "$DB5"
CHUMP_STATE_DB="$DB5" CHUMP_AMBIENT_LOG="$AMB5" CHUMP_BIN="$BIN" \
    "$SCRIPT" --json > "$TMPDIR_BASE/t5.out" 2>/dev/null
if python3 -c "
import json
d = json.load(open('$TMPDIR_BASE/t5.out'))
overweight = [a for a in d['alerts'] if a['kind'] == 'pillar_balance_overweight']
assert overweight, 'expected overweight alert'
a = overweight[0]
assert a['pillar'] == 'EFFECTIVE', a
assert 'pct' in a
assert a['pct'] > 50
"; then
    ok "overweight pillar (EFFECTIVE, 5/8 = 62%) emits pillar_balance_overweight with pct>50"
else
    fail "overweight alert check failed"
fi

# ── Test 6: balanced pillars (each >=2, none >50%) → no alerts, exit 0 ──
DB6="$TMPDIR_BASE/t6.db"
AMB6="$TMPDIR_BASE/t6-ambient.jsonl"
for pillar in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    reserve_gap "$pillar" 1 "$DB6"
    reserve_gap "$pillar" 2 "$DB6"
done
CHUMP_STATE_DB="$DB6" CHUMP_AMBIENT_LOG="$AMB6" CHUMP_BIN="$BIN" \
    "$SCRIPT" --json > "$TMPDIR_BASE/t6.out" 2>/dev/null
EXIT6=$?
if [[ "$EXIT6" -eq 0 ]]; then
    ok "balanced pillars (2 each) exit 0"
else
    fail "expected exit 0 for balanced pillars, got $EXIT6: $(cat "$TMPDIR_BASE/t6.out")"
fi
if python3 -c "
import json
d = json.load(open('$TMPDIR_BASE/t6.out'))
assert d['alerts'] == [], d['alerts']
"; then
    ok "balanced pillars produce zero alerts"
else
    fail "balanced pillars still produced alerts"
fi

# ── Test 7: untagged gaps are excluded from pillar counts ──
DB7="$TMPDIR_BASE/t7.db"
AMB7="$TMPDIR_BASE/t7-ambient.jsonl"
CHUMP_STATE_DB="$DB7" "$BIN" gap reserve --domain INFRA --title "fix login bug $$" \
    --priority P1 --effort s --no-outcome-required >/dev/null 2>&1
CHUMP_STATE_DB="$DB7" CHUMP_AMBIENT_LOG="$AMB7" CHUMP_BIN="$BIN" \
    "$SCRIPT" --json > "$TMPDIR_BASE/t7.out" 2>/dev/null
if python3 -c "
import json
d = json.load(open('$TMPDIR_BASE/t7.out'))
assert d['total_pickable'] == 0, d
"; then
    ok "untagged gap (no EFFECTIVE:/CREDIBLE:/etc prefix) excluded from pillar counts"
else
    fail "untagged gap leaked into pillar counts"
fi

# ── Test 8: 'chump gap audit-priorities' calls the script and includes result ──
DB8="$TMPDIR_BASE/t8.db"
AMB8="$TMPDIR_BASE/t8-ambient.jsonl"
reserve_gap EFFECTIVE 1 "$DB8"
OUT8="$(CHUMP_STATE_DB="$DB8" CHUMP_AMBIENT_LOG="$AMB8" "$BIN" gap audit-priorities --json 2>/dev/null)"
if echo "$OUT8" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert 'pillar_balance' in d, d.keys()
assert 'alerts' in d['pillar_balance'], d['pillar_balance']
"; then
    ok "'chump gap audit-priorities --json' includes pillar_balance field wired from the script"
else
    fail "'chump gap audit-priorities --json' missing pillar_balance field"
fi

TXT8="$(CHUMP_STATE_DB="$DB8" CHUMP_AMBIENT_LOG="$AMB8" "$BIN" gap audit-priorities 2>/dev/null)"
if echo "$TXT8" | grep -q "Pillar balance"; then
    ok "'chump gap audit-priorities' human output includes Pillar balance section"
else
    fail "'chump gap audit-priorities' human output missing Pillar balance section"
fi

# ── Test 9: script exits non-zero on missing/empty gap-list output (defensive) ──
DB9="$TMPDIR_BASE/t9-does-not-exist.db"
CHUMP_STATE_DB="$DB9" CHUMP_BIN="/bin/false" CHUMP_AMBIENT_LOG="$TMPDIR_BASE/t9-ambient.jsonl" \
    "$SCRIPT" --json >/dev/null 2>&1
EXIT9=$?
if [[ "$EXIT9" -ne 0 ]]; then
    ok "script exits non-zero when CHUMP_BIN produces no gap-list output"
else
    fail "expected non-zero exit when gap-list output is empty, got $EXIT9"
fi

# ── Test 10: script has no Bash-4+ constructs (macOS ships Bash 3.2) ──
if grep -v '^\s*#' "$SCRIPT" | grep -qE 'declare -A|declare -n|mapfile|readarray'; then
    fail "script uses a Bash-4+-only construct (declare -A/-n, mapfile, readarray)"
else
    ok "script is free of declare -A/-n, mapfile, readarray (Bash 3.2 compatible)"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
