#!/usr/bin/env bash
# test-gap-lock-self-clean.sh — INFRA-676
#
# Validates that try_claim_gap() deletes stale .gap-*.lock files whose first
# token matches THIS session before creating a new lock (within flock).

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/scripts/dispatch/_pick_and_claim_gap.py"

echo "=== INFRA-676 gap-lock self-clean test ==="
echo

# --- 1. Code-level checks ---

if grep -q "INFRA-676" "$SCRIPT"; then
    ok "INFRA-676 sweep comment present in _pick_and_claim_gap.py"
else
    fail "INFRA-676 sweep comment missing from _pick_and_claim_gap.py"
fi

if grep -q -- '--lease-only' "$SCRIPT"; then
    ok "_pick_and_claim_gap.py delegates try_claim_gap to chump claim --lease-only (INFRA-8580)"
else
    fail "_pick_and_claim_gap.py missing --lease-only delegation (INFRA-8580)"
fi

# --- 2. Functional test via temp directory ---

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

SESSION_A="test-session-alpha-$$"
SESSION_B="test-session-beta-$$"
NOW="$(date +%s)"

# Write 3 stale gap locks attributed to SESSION_A
for gap in INFRA-001 INFRA-002 INFRA-003; do
    echo "${SESSION_A} ${NOW}" > "$TMPDIR_TEST/.gap-${gap}.lock"
done

# Write 1 gap lock attributed to SESSION_B (should NOT be removed)
echo "${SESSION_B} ${NOW}" > "$TMPDIR_TEST/.gap-INFRA-004.lock"

# Touch the .claim-lock sentinel so flock works
touch "$TMPDIR_TEST/.claim-lock"

# Run the picker for SESSION_A claiming a *different* gap (INFRA-099) against
# an empty gap JSON to get past JSON parsing cleanly, then verify stale locks gone.
# We exercise try_claim_gap directly via a small inline test driver.
python3 - <<PYEOF
import sys, os, json, tempfile, fcntl, time
sys.path.insert(0, "$REPO_ROOT/scripts/dispatch")

os.environ["CHUMP_LOCK_DIR"] = "$TMPDIR_TEST"
os.environ["CHUMP_SESSION_ID"] = "$SESSION_A"

from _pick_and_claim_gap import try_claim_gap, get_lock_dir
from pathlib import Path

lock_dir = Path("$TMPDIR_TEST")
result = try_claim_gap("INFRA-099", "$SESSION_A", lock_dir)
# result may be True or False — we only care about side-effects
sys.exit(0)
PYEOF

# Check SESSION_A locks are gone
STALE_REMAINING=0
for gap in INFRA-001 INFRA-002 INFRA-003; do
    if [[ -f "$TMPDIR_TEST/.gap-${gap}.lock" ]]; then
        STALE_REMAINING=$((STALE_REMAINING+1))
    fi
done

if [[ "$STALE_REMAINING" -eq 0 ]]; then
    ok "all 3 stale locks for $SESSION_A removed"
else
    fail "$STALE_REMAINING stale lock(s) for $SESSION_A remain after claim"
fi

# Check SESSION_B lock is untouched
if [[ -f "$TMPDIR_TEST/.gap-INFRA-004.lock" ]]; then
    ok "SESSION_B lock left intact"
else
    fail "SESSION_B lock was incorrectly removed"
fi

# --- 3. Companion reaper script present ---

REAPER="$REPO_ROOT/scripts/ops/stale-gap-lock-reaper.sh"
if [[ -x "$REAPER" ]]; then
    ok "stale-gap-lock-reaper.sh exists and is executable"
else
    fail "stale-gap-lock-reaper.sh missing or not executable at $REAPER"
fi

# --- Summary ---
echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
