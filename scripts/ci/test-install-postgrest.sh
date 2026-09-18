#!/usr/bin/env bash
# scripts/ci/test-install-postgrest.sh — INFRA-7303
#
# Verifies install-postgrest.sh (INFRA-6804 / INFRA-3631 slice):
#   AC1: installs the postgrest binary if not already present
#   AC2: writes ~/.chump/postgrest.conf pointed at chump_fleet via authenticator
#   AC3: config is written only once — re-run is a no-op, exits 0
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$REPO_ROOT/scripts/setup/install-postgrest.sh"

PASS=0
FAIL=0
FAILURES=()

pass() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); FAILURES+=("$1: $2"); printf '  FAIL  %s — %s\n' "$1" "$2"; }

[ -f "$TARGET" ] || { echo "FATAL: $TARGET not found"; exit 1; }

# T1: syntax check
if bash -n "$TARGET" 2>/dev/null; then
    pass "T1: install-postgrest.sh syntax OK"
else
    fail "T1" "bash -n failed on $TARGET"
fi

TMP_STATE="$(mktemp -d)"
TMP_NODE="$(mktemp -d)"
cleanup() { rm -rf "$TMP_STATE" "$TMP_NODE"; }
trap cleanup EXIT

# T2: first run installs binary + writes conf pointed at chump_fleet/authenticator, exits 0
out1="$(CHUMP_STATE_DIR="$TMP_STATE" CHUMP_NODE_DIR="$TMP_NODE" bash "$TARGET" 2>&1)"
rc1=$?
conf="$TMP_STATE/postgrest.conf"
if [ "$rc1" -eq 0 ] && [ -f "$conf" ]; then
    pass "T2: first run exits 0 and writes postgrest.conf"
else
    fail "T2" "rc=$rc1 conf_exists=$([ -f "$conf" ] && echo yes || echo no) — output: $out1"
fi

# T3: conf points at chump_fleet DB via the authenticator role
if grep -q 'db-uri' "$conf" 2>/dev/null && grep -q 'chump_authenticator' "$conf" 2>/dev/null && grep -q '/chump_fleet' "$conf" 2>/dev/null; then
    pass "T3: postgrest.conf db-uri targets chump_fleet via chump_authenticator"
else
    fail "T3" "postgrest.conf missing expected db-uri content: $(cat "$conf" 2>/dev/null)"
fi

# T4: second run is a no-op — conf unchanged, exits 0
sum_before="$(md5sum "$conf" 2>/dev/null)"
out2="$(CHUMP_STATE_DIR="$TMP_STATE" CHUMP_NODE_DIR="$TMP_NODE" bash "$TARGET" 2>&1)"
rc2=$?
sum_after="$(md5sum "$conf" 2>/dev/null)"
if [ "$rc2" -eq 0 ] && [ "$sum_before" = "$sum_after" ]; then
    pass "T4: second run is idempotent no-op, exits 0"
else
    fail "T4" "rc=$rc2 sum_before=[$sum_before] sum_after=[$sum_after] — output: $out2"
fi

echo
echo "=== $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    printf '%s\n' "${FAILURES[@]}"
    exit 1
fi
exit 0
