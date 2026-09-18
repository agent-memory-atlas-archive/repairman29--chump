#!/usr/bin/env bash
# test-chump-gap-reserve-acceptance-criteria.sh — CREDIBLE-1300 (CREDIBLE-1270 slice)
#
# Validates the --acceptance-criteria gate on `chump gap reserve`:
#  (a) --acceptance-criteria stores the provided string verbatim
#  (b) P0/P1 gap with --skip-obs-acs and no --acceptance-criteria is rejected
#  (c) --no-ac-required bypasses the rejection and emits ac_gate_bypassed to ambient.jsonl

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"

echo "=== CREDIBLE-1300 --acceptance-criteria gate test ==="
echo

# ── Source checks (static, no binary needed) ──────────────────────────────────

if grep -q 'no-ac-required' "$REPO_ROOT/src/main.rs"; then
    ok "--no-ac-required bypass wired in main.rs"
else
    fail "--no-ac-required not found in main.rs"
fi

if grep -q 'ac_gate_bypassed' "$REPO_ROOT/src/main.rs"; then
    ok "ac_gate_bypassed audit event wired in main.rs"
else
    fail "ac_gate_bypassed not found in main.rs"
fi

# ── Functional tests ──────────────────────────────────────────────────────────

BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
if [[ ! -f "$BIN" ]]; then
    echo "  [build] cargo build --bin chump (quiet)..."
    RUSTC_WRAPPER="" cargo build --bin chump --manifest-path "$REPO_ROOT/Cargo.toml" -q 2>&1 | tail -5
fi

if [[ ! -f "$BIN" ]]; then
    fail "chump binary not found after build — skipping functional tests"
    echo
    echo "=== Results: $PASS passed, $FAIL failed ==="
    [[ "$FAIL" -eq 0 ]]
    exit
fi

TMP="$(mktemp -d)"
AMBIENT="$TMP/.chump-locks/ambient.jsonl"
mkdir -p "$TMP/.chump-locks"
trap 'rm -rf "$TMP"' EXIT

export CHUMP_REPO="$TMP"
export CHUMP_HOME="$TMP"
export CHUMP_ALLOW_MAIN_WORKTREE=1
export FLEET_029_AMBIENT_GLANCE_SKIP=1
export CHUMP_RESERVE_NO_AUTOSTAGE=1
export CHUMP_DISABLE_OFFLINE_CHECK=1
export CHUMP_GAP_RESERVE_NO_SIMILARITY=1
export CHUMP_PILLAR_BALANCE_DISABLE=1
export CHUMP_GAP_RESERVE_NO_EVIDENCE=1

# (a) --acceptance-criteria stores the provided string verbatim
echo
echo "--- (a) successful creation with --acceptance-criteria ---"
A_ID=$("$BIN" gap reserve --domain INFRA --priority P2 --effort xs \
    --title "test-ac-gate-a" \
    --acceptance-criteria "First bullet|Second bullet" \
    --quiet 2>/dev/null || true)
if [[ -n "$A_ID" ]]; then
    ok "(a) reserve with --acceptance-criteria succeeded (id=$A_ID)"
else
    fail "(a) reserve with --acceptance-criteria failed"
fi
if [[ -n "$A_ID" ]]; then
    SHOW_OUT=$("$BIN" gap show "$A_ID" 2>/dev/null || true)
    if echo "$SHOW_OUT" | grep -q "First bullet"; then
        ok "(a) acceptance criteria text stored verbatim and shown in gap show"
    else
        fail "(a) acceptance criteria not found in gap show output (show=$SHOW_OUT)"
    fi
fi

# (b) P0/P1 gap with --skip-obs-acs and no --acceptance-criteria → rejected
echo
echo "--- (b) P1 gap, --skip-obs-acs, no --acceptance-criteria ---"
ERR_OUT=$(
    "$BIN" gap reserve --domain INFRA --priority P1 --effort xs \
        --title "test-ac-gate-b" \
        --skip-obs-acs 2>&1 || true
)
if echo "$ERR_OUT" | grep -q "require acceptance criteria"; then
    ok "(b) gate fires: refused with documented message"
else
    fail "(b) gate did not fire for P1 without acceptance criteria (got: $ERR_OUT)"
fi
CNT=$("$BIN" gap list --status open 2>/dev/null | grep -c "test-ac-gate-b" || true)
if [[ "$CNT" -eq 0 ]]; then
    ok "(b) gap was NOT reserved (gate blocked correctly)"
else
    fail "(b) gap was reserved despite gate (should have been blocked)"
fi

# (c) --no-ac-required bypasses the gate and logs an audit-trailer entry
echo
echo "--- (c) bypass via --no-ac-required ---"
"$BIN" gap reserve --domain INFRA --priority P1 --effort xs \
    --title "test-ac-gate-c" \
    --skip-obs-acs \
    --no-ac-required \
    --quiet 2>/dev/null
CNT=$("$BIN" gap list --status open 2>/dev/null | grep -c "test-ac-gate-c" || true)
if [[ "$CNT" -ge 1 ]]; then
    ok "(c) bypass via --no-ac-required succeeded — gap reserved"
else
    fail "(c) bypass via --no-ac-required did not reserve gap"
fi
if [[ -f "$AMBIENT" ]] && grep -q "ac_gate_bypassed" "$AMBIENT"; then
    ok "(c) ac_gate_bypassed audit event emitted to ambient.jsonl"
else
    fail "(c) ac_gate_bypassed event NOT found in ambient.jsonl"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
