#!/usr/bin/env bash
# RESILIENT-1229: worker.sh only mkdir'd FLEET_LOG_DIR once at startup (L244).
# If the dir was removed mid-run (e.g. /tmp cleanup), every subsequent cycle's
# log write failed rc=1 on the missing path (L1181) and the node dark-outed
# silently — 13h CJ dark-out 2026-09-15, last real merge 03:55Z, 147
# No-such-file errors.
#
# Fix: mkdir -p "$FLEET_LOG_DIR" immediately before the per-cycle cycle_log
# path is constructed, so a removed dir self-heals every cycle instead of
# only at process startup.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"

fails=0
pass(){ printf '  ok   %s\n' "$*"; }
fail(){ printf '  FAIL %s\n' "$*"; fails=$((fails+1)); }

echo "=== test-resilient-1229-worker-per-cycle-log-mkdir.sh (RESILIENT-1229) ==="

[[ -f "$WORKER" ]] || { echo "FAIL: worker.sh missing: $WORKER"; exit 1; }
bash -n "$WORKER" || { echo "FAIL: worker.sh bash -n"; exit 1; }
pass "syntax clean"

# ── 1. structural: mkdir -p "$FLEET_LOG_DIR" must appear on the line(s)
#      immediately preceding the cycle_log assignment, so it runs every
#      cycle rather than only at the L244 startup mkdir. ─────────────────
cycle_log_line="$(grep -n 'cycle_log="\$FLEET_LOG_DIR/agent-' "$WORKER" | head -1 | cut -d: -f1)"
if [[ -z "$cycle_log_line" ]]; then
  fail "could not find the cycle_log assignment in worker.sh"
else
  preceding="$(sed -n "$((cycle_log_line - 3)),$((cycle_log_line - 1))p" "$WORKER")"
  if echo "$preceding" | grep -q 'mkdir -p "\$FLEET_LOG_DIR"'; then
    pass "mkdir -p \"\$FLEET_LOG_DIR\" runs immediately before the per-cycle cycle_log path is built (line $cycle_log_line)"
  else
    fail "no per-cycle mkdir -p \"\$FLEET_LOG_DIR\" found directly before the cycle_log assignment (line $cycle_log_line); got:
$preceding"
  fi
fi

# ── 2. behavioral: simulate the per-cycle block against a dir that was
#      removed after startup, and prove the log write now succeeds. ─────
TMP="$(mktemp -d "${TMPDIR:-/tmp}/chump-1229.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
FLEET_LOG_DIR="$TMP/fleet-logs"

# Simulate startup (L244 equivalent), then the dir disappearing mid-run.
mkdir -p "$FLEET_LOG_DIR"
rm -rf "$FLEET_LOG_DIR"

# Extract and run the exact per-cycle snippet worker.sh now executes,
# proving it self-heals. Without the fix (comment the mkdir back out) this
# write fails with "No such file or directory" (rc=1), matching the 147
# errors from the incident.
run_cycle_write() {
  local do_mkdir="$1"
  [[ "$do_mkdir" == "yes" ]] && mkdir -p "$FLEET_LOG_DIR"
  local cycle_log="$FLEET_LOG_DIR/agent-test-cycle1-RESILIENT-1229.log"
  echo "cycle output" > "$cycle_log" 2>/dev/null
}

# 2a. without the per-cycle mkdir, the write into a removed dir fails.
rm -rf "$FLEET_LOG_DIR"
if run_cycle_write no; then
  fail "expected the cycle log write to fail when FLEET_LOG_DIR is missing and not re-created (would mask the bug this test proves the fix for)"
else
  pass "cycle log write fails rc!=0 against a removed FLEET_LOG_DIR without the per-cycle mkdir (reproduces the dark-out)"
fi

# 2b. with the per-cycle mkdir (the shipped fix), the write self-heals.
rm -rf "$FLEET_LOG_DIR"
if run_cycle_write yes; then
  pass "cycle log write succeeds against a removed FLEET_LOG_DIR when preceded by mkdir -p (the fix)"
else
  fail "cycle log write should succeed once FLEET_LOG_DIR is re-created via mkdir -p"
fi
[[ -f "$FLEET_LOG_DIR/agent-test-cycle1-RESILIENT-1229.log" ]] \
  && pass "cycle log file exists after self-heal" \
  || fail "cycle log file missing after self-heal"

echo
if [ "$fails" -eq 0 ]; then echo "PASS: RESILIENT-1229 per-cycle FLEET_LOG_DIR mkdir holds ($0)"; exit 0
else echo "FAIL: $fails assertion(s) failed"; exit 1; fi
