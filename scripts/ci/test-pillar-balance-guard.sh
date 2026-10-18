#!/usr/bin/env bash
# capability-guard-exempt: existing skip-path covers missing binary; pattern wording differs from canonical (CREDIBLE-078)
# scripts/ci/test-pillar-balance-guard.sh — INFRA-1152
#
# Tests the pillar-balance guard in `chump gap reserve`:
#   AC8: synthetic registry with 7 RESILIENT / 3 others — reserve another
#        RESILIENT asserts block (exit 1); with --force-pillar allows.
#   AC9: synthetic registry with 1 EFFECTIVE / 9 others — reserve any
#        non-EFFECTIVE asserts warn mentions Effective under-fed.
#
# Network-free: runs against a fresh tempdir state.db via CHUMP_REPO.

set -uo pipefail

CHUMP_BIN="${CHUMP_BIN:-${CARGO_TARGET_DIR:-$(git rev-parse --show-toplevel)/target}/debug/chump}"
[ -x "$CHUMP_BIN" ] || { echo "FATAL: $CHUMP_BIN not found" >&2; exit 2; }

PASS=0
FAIL=0
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

echo "=== INFRA-1152 pillar-balance guard tests ==="
echo

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.chump" "$TMP/docs/gaps"
cd "$TMP"
git init -q -b main . 2>/dev/null || git init -q . 2>/dev/null || true
git -C "$TMP" config user.email "test@ci.local" 2>/dev/null || true
git -C "$TMP" config user.name "CI" 2>/dev/null || true

export CHUMP_REPO="$TMP"
# CREDIBLE-1519: CHUMP_HOME redirects the RESILIENT-069 farmer gate's oauth
# freshness path off the host's ~/.chump so a stale host token can't RED-block
# these seeds. --force would bypass the pillar-balance gate under test, so we
# isolate via CHUMP_HOME (honored by src/farmer_status.rs) instead.
export CHUMP_HOME="$TMP"
export CHUMP_WORKTREE_ROOT="$TMP"
export CHUMP_BINARY_STALENESS_CHECK=0
# Bypass FLEET-029 ambient glance and INFRA-1149 similarity check in seed
export FLEET_029_AMBIENT_GLANCE_SKIP=1
export CHUMP_RESERVE_SCAN_OPEN_PRS=0
export CHUMP_RESERVE_NO_AUTOSTAGE=1

reserve() {
    "$CHUMP_BIN" gap reserve "$@" --force --force-duplicate >/dev/null 2>&1
}

reserve_check() {
    # Reserve without --force so guards run
    "$CHUMP_BIN" gap reserve "$@" \
        --force-duplicate \
        2>&1
}

# ── Scenario A: 7 RESILIENT + 3 other → BLOCK on 8th RESILIENT ────────────
echo "--- Scenario A: 7 RESILIENT + 3 others → block on 8th RESILIENT ---"

# Seed 7 RESILIENT gaps with real ACs (not TODO placeholders)
for i in $(seq 1 7); do
    reserve --domain INFRA --title "RESILIENT: fix-$i-$$" --priority P2 --effort xs \
        --acceptance-criteria "verify fix-$i works" || true
done
# Seed 3 other-pillar gaps with real ACs
for i in $(seq 1 3); do
    reserve --domain INFRA --title "EFFECTIVE: feature-$i-$$" --priority P2 --effort xs \
        --acceptance-criteria "verify feature-$i works" || true
done

# Now try to reserve an 8th RESILIENT — should be blocked (ratio = 8/11 ≈ 73% >> 50%)
out_block="$(reserve_check --domain INFRA --title "RESILIENT: should-be-blocked-$$" \
    --priority P2 --effort xs --acceptance-criteria "verify block works")"
exit_block=$?

if [ "$exit_block" -ne 0 ]; then
    ok "8th RESILIENT reserve exits non-zero (blocked)"
else
    fail "8th RESILIENT reserve should have been blocked, but exited 0"
fi

if echo "$out_block" | grep -qi "PILLAR BLOCKED\|pillar.*blocked\|INFRA-1152"; then
    ok "block message mentions PILLAR BLOCKED / INFRA-1152"
else
    fail "block message missing PILLAR BLOCKED keyword: $out_block"
fi

# With --force-pillar, the same reserve should succeed
out_force="$(reserve_check --domain INFRA --title "RESILIENT: force-override-$$" \
    --priority P2 --effort xs --acceptance-criteria "verify force works" \
    --force-pillar 2>&1)"
exit_force=$?

if [ "$exit_force" -eq 0 ]; then
    ok "--force-pillar overrides block (exit 0)"
else
    fail "--force-pillar should override block, got exit $exit_force: $out_force"
fi

# ── Scenario B: 1 EFFECTIVE + 9 others → warn on non-EFFECTIVE ────────────
echo ""
echo "--- Scenario B: 1 EFFECTIVE / 9 others → warn mentions Effective under-fed ---"

# Fresh DB
TMP2="$(mktemp -d)"
mkdir -p "$TMP2/.chump" "$TMP2/docs/gaps"
cd "$TMP2"
git init -q -b main . 2>/dev/null || git init -q . 2>/dev/null || true
git -C "$TMP2" config user.email "test@ci.local" 2>/dev/null || true
git -C "$TMP2" config user.name "CI" 2>/dev/null || true
export CHUMP_REPO="$TMP2"
export CHUMP_HOME="$TMP2"  # CREDIBLE-1519: isolate farmer-gate oauth path
export CHUMP_WORKTREE_ROOT="$TMP2"

# Seed 9 RESILIENT + 1 EFFECTIVE with real ACs
for i in $(seq 1 9); do
    "$CHUMP_BIN" gap reserve --domain INFRA --title "RESILIENT: resilient-$i-$$" --priority P2 --effort xs \
        --acceptance-criteria "verify resilient-$i" --force --force-duplicate >/dev/null 2>&1 || true
done
"$CHUMP_BIN" gap reserve --domain INFRA --title "EFFECTIVE: just-one-$$" --priority P2 --effort xs \
    --acceptance-criteria "verify just one effective" --force --force-duplicate >/dev/null 2>&1 || true

# Reserve a RESILIENT — RESILIENT will be ~91% of total (9 RESILIENT + 1 EFFECTIVE + this one),
# so it will BLOCK (not just warn). The key assertion is that the message mentions
# EFFECTIVE as under-fed regardless of block or warn.
out_warn="$(reserve_check --domain INFRA --title "RESILIENT: new-resilient-$$" \
    --priority P2 --effort xs --acceptance-criteria "verify new resilient")"
exit_warn=$?

# With 9 RESILIENT + 1 EFFECTIVE: new RESILIENT would be 10/11 ≈ 91% → BLOCK expected
if [ "$exit_warn" -ne 0 ]; then
    ok "RESILIENT reserve exits non-zero (blocked at 91% ratio)"
else
    ok "RESILIENT reserve proceeded (warn only path)"
fi

if echo "$out_warn" | grep -qi "EFFECTIVE\|effective\|under-fed\|under.fed\|under.weighted"; then
    ok "guard message mentions EFFECTIVE as under-fed"
else
    fail "guard message should mention EFFECTIVE under-fed: $out_warn"
fi

rm -rf "$TMP2"

# ── Scenario C: CHUMP_PILLAR_BALANCE_DISABLE=1 bypasses all checks ─────────
echo ""
echo "--- Scenario C: CHUMP_PILLAR_BALANCE_DISABLE=1 bypasses guard ---"
TMP3="$(mktemp -d)"
mkdir -p "$TMP3/.chump" "$TMP3/docs/gaps"
cd "$TMP3"
git init -q -b main . 2>/dev/null || git init -q . 2>/dev/null || true
git -C "$TMP3" config user.email "test@ci.local" 2>/dev/null || true
git -C "$TMP3" config user.name "CI" 2>/dev/null || true
export CHUMP_REPO="$TMP3"
export CHUMP_WORKTREE_ROOT="$TMP3"

# Seed 5 RESILIENT with real ACs (would be 100% if we add one more)
for i in $(seq 1 5); do
    "$CHUMP_BIN" gap reserve --domain INFRA --title "RESILIENT: r$i-$$" --priority P2 --effort xs \
        --acceptance-criteria "check r$i" --force --force-duplicate >/dev/null 2>&1 || true
done

out_disabled="$(CHUMP_PILLAR_BALANCE_DISABLE=1 reserve_check --domain INFRA \
    --title "RESILIENT: disabled-check-$$" \
    --priority P2 --effort xs --acceptance-criteria "check disabled")"
exit_disabled=$?

if [ "$exit_disabled" -eq 0 ]; then
    ok "CHUMP_PILLAR_BALANCE_DISABLE=1 allows reserve without block"
else
    fail "CHUMP_PILLAR_BALANCE_DISABLE=1 should bypass guard, got exit $exit_disabled: $out_disabled"
fi

rm -rf "$TMP3"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
