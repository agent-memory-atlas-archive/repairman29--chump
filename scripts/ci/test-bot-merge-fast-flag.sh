#!/usr/bin/env bash
# scripts/ci/test-bot-merge-fast-flag.sh — INFRA-252 contract test
#
# Asserts that bot-merge.sh's --fast flag is parsed AND skips the cargo
# clippy step. Static analysis only — does not actually invoke bot-merge.sh
# end-to-end (which would need a full git/gh sandbox).
#
# Pattern: parse the script's source to verify (a) --fast is in the flag
# table, (b) FAST=1 implies SKIP_TESTS=1, (c) the clippy stage is gated on
# `[[ $FAST -eq 1 ]]`, (d) the usage-block describes --fast.
#
# Failure mode this catches: someone accidentally drops the --fast handling
# (or wires it to the wrong stage) and the regression silently blows the
# agent task budget on next clippy-cold run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"

[[ -f "$BOT_MERGE" ]] || { echo "FAIL: bot-merge.sh not found at $BOT_MERGE"; exit 1; }

PASS=0
FAIL=0

assert() {
    local desc="$1"
    local pattern="$2"
    if grep -qE "$pattern" "$BOT_MERGE"; then
        echo "[PASS] $desc"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $desc"
        echo "       expected pattern: $pattern"
        FAIL=$((FAIL + 1))
    fi
}

# ── Contract checks ─────────────────────────────────────────────────────────
# RESILIENT-1407: default init changed from a bare `FAST=0` to `FAST=${FAST:-0}`
# so the CHUMP_DISPATCH_DEPTH=1 block (which pre-sets FAST=1) doesn't get
# silently clobbered on the very next line — see test-bot-merge-no-local-build.sh
# for the regression this fixes.
assert "FAST default initialized to 0 (preserving any pre-set value)" \
       'FAST=\$\{FAST:-0\}'

assert "--fast flag is in the case statement" \
       'FAST=1; SKIP_TESTS=1'

assert "--fast is documented in the usage block" \
       'Skip BOTH cargo clippy AND cargo test'

assert "clippy stage is gated on FAST" \
       '\[\[ \$FAST -eq 1 \]\]'

assert "clippy gate has user-facing skip message" \
       'Skipping local clippy \(--fast, no cargo\)'

assert "INFRA-252 reference present" \
       'INFRA-252'

# ── Smoke test: bash syntax check still passes ──────────────────────────────
if bash -n "$BOT_MERGE" 2>/dev/null; then
    echo "[PASS] bash -n bot-merge.sh — syntax clean"
    PASS=$((PASS + 1))
else
    echo "[FAIL] bash -n bot-merge.sh — syntax error introduced"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "Passed: $PASS  Failed: $FAIL"

[[ $FAIL -eq 0 ]] || exit 1
