#!/usr/bin/env bash
# test-branch-protection-gate.sh — CREDIBLE-1502 (Phase R R3)
#
# The operator flipped live branch-protection on `main` to
# enforce_admins=true + required_status_checks.strict=true (contexts stay
# [verified]). This test makes that flip a constraint instead of a one-time
# fact: it asserts the checked-in baseline still reflects it, and (when gh +
# network are available) that the live rule hasn't drifted from the baseline.
#
# Two parts:
#   1. Pure-file check (always runs, no network): asserts
#      docs/baselines/branch-protection-main.json has enforce_admins.enabled,
#      required_status_checks.strict, and contexts == ["verified"].
#   2. Live check (skipped if gh/network unavailable): runs
#      scripts/ops/branch-protection-drift.sh --dry-run and fails on drift.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BASELINE="$REPO_ROOT/docs/baselines/branch-protection-main.json"
DRIFT_SCRIPT="$REPO_ROOT/scripts/ops/branch-protection-drift.sh"

PASS=0
FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== CREDIBLE-1502: branch-protection gate ==="

if [[ ! -f "$BASELINE" ]]; then
    bad "baseline missing: $BASELINE"
    echo "FAIL: $FAIL  PASS: $PASS"
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    bad "jq not found — cannot evaluate baseline"
    echo "FAIL: $FAIL  PASS: $PASS"
    exit 1
fi

# ── 1. pure-file check ────────────────────────────────────────────────────
enforce_admins="$(jq -r '.enforce_admins.enabled' "$BASELINE")"
if [[ "$enforce_admins" == "true" ]]; then
    ok "baseline: enforce_admins.enabled == true"
else
    bad "baseline: enforce_admins.enabled == '$enforce_admins' (expected true)"
fi

strict="$(jq -r '.required_status_checks.strict' "$BASELINE")"
if [[ "$strict" == "true" ]]; then
    ok "baseline: required_status_checks.strict == true"
else
    bad "baseline: required_status_checks.strict == '$strict' (expected true)"
fi

contexts="$(jq -c '.required_status_checks.contexts' "$BASELINE")"
if [[ "$contexts" == '["verified"]' ]]; then
    ok "baseline: required_status_checks.contexts == [\"verified\"]"
else
    bad "baseline: required_status_checks.contexts == '$contexts' (expected [\"verified\"])"
fi

# ── 2. live drift check (skipped without gh + network) ───────────────────
if ! command -v gh >/dev/null 2>&1; then
    echo "  SKIP: gh not found — skipping live drift check"
elif ! gh auth status >/dev/null 2>&1; then
    echo "  SKIP: gh not authenticated — skipping live drift check"
else
    if bash "$DRIFT_SCRIPT" --dry-run >/tmp/branch-protection-gate-live.$$ 2>&1; then
        if grep -q 'DRIFT detected' /tmp/branch-protection-gate-live.$$; then
            bad "live branch protection has drifted from baseline"
            cat /tmp/branch-protection-gate-live.$$
        else
            ok "live branch protection matches baseline"
        fi
    else
        echo "  SKIP: branch-protection-drift.sh --dry-run could not reach the API — skipping live check"
    fi
    rm -f /tmp/branch-protection-gate-live.$$
fi

echo ""
echo "FAIL: $FAIL  PASS: $PASS"
[[ "$FAIL" -eq 0 ]]
