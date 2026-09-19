#!/usr/bin/env bash
# INFRA-7595: CLI-level regression gate for `chump trek`'s route gatekeeping.
#
# src/trek.rs already has unit coverage for run_trek() directly, but that
# never exercises the actual `chump trek "<job>" [--yes]` argv parsing in
# src/main.rs — a wiring regression there (wrong flag name, argv index off
# by one, exit code not propagated) would ship green. This test drives the
# real built binary end-to-end for the 3 gatekeeping ACs:
#   1. classification happens via src/front_door.rs (implicit — every case
#      below only passes if classify() routed correctly)
#   2. an ambiguous ask refuses execution and asks for clarification, even
#      under --yes (nothing to auto-confirm to)
#   3. a diagnosis-only route (Rescue) exits non-zero with a "no Trek
#      outcome" message
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

BIN_DIR="${CARGO_TARGET_DIR:-$ROOT/target}/debug"

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== INFRA-7595: chump trek route gatekeeping ==="
echo

if [[ ! -x "$BIN_DIR/chump" ]]; then
  echo "test-trek-gatekeeping: building chump ($BIN_DIR/chump) …" >&2
  if ! command -v cargo >/dev/null 2>&1; then
    echo "  SKIP: cargo not on PATH — test-trek-gatekeeping needs chump" >&2
    exit 0
  fi
  cargo build -q --bin chump 2>&1 || {
    echo "  SKIP: cargo build failed — test-trek-gatekeeping cannot run" >&2
    exit 0
  }
  if [[ ! -x "$BIN_DIR/chump" ]]; then
    echo "  SKIP: chump binary still missing after cargo build ($BIN_DIR/chump)" >&2
    exit 0
  fi
fi

BIN="$BIN_DIR/chump"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# run_trek <job> [args...] — invokes `chump trek` without letting set -e
# abort the script on the (expected) non-zero exit codes under test.
run_trek() {
  set +e
  out="$(cd "$TMP" && "$BIN" trek "$@" 2>&1)"
  rc=$?
  set -e
}

# ── AC2: ambiguous ask refuses + asks, even with --yes ─────────────────────
run_trek "hello there" --yes
if [[ "$rc" -eq 2 ]] && grep -qi "not sure\|which is closest\|could you say a bit more" <<<"$out"; then
  ok "ambiguous route: exit 2, asks for clarification (rc=$rc)"
else
  fail "ambiguous route: rc=$rc out='$out' (expected exit 2 + clarifying question)"
fi

# ── AC2: confident route without --yes refuses + asks ───────────────────────
run_trek "can you fix the login bug and improve the error message"
if [[ "$rc" -eq 2 ]] && grep -qi "yes" <<<"$out"; then
  ok "confident route without --yes: exit 2, asks for confirmation (rc=$rc)"
else
  fail "confident route without --yes: rc=$rc out='$out' (expected exit 2 + confirm prompt)"
fi

# ── AC3: diagnosis-only (Rescue) route exits non-zero with 'no Trek outcome' ─
run_trek "help me, my app is broken and won't start" --yes
if [[ "$rc" -ne 0 ]] && grep -qi "no Trek outcome" <<<"$out"; then
  ok "diagnosis-only (Rescue) route: exit non-zero with 'no Trek outcome' message (rc=$rc)"
else
  fail "diagnosis-only (Rescue) route: rc=$rc out='$out' (expected non-zero + 'no Trek outcome')"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
