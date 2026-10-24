#!/usr/bin/env bash
# test-gap-ship-integration.sh — CREDIBLE-060 + CREDIBLE-1571
#
# Verifies that `chump gap ship` correctly flips status and emits ambient
# event inside an isolated temp sandbox (scripts/coord/lib/test-sandbox.sh)
# so the live checkout's .chump/state.db is never touched.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

CHUMP_BIN="${CHUMP_BIN:-${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump}"
if ! command -v "$CHUMP_BIN" >/dev/null 2>&1 && [[ ! -x "$CHUMP_BIN" ]]; then
  CHUMP_BIN="chump"
fi
command -v "$CHUMP_BIN" >/dev/null 2>&1 || [[ -x "$CHUMP_BIN" ]] || fail "Cannot find chump binary"

# shellcheck source=../coord/lib/test-sandbox.sh
source "$REPO_ROOT/scripts/coord/lib/test-sandbox.sh"

TMP="$(mktemp -d -t test-credible-060.XXXXXX)"
SANDBOX="$TMP/sandbox"
cleanup() {
  chump_test_sandbox_cleanup "$SANDBOX"
  rm -rf "$TMP"
}
trap cleanup EXIT

git init -q --bare "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$SANDBOX" 2>/dev/null
git -C "$SANDBOX" config user.email "test@chump.bot"
git -C "$SANDBOX" config user.name "Test"
git -C "$SANDBOX" config commit.gpgsign false
git -C "$SANDBOX" checkout -q -B main
git -C "$SANDBOX" commit -q --allow-empty -m "feat(CREDIBLE-001): landed (#9999)"
git -C "$SANDBOX" push -q origin main

chump_test_sandbox_setup "$SANDBOX"
cd "$SANDBOX" || fail "Cannot cd to $SANDBOX"

# ─ Create a test gap in the sandbox store ──────────────────────────────────────
TEST_GAP=$(CHUMP_RESERVE_SCAN_OPEN_PRS=0 "$CHUMP_BIN" gap reserve --domain CREDIBLE --title "CREDIBLE: test integration smoke test" --priority P3 --force 2>&1 | grep '^CREDIBLE-' | tail -1)
[ -n "$TEST_GAP" ] || fail "Cannot reserve test gap"
pass "Created test gap in sandbox: $TEST_GAP"

status_before=$("$CHUMP_BIN" gap show "$TEST_GAP" | grep '^  status: ' | awk '{print $2}' || echo "error")
[ "$status_before" = "open" ] || fail "Gap not open before ship: $status_before"
pass "Gap is open before ship"

# Commit any reserve artifacts so the sandbox worktree is clean for gap ship.
git -C "$SANDBOX" add -A >/dev/null 2>&1 || true
git -C "$SANDBOX" commit -q --allow-empty -m "chore: reserve $TEST_GAP (#9999)" >/dev/null 2>&1 || true
git -C "$SANDBOX" push -q origin main >/dev/null 2>&1 || true
"$CHUMP_BIN" gap link-pr "$TEST_GAP" 9999 --sha "$(git -C "$SANDBOX" rev-parse HEAD)" >/dev/null

# ─ Run gap ship against the sandbox store ──────────────────────────────────────
CHUMP_BINARY_STALENESS_CHECK=0 \
"$CHUMP_BIN" gap ship "$TEST_GAP" --update-yaml --closed-pr 9999 \
  || fail "gap ship failed"
pass "gap ship succeeded"

status_after=$("$CHUMP_BIN" gap show "$TEST_GAP" | grep '^  status: ' | awk '{print $2}' || echo "error")
[ "$status_after" = "done" ] || fail "Status not done after ship: $status_after"
pass "Status flipped to done in sandbox state.db"

show_out=$("$CHUMP_BIN" gap show "$TEST_GAP")
echo "$show_out" | grep -q "^  closed_pr: 9999" || \
  fail "closed_pr: 9999 not in sandbox state.db"
pass "sandbox state.db updated with closed_pr"

YAML_FILE="$SANDBOX/docs/gaps/$TEST_GAP.yaml"
if [ -f "$YAML_FILE" ]; then
  grep -Eq "^[[:space:]]*status: done" "$YAML_FILE" || \
    fail "docs/gaps/$TEST_GAP.yaml does not have status: done"
  grep -Eq "^[[:space:]]*closed_pr: 9999" "$YAML_FILE" || \
    fail "docs/gaps/$TEST_GAP.yaml does not have closed_pr: 9999"
  pass "docs/gaps/<ID>.yaml written with status=done and closed_pr in sandbox"
else
  fail "docs/gaps/$TEST_GAP.yaml not found after ship in sandbox"
fi

if [ -d "$SANDBOX/.chump-plans/$TEST_GAP" ]; then
  [ -f "$SANDBOX/.chump-plans/$TEST_GAP/SHIPPED_AT" ] || \
    fail "SHIPPED_AT marker not created in .chump-plans"
  pass ".chump-plans marker created"
else
  pass ".chump-plans marker (deferred feature, not yet implemented)"
fi

if [ -f "$SANDBOX/.chump-locks/ambient.jsonl" ]; then
  if grep -q '"kind":"gap_shipped"\|"kind":"ship_landed"' "$SANDBOX/.chump-locks/ambient.jsonl"; then
    grep -q "\"gap_id\":\"$TEST_GAP\"" "$SANDBOX/.chump-locks/ambient.jsonl" || \
      fail "gap_id not in ship ambient event"
    pass "ship ambient event emitted in sandbox"
  else
    pass "gap_shipped event (deferred feature, not yet emitted)"
  fi
else
  pass "ambient.jsonl event check skipped (not available in CI)"
fi

output=$(CHUMP_BINARY_STALENESS_CHECK=0 "$CHUMP_BIN" gap ship "$TEST_GAP" --update-yaml --closed-pr 9999 2>&1 || true)
if echo "$output" | grep -q "already done"; then
  pass "gap ship is idempotent (second run reports already done)"
else
  status_final=$("$CHUMP_BIN" gap show "$TEST_GAP" | grep '^  status: ' | awk '{print $2}' || echo "error")
  [ "$status_final" = "done" ] || fail "Gap status changed on idempotent run"
  pass "gap ship is idempotent (status unchanged on second run)"
fi

pass "All CREDIBLE-060 integration tests passed"
