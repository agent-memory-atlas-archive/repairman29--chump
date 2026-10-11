#!/usr/bin/env bash
# RESILIENT-803: pixel-worker (proot-glibc path) carries cooldown + wedge-kill.
set -euo pipefail
f="$(dirname "$0")/../setup/pixel-worker.sh"
bash -n "$f"
grep -q 'PIXEL_WORKER_COOLDOWN_S' "$f"
grep -q 'FAILED_FILE' "$f"
grep -q 'timeout -k 30 "\$WEDGE_S" "\$CLAUDE_PROOT_WRAPPER"' "$f"
grep -q 'wedge-kill' "$f"
echo "PASS: pixel-worker self-heal (cooldown + wedge-kill) present"

# RESILIENT-805: kill switch prevents the loop from starting.
out="$(PIXEL_WORKER_DISABLE=1 CHUMP_HOME=/nonexistent CHUMP_REPO=/nonexistent timeout 10 bash "$f" 2>&1)" \
  || { echo "FAIL: disabled worker exited non-zero"; exit 1; }
echo "$out" | grep -q 'not starting loop' || { echo "FAIL: no disable message"; exit 1; }
echo "$out" | grep -q 'tick' && { echo "FAIL: loop started while disabled"; exit 1; }
tmpf="$(mktemp -u)"; touch "$tmpf"
out="$(PIXEL_WORKER_DISABLE_FILE="$tmpf" CHUMP_HOME=/nonexistent timeout 10 bash "$f" 2>&1)"; rm -f "$tmpf"
echo "$out" | grep -q 'not starting loop' || { echo "FAIL: disable file ignored"; exit 1; }
echo "PASS: pixel-worker kill switch blocks loop start"
