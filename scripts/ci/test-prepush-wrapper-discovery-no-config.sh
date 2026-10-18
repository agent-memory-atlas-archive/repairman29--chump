#!/usr/bin/env bash
# scripts/ci/test-prepush-wrapper-discovery-no-config.sh — RESILIENT-1619
#
# THE BUG (receipt 2026-10-17, cuphead): the EFFECTIVE-097 wrapper-discovery
# line in scripts/git-hooks/pre-push reads the rustc-wrapper out of
# .cargo/config.toml with awk:
#
#   _PREPUSH_WRAPPER_BIN="${RUSTC_WRAPPER:-$(awk ... "$REPO_ROOT_T/.cargo/config.toml" 2>/dev/null)}"
#
# .cargo/config.toml is per-machine and gitignored (written by
# scripts/setup/install-sccache.sh). On any checkout WITHOUT it and with
# RUSTC_WRAPPER unset, awk exits 2 reading the missing file, the command
# substitution carries that status into the assignment, and the hook's
# `set -euo pipefail` kills the whole hook BEFORE the cargo test gate runs:
# "hook aborted at line … with exit 2", no BLOCKED reason, no test log.
# `2>/dev/null` only silenced stderr — not the exit status.
#
# THE FIX: `|| true` INSIDE the substitution, so a missing/empty file leaves
# _PREPUSH_WRAPPER_BIN empty and the hook falls through to the test gate.
#
# This test (a) checks the hook parses, (b) asserts the ERR trap prints the
# failing command text (BASH_COMMAND), and (c) BEHAVIORALLY extracts the real
# wrapper-discovery line from the hook and runs it under the hook's exact
# shell options (set -euo pipefail + the ERR trap) in a temp checkout with NO
# .cargo/config.toml and RUSTC_WRAPPER unset, asserting the line survives and
# a "test gate reached" sentinel AFTER it is printed.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; cd "$ROOT" || exit 2
HOOK=scripts/git-hooks/pre-push
P=0; F=0
p(){ echo "[PASS] $1"; P=$((P+1)); }
f(){ echo "[FAIL] $1"; F=$((F+1)); }

echo "=== test-prepush-wrapper-discovery-no-config.sh (RESILIENT-1619) ==="

# 1. The hook parses (no syntax regression).
if bash -n "$HOOK" 2>/dev/null; then p "pre-push parses"; else f "pre-push FAILS bash -n"; fi

# 2. The ERR trap prints the failing command, not only the line number.
if grep -qE "trap '.*BASH_COMMAND.*' ERR" "$HOOK"; then
  p "ERR trap prints the failing command (\$BASH_COMMAND)"
else
  f "ERR trap does not print \$BASH_COMMAND — a silent exit-2 abort has no diagnostic"
fi

# 3. Extract the real wrapper-discovery line from the hook (don't duplicate it —
#    track the actual code so the test can't drift from the hook).
WRAPPER_LINE="$(grep -E '_PREPUSH_WRAPPER_BIN="\$\{RUSTC_WRAPPER:-' "$HOOK" | head -1)"
if [[ -n "$WRAPPER_LINE" ]]; then
  p "found wrapper-discovery line in hook"
else
  f "could not locate wrapper-discovery line — test cannot run its behavioral check"
fi

# 4. BEHAVIORAL: run the extracted line under the hook's exact shell options in a
#    temp checkout with no .cargo/config.toml and RUSTC_WRAPPER unset. The
#    sentinel AFTER the line must print — i.e. the test gate is reached, the hook
#    did NOT abort on exit 2.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# No .cargo/config.toml in $TMP — this is the cuphead condition.
OUT="$(
  env -u RUSTC_WRAPPER REPO_ROOT_T="$TMP" WRAPPER_LINE="$WRAPPER_LINE" bash -c '
    set -euo pipefail
    trap '"'"'rc=$?; echo "ABORTED line $LINENO (command: ${BASH_COMMAND}) exit $rc" >&2; exit $rc'"'"' ERR
    eval "$WRAPPER_LINE"
    echo "TEST_GATE_REACHED wrapper=[${_PREPUSH_WRAPPER_BIN}]"
  ' 2>&1
)"
RC=$?
if [[ $RC -eq 0 && "$OUT" == *"TEST_GATE_REACHED"* ]]; then
  p "wrapper-discovery survives missing config.toml + unset RUSTC_WRAPPER (gate reached: $OUT)"
else
  f "wrapper-discovery ABORTED without config.toml (rc=$RC): $OUT"
fi

echo ""
echo "=== $P passed, $F failed ==="
[ "$F" -eq 0 ] || exit 1
