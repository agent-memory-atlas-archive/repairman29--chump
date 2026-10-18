#!/usr/bin/env bash
# scripts/ci/test-gap-close-decomposed-integration.sh — RESILIENT-1373
#
# Integration test for auto-closing decomposed parent gaps when all child slices reach 'done'.
#
# AC:
#   1. Test creates a decomposed parent gap with child gaps that transition to `done`.
#   2. Test triggers the close-decomposed command (mimics what the timer would run).
#   3. Test asserts that the parent gap status becomes `closed`/`done` within the operation.
#   4. Test verifies behavior when close-decomposed command produces results.
#   5. Idempotence: running close-decomposed again when parent is already done is safe.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Silence binary staleness warnings (warnings, not errors)
export CHUMP_BINARY_STALENESS_CHECK=0

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

# Resolve chump binary
CHUMP_BIN="${CHUMP_BIN:-chump}"
# CREDIBLE-1522: absolutize a relative path (CI passes CHUMP_BIN=target/debug/chump)
# BEFORE the cd into the isolated store below, or it stops resolving there.
if [[ "$CHUMP_BIN" == */* && "$CHUMP_BIN" != /* ]]; then
  CHUMP_BIN="$PWD/$CHUMP_BIN"
fi
command -v "$CHUMP_BIN" >/dev/null 2>&1 || fail "Cannot find chump binary"

TMP="$(mktemp -d -t test-resilient-1373.XXXXXX)"
cleanup() {
  rm -rf "$TMP"
}
trap cleanup EXIT

# CREDIBLE-1522 (PHASE-R R3): run against an ISOLATED store, not the canonical
# checkout's. Before this, the test `cd`'d into $REPO_ROOT and created/mutated
# gaps in the real state.db — it auto-closed real decomposed parents as a side
# effect, and under the R1 single writer (CREDIBLE-1491) the child done-flips
# (`gap set --status done --closed-pr 900X`) were REFUSED because no commit
# carrying (#900X) is on origin/main (the proof-of-merge guard) — which reddened
# the INFRA-849 integration-test job on every PR (masked by continue-on-error).
# A fresh CHUMP_REPO with NO `.git` makes `verify_proof_of_merge` run in its
# documented fixture mode (fail-open for test scaffolding), so the synthetic
# done-flips are allowed, and nothing touches the canonical store.
export CHUMP_REPO="$TMP/repo"
mkdir -p "$CHUMP_REPO"
cd "$CHUMP_REPO" || fail "Cannot cd to isolated repo $CHUMP_REPO"

echo "=== RESILIENT-1373: auto-close decomposed parent gaps ==="
echo "  (isolated store: $CHUMP_REPO)"

# ─ Create decomposed parent gap ────────────────────────────────────────────────
PARENT=$(CHUMP_GAP_RESERVE_NO_EVIDENCE=1 CHUMP_GAP_RESERVE_NO_SIMILARITY=1 $CHUMP_BIN gap reserve --force --domain RESILIENT --title "RESILIENT: test decomposed parent" --priority P1 2>&1 | grep '^RESILIENT-' | tail -1)
[ -n "$PARENT" ] || fail "Cannot reserve parent gap"
pass "Created parent gap: $PARENT"

# ─ Create child slices ─────────────────────────────────────────────────────────
CHILD1=$(CHUMP_GAP_RESERVE_NO_EVIDENCE=1 CHUMP_GAP_RESERVE_NO_SIMILARITY=1 $CHUMP_BIN gap reserve --force --domain RESILIENT --title "RESILIENT: test slice one" --priority P2 2>&1 | grep '^RESILIENT-' | tail -1)
[ -n "$CHILD1" ] || fail "Cannot reserve child1 gap"
pass "Created child gap 1: $CHILD1"

CHILD2=$(CHUMP_GAP_RESERVE_NO_EVIDENCE=1 CHUMP_GAP_RESERVE_NO_SIMILARITY=1 $CHUMP_BIN gap reserve --force --domain RESILIENT --title "RESILIENT: test slice two" --priority P2 2>&1 | grep '^RESILIENT-' | tail -1)
[ -n "$CHILD2" ] || fail "Cannot reserve child2 gap"
pass "Created child gap 2: $CHILD2"

# ─ Mark parent as decomposed with children in notes ─────────────────────────────
# The notes field must contain "Decomposed into N slices: <CHILD1>, <CHILD2>, ..."
decomposed_notes="Decomposed into 2 slices: $CHILD1, $CHILD2"
CHUMP_ALLOW_STALE_DESTRUCTIVE=1 $CHUMP_BIN gap set "$PARENT" \
  --status decomposed \
  --notes "$decomposed_notes" \
  || fail "Cannot set parent to decomposed"
pass "Set parent to decomposed status with child references"

# ─ Verify parent is decomposed ─────────────────────────────────────────────────
parent_status=$($CHUMP_BIN gap show "$PARENT" | grep '^  status: ' | awk '{print $2}' || echo "error")
[ "$parent_status" = "decomposed" ] || fail "Parent not decomposed: $parent_status"
pass "Parent status verified as decomposed"

# ─ Mark child slices as done ───────────────────────────────────────────────────
# Use gap set to directly mark as done (bypass merge commit requirement for testing)
CHUMP_ALLOW_STALE_DESTRUCTIVE=1 $CHUMP_BIN gap set "$CHILD1" \
  --status done \
  --closed-pr 9001 \
  || fail "Cannot mark child1 as done"
pass "Marked child gap 1 as done"

CHUMP_ALLOW_STALE_DESTRUCTIVE=1 $CHUMP_BIN gap set "$CHILD2" \
  --status done \
  --closed-pr 9002 \
  || fail "Cannot mark child2 as done"
pass "Marked child gap 2 as done"

# ─ Verify both children are done ───────────────────────────────────────────────
child1_status=$($CHUMP_BIN gap show "$CHILD1" | grep '^  status: ' | awk '{print $2}' || echo "error")
[ "$child1_status" = "done" ] || fail "Child1 not done: $child1_status"
pass "Child1 status verified as done"

child2_status=$($CHUMP_BIN gap show "$CHILD2" | grep '^  status: ' | awk '{print $2}' || echo "error")
[ "$child2_status" = "done" ] || fail "Child2 not done: $child2_status"
pass "Child2 status verified as done"

# ─ Run close-decomposed to auto-close the parent ──────────────────────────────
close_output=$($CHUMP_BIN gap close-decomposed 2>&1 || true)
echo "  close-decomposed output: $close_output"

# Verify output indicates the parent was closed
if echo "$close_output" | grep -q "auto-closed.*$PARENT"; then
  pass "close-decomposed reported closing the parent"
else
  fail "close-decomposed did not report closing parent: $close_output"
fi

# ─ Assert parent status is now done ────────────────────────────────────────────
parent_status_after=$($CHUMP_BIN gap show "$PARENT" | grep '^  status: ' | awk '{print $2}' || echo "error")
[ "$parent_status_after" = "done" ] || fail "Parent not done after close-decomposed: $parent_status_after"
pass "Parent status verified as done after close-decomposed"

# ─ Test idempotence: run close-decomposed again ────────────────────────────────
close_output_2nd=$($CHUMP_BIN gap close-decomposed 2>&1 || true)
echo "  second run output: $close_output_2nd"

# Should report no parents ready (since the one we closed is already done)
if echo "$close_output_2nd" | grep -q "no decomposed parents ready"; then
  pass "close-decomposed is idempotent (second run reports no parents ready)"
else
  # Verify the parent is still done (state.db via `gap show`)
  parent_status_final=$($CHUMP_BIN gap show "$PARENT" | grep '^  status: ' | awk '{print $2}' || echo "error")
  [ "$parent_status_final" = "done" ] || fail "Parent status changed on idempotent run: $parent_status_final"
  pass "close-decomposed is idempotent (parent remains done on second run)"
fi

# ─ Test with partial children (only one done) ──────────────────────────────────
PARENT2=$(CHUMP_GAP_RESERVE_NO_EVIDENCE=1 CHUMP_GAP_RESERVE_NO_SIMILARITY=1 $CHUMP_BIN gap reserve --force --domain RESILIENT --title "RESILIENT: test partial decomposed" --priority P1 2>&1 | grep '^RESILIENT-' | tail -1)
[ -n "$PARENT2" ] || fail "Cannot reserve second parent gap"
pass "Created second parent gap: $PARENT2"

CHILD3=$(CHUMP_GAP_RESERVE_NO_EVIDENCE=1 CHUMP_GAP_RESERVE_NO_SIMILARITY=1 $CHUMP_BIN gap reserve --force --domain RESILIENT --title "RESILIENT: test slice three" --priority P2 2>&1 | grep '^RESILIENT-' | tail -1)
[ -n "$CHILD3" ] || fail "Cannot reserve child3 gap"
pass "Created child gap 3: $CHILD3"

CHILD4=$(CHUMP_GAP_RESERVE_NO_EVIDENCE=1 CHUMP_GAP_RESERVE_NO_SIMILARITY=1 $CHUMP_BIN gap reserve --force --domain RESILIENT --title "RESILIENT: test slice four" --priority P2 2>&1 | grep '^RESILIENT-' | tail -1)
[ -n "$CHILD4" ] || fail "Cannot reserve child4 gap"
pass "Created child gap 4: $CHILD4"

# Mark parent2 as decomposed with children
decomposed_notes2="Decomposed into 2 slices: $CHILD3, $CHILD4"
CHUMP_ALLOW_STALE_DESTRUCTIVE=1 $CHUMP_BIN gap set "$PARENT2" \
  --status decomposed \
  --notes "$decomposed_notes2" \
  || fail "Cannot set parent2 to decomposed"
pass "Set parent2 to decomposed status"

# Only mark child3 as done, leave child4 open
CHUMP_ALLOW_STALE_DESTRUCTIVE=1 $CHUMP_BIN gap set "$CHILD3" \
  --status done \
  --closed-pr 9003 \
  || fail "Cannot mark child3 as done"
pass "Marked only child3 as done (leaving child4 open)"

# Run close-decomposed again
close_output_partial=$($CHUMP_BIN gap close-decomposed 2>&1 || true)
echo "  close-decomposed output (partial children): $close_output_partial"

# Verify parent2 is still decomposed (not closed yet)
parent2_status=$($CHUMP_BIN gap show "$PARENT2" | grep '^  status: ' | awk '{print $2}' || echo "error")
[ "$parent2_status" = "decomposed" ] || fail "Parent2 should still be decomposed but is: $parent2_status"
pass "Parent2 remains decomposed when not all children are done"

pass "All RESILIENT-1373 integration tests passed"
