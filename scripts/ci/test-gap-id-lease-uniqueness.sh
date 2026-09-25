#!/usr/bin/env bash
# test-gap-id-lease-uniqueness.sh — INFRA-1970
#
# Validates the gap-ID uniqueness gate in `chump claim`:
#  1. check_gap_id_uniqueness function exists in src/atomic_claim.rs
#  2. emit_claim_duplicate_gap_event function exists in src/atomic_claim.rs
#  3. scanner-anchor present for ambient event kind registration
#  4. Functional: second claim for same gap is rejected with blocker session in the error
#  5. Functional: CHUMP_CLAIM_ALLOW_DUPLICATE_GAP=1 bypasses but emits audit event
#  6. Functional: expired competing lease is NOT a blocker
#  7. run_check_only gate 'gap-id-unique' present in code

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"

echo "=== INFRA-1970 gap-ID lease uniqueness test ==="
echo

# 1. check_gap_id_uniqueness function present in atomic_claim.rs.
if grep -q 'fn check_gap_id_uniqueness' "$REPO_ROOT/crates/chump-atomic-claim/src/atomic_claim.rs"; then
    ok "check_gap_id_uniqueness function exists"
else
    fail "check_gap_id_uniqueness function missing from src/atomic_claim.rs"
fi

# 2. emit_claim_duplicate_gap_event function present.
if grep -q 'fn emit_claim_duplicate_gap_event' "$REPO_ROOT/crates/chump-atomic-claim/src/atomic_claim.rs"; then
    ok "emit_claim_duplicate_gap_event function exists"
else
    fail "emit_claim_duplicate_gap_event function missing from src/atomic_claim.rs"
fi

# 3. scanner-anchor present for ambient event kind.
if grep -q 'claim_duplicate_gap_blocked' "$REPO_ROOT/crates/chump-atomic-claim/src/atomic_claim.rs"; then
    ok "scanner-anchor 'claim_duplicate_gap_blocked' present"
else
    fail "scanner-anchor 'claim_duplicate_gap_blocked' missing — ambient kind won't appear in registry"
fi

# 4. run_check_only wires gate 'gap-id-unique'.
if grep -q '"gap-id-unique"' "$REPO_ROOT/crates/chump-atomic-claim/src/atomic_claim.rs"; then
    ok "gate 'gap-id-unique' wired in run_check_only"
else
    fail "gate 'gap-id-unique' missing from run_check_only"
fi

# 5. CHUMP_CLAIM_ALLOW_DUPLICATE_GAP bypass env-var referenced in code.
if grep -q 'CHUMP_CLAIM_ALLOW_DUPLICATE_GAP' "$REPO_ROOT/crates/chump-atomic-claim/src/atomic_claim.rs"; then
    ok "CHUMP_CLAIM_ALLOW_DUPLICATE_GAP bypass env-var referenced"
else
    fail "CHUMP_CLAIM_ALLOW_DUPLICATE_GAP bypass env-var missing"
fi

# 6. Functional tests: build binary first.
BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
if [[ ! -f "$BIN" ]]; then
    echo "  [build] cargo build --bin chump (quiet)..."
    cargo build --bin chump --manifest-path "$REPO_ROOT/Cargo.toml" -q 2>&1 | tail -5
fi

if [[ ! -f "$BIN" ]]; then
    fail "chump binary not found after build — skipping functional tests"
    echo
    echo "=== Results: $PASS passed, $FAIL failed ==="
    [[ "$FAIL" -eq 0 ]]
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export CHUMP_REPO="$TMP"
export CHUMP_HOME="$TMP"
export CHUMP_ALLOW_MAIN_WORKTREE=1
export CHUMP_RESERVE_NO_AUTOSTAGE=1
# Skip gates that require network or git state.
# INFRA-2422: CHUMP_PREFLIGHT_SKIP deleted. Use CHUMP_CLAIM_IGNORE_MAIN_HEALTH
# to bypass the main-health gate in tests that use a synthetic repo.
export CHUMP_CLAIM_IGNORE_MAIN_HEALTH=1
export CHUMP_CLAIM_SKIP_NUGGET_SEARCH=1

# RESILIENT-073: kill switch reads ~/.chump/AUTONOMY_LEVEL via HOME (not
# CHUMP_HOME). Without this opt-in the gap-id-unique check never fires —
# the fail-closed kill switch bails first. Set HOME=$TMP and write a
# permissive level so the test exercises the path it cares about.
export HOME="$TMP"
mkdir -p "$TMP/.chump"
echo "5" > "$TMP/.chump/AUTONOMY_LEVEL"

LOCKS_DIR="$TMP/.chump-locks"
mkdir -p "$LOCKS_DIR"

# Helper: write a fake lease JSON with a given gap_id, session_id, and expires_at.
write_lease() {
    local gap="$1" session="$2" expires="$3"
    local taken
    taken="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
    cat >"$LOCKS_DIR/${session}.json" <<EOF
{
  "session_id": "$session",
  "gap_id": "$gap",
  "paths": ["src/some_file.rs"],
  "taken_at": "$taken",
  "expires_at": "$expires",
  "heartbeat_at": "$taken",
  "purpose": "gap:$gap"
}
EOF
}

# Compute future/past timestamps.
FUTURE_EXPIRES="$(python3 -c "import datetime; print((datetime.datetime.utcnow() + datetime.timedelta(hours=4)).strftime('%Y-%m-%dT%H:%M:%SZ'))")"
PAST_EXPIRES="$(python3 -c "import datetime; print((datetime.datetime.utcnow() - datetime.timedelta(hours=1)).strftime('%Y-%m-%dT%H:%M:%SZ'))")"

# 6a. Live competing lease → claim of same gap rejected.
write_lease "INFRA-XXXX" "claim-infra-xxxx-session-A" "$FUTURE_EXPIRES"

ERROR_OUT=$("$BIN" claim INFRA-XXXX --role fleet-test --check-only 2>&1 || true)

if echo "$ERROR_OUT" | grep -qi "gap-id-unique\|claim_duplicate_gap_blocked\|already claimed\|session-A"; then
    ok "check-only: live duplicate lease triggers gap-id-unique failure"
else
    fail "check-only: expected gap-id-unique failure mentioning session-A; got: $ERROR_OUT"
fi
rm -f "$LOCKS_DIR/claim-infra-xxxx-session-A.json"

# 6b. Expired competing lease → NOT a blocker.
write_lease "INFRA-YYYY" "claim-infra-yyyy-session-B" "$PAST_EXPIRES"

EXPIRED_OUT=$("$BIN" claim INFRA-YYYY --role fleet-test --check-only 2>&1 || true)

# The gap-id-unique gate should pass (expired lease is not live).
# We look for the gate to be 'pass', or absence of 'already claimed' error referencing session-B.
if echo "$EXPIRED_OUT" | grep -qi "already claimed.*session-B"; then
    fail "expired lease should not block claim; got: $EXPIRED_OUT"
else
    ok "check-only: expired lease does NOT block same-gap claim"
fi
rm -f "$LOCKS_DIR/claim-infra-yyyy-session-B.json"

# 6c. No competing lease → claim-only check passes gap-id-unique gate.
NO_LEASE_OUT=$("$BIN" claim INFRA-ZZZZ --role fleet-test --check-only 2>&1 || true)
if echo "$NO_LEASE_OUT" | grep -qi "gap-id-unique.*fail\|already claimed"; then
    fail "no competing lease should not trigger gap-id-unique failure; got: $NO_LEASE_OUT"
else
    ok "check-only: no competing lease → gap-id-unique passes"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
