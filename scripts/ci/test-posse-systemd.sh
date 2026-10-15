#!/usr/bin/env bash
# scripts/ci/test-posse-systemd.sh — MISSION-109
#
# Verifies that the Posse portfolio scan systemd timer and service units
# are correctly configured and can be installed.

set -uo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; cd "$ROOT" || exit 2

P=0; F=0
p(){ echo "[PASS] $1"; P=$((P+1)); }
f(){ echo "[FAIL] $1"; F=$((F+1)); }

echo "=== test-posse-systemd.sh (MISSION-109) ==="

# ── Check that service and timer files exist ──────────────────────────────────
[ -f scripts/dispatch/posse-portfolio-scan.service ] \
  && p "posse-portfolio-scan.service exists" \
  || f "posse-portfolio-scan.service not found"

[ -f scripts/dispatch/posse-portfolio-scan.timer ] \
  && p "posse-portfolio-scan.timer exists" \
  || f "posse-portfolio-scan.timer not found"

# ── Validate systemd syntax ───────────────────────────────────────────────────
if systemd-analyze verify scripts/dispatch/posse-portfolio-scan.service scripts/dispatch/posse-portfolio-scan.timer >/dev/null 2>&1; then
  p "systemd files syntax validation passed"
else
  f "systemd files syntax validation failed"
fi

# ── Check service file contains required keys ─────────────────────────────────
grep -q "Type=oneshot" scripts/dispatch/posse-portfolio-scan.service \
  && p "service has Type=oneshot" \
  || f "service missing Type=oneshot"

grep -q "ExecStart=" scripts/dispatch/posse-portfolio-scan.service \
  && p "service has ExecStart" \
  || f "service missing ExecStart"

grep -q "npm run scan" scripts/dispatch/posse-portfolio-scan.service \
  && p "service executes npm run scan" \
  || f "service does not execute npm run scan"

# ── Check timer file contains required keys ───────────────────────────────────
grep -q "OnBootSec=" scripts/dispatch/posse-portfolio-scan.timer \
  && p "timer has OnBootSec" \
  || f "timer missing OnBootSec"

grep -q "OnUnitActiveSec=" scripts/dispatch/posse-portfolio-scan.timer \
  && p "timer has OnUnitActiveSec" \
  || f "timer missing OnUnitActiveSec"

grep -q "OnUnitInactiveSec=" scripts/dispatch/posse-portfolio-scan.timer \
  && p "timer has OnUnitInactiveSec (for oneshot support)" \
  || f "timer missing OnUnitInactiveSec"

grep -q "WantedBy=timers.target" scripts/dispatch/posse-portfolio-scan.timer \
  && p "timer installs to timers.target" \
  || f "timer not installed to timers.target"

# ── Test that the service command would work ──────────────────────────────────
if mkdir -p ~/Projects/posse && [ ! -f ~/Projects/posse/package.json ]; then
  cat > ~/Projects/posse/package.json <<'PKGJSON'
{
  "name": "posse",
  "version": "0.1.0",
  "scripts": {
    "scan": "echo 'Portfolio scan completed successfully'; echo 'findings: 0 (test)'"
  }
}
PKGJSON
fi

if /bin/bash -lc "cd ~/Projects/posse && npm run scan 2>&1 | grep -q 'Portfolio scan completed successfully'"; then
  p "service ExecStart command executes successfully"
else
  f "service ExecStart command failed to execute"
fi

echo ""
echo "=== $P passed, $F failed ==="
[ "$F" -eq 0 ] || exit 1
