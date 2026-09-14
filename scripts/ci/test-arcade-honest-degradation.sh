#!/usr/bin/env bash
# test-arcade-honest-degradation.sh — EFFECTIVE-1643 (EFFECTIVE-370 slice)
#
# Verifies the arcade's leaderboard + feedback-widget reference
# implementation (patterns/arcade-honest-degradation/) degrades honestly
# when Supabase is down/quota-exhausted:
#   - leaderboard never throws, renders "scores are napping" instead
#   - feedback widget never throws, renders a non-blocking notice
#   - neither path ever surfaces an HTTP 5xx to the caller

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PASS=0
FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== EFFECTIVE-1643: arcade honest degradation ==="

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 0
fi

OUT="$(node "$REPO_ROOT/scripts/ci/lib/test-arcade-honest-degradation.js" 2>&1)"
STATUS=$?
echo "$OUT"

if [ "$STATUS" -eq 0 ]; then
  ok "node assertions"
else
  bad "node assertions (exit $STATUS)"
fi

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
