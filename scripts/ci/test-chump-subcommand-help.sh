#!/usr/bin/env bash
# scripts/ci/test-chump-subcommand-help.sh — INFRA-1238 (also referenced by INFRA-1246)
#
# Regression gate for the "leaf-verb --help broken" bug class. Each verb's
# --help must exit 0 with non-empty usage output, NOT fall through to the
# LLM agent or fail on "missing positional".
#
# Pre-fix symptoms (2026-05-14):
#   chump claim --help       → exit non-zero, "missing GAP-ID (saw flag --help)"
#   chump ship --help        → falls through to LLM agent ("Response from Agent: ...")
#   chump gap preflight --help → "WARN --help not found in state.db"
#
# Post-fix expectations: all return exit 0 with a usage string.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }
skip() { printf '\033[0;33mSKIP\033[0m %s\n' "$*"; exit 0; }

# CREDIBLE-1528: resolve chump via shared discover-chump-bin.sh (exits non-zero instead of SKIP+exit 0).
# shellcheck source=scripts/ci/lib/discover-chump-bin.sh
source "$REPO_ROOT/scripts/ci/lib/discover-chump-bin.sh"
CHUMP="$CHUMP_BIN"

# Skip staleness check + LLM dispatch; help is local.
export CHUMP_BINARY_STALENESS_CHECK=0

check_help() {
    local label="$1"; shift
    local cmd=("$@")
    local out err rc
    out=$("${cmd[@]}" --help 2>/dev/null)
    rc=$?
    if [[ "$rc" -ne 0 ]]; then
        fail "$label: exit $rc (expected 0)"
    fi
    if [[ -z "$out" ]]; then
        fail "$label: empty stdout"
    fi
    if echo "$out" | grep -qiE "Response from Agent|missing GAP-ID|not found in state\.db"; then
        fail "$label: fell through to LLM agent or positional-validation error. output:\n$out"
    fi
    if ! echo "$out" | grep -qiE "usage|options"; then
        fail "$label: stdout has no Usage/Options preamble. output:\n$out"
    fi
    ok "$label"
}

check_help "chump claim --help"             "$CHUMP" claim
check_help "chump ship --help"              "$CHUMP" ship
check_help "chump gap preflight --help"     "$CHUMP" gap preflight
check_help "chump gap ship --help"          "$CHUMP" gap ship
check_help "chump gap decompose --help"     "$CHUMP" gap decompose
check_help "chump gap triage --help"        "$CHUMP" gap triage

echo
echo "All INFRA-1238 subcommand-help tests passed."
