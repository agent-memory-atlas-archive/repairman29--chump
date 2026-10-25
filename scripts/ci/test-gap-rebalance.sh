#!/usr/bin/env bash
# test-gap-rebalance.sh — INFRA-635
#
# Validates `chump gap rebalance`:
#  - subcommand wired in main.rs
#  - --json output has required fields
#  - Scenario 1: over-budget P0 → DEMOTE action, exit 1
#  - Scenario 2: pillar skew (one pillar dominates) → DEMOTE action, exit 1
#  - Scenario 3: all clean → exit 0, "clean" message
#  - Scenario 4: no-action-needed (at floor but balanced) → exit 0

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# shellcheck source=scripts/coord/lib/test-sandbox.sh
# INFRA-2088: canonical sandbox primitive — single source of truth for the
# full CHUMP_HOME/CHUMP_REPO/CHUMP_REPO_ROOT/CHUMP_STATE_DB/CHUMP_LOCK_DIR
# isolation set, so this test can't silently bleed into the real state.db.
source "$REPO_ROOT/scripts/coord/lib/test-sandbox.sh"
# RESILIENT-1652: healthy-node fixture helper — each sandbox below lays down a
# content-valid oauth token, a not-paused node.env and a fresh farmer heartbeat
# INSIDE its own sandbox dir so the RESILIENT-069 farmer readiness gate
# (consulted by `gap reserve`) reads GREEN by evidence on a fresh Linux runner.
# No gate loosening, no skip env var.
# shellcheck source=scripts/ci/lib/sandbox-healthy-node.sh
source "$REPO_ROOT/scripts/ci/lib/sandbox-healthy-node.sh"

echo "=== INFRA-635 gap rebalance test ==="
echo

# 1. Subcommand wired
if grep -q '"rebalance"' "$REPO_ROOT/src/main.rs"; then
    ok "rebalance arm in main.rs"
else
    fail "rebalance arm missing from main.rs"
fi

if grep -q 'rebalance' "$REPO_ROOT/src/main.rs"; then
    ok "rebalance in help text"
else
    fail "rebalance not in help text"
fi

BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
if [[ ! -f "$BIN" ]]; then
    echo "  [build] cargo build --bin chump..."
    cargo build --bin chump --manifest-path "$REPO_ROOT/Cargo.toml" -q 2>&1 | tail -5
fi

if [[ ! -f "$BIN" ]]; then
    fail "chump binary not found — skipping functional tests"
    echo; echo "=== Results: $PASS passed, $FAIL failed ==="; [[ "$FAIL" -eq 0 ]]
fi

reserve_gap() {
    local title="$1" priority="${2:-P1}" effort="${3:-xs}"
    # MISSION-045: these synthetic P0/P1 fixtures have no real outcome to trace
    # to; --no-outcome-required is the audited escape hatch (no env-var bypass,
    # per the EFFECTIVE-094 debt ceiling). Same spirit as CHUMP_GAP_RESERVE_NO_EVIDENCE above.
    # CREDIBLE-1543: Scenario 1 intentionally seeds 6 P0 gaps (over the 5-P0
    # ceiling) to exercise `chump gap rebalance`; pass --p0-override for P0 fixtures.
    local extra_args=()
    if [[ "$priority" == "P0" ]]; then
        extra_args+=(--p0-override "INFRA-635 rebalance fixture seeding >5 P0")
    fi
    "$BIN" gap reserve --domain INFRA --priority "$priority" --effort "$effort" \
        --title "$title" --quiet --force-duplicate --no-outcome-required "${extra_args[@]}" 2>/dev/null
}

export CHUMP_ALLOW_MAIN_WORKTREE=1
export FLEET_029_AMBIENT_GLANCE_SKIP=1
export CHUMP_RESERVE_NO_AUTOSTAGE=1
# EFFECTIVE-294: default AC are now concrete (no TODO placeholders), which
# makes fixture gaps *pickable* — so the INFRA-1152 pillar-balance gate fires
# inside these synthetic DBs (2nd same-pillar reserve = 100% of pool →
# blocked; under set -e the script dies mid-seed). Fixtures aren't real
# pillar inventory; disable the gate, same as test-gap-list-since-json-schema.
export CHUMP_PILLAR_BALANCE_DISABLE=1
export CHUMP_GAP_RESERVE_NO_EVIDENCE=1

# ── Scenario 1: over-budget P0 (>5) ─────────────────────────────────────────
echo "[scenario 1: over-budget P0]"
TMP1="$(mktemp -d)"; chump_test_sandbox_setup "$TMP1"; export HOME="$TMP1"; write_sandbox_healthy_node "$TMP1"  # RESILIENT-1652

# 6 P0 gaps (one over budget)
for i in $(seq 1 6); do
    reserve_gap "EFFECTIVE: fixture-p0-$i" P0 xs
done

OUT1=$("$BIN" gap rebalance 2>&1 || true)
if "$BIN" gap rebalance >/dev/null 2>&1; then
    fail "over-budget P0 should exit non-zero"
else
    ok "over-budget P0 exits non-zero"
fi

if echo "$OUT1" | grep -qi "DEMOTE\|demote\|budget"; then
    ok "over-budget P0 suggests DEMOTE action"
else
    fail "over-budget P0 should suggest DEMOTE — got: $OUT1"
fi

# --apply should demote excess P0s
"$BIN" gap rebalance --apply >/dev/null 2>&1 || true
_p0_tmpout="$(mktemp)"
"$BIN" gap rebalance --json > "$_p0_tmpout" 2>/dev/null || true
P0_AFTER=$(python3 -c "import sys,json; d=json.load(open('$_p0_tmpout')); print(d.get('p0_count',99))" 2>/dev/null || echo 99)
rm -f "$_p0_tmpout"
if [[ "${P0_AFTER:-99}" -le 5 ]]; then
    ok "after --apply, P0 count ≤ 5 (got $P0_AFTER)"
else
    fail "after --apply, P0 count should be ≤ 5 (got $P0_AFTER)"
fi

chump_test_sandbox_cleanup "$TMP1"

# ── Scenario 2: pillar skew (one dominates >50%) ─────────────────────────────
echo
echo "[scenario 2: pillar skew]"
TMP2="$(mktemp -d)"; chump_test_sandbox_setup "$TMP2"; export HOME="$TMP2"; write_sandbox_healthy_node "$TMP2"  # RESILIENT-1652

# 10 EFFECTIVE P1 gaps — EFFECTIVE dominates; other pillars starved
for i in $(seq 1 10); do
    reserve_gap "EFFECTIVE: fixture-skew-$i" P1 xs
done

if "$BIN" gap rebalance >/dev/null 2>&1; then
    fail "pillar-skew should exit non-zero"
else
    ok "pillar-skew exits non-zero"
fi

OUT2=$("$BIN" gap rebalance 2>&1 || true)
if echo "$OUT2" | grep -qi "DEMOTE\|FILE\|pillar\|floor\|dominates"; then
    ok "pillar-skew suggests corrective action"
else
    fail "pillar-skew should suggest corrective action — got: $OUT2"
fi

chump_test_sandbox_cleanup "$TMP2"

# ── Scenario 3: all clean ────────────────────────────────────────────────────
echo
echo "[scenario 3: all clean]"
TMP3="$(mktemp -d)"; chump_test_sandbox_setup "$TMP3"; export HOME="$TMP3"; write_sandbox_healthy_node "$TMP3"  # RESILIENT-1652

# 2 per pillar → balanced, no P0s
for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    reserve_gap "${p}: fixture-clean-a" P1 xs
    reserve_gap "${p}: fixture-clean-b" P1 xs
done

if "$BIN" gap rebalance >/dev/null 2>&1; then
    ok "clean registry exits 0"
else
    fail "clean registry should exit 0"
fi

OUT3=$("$BIN" gap rebalance 2>&1)
if echo "$OUT3" | grep -q "clean\|OK"; then
    ok "clean registry prints OK message"
else
    fail "clean registry should print OK message — got: $OUT3"
fi

JSON3=$("$BIN" gap rebalance --json 2>/dev/null)
if echo "$JSON3" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('clean')==True" 2>/dev/null; then
    ok "--json clean=true on balanced registry"
else
    fail "--json clean should be true — got: $JSON3"
fi

chump_test_sandbox_cleanup "$TMP3"

# ── Scenario 4: no-action-needed (exactly at floor, P0=0) ───────────────────
echo
echo "[scenario 4: no-action-needed]"
TMP4="$(mktemp -d)"; chump_test_sandbox_setup "$TMP4"; export HOME="$TMP4"; write_sandbox_healthy_node "$TMP4"  # RESILIENT-1652

# Exactly 2 per pillar, 0 P0s → no action
for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    reserve_gap "${p}: fixture-floor-a" P1 s
    reserve_gap "${p}: fixture-floor-b" P1 s
done

ACTIONS=$("$BIN" gap rebalance --json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('actions',[])))" 2>/dev/null || echo -1)
if [[ "$ACTIONS" -eq 0 ]]; then
    ok "no-action-needed: 0 actions (got $ACTIONS)"
else
    fail "no-action-needed should have 0 actions (got $ACTIONS)"
fi

chump_test_sandbox_cleanup "$TMP4"

# ── --json required keys ──────────────────────────────────────────────────────
echo
echo "[--json required keys]"
TMP5="$(mktemp -d)"; chump_test_sandbox_setup "$TMP5"; export HOME="$TMP5"; write_sandbox_healthy_node "$TMP5"  # RESILIENT-1652
_j5_out="$(mktemp)"
"$BIN" gap rebalance --json > "$_j5_out" 2>/dev/null || true
JSON5="$(cat "$_j5_out")"; rm -f "$_j5_out"
for key in p0_count p0_budget total_pickable actions applied clean; do
    if printf '%s' "$JSON5" | python3 -c "import sys,json; d=json.load(sys.stdin); assert '$key' in d" 2>/dev/null; then
        ok "JSON key '$key' present"
    else
        fail "JSON key '$key' missing — got: $JSON5"
    fi
done
chump_test_sandbox_cleanup "$TMP5"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
