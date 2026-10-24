#!/usr/bin/env bash
# scripts/ci/test-worker-prelude-floor-signals.sh — INFRA-2008 + INFRA-2029
#
# Validates that worker.sh prelude reads floor signals before claiming and
# emits worker_stuck on exit-without-ship paths. Tests run in an isolated
# tmp directory with stubbed fleet-hold-check.sh and chump binaries.
#
# Tests:
#   1. worker_floor_signal_read(fleet_hold) emitted each cycle — no-hold path
#   2. worker_floor_signal_read(fleet_hold) emitted each cycle — hold active path
#   3. Worker sleeps+continues (doesn't claim) when fleet-hold active
#   4. worker_floor_signal_read(floor_temp) emitted — COLD path
#   5. worker_floor_signal_read(floor_temp) emitted — HOT path
#   6. HOT path narrows effort filter to xs (picker sees FLEET_EFFORT_FILTER=xs)
#   7. worker_stuck emitted on preflight_fail path
#   8. worker_stuck emitted on stand_down path
#   9. worker_stuck emitted on worktree_create_fail path
#  10. event kinds registered in event-registry-reserved.txt
#
# W-013 immunization: unset workflow-injected env so fixtures aren't hijacked.

set -uo pipefail
# CREDIBLE-1527: ensure temp-repo git commits succeed on runners without global git identity.
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-chump-ci-test}" GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-ci-test@chump.local}" GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-chump-ci-test}" GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-ci-test@chump.local}"


PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-2008+2029 worker prelude floor-signal tests ==="
echo

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"

# Verify worker.sh exists
[[ -f "$WORKER" ]] || { echo "FATAL: missing $WORKER"; exit 2; }

# W-013 immunization
unset CHUMP_REPO CHUMP_LOCK_DIR CHUMP_FLEET_HOLD_FILE CHUMP_AMBIENT_LOG 2>/dev/null || true

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── Source-contract checks (static, no subprocess) ───────────────────────────

# Test 10 first (fast): event kinds registered
REGISTRY="$REPO_ROOT/scripts/ci/event-registry-reserved.txt"
if grep -q "worker_floor_signal_read" "$REGISTRY" 2>/dev/null; then
    ok "event-registry: worker_floor_signal_read registered"
else
    fail "event-registry: worker_floor_signal_read NOT registered in $REGISTRY"
fi
if grep -q "worker_stuck" "$REGISTRY" 2>/dev/null; then
    ok "event-registry: worker_stuck registered"
else
    fail "event-registry: worker_stuck NOT registered in $REGISTRY"
fi

# Static grep: floor-signal prelude block present
if grep -q "INFRA-2008.*pre-claim floor-signal\|fleet-hold-check\|fleet_hold_check" "$WORKER" 2>/dev/null; then
    ok "worker.sh: fleet-hold prelude block present"
else
    fail "worker.sh: missing fleet-hold prelude block (look for INFRA-2008)"
fi

if grep -q "chump health --temp\|floor_temp\|_floor_temp" "$WORKER" 2>/dev/null; then
    ok "worker.sh: floor-temp prelude block present"
else
    fail "worker.sh: missing floor-temp prelude block"
fi

if grep -q "_emit_worker_stuck" "$WORKER" 2>/dev/null; then
    _stuck_count=$(grep -c "_emit_worker_stuck" "$WORKER" 2>/dev/null || true)
    ok "worker.sh: _emit_worker_stuck present ($_stuck_count call sites)"
else
    fail "worker.sh: missing _emit_worker_stuck call sites"
fi

# Verify it's called in ALL three required paths.
# Use grep -A6 — the release-lock line sits between the log and the emit call.
if grep -A6 "failed pre-pick preflight" "$WORKER" 2>/dev/null | grep -q "_emit_worker_stuck"; then
    ok "worker.sh: worker_stuck on preflight_fail"
else
    fail "worker.sh: worker_stuck NOT called on preflight_fail path"
fi

if grep -A6 "worktree create failed" "$WORKER" 2>/dev/null | grep -q "_emit_worker_stuck"; then
    ok "worker.sh: worker_stuck on worktree_create_fail"
else
    fail "worker.sh: worker_stuck NOT called on worktree_create_fail path"
fi

# stand_down: _emit_worker_stuck is right after the log line (no gap-lock release)
if grep -A2 "INFRA-613.*worker_stand_down" "$WORKER" 2>/dev/null | grep -q "_emit_worker_stuck"; then
    ok "worker.sh: worker_stuck on stand_down"
else
    fail "worker.sh: worker_stuck NOT called on stand_down exit"
fi

# ── Functional tests: run worker in isolated tmp env ─────────────────────
# Strategy: run worker with CHUMP_STAND_DOWN_THRESHOLD=1 CHUMP_STARVE_THRESHOLD=1
# so it exits after exactly one empty-pick cycle. Stub chump + fleet-hold-check.sh.
# All tests use timeout 8s as a safety net against any infinite loops.

FAKE="$TMP/repo"
mkdir -p "$FAKE/.chump-locks/cooldown" "$FAKE/scripts/coord" \
         "$FAKE/scripts/dispatch" "$FAKE/scripts/dev" "$FAKE/logs"

# Minimal git repo so git commands don't crash
git init -q "$FAKE" 2>/dev/null || true
git -C "$FAKE" commit --allow-empty -m "init" --no-gpg-sign -q 2>/dev/null || true

# fleet-hold-check.sh stub: reads CHUMP_FLEET_HOLD_FILE directly (real contract)
# When the hold file exists: exits 2. When absent: exits 0.
cat > "$FAKE/scripts/coord/fleet-hold-check.sh" <<'HOLD_CHECK'
#!/usr/bin/env bash
HOLD_FILE="${CHUMP_FLEET_HOLD_FILE:-/nonexistent}"
[[ -f "$HOLD_FILE" ]] && exit 2
exit 0
HOLD_CHECK
chmod +x "$FAKE/scripts/coord/fleet-hold-check.sh"

# chump stub: records health --temp rc from CHUMP_MOCK_TEMP_RC env
mkdir -p "$TMP/bin"
cat > "$TMP/bin/chump" <<'CMOCK'
#!/usr/bin/env bash
case "$1 $2" in
    "gap list")      echo '[]' ;;
    "gap preflight") [[ "${CHUMP_MOCK_PREFLIGHT_FAIL:-0}" == "1" ]] && exit 1; exit 0 ;;
    "gap show")      echo "id: ${3:-GAP-TEST}"; echo "status: open"; echo "priority: P1"; echo "effort: s" ;;
    "health --temp") exit "${CHUMP_MOCK_TEMP_RC:-0}" ;;
    "session-track"*) exit 0 ;;
    *) exit 0 ;;
esac
CMOCK
chmod +x "$TMP/bin/chump"

# chump-binary-unwedge.sh stub (called at worker startup)
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE/scripts/dev/chump-binary-unwedge.sh"
chmod +x "$FAKE/scripts/dev/chump-binary-unwedge.sh"

# Default picker stub: returns empty (no gap to pick) → worker hits stand-down
printf 'import sys\nprint("", end="")\n' > "$FAKE/scripts/dispatch/_pick_and_claim_gap.py"

AMB="$TMP/ambient.jsonl"

# Common env for all worker runs (fast exit: stand-down after 1 empty cycle)
_WORKER_ENV=(
    PATH="$TMP/bin:$PATH"
    REPO_ROOT="$FAKE"
    CHUMP_AMBIENT_LOG="$AMB"
    AGENT_ID="T1"
    FLEET_LOG_DIR="$TMP/logs"
    FLEET_BACKEND="claude"
    IDLE_SLEEP_S="0"
    CHUMP_STAND_DOWN_THRESHOLD="1"
    CHUMP_STARVE_THRESHOLD="1"
    CHUMP_FIRST_OUTPUT_WATCHDOG="0"
    CHUMP_PR_REPAIR="0"
    CHUMP_SKIP_PRESHIP_CLIPPY="1"
    CHUMP_HANDOFF_REENGAGE="0"
    CHUMP_TIMEOUT_RESCUE="0"
    CHUMP_CIRCUIT_BREAKER="0"
)

# ── Test 1: no-hold path emits worker_floor_signal_read(fleet_hold,hold=0) ──
echo ""
echo "--- Test 1: no-hold → worker_floor_signal_read fleet_hold=0 ---"
rm -f "$AMB" "$FAKE/.chump-locks/fleet-hold.txt"; touch "$AMB"
env "${_WORKER_ENV[@]}" \
    CHUMP_FLEET_HOLD_FILE="$FAKE/.chump-locks/fleet-hold.txt" \
    CHUMP_MOCK_TEMP_RC="0" \
    timeout 8s bash "$WORKER" 2>/dev/null || true

if grep -q '"kind":"worker_floor_signal_read"' "$AMB" 2>/dev/null; then
    ok "Test 1: worker_floor_signal_read emitted (no-hold path)"
else
    fail "Test 1: worker_floor_signal_read NOT emitted (no-hold path)"
fi
if grep '"kind":"worker_floor_signal_read"' "$AMB" 2>/dev/null | grep -q '"signal":"fleet_hold"'; then
    ok "Test 1: fleet_hold signal present"
else
    fail "Test 1: fleet_hold signal missing from worker_floor_signal_read event"
fi
if grep '"kind":"worker_floor_signal_read"' "$AMB" 2>/dev/null | grep '"signal":"fleet_hold"' | grep -q '"hold":0'; then
    ok "Test 1: hold=0 in no-hold event"
else
    fail "Test 1: hold field wrong in no-hold event"
fi

# ── Test 2+3: hold active → hold=1, no gap claimed ───────────────────────
echo ""
echo "--- Test 2+3: hold active → hold=1 emitted, no gap claimed ---"
rm -f "$AMB"; touch "$AMB"
echo '{"active":true,"cluster_id":"TEST","reason":"test cluster"}' \
    > "$FAKE/.chump-locks/fleet-hold.txt"
env "${_WORKER_ENV[@]}" \
    CHUMP_FLEET_HOLD_FILE="$FAKE/.chump-locks/fleet-hold.txt" \
    CHUMP_MOCK_TEMP_RC="0" \
    IDLE_SLEEP_S="0" \
    timeout 3s bash "$WORKER" 2>/dev/null || true
rm -f "$FAKE/.chump-locks/fleet-hold.txt"

if grep '"kind":"worker_floor_signal_read"' "$AMB" 2>/dev/null | grep '"signal":"fleet_hold"' | grep -q '"hold":1'; then
    ok "Test 2: hold=1 emitted when fleet-hold file present"
else
    fail "Test 2: hold=1 NOT emitted when fleet-hold active"
fi
if ! grep -q '"kind":"model_selected"' "$AMB" 2>/dev/null; then
    ok "Test 3: no gap claimed when hold active"
else
    fail "Test 3: worker claimed gap despite fleet-hold"
fi

# ── Test 4: COLD temp → temp=COLD in event ───────────────────────────────
echo ""
echo "--- Test 4: COLD floor-temp ---"
rm -f "$AMB" "$FAKE/.chump-locks/fleet-hold.txt"; touch "$AMB"
env "${_WORKER_ENV[@]}" \
    CHUMP_FLEET_HOLD_FILE="$FAKE/.chump-locks/fleet-hold.txt" \
    CHUMP_MOCK_TEMP_RC="0" \
    timeout 8s bash "$WORKER" 2>/dev/null || true

if grep '"kind":"worker_floor_signal_read"' "$AMB" 2>/dev/null | grep -q '"signal":"floor_temp"'; then
    ok "Test 4: floor_temp signal present"
else
    fail "Test 4: floor_temp signal missing from worker_floor_signal_read event"
fi
if grep '"kind":"worker_floor_signal_read"' "$AMB" 2>/dev/null | grep '"signal":"floor_temp"' | grep -q '"temp":"COLD"'; then
    ok "Test 4: temp=COLD when chump health exits 0"
else
    fail "Test 4: temp field wrong for COLD path"
fi

# ── Test 5+6: HOT temp → temp=HOT, effort filter narrowed to xs ──────────
echo ""
echo "--- Test 5+6: HOT floor-temp → temp=HOT, effort=xs for picker ---"
rm -f "$AMB" "$FAKE/.chump-locks/fleet-hold.txt"; touch "$AMB"
PICKER_ENV_LOG="$TMP/picker-env.log"; rm -f "$PICKER_ENV_LOG"
# Picker stub that logs the effort filter it sees
cat > "$FAKE/scripts/dispatch/_pick_and_claim_gap.py" <<PYPICK
import os
log = os.environ.get("PICKER_ENV_LOG", "/tmp/picker-env.log")
effort = os.environ.get("FLEET_EFFORT_FILTER", "unset")
with open(log, "a") as f:
    f.write(f"FLEET_EFFORT_FILTER={effort}\n")
print("", end="")
PYPICK

env "${_WORKER_ENV[@]}" \
    CHUMP_FLEET_HOLD_FILE="$FAKE/.chump-locks/fleet-hold.txt" \
    CHUMP_MOCK_TEMP_RC="2" \
    FLEET_EFFORT_FILTER="xs,s,m" \
    PICKER_ENV_LOG="$PICKER_ENV_LOG" \
    timeout 8s bash "$WORKER" 2>/dev/null || true

# Restore default picker
printf 'import sys\nprint("", end="")\n' > "$FAKE/scripts/dispatch/_pick_and_claim_gap.py"

if grep '"kind":"worker_floor_signal_read"' "$AMB" 2>/dev/null | grep '"signal":"floor_temp"' | grep -q '"temp":"HOT"'; then
    ok "Test 5: temp=HOT when chump health exits 2"
else
    fail "Test 5: temp field wrong for HOT path"
fi
if grep -q "FLEET_EFFORT_FILTER=xs$" "$PICKER_ENV_LOG" 2>/dev/null; then
    ok "Test 6: HOT path narrows FLEET_EFFORT_FILTER to xs for picker"
else
    _got=$(cat "$PICKER_ENV_LOG" 2>/dev/null | head -1)
    fail "Test 6: HOT path did NOT narrow to xs (got: $_got)"
fi

# ── Test 7: worker_stuck on preflight_fail ────────────────────────────────
echo ""
echo "--- Test 7: worker_stuck on preflight_fail ---"
rm -f "$AMB" "$FAKE/.chump-locks/fleet-hold.txt"; touch "$AMB"
# Picker returns a gap so preflight runs
printf 'print("INFRA-9999")\n' > "$FAKE/scripts/dispatch/_pick_and_claim_gap.py"
env "${_WORKER_ENV[@]}" \
    CHUMP_FLEET_HOLD_FILE="$FAKE/.chump-locks/fleet-hold.txt" \
    CHUMP_MOCK_TEMP_RC="0" \
    CHUMP_MOCK_PREFLIGHT_FAIL="1" \
    CHUMP_STAND_DOWN_THRESHOLD="2" \
    CHUMP_STARVE_THRESHOLD="3" \
    timeout 8s bash "$WORKER" 2>/dev/null || true
# Restore empty picker
printf 'import sys\nprint("", end="")\n' > "$FAKE/scripts/dispatch/_pick_and_claim_gap.py"

if grep -q '"kind":"worker_stuck"' "$AMB" 2>/dev/null; then
    ok "Test 7: worker_stuck emitted on preflight_fail"
else
    fail "Test 7: worker_stuck NOT emitted on preflight_fail path"
fi
if grep '"kind":"worker_stuck"' "$AMB" 2>/dev/null | grep -q '"reason":"preflight_fail'; then
    ok "Test 7: worker_stuck reason=preflight_fail"
else
    fail "Test 7: worker_stuck reason field wrong (expected preflight_fail)"
fi

# ── Test 8: worker_stuck on stand_down ───────────────────────────────────
echo ""
echo "--- Test 8: worker_stuck on stand_down ---"
rm -f "$AMB" "$FAKE/.chump-locks/fleet-hold.txt"; touch "$AMB"
env "${_WORKER_ENV[@]}" \
    CHUMP_FLEET_HOLD_FILE="$FAKE/.chump-locks/fleet-hold.txt" \
    CHUMP_MOCK_TEMP_RC="0" \
    timeout 8s bash "$WORKER" 2>/dev/null || true

if grep -q '"kind":"worker_stuck"' "$AMB" 2>/dev/null; then
    ok "Test 8: worker_stuck emitted on stand_down"
else
    fail "Test 8: worker_stuck NOT emitted on stand_down exit"
fi
if grep '"kind":"worker_stuck"' "$AMB" 2>/dev/null | grep -q '"reason":"stand_down'; then
    ok "Test 8: worker_stuck reason=stand_down"
else
    fail "Test 8: worker_stuck reason field wrong (expected stand_down)"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
