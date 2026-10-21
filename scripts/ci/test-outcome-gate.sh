#!/usr/bin/env bash
# test-outcome-gate.sh — MISSION-045
#
# Proves the P0/P1 outcome gate (the anti-bloat keystone) actually BITES, and
# that its escape hatches / skip semantics behave. Without this, the gate could
# silently no-op and every "green" run would still report it covered.
#
# Cases:
#   1. Outcomes EXIST, P0 reserve WITHOUT --outcome        → BLOCKED (exit 1)
#   2. Outcomes EXIST, P1 reserve WITHOUT --outcome        → BLOCKED (exit 1)
#   3. Outcomes EXIST, P0 reserve WITH a valid --outcome   → SUCCEEDS
#   4. Outcomes EXIST, P0 reserve WITH --no-outcome-required → SUCCEEDS + audited
#   5. Outcomes EXIST, P2 reserve WITHOUT --outcome        → SUCCEEDS (permissionless)
#   6. EMPTY outcomes table, P0 reserve WITHOUT --outcome  → SUCCEEDS (vacuous-skip)

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# shellcheck source=scripts/coord/lib/test-sandbox.sh
# INFRA-2088: canonical sandbox primitive.
source "$REPO_ROOT/scripts/coord/lib/test-sandbox.sh"
# RESILIENT-1652: healthy-node fixture helper — each sandbox below lays down a
# content-valid oauth token, a not-paused node.env and a fresh farmer heartbeat
# INSIDE its own sandbox dir so the RESILIENT-069 farmer readiness gate
# (consulted by `gap reserve`) reads GREEN by evidence on a fresh Linux runner.
# No gate loosening, no skip env var.
# shellcheck source=scripts/ci/lib/sandbox-healthy-node.sh
source "$REPO_ROOT/scripts/ci/lib/sandbox-healthy-node.sh"

echo "=== MISSION-045 outcome gate test ==="
echo

BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
if [[ ! -f "$BIN" ]]; then
    echo "  [build] cargo build --bin chump..."
    cargo build --bin chump --manifest-path "$REPO_ROOT/Cargo.toml" -q 2>&1 | tail -5
fi
if [[ ! -f "$BIN" ]]; then
    fail "chump binary not found — skipping functional tests"
    echo; echo "=== Results: $PASS passed, $FAIL failed ==="; [[ "$FAIL" -eq 0 ]]
fi

# Fixture env mirrors test-gap-rebalance.sh: synthetic DBs, gates that are not
# under test disabled so a reserve's only remaining gate is the outcome gate.
export CHUMP_ALLOW_MAIN_WORKTREE=1
export FLEET_029_AMBIENT_GLANCE_SKIP=1
export CHUMP_RESERVE_NO_AUTOSTAGE=1
export CHUMP_PILLAR_BALANCE_DISABLE=1
export CHUMP_GAP_RESERVE_NO_EVIDENCE=1

reserve() {  # domain priority effort title [extra-args...]
    local domain="$1" priority="$2" effort="$3" title="$4"; shift 4
    "$BIN" gap reserve --domain "$domain" --priority "$priority" --effort "$effort" \
        --title "$title" --quiet --force-duplicate "$@"
}

# ── DB WITH outcomes ─────────────────────────────────────────────────────────
WITH="$(mktemp -d)"; chump_test_sandbox_setup "$WITH"; export HOME="$WITH"; write_sandbox_healthy_node "$WITH"  # RESILIENT-1652
"$BIN" outcome new --id GATEOUT --title "gate fixture outcome" >/dev/null 2>&1
if "$BIN" outcome list 2>/dev/null | grep -q GATEOUT; then
    ok "fixture outcome GATEOUT created"
else
    fail "could not create fixture outcome — cannot test gate"
    echo; echo "=== Results: $PASS passed, $FAIL failed ==="; [[ "$FAIL" -eq 0 ]]; exit
fi

# 1. P0 without --outcome → BLOCKED
if reserve INFRA P0 xs "gate-p0-block" >/dev/null 2>&1; then
    fail "case 1: P0 without --outcome should be BLOCKED (gate no-op'd)"
else
    ok "case 1: P0 without --outcome is blocked"
fi

# 2. P1 without --outcome → BLOCKED
if reserve INFRA P1 xs "gate-p1-block" >/dev/null 2>&1; then
    fail "case 2: P1 without --outcome should be BLOCKED"
else
    ok "case 2: P1 without --outcome is blocked"
fi

# 3. P0 WITH valid --outcome → SUCCEEDS
if reserve INFRA P0 xs "gate-p0-outcome" --outcome GATEOUT >/dev/null 2>&1; then
    ok "case 3: P0 with valid --outcome succeeds"
else
    fail "case 3: P0 with valid --outcome should succeed"
fi

# 4. P0 WITH --no-outcome-required → SUCCEEDS + audited
AMB4="$CHUMP_LOCK_DIR/ambient.jsonl"
if reserve INFRA P0 xs "gate-p0-bypass" --no-outcome-required >/dev/null 2>&1; then
    ok "case 4: P0 with --no-outcome-required succeeds"
    if grep -q '"kind":"outcome_gate_bypassed"' "$AMB4" 2>/dev/null; then
        ok "case 4: bypass emitted audited outcome_gate_bypassed event"
    else
        fail "case 4: --no-outcome-required must emit outcome_gate_bypassed"
    fi
else
    fail "case 4: P0 with --no-outcome-required should succeed"
fi

# 5. P2 without --outcome → SUCCEEDS (permissionless)
if reserve INFRA P2 xs "gate-p2-ok" >/dev/null 2>&1; then
    ok "case 5: P2 without outcome is permissionless"
else
    fail "case 5: P2 without outcome should succeed (permissionless)"
fi

# ── EMPTY outcomes DB (vacuous-skip) ─────────────────────────────────────────
chump_test_sandbox_cleanup "$WITH"
EMPTY="$(mktemp -d)"; chump_test_sandbox_setup "$EMPTY"; export HOME="$EMPTY"; write_sandbox_healthy_node "$EMPTY"  # RESILIENT-1652
if "$BIN" outcome list 2>/dev/null | grep -q '\['; then
    fail "case 6 setup: fresh DB unexpectedly has outcomes"
fi
# 6. P0 without --outcome in an empty-outcomes DB → SUCCEEDS (nothing to trace to)
if reserve INFRA P0 xs "gate-empty-skip" >/dev/null 2>&1; then
    ok "case 6: empty-outcomes DB skips the gate (P0 reserve succeeds)"
else
    fail "case 6: empty-outcomes DB should skip the gate"
fi

chump_test_sandbox_cleanup "$EMPTY"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
