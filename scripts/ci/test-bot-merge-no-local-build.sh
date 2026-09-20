#!/usr/bin/env bash
# scripts/ci/test-bot-merge-no-local-build.sh — RESILIENT-1407 contract test
#
# RESILIENT-1407 is the lean-on-CI land path: a dispatched agent should be
# able to land a change WITHOUT a synchronous local `cargo` build on the
# coordinator (push -> CI builds/verifies -> pr-lander/verified organ lands
# it). RESILIENT-1406 attempted this by setting FAST=1 for
# CHUMP_DISPATCH_DEPTH=1 sessions, but that assignment ran BEFORE the
# "-- Flags --" block's unconditional `FAST=0` default, which silently
# clobbered it — dispatched agents kept compiling locally exactly as before.
# That's why RESILIENT-1406 shipped as a false-done no-op (PR #4774).
#
# This is a static-analysis test (parses bot-merge.sh's source) — it does not
# invoke bot-merge.sh end-to-end, which would need a full git/gh sandbox.
#
# Failure mode this catches: the clobber bug regresses (defaults block goes
# back to a bare `FAST=0` / `SKIP_TESTS=0`), or --no-local-build stops
# skipping the `cargo clippy --fix` pre-flight that --fast alone still runs
# (that pre-flight is a real compile — the exact thing this gap exists to
# remove from the dispatched-agent path).

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

refute() {
    local desc="$1"
    local pattern="$2"
    if grep -qE "$pattern" "$BOT_MERGE"; then
        echo "[FAIL] $desc"
        echo "       pattern must NOT match: $pattern"
        FAIL=$((FAIL + 1))
    else
        echo "[PASS] $desc"
        PASS=$((PASS + 1))
    fi
}

# ── Contract checks ─────────────────────────────────────────────────────────

assert "--no-local-build flag is in the case statement and forces FAST+SKIP_TESTS" \
       'no-local-build\)[[:space:]]+NO_LOCAL_BUILD=1; FAST=1; SKIP_TESTS=1'

assert "--no-local-build is documented in the usage block" \
       'RESILIENT-1407 \(the lean-on-CI land path\)'

# INFRA-2429: the env override is a MODE SELECTOR (CHUMP_BOT_MERGE_LAND_MODE
# = ci|local), not a NO_/SKIP/BYPASS-shaped var — a bare
# CHUMP_BOT_MERGE_NO_LOCAL_BUILD=1 flag was tried first and correctly bounced
# by the bypass-debt-ceiling gate (test-no-new-bypass-env-vars.sh), since its
# "NO_" substring reads as skip-class even though the semantics are a
# legitimate mode choice, not a safety-gate bypass.
assert "CHUMP_BOT_MERGE_LAND_MODE=ci env var is honored as a mode selector" \
       'CHUMP_BOT_MERGE_LAND_MODE:-local.*==.*"ci"'
refute "no bypass-class CHUMP_BOT_MERGE_NO_LOCAL_BUILD env var reintroduced" \
       'CHUMP_BOT_MERGE_NO_LOCAL_BUILD'

# The RESILIENT-1406 clobber-bug regression guard: the Flags block must read
# pre-set values back (not stomp them), or CHUMP_DISPATCH_DEPTH=1's FAST=1
# never survives to the arg-parsing / clippy-gating logic below it.
assert "Flags block preserves a pre-set FAST instead of stomping it" \
       'FAST=\$\{FAST:-0\}'
assert "Flags block preserves a pre-set SKIP_TESTS instead of stomping it" \
       'SKIP_TESTS=\$\{SKIP_TESTS:-0\}'
refute "no bare FAST=0 default remains (the clobber bug)" \
       '^FAST=0$'
refute "no bare SKIP_TESTS=0 default remains (the clobber bug)" \
       '^SKIP_TESTS=0$'

# CHUMP_DISPATCH_DEPTH=1 must set the full lean-on-CI trio, not just FAST.
assert "CHUMP_DISPATCH_DEPTH=1 sets FAST=1 for dispatched agents" \
       'CHUMP_DISPATCH_DEPTH.*==.*"1"'
assert "CHUMP_DISPATCH_DEPTH=1 block sets NO_LOCAL_BUILD=1" \
       '^[[:space:]]*NO_LOCAL_BUILD=1$'

# The actual local-build elimination: --fast alone still ran a real compile
# (`cargo clippy --fix --bin chump`) as a pre-flight step. NO_LOCAL_BUILD=1
# must short-circuit BEFORE that branch, not just reuse it.
assert "clippy stage checks NO_LOCAL_BUILD before the --fast pre-flight branch" \
       '\[\[ \$NO_LOCAL_BUILD -eq 1 \]\]'
assert "NO_LOCAL_BUILD clippy-skip message is user-facing" \
       'skipping ALL local cargo clippy \(including --fast pre-flight\)'

# Order matters: NO_LOCAL_BUILD's elif must appear before the --fast elif in
# the clippy stage, otherwise --fast's compiling branch would shadow it.
_no_local_build_line="$(grep -n '\[\[ \$NO_LOCAL_BUILD -eq 1 \]\]' "$BOT_MERGE" | head -1 | cut -d: -f1 || true)"
_fast_preflight_line="$(grep -n 'pre-flight auto-correct' "$BOT_MERGE" | head -1 | cut -d: -f1 || true)"
if [[ -n "$_no_local_build_line" && -n "$_fast_preflight_line" && "$_no_local_build_line" -lt "$_fast_preflight_line" ]]; then
    echo "[PASS] NO_LOCAL_BUILD branch is checked before the compiling --fast pre-flight branch"
    PASS=$((PASS + 1))
else
    echo "[FAIL] NO_LOCAL_BUILD branch must precede the --fast pre-flight branch (found at lines: $_no_local_build_line vs $_fast_preflight_line)"
    FAIL=$((FAIL + 1))
fi

assert "RESILIENT-1407 reference present" \
       'RESILIENT-1407'

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
