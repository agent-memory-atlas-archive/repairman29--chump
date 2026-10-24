#!/usr/bin/env bash
# scripts/ci/test-auto-flip-on-merge.sh — INFRA-2121 + CREDIBLE-1553 smoke test.
#
# Asserts that .github/workflows/auto-flip-on-merge.yml and
# scripts/ops/backfill-shipped-gaps.sh resolve closed gaps via the typed
# gap_prs FK (`chump gap gaps-for-pr`), never via PR-title regexes.

set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

# ── Test 1: workflow YAML parses ────────────────────────────────────────────
echo ""
echo "Test 1: .github/workflows/auto-flip-on-merge.yml parses as YAML"
if python3 -c "import yaml; yaml.safe_load(open('.github/workflows/auto-flip-on-merge.yml'))" 2>/dev/null; then
    pass "yaml parses"
else
    fail "yaml parse failed"
fi

# ── Test 2: workflow resolves gaps via chump gap gaps-for-pr, not PR title ──
echo ""
echo "Test 2: .github/workflows/auto-flip-on-merge.yml uses gaps-for-pr (no PR title regex)"
if grep -q 'gaps-for-pr' .github/workflows/auto-flip-on-merge.yml; then
    pass "workflow calls gaps-for-pr"
else
    fail "workflow does not call gaps-for-pr"
fi
if grep -q 'pull_request.title' .github/workflows/auto-flip-on-merge.yml; then
    fail "workflow still references pull_request.title"
else
    pass "workflow does not reference pull_request.title"
fi

# ── Test 3: backfill-shipped-gaps.sh uses gaps-for-pr (no GAP_ID_REGEX) ─────
echo ""
echo "Test 3: scripts/ops/backfill-shipped-gaps.sh uses gaps-for-pr (no GAP_ID_REGEX)"
if grep -q 'gaps-for-pr' scripts/ops/backfill-shipped-gaps.sh; then
    pass "backfill-shipped-gaps.sh calls gaps-for-pr"
else
    fail "backfill-shipped-gaps.sh does not call gaps-for-pr"
fi
if grep -q 'GAP_ID_REGEX' scripts/ops/backfill-shipped-gaps.sh; then
    fail "backfill-shipped-gaps.sh still defines GAP_ID_REGEX"
else
    pass "backfill-shipped-gaps.sh does not define GAP_ID_REGEX"
fi

# ── Test 4: backfill --dry-run exits 0 ──────────────────────────────────────
echo ""
echo "Test 4: backfill --dry-run runs without crashing"
if command -v chump >/dev/null 2>&1 && command -v gh >/dev/null 2>&1; then
    if bash scripts/ops/backfill-shipped-gaps.sh --days 7 --dry-run >/dev/null 2>&1; then
        pass "backfill --dry-run exits 0"
    else
        fail "backfill --dry-run exited non-zero"
    fi
else
    echo "[SKIP] chump or gh not in PATH"
fi

# ── Test 5: backfill rejects unknown flag ───────────────────────────────────
echo ""
echo "Test 5: backfill rejects unknown flag with exit 1"
if bash scripts/ops/backfill-shipped-gaps.sh --bogus-flag 2>/dev/null; then
    fail "backfill accepted --bogus-flag (should reject)"
else
    pass "backfill rejected --bogus-flag"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
