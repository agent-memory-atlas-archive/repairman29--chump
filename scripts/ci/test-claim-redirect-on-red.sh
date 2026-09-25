#!/usr/bin/env bash
# INFRA-2428: smoke test for zero-bypass trunk-fix routing in chump claim.
#
# Tests four scenarios from the acceptance criteria:
#   1. Red state + filed_gaps → exit 3 + stderr "Routing you to the trunk-fix gap: INFRA-9999"
#   2. CHUMP_CLAIM_IGNORE_MAIN_HEALTH=1 set + red state → same redirect (bypass deleted)
#   3. Green state → exit != 3 (claim proceeds past gate)
#   4. Red state with no filed_gaps → exit 3 + stderr "(none filed yet)"
#
# Usage: bash scripts/ci/test-claim-redirect-on-red.sh
#
# Exits 0 on pass, 1 on any failure.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# Resolve binary: cargo may redirect target/ to the main repo (INFRA-481 shared target-dir).
# Prefer explicit CHUMP_BIN env, then cargo-config target-dir, then local REPO_ROOT/target.
_cargo_target_dir=""
if [[ -f "$REPO_ROOT/.cargo/config.toml" ]]; then
    _cargo_target_dir="$(grep -E '^\s*target-dir\s*=' "$REPO_ROOT/.cargo/config.toml" \
        | head -1 | sed 's/.*=\s*"\(.*\)"/\1/' | tr -d ' ')"
fi
_resolved_bin="${_cargo_target_dir:+$_cargo_target_dir/debug/chump}"

if [[ -n "${CHUMP_BIN:-}" ]] && [[ -x "$CHUMP_BIN" ]]; then
    : # use provided CHUMP_BIN
elif [[ -n "$_resolved_bin" ]] && [[ -x "$_resolved_bin" ]]; then
    CHUMP_BIN="$_resolved_bin"
elif [[ -x "$REPO_ROOT/target/debug/chump" ]]; then
    CHUMP_BIN="$REPO_ROOT/target/debug/chump"
else
    echo "[test-claim-redirect-on-red] building chump binary..."
    PATH="$HOME/.cargo/bin:$PATH" cargo build -q 2>&1
    CHUMP_BIN="${_resolved_bin:-$REPO_ROOT/target/debug/chump}"
fi
echo "[test-claim-redirect-on-red] using binary: $CHUMP_BIN"

# ── helpers ──────────────────────────────────────────────────────────────────

PASS=0
FAIL=0

ok() {
    echo "  PASS: $1"
    PASS=$((PASS + 1))
}

fail() {
    echo "  FAIL: $1"
    FAIL=$((FAIL + 1))
}

STATE_FILE="$REPO_ROOT/.chump/main-preflight-state.json"
AMBIENT_LOG="$REPO_ROOT/.chump-locks/ambient.jsonl"
BACKUP_STATE=""
NOW_SECS="$(date +%s)"

setup_state() {
    # $1 = json content
    if [[ -f "$STATE_FILE" ]]; then
        BACKUP_STATE="$(cat "$STATE_FILE")"
    fi
    printf '%s\n' "$1" > "$STATE_FILE"
}

teardown_state() {
    if [[ -n "$BACKUP_STATE" ]]; then
        printf '%s\n' "$BACKUP_STATE" > "$STATE_FILE"
        BACKUP_STATE=""
    else
        rm -f "$STATE_FILE"
    fi
}

ambient_line_count() {
    if [[ ! -f "$AMBIENT_LOG" ]]; then echo 0; return; fi
    wc -l < "$AMBIENT_LOG" | tr -d ' '
}

ambient_count_since() {
    local pattern="$1"
    local offset="${2:-0}"
    if [[ ! -f "$AMBIENT_LOG" ]]; then
        echo 0
        return
    fi
    tail -n +"$((offset + 1))" "$AMBIENT_LOG" 2>/dev/null | grep -c "$pattern" || true
}

echo ""
echo "=== INFRA-2428: test-claim-redirect-on-red ==="
echo ""

# ── Test 1: Red state + filed_gaps → exit 3 + routing message ───────────────
echo "--- Test 1: red state with filed_gaps → exit 3 + routing message ---"
RED_STATE="{\"last_tick_at\":${NOW_SECS},\"last_status\":\"red\",\"head_sha\":\"abc123\",\"failing_gates\":[\"cargo-fmt\",\"clippy\"],\"filed_gaps\":[\"INFRA-9999\"],\"fingerprint\":\"fp1\"}"
setup_state "$RED_STATE"

STDERR_OUT="$(mktemp)"
EXIT_CODE=0
AMBIENT_BEFORE="$(ambient_line_count)"
"$CHUMP_BIN" claim INFRA-NONEXISTENT-SMOKE-TEST --role fleet-test --skip-doctor --skip-import 2>"$STDERR_OUT" || EXIT_CODE=$?

if [[ "$EXIT_CODE" -eq 3 ]]; then
    ok "exit code is 3 for red state"
else
    fail "expected exit 3 for red state, got $EXIT_CODE"
fi

STDERR_CONTENT="$(cat "$STDERR_OUT")"
if echo "$STDERR_CONTENT" | grep -q "Routing you to the trunk-fix gap: INFRA-9999"; then
    ok "stderr contains routing message with trunk-fix gap ID"
else
    fail "stderr missing routing message. stderr: $STDERR_CONTENT"
fi

if echo "$STDERR_CONTENT" | grep -q "cargo-fmt"; then
    ok "stderr mentions failing gate 'cargo-fmt'"
else
    fail "stderr did not mention 'cargo-fmt'. stderr: $STDERR_CONTENT"
fi

# Verify claim_main_health_redirect was emitted
REDIRECT_EVENTS="$(ambient_count_since "claim_main_health_redirect" "$AMBIENT_BEFORE")"
if [[ "$REDIRECT_EVENTS" -ge 1 ]]; then
    ok "claim_main_health_redirect event emitted to ambient.jsonl"
else
    fail "claim_main_health_redirect event NOT emitted to ambient.jsonl"
fi

# Verify INFRA-9999 appears in the ambient event
if tail -n +"$((AMBIENT_BEFORE + 1))" "$AMBIENT_LOG" 2>/dev/null | grep -q "INFRA-9999"; then
    ok "trunk_fix_gap_id INFRA-9999 present in ambient event"
else
    fail "trunk_fix_gap_id INFRA-9999 missing from ambient event"
fi

rm -f "$STDERR_OUT"
teardown_state

# ── Test 2: CHUMP_CLAIM_IGNORE_MAIN_HEALTH=1 set → same redirect (bypass gone) ─
echo "--- Test 2: CHUMP_CLAIM_IGNORE_MAIN_HEALTH=1 with red → still exit 3 (bypass deleted) ---"
RED_STATE="{\"last_tick_at\":${NOW_SECS},\"last_status\":\"red\",\"head_sha\":\"abc123\",\"failing_gates\":[\"cargo-fmt\"],\"filed_gaps\":[\"INFRA-9999\"],\"fingerprint\":\"fp2\"}"
setup_state "$RED_STATE"

STDERR_OUT="$(mktemp)"
EXIT_CODE=0
CHUMP_CLAIM_IGNORE_MAIN_HEALTH=1 \
    "$CHUMP_BIN" claim INFRA-NONEXISTENT-SMOKE-TEST --role fleet-test --skip-doctor --skip-import 2>"$STDERR_OUT" \
    || EXIT_CODE=$?

if [[ "$EXIT_CODE" -eq 3 ]]; then
    ok "exit code is 3 even with CHUMP_CLAIM_IGNORE_MAIN_HEALTH=1 (bypass is deleted)"
else
    fail "expected exit 3 with deleted bypass env var, got $EXIT_CODE"
fi

STDERR_CONTENT="$(cat "$STDERR_OUT")"
if echo "$STDERR_CONTENT" | grep -q "Routing you to the trunk-fix gap: INFRA-9999"; then
    ok "routing message still shown with CHUMP_CLAIM_IGNORE_MAIN_HEALTH=1"
else
    fail "routing message missing with CHUMP_CLAIM_IGNORE_MAIN_HEALTH=1. stderr: $STDERR_CONTENT"
fi

rm -f "$STDERR_OUT"
teardown_state

# ── Test 3: Green state → exit != 3 ─────────────────────────────────────────
echo "--- Test 3: green state → exit != 3 ---"
GREEN_STATE="{\"last_tick_at\":${NOW_SECS},\"last_status\":\"green\",\"head_sha\":\"abc123\",\"failing_gates\":[],\"filed_gaps\":[],\"fingerprint\":\"fp3\"}"
setup_state "$GREEN_STATE"

EXIT_CODE=0
"$CHUMP_BIN" claim INFRA-NONEXISTENT-SMOKE-TEST --role fleet-test --skip-doctor --skip-import 2>/dev/null || EXIT_CODE=$?

if [[ "$EXIT_CODE" -ne 3 ]]; then
    ok "exit code is not 3 for green state (got $EXIT_CODE — claim proceeded past health gate)"
else
    fail "exit code was 3 for green state — health gate wrongly blocked"
fi

teardown_state

# ── Test 4: Red state with no filed_gaps → exit 3 + "(none filed yet)" ───────
echo "--- Test 4: red state no filed_gaps → exit 3 + (none filed yet) ---"
RED_NO_GAPS="{\"last_tick_at\":${NOW_SECS},\"last_status\":\"red\",\"head_sha\":\"abc123\",\"failing_gates\":[\"clippy\"],\"filed_gaps\":[],\"fingerprint\":\"fp4\"}"
setup_state "$RED_NO_GAPS"

STDERR_OUT="$(mktemp)"
EXIT_CODE=0
"$CHUMP_BIN" claim INFRA-NONEXISTENT-SMOKE-TEST --role fleet-test --skip-doctor --skip-import 2>"$STDERR_OUT" || EXIT_CODE=$?

if [[ "$EXIT_CODE" -eq 3 ]]; then
    ok "exit code is 3 for red state with no filed_gaps"
else
    fail "expected exit 3, got $EXIT_CODE"
fi

STDERR_CONTENT="$(cat "$STDERR_OUT")"
if echo "$STDERR_CONTENT" | grep -q "none filed yet"; then
    ok "stderr shows '(none filed yet)' when no filed_gaps"
else
    fail "stderr missing '(none filed yet)'. stderr: $STDERR_CONTENT"
fi

rm -f "$STDERR_OUT"
teardown_state

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
echo ""

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
