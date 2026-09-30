#!/usr/bin/env bash
# test-infra-7938.sh — INFRA-7938 (INFRA-1965 slice)
#
# Validates the src/lib.rs base crate structure:
#  - src/lib.rs exists and declares at least one pub mod
#  - src/main.rs no longer declares calc_tool as a local `mod` but
#    re-exports it from the lib crate instead
#  - `cargo test --lib calc_tool` passes against the lib crate

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

echo "=== INFRA-7938 src/lib.rs base crate structure test ==="

if [[ -f src/lib.rs ]] && grep -q '^pub mod ' src/lib.rs; then
  ok "src/lib.rs exists and exposes at least one pub mod"
else
  fail "src/lib.rs missing or has no pub mod declarations"
fi

if grep -q '^pub use chump::calc_tool;' src/main.rs && ! grep -q '^mod calc_tool;' src/main.rs; then
  ok "src/main.rs references calc_tool via the lib crate, not a local mod"
else
  fail "src/main.rs still declares calc_tool as a local mod, or is missing the lib re-export"
fi

if PATH="$HOME/.cargo/bin:$PATH" cargo test --lib calc_tool 2>&1 | tail -20 | grep -q "test result: ok"; then
  ok "cargo test --lib calc_tool passes"
else
  fail "cargo test --lib calc_tool did not pass"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
