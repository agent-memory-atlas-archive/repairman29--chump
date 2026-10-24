#!/usr/bin/env bash
# test-gap-triage-close.sh — RESILIENT-119 + CREDIBLE-1571
#
# Verifies `chump gap close <ID> --reason <R>` is a first-class triage-close
# path inside an isolated temp sandbox (scripts/coord/lib/test-sandbox.sh) so
# the live checkout's .chump/state.db is never touched.

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

TMP="$(mktemp -d -t test-resilient-119.XXXXXX)"
SANDBOX="$TMP/sandbox"
cleanup() {
  chump_test_sandbox_cleanup "$SANDBOX"
  rm -rf "$TMP"
}
trap cleanup EXIT

git init -q "$SANDBOX"
git -C "$SANDBOX" config user.email "test@chump.bot"
git -C "$SANDBOX" config user.name "Test"
git -C "$SANDBOX" config commit.gpgsign false
git -C "$SANDBOX" checkout -q -B main
git -C "$SANDBOX" commit -q --allow-empty -m "chore: init sandbox"

chump_test_sandbox_setup "$SANDBOX"
cd "$SANDBOX" || fail "Cannot cd to $SANDBOX"

# ── Test 1..4: one gap per valid reason ─────────────────────────────────────
for REASON in superseded wontfix obsolete duplicate; do
  TEST_GAP=$(CHUMP_RESERVE_SCAN_OPEN_PRS=0 "$CHUMP_BIN" gap reserve --domain RESILIENT --title "RESILIENT: triage-close smoke ($REASON)" --priority P3 --force 2>&1 | grep '^RESILIENT-' | tail -1)
  [ -n "$TEST_GAP" ] || fail "Cannot reserve test gap for reason=$REASON"

  status_before=$("$CHUMP_BIN" gap show "$TEST_GAP" | grep '^  status: ' | awk '{print $2}' || echo "error")
  [ "$status_before" = "open" ] || fail "Gap not open before close ($REASON): $status_before"

  "$CHUMP_BIN" gap close "$TEST_GAP" --reason "$REASON" \
    || fail "gap close --reason $REASON failed"

  status_after=$("$CHUMP_BIN" gap show "$TEST_GAP" | grep '^  status: ' | awk '{print $2}' || echo "error")
  [ "$status_after" = "$REASON" ] || fail "Status not $REASON after close: got $status_after"
  pass "gap close --reason $REASON flips status without ship-path guards ($TEST_GAP)"

  if [ -f "$SANDBOX/.chump-locks/ambient.jsonl" ]; then
    tail -50 "$SANDBOX/.chump-locks/ambient.jsonl" | grep -q "\"kind\":\"gap_triage_closed\".*\"gap_id\":\"$TEST_GAP\".*\"reason\":\"$REASON\"" \
      || fail "gap_triage_closed ambient event missing/malformed for $TEST_GAP"
    pass "gap_triage_closed ambient event emitted for $TEST_GAP"
  fi
done

# ── Test 5: invalid --reason is rejected ────────────────────────────────────
TEST_GAP=$(CHUMP_RESERVE_SCAN_OPEN_PRS=0 "$CHUMP_BIN" gap reserve --domain RESILIENT --title "RESILIENT: triage-close invalid-reason smoke" --priority P3 --force 2>&1 | grep '^RESILIENT-' | tail -1)
[ -n "$TEST_GAP" ] || fail "Cannot reserve test gap for invalid-reason case"
if "$CHUMP_BIN" gap close "$TEST_GAP" --reason bogus 2>/dev/null; then
  fail "gap close accepted an invalid --reason"
fi
status_after=$("$CHUMP_BIN" gap show "$TEST_GAP" | grep '^  status: ' | awk '{print $2}' || echo "error")
[ "$status_after" = "open" ] || fail "Gap status changed despite invalid --reason: $status_after"
pass "gap close rejects invalid --reason and leaves status unchanged"

pass "All RESILIENT-119 gap-close tests passed"
