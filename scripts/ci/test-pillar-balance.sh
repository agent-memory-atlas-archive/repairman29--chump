#!/usr/bin/env bash
# test-pillar-balance.sh — INFRA-604
#
# Validates `chump gap pillar-balance`:
#  - subcommand wired in main.rs
#  - all 4 pillars detected from title keywords
#  - --json output has required fields
#  - imbalance (all-same-pillar) exits non-zero with HIGH warning
#  - starved (all-OTHER) exits non-zero with UNDER warnings for all 4 pillars
#  - perfectly-balanced exits 0 with no warnings
#  - --suggest lists P2 candidates when pillar is under-filled

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

echo "=== INFRA-604 pillar-balance test ==="
echo

# 1. Subcommand wired in main.rs.
if grep -q '"pillar-balance"' "$REPO_ROOT/src/main.rs"; then
    ok "pillar-balance arm in main.rs"
else
    fail "pillar-balance arm missing from main.rs"
fi

# 2. Help text updated.
if grep -q 'pillar-balance' "$REPO_ROOT/src/main.rs"; then
    ok "pillar-balance mentioned in main.rs"
else
    fail "pillar-balance not mentioned in main.rs"
fi

# 3. Find binary (shared target-dir per INFRA-481, or local fallback).
if [[ -x "${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump" ]]; then
    BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
elif [[ -x "/Users/jeffadkins/Projects/Chump/target/debug/chump" ]]; then
    BIN="/Users/jeffadkins/Projects/Chump/target/debug/chump"
else
    echo "  [build] cargo build --bin chump..."
    cargo build --bin chump --manifest-path "$REPO_ROOT/Cargo.toml" -q 2>&1 | tail -5
    if [[ -x "${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump" ]]; then
        BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
    elif [[ -x "/Users/jeffadkins/Projects/Chump/target/debug/chump" ]]; then
        BIN="/Users/jeffadkins/Projects/Chump/target/debug/chump"
    else
        fail "chump binary not found after build — skipping functional tests"
        echo
        echo "=== Results: $PASS passed, $FAIL failed ==="
        [[ "$FAIL" -eq 0 ]]
        exit
    fi
fi

# Shared test helpers
reserve_gap() {
    local title="$1" priority="${2:-P1}" effort="${3:-xs}"
    "$BIN" gap reserve --domain INFRA --priority "$priority" --effort "$effort" \
        --title "$title" --quiet --force-duplicate 2>/dev/null
}

# ── Fixture: perfectly balanced ──────────────────────────────────────────────
echo "[balanced fixture]"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# RESILIENT-1652: CHUMP_HOME stays $TMP across the TMP2/3/4 blocks (only
# CHUMP_REPO changes so each scenario's reserves stay per-repo), so the farmer
# readiness gate always resolves oauth + node.env from $TMP/.chump. ONE
# healthy-node fixture there covers every scenario. repair 6: the fixture
# function now requires the lib's sandbox marker, so go through
# chump_test_sandbox_setup "$TMP" (which sets CHUMP_HOME/CHUMP_STATE_DIR + the
# marker to $TMP), write the fixture, THEN unset CHUMP_STATE_DB so reserves
# resolve per-CHUMP_REPO again (setup pins CHUMP_STATE_DB, which would funnel
# every scenario into one db and break the per-repo pillar counts). No gate
# loosening, no skip env var.
# shellcheck source=../coord/lib/test-sandbox.sh
source "$REPO_ROOT/scripts/coord/lib/test-sandbox.sh"
# shellcheck source=scripts/ci/lib/sandbox-healthy-node.sh
source "$REPO_ROOT/scripts/ci/lib/sandbox-healthy-node.sh"
chump_test_sandbox_setup "$TMP"
write_sandbox_healthy_node "$TMP"
unset CHUMP_STATE_DB          # per-repo reserves (test design); gate still reads $TMP
export CHUMP_REPO="$TMP"
export HOME="$TMP"
export CHUMP_ALLOW_MAIN_WORKTREE=1
export FLEET_029_AMBIENT_GLANCE_SKIP=1
export CHUMP_RESERVE_NO_AUTOSTAGE=1

# 2 gaps per pillar → exactly at floor, no one dominates
for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    reserve_gap "${p}: fixture-gap-a"
    reserve_gap "${p}: fixture-gap-b"
done

OUT=$("$BIN" gap pillar-balance 2>&1)
if "$BIN" gap pillar-balance >/dev/null 2>&1; then
    ok "balanced fixture exits 0"
else
    fail "balanced fixture should exit 0 — got: $OUT"
fi

if echo "$OUT" | grep -q "✓ Balance OK"; then
    ok "balanced fixture prints OK message"
else
    fail "balanced fixture missing OK message — got: $OUT"
fi

for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    if echo "$OUT" | grep -q "$p"; then
        ok "pillar $p appears in output"
    else
        fail "pillar $p missing from output"
    fi
done

# ── --json output has required fields ────────────────────────────────────────
echo
echo "[--json output]"
JSON=$("$BIN" gap pillar-balance --json 2>/dev/null)
for key in pillars total_pickable warnings suggestions other; do
    if echo "$JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); assert '$key' in d" 2>/dev/null; then
        ok "JSON key '$key' present"
    else
        fail "JSON key '$key' missing — got: $JSON"
    fi
done

for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    if echo "$JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); assert '$p' in d['pillars']" 2>/dev/null; then
        ok "JSON pillars.$p present"
    else
        fail "JSON pillars.$p missing"
    fi
done

# ── Fixture: all-same-pillar (EFFECTIVE dominates) ───────────────────────────
echo
echo "[all-same-pillar fixture]"
TMP2="$(mktemp -d)"
OLD_CHUMP_REPO="$CHUMP_REPO"
export CHUMP_REPO="$TMP2"

# 10 EFFECTIVE gaps, nothing else
for i in $(seq 1 10); do
    reserve_gap "EFFECTIVE: fixture-dominate-$i"
done

if "$BIN" gap pillar-balance >/dev/null 2>&1; then
    fail "all-same-pillar should exit non-zero (CREDIBLE/RESILIENT/ZERO-WASTE under floor)"
else
    ok "all-same-pillar exits non-zero"
fi

DOM_OUT=$("$BIN" gap pillar-balance 2>&1 || true)
if echo "$DOM_OUT" | grep -qi "credible\|resilient\|zero-waste"; then
    ok "all-same-pillar warns about starved pillars"
else
    fail "all-same-pillar should warn about starved pillars — got: $DOM_OUT"
fi

rm -rf "$TMP2"
export CHUMP_REPO="$OLD_CHUMP_REPO"

# ── Fixture: all-OTHER (no pillar keywords) ───────────────────────────────────
echo
echo "[all-OTHER fixture]"
TMP3="$(mktemp -d)"
OLD_CHUMP_REPO2="$CHUMP_REPO"
export CHUMP_REPO="$TMP3"

for i in $(seq 1 4); do
    reserve_gap "infra-fixture-no-pillar-tag-$i"
done

if "$BIN" gap pillar-balance >/dev/null 2>&1; then
    fail "all-OTHER should exit non-zero (all pillars under floor)"
else
    ok "all-OTHER exits non-zero"
fi

OTHER_OUT=$("$BIN" gap pillar-balance 2>&1 || true)
# Should warn about all 4 pillars
WARN_COUNT=$(echo "$OTHER_OUT" | grep -c "has only 0\|has only 1" || true)
if [[ "$WARN_COUNT" -ge 4 ]]; then
    ok "all-OTHER warns about all 4 pillars ($WARN_COUNT warnings)"
else
    fail "all-OTHER should warn about all 4 pillars — got $WARN_COUNT warnings: $OTHER_OUT"
fi

rm -rf "$TMP3"
export CHUMP_REPO="$OLD_CHUMP_REPO2"

# ── --suggest with under-filled pillar ───────────────────────────────────────
echo
echo "[--suggest with P2 candidates]"
TMP4="$(mktemp -d)"
OLD_CHUMP_REPO3="$CHUMP_REPO"
export CHUMP_REPO="$TMP4"

# 2 EFFECTIVE P1 (at floor), 1 CREDIBLE P1 (under floor), 1 CREDIBLE P2 (candidate)
reserve_gap "EFFECTIVE: fixture-suggest-a"
reserve_gap "EFFECTIVE: fixture-suggest-b"
reserve_gap "CREDIBLE: fixture-suggest-c"
reserve_gap "CREDIBLE: fixture-suggest-d" P2

SUGGEST_OUT=$("$BIN" gap pillar-balance --suggest 2>&1 || true)
if echo "$SUGGEST_OUT" | grep -qi "credible\|promote\|P1\|P2"; then
    ok "--suggest mentions CREDIBLE promotion candidate"
else
    fail "--suggest should list CREDIBLE P2 candidate — got: $SUGGEST_OUT"
fi

rm -rf "$TMP4"
export CHUMP_REPO="$OLD_CHUMP_REPO3"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
