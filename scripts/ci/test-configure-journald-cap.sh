#!/usr/bin/env bash
# test-configure-journald-cap.sh — INFRA-7890 smoke test for
# scripts/setup/configure-journald-cap.sh. Runs fully sandboxed (writes into
# a tmpdir via CHUMP_JOURNALD_CONF_DIR) — never touches the real
# /etc/systemd/journald.conf.d.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="${REPO_ROOT}/scripts/setup/configure-journald-cap.sh"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

echo "=== test-configure-journald-cap.sh (INFRA-7890) ==="

# ── Test 1: writes a SystemMaxUse drop-in with the default cap ──────────────
CONF_DIR="${SANDBOX}/journald.conf.d"
if CHUMP_JOURNALD_CONF_DIR="$CONF_DIR" bash "$SCRIPT" >/dev/null 2>&1; then
    if [[ -f "${CONF_DIR}/chump-cap.conf" ]] && grep -q '^SystemMaxUse=1G$' "${CONF_DIR}/chump-cap.conf"; then
        pass "writes drop-in with default SystemMaxUse=1G"
    else
        fail "drop-in missing or missing SystemMaxUse=1G"
    fi
else
    fail "script exited non-zero on first run"
fi

# ── Test 2: honors CHUMP_JOURNALD_MAX_USE override ───────────────────────────
CONF_DIR2="${SANDBOX}/journald.conf.d.2"
CHUMP_JOURNALD_CONF_DIR="$CONF_DIR2" CHUMP_JOURNALD_MAX_USE="500M" bash "$SCRIPT" >/dev/null 2>&1 || true
if grep -q '^SystemMaxUse=500M$' "${CONF_DIR2}/chump-cap.conf" 2>/dev/null; then
    pass "honors CHUMP_JOURNALD_MAX_USE override"
else
    fail "override CHUMP_JOURNALD_MAX_USE=500M not reflected in drop-in"
fi

# ── Test 3: idempotent — re-running with same cap doesn't error ─────────────
if CHUMP_JOURNALD_CONF_DIR="$CONF_DIR" bash "$SCRIPT" >/dev/null 2>&1; then
    pass "re-running with unchanged cap is a clean no-op"
else
    fail "re-run with unchanged cap exited non-zero"
fi

# ── Test 4: dry-run mode does not write the file ─────────────────────────────
CONF_DIR3="${SANDBOX}/journald.conf.d.3"
CHUMP_JOURNALD_CONF_DIR="$CONF_DIR3" CHUMP_JOURNALD_DRY_RUN=1 bash "$SCRIPT" >/dev/null 2>&1 || true
if [[ ! -f "${CONF_DIR3}/chump-cap.conf" ]]; then
    pass "dry-run mode does not write the drop-in"
else
    fail "dry-run mode wrote the drop-in file"
fi

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
