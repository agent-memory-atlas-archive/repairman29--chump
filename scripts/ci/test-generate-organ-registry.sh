#!/usr/bin/env bash
# scripts/ci/test-generate-organ-registry.sh — INFRA-7586 (INFRA-3648 slice)
#
# Proves scripts/ops/generate-organ-registry.sh runs clean and produces a
# registry that covers all 9 live CJ node-housekeeping organs with a
# correctly formed pgrep detector line each (gap AC4/AC5).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

GEN="$REPO_ROOT/scripts/ops/generate-organ-registry.sh"
OUT="$REPO_ROOT/scripts/ops/organ-registry.txt"

pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; exit 1; }

echo "=== test-generate-organ-registry.sh (INFRA-7586) ==="

[[ -f "$GEN" ]] || fail "generator missing: $GEN"
[[ -x "$GEN" ]] || fail "generator not executable: $GEN"
bash -n "$GEN" || fail "generator bash -n failed"
pass "generator present, executable, syntax clean"

out="$(bash "$GEN" 2>&1)"
rc=$?
[[ $rc -eq 0 ]] || fail "generator exited $rc: $out"
pass "generator exits 0"

[[ -f "$OUT" ]] || fail "registry not written: $OUT"

REQUIRED_ORGANS="cargo-sweep-gc disk-monitor main-health-watchdog node-orchestrator pr-lander pr-stuck-live-scan reviver rot-reaper worktree-reaper"
for name in $REQUIRED_ORGANS; do
  line="$(grep -E "^enabled[[:space:]]+${name}[[:space:]]" "$OUT" || true)"
  [[ -n "$line" ]] || fail "missing registry line for organ: $name"
  echo "$line" | grep -q 'launcher=' || fail "$name: missing launcher= field"
  echo "$line" | grep -q 'pgrep=' || fail "$name: missing pgrep= field"
  echo "$line" | grep -q 'heartbeat=' || fail "$name: missing heartbeat= field"
done
pass "all 9 required organs present with launcher/pgrep/heartbeat fields"

# --stdout mode must not write the file and must emit the same body.
stdout_body="$(bash "$GEN" --stdout)"
[[ -n "$stdout_body" ]] || fail "--stdout produced no output"
pass "--stdout mode works"

echo "=== test-generate-organ-registry.sh: PASS ==="
