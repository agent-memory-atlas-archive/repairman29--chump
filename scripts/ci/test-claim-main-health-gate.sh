#!/usr/bin/env bash
# INFRA-2398: smoke test for chump claim main-health-gate.
#
# Tests four scenarios from the acceptance criteria:
#   1. Red state  → exit 3 + stderr mentions failing gates + routing message
#   2. Green state → exit != 3
#   3. Stale state (>30 min) → stderr warning + exit != 3
#   4. CHUMP_CLAIM_IGNORE_MAIN_HEALTH=1 with red → exit 3 (bypass deleted, INFRA-2428)
#
# Usage: bash scripts/ci/test-claim-main-health-gate.sh
#
# Exits 0 on pass, 1 on any failure.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# Build the binary first (skip if already built to save time in tight loops).
CHUMP_BIN="${CHUMP_BIN:-$REPO_ROOT/target/debug/chump}"
if [[ ! -x "$CHUMP_BIN" ]]; then
    echo "[test-claim-main-health-gate] building chump binary..."
    PATH="$HOME/.cargo/bin:$PATH" cargo build -q 2>&1
    CHUMP_BIN="$REPO_ROOT/target/debug/chump"
fi

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

# Write a mock state file to a temp dir and set CHUMP_REPO_ROOT-equivalent via env.
# We rely on chump resolving the state path as <repo_root>/.chump/main-preflight-state.json.
# We use CHUMP_REPO_ROOT_OVERRIDE if the binary supports it, otherwise we work in a
# temp dir that mirrors the .chump/ layout and set the env.
#
# Since atomic_claim::check_main_health_gate uses args.repo_root (passed from ClaimArgs
# which comes from repo_path::repo_root()), the easiest approach is to write directly
# into .chump/ under the real repo root and restore afterward.
STATE_FILE="$REPO_ROOT/.chump/main-preflight-state.json"
AMBIENT_LOG="$REPO_ROOT/.chump-locks/ambient.jsonl"
BACKUP_STATE=""
NOW_SECS="$(date +%s)"

setup_state() {
    # $1 = json content
    if [[ -f "$STATE_FILE" ]]; then
        BACKUP_STATE="$(cat "$STATE_FILE")"
    fi
    echo "$1" > "$STATE_FILE"
}

teardown_state() {
    if [[ -n "$BACKUP_STATE" ]]; then
        echo "$BACKUP_STATE" > "$STATE_FILE"
        BACKUP_STATE=""
    else
        rm -f "$STATE_FILE"
    fi
}

# Count lines matching a pattern in ambient.jsonl since a given offset.
ambient_count_since() {
    local pattern="$1"
    local offset="${2:-0}"
    if [[ ! -f "$AMBIENT_LOG" ]]; then
        echo 0
        return
    fi
    tail -n +"$((offset + 1))" "$AMBIENT_LOG" 2>/dev/null | grep -c "$pattern" || true
}

ambient_line_count() {
    if [[ ! -f "$AMBIENT_LOG" ]]; then echo 0; return; fi
    wc -l < "$AMBIENT_LOG" | tr -d ' '
}

echo ""
echo "=== INFRA-2398: test-claim-main-health-gate ==="
echo ""

# ── Test 1: Red state → exit 3 + stderr mentions failing gates ─────────────
echo "--- Test 1: red state → exit 3 ---"
RED_STATE="{\"last_tick_at\":${NOW_SECS},\"last_status\":\"red\",\"head_sha\":\"abc123\",\"failing_gates\":[\"cargo-fmt\",\"clippy\"],\"fingerprint\":\"fp1\"}"
setup_state "$RED_STATE"

STDERR_OUT="$(mktemp)"
EXIT_CODE=0
# Use a non-existent gap so claim fails at gap-lookup, not at our gate.
# But the main-health-gate runs BEFORE gap verification, so exit 3 fires first.
"$CHUMP_BIN" claim INFRA-NONEXISTENT-SMOKE-TEST --role fleet-test --skip-doctor --skip-import 2>"$STDERR_OUT" || EXIT_CODE=$?

if [[ "$EXIT_CODE" -eq 3 ]]; then
    ok "exit code is 3 for red state"
else
    fail "expected exit 3 for red state, got $EXIT_CODE"
fi

STDERR_CONTENT="$(cat "$STDERR_OUT")"
if echo "$STDERR_CONTENT" | grep -q "cargo-fmt"; then
    ok "stderr mentions failing gate 'cargo-fmt'"
else
    fail "stderr did not mention 'cargo-fmt'. stderr: $STDERR_CONTENT"
fi

if echo "$STDERR_CONTENT" | grep -q "clippy"; then
    ok "stderr mentions failing gate 'clippy'"
else
    fail "stderr did not mention 'clippy'. stderr: $STDERR_CONTENT"
fi

if echo "$STDERR_CONTENT" | grep -qi "Routing you to the trunk-fix gap"; then
    ok "stderr contains routing-to-trunk-fix message"
else
    fail "stderr did not contain routing message. stderr: $STDERR_CONTENT"
fi

rm -f "$STDERR_OUT"
teardown_state

# ── Test 2: Green state → exit != 3 ─────────────────────────────────────────
echo "--- Test 2: green state → exit != 3 ---"
GREEN_STATE="{\"last_tick_at\":${NOW_SECS},\"last_status\":\"green\",\"head_sha\":\"abc123\",\"failing_gates\":[],\"fingerprint\":\"fp2\"}"
setup_state "$GREEN_STATE"

EXIT_CODE=0
"$CHUMP_BIN" claim INFRA-NONEXISTENT-SMOKE-TEST --role fleet-test --skip-doctor --skip-import 2>/dev/null || EXIT_CODE=$?

# Exit 3 means health-gate blocked; any other exit is OK (gap not found = 1).
if [[ "$EXIT_CODE" -ne 3 ]]; then
    ok "exit code is not 3 for green state (got $EXIT_CODE — claim proceeded past health gate)"
else
    fail "exit code was 3 for green state — health gate wrongly blocked"
fi

teardown_state

# ── Test 3: Stale state (>30 min) → stderr warning + exit != 3 ───────────────
echo "--- Test 3: stale state → warning + exit != 3 ---"
STALE_TICK=$((NOW_SECS - 2000))  # 33+ minutes ago
STALE_STATE="{\"last_tick_at\":${STALE_TICK},\"last_status\":\"red\",\"head_sha\":\"abc123\",\"failing_gates\":[\"clippy\"],\"fingerprint\":\"fp3\"}"
setup_state "$STALE_STATE"

STDERR_OUT="$(mktemp)"
EXIT_CODE=0
AMBIENT_BEFORE="$(ambient_line_count)"
"$CHUMP_BIN" claim INFRA-NONEXISTENT-SMOKE-TEST --role fleet-test --skip-doctor --skip-import 2>"$STDERR_OUT" || EXIT_CODE=$?

STDERR_CONTENT="$(cat "$STDERR_OUT")"

# Stale state should NOT block (exit != 3), even if status is red.
if [[ "$EXIT_CODE" -ne 3 ]]; then
    ok "exit code is not 3 for stale state (got $EXIT_CODE — stale watchdog does not block)"
else
    fail "exit code was 3 for stale state — stale watchdog should not block claim"
fi

if echo "$STDERR_CONTENT" | grep -qi "stale"; then
    ok "stderr mentions 'stale' for stale state"
else
    fail "stderr did not mention 'stale' for stale state. stderr: $STDERR_CONTENT"
fi

# Check that claim_main_health_stale was emitted.
STALE_EVENTS="$(ambient_count_since "claim_main_health_stale" "$AMBIENT_BEFORE")"
if [[ "$STALE_EVENTS" -ge 1 ]]; then
    ok "claim_main_health_stale event emitted to ambient.jsonl"
else
    fail "claim_main_health_stale event NOT emitted to ambient.jsonl"
fi

rm -f "$STDERR_OUT"
teardown_state

# ── Test 4: CHUMP_CLAIM_IGNORE_MAIN_HEALTH=1 with red → exit 3 (bypass deleted, INFRA-2428)
echo "--- Test 4: CHUMP_CLAIM_IGNORE_MAIN_HEALTH=1 with red → still exit 3 (bypass deleted) ---"
RED_STATE="{\"last_tick_at\":${NOW_SECS},\"last_status\":\"red\",\"head_sha\":\"abc123\",\"failing_gates\":[\"cargo-fmt\"],\"filed_gaps\":[\"INFRA-9999\"],\"fingerprint\":\"fp4\"}"
setup_state "$RED_STATE"

AMBIENT_BEFORE="$(ambient_line_count)"
EXIT_CODE=0
CHUMP_CLAIM_IGNORE_MAIN_HEALTH=1 \
    "$CHUMP_BIN" claim INFRA-NONEXISTENT-SMOKE-TEST --role fleet-test --skip-doctor --skip-import 2>/dev/null \
    || EXIT_CODE=$?

# INFRA-2428: bypass env var deleted — setting it has no effect, gate still blocks.
if [[ "$EXIT_CODE" -eq 3 ]]; then
    ok "exit code is 3 with CHUMP_CLAIM_IGNORE_MAIN_HEALTH=1 (bypass deleted, gate enforced)"
else
    fail "expected exit 3 even with deleted bypass env var, got $EXIT_CODE"
fi

# Check that claim_main_health_redirect was emitted (replaces bypass kind).
REDIRECT_EVENTS="$(ambient_count_since "claim_main_health_redirect" "$AMBIENT_BEFORE")"
if [[ "$REDIRECT_EVENTS" -ge 1 ]]; then
    ok "claim_main_health_redirect event emitted to ambient.jsonl"
else
    fail "claim_main_health_redirect event NOT emitted to ambient.jsonl"
fi

teardown_state

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
echo ""

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
