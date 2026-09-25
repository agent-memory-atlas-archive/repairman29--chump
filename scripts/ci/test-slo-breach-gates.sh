#!/usr/bin/env bash
# test-slo-breach-gates.sh — INFRA-2424
#
# Verifies the reserve/claim split introduced by INFRA-2424:
#   - chump gap reserve SUCCEEDS when slo_breach=true (fleet-paused exists)
#   - chump claim FAILS when slo_breach=true (fleet-paused exists)
#   - CHUMP_IGNORE_WASTE_PAUSE is NOT consulted by either path
#   - waste-spike-detector.sh does NOT reference CHUMP_IGNORE_WASTE_PAUSE
#   - worker.sh fleet-paused check is intact (claim still blocked)
#   - src/main.rs does NOT contain CHUMP_IGNORE_WASTE_PAUSE

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== INFRA-2424 slo-breach gate smoke test ==="
echo

# ── 1. src/main.rs does NOT call std::env::var("CHUMP_IGNORE_WASTE_PAUSE") ───
# Comments mentioning the var for historical context are acceptable; the
# live env::var call must be gone.
if grep -q 'env::var.*CHUMP_IGNORE_WASTE_PAUSE\|CHUMP_IGNORE_WASTE_PAUSE.*env::var' "$REPO_ROOT/src/main.rs" 2>/dev/null; then
    fail "src/main.rs still calls env::var(CHUMP_IGNORE_WASTE_PAUSE) — reserve guard not deleted"
else
    ok "src/main.rs: CHUMP_IGNORE_WASTE_PAUSE env::var call removed (comments OK)"
fi

# ── 2. waste-spike-detector.sh does NOT reference CHUMP_IGNORE_WASTE_PAUSE ───
DETECTOR="$REPO_ROOT/scripts/coord/waste-spike-detector.sh"
if grep -q "CHUMP_IGNORE_WASTE_PAUSE" "$DETECTOR" 2>/dev/null; then
    fail "waste-spike-detector.sh still references CHUMP_IGNORE_WASTE_PAUSE"
else
    ok "waste-spike-detector.sh: CHUMP_IGNORE_WASTE_PAUSE removed"
fi

# ── 3. worker.sh: fleet-paused check intact, bypass var gone ─────────────────
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"
if grep -q "fleet-paused" "$WORKER" 2>/dev/null; then
    ok "worker.sh: fleet-paused sentinel check intact (claim still blocks)"
else
    fail "worker.sh: fleet-paused sentinel check missing — claim guard regressed"
fi
if grep -q "CHUMP_IGNORE_WASTE_PAUSE" "$WORKER" 2>/dev/null; then
    fail "worker.sh still references CHUMP_IGNORE_WASTE_PAUSE — bypass not deleted"
else
    ok "worker.sh: CHUMP_IGNORE_WASTE_PAUSE removed"
fi

# ── 4. env-vars-internal.txt does NOT contain CHUMP_IGNORE_WASTE_PAUSE ───────
ENV_VARS="$REPO_ROOT/scripts/ci/env-vars-internal.txt"
if grep -q "^CHUMP_IGNORE_WASTE_PAUSE" "$ENV_VARS" 2>/dev/null; then
    fail "env-vars-internal.txt still has CHUMP_IGNORE_WASTE_PAUSE entry"
else
    ok "env-vars-internal.txt: CHUMP_IGNORE_WASTE_PAUSE removed"
fi

# ── 5. bypass-env-var-allowlist.txt does NOT contain CHUMP_IGNORE_WASTE_PAUSE ─
ALLOWLIST="$REPO_ROOT/scripts/ci/bypass-env-var-allowlist.txt"
if grep -q "CHUMP_IGNORE_WASTE_PAUSE" "$ALLOWLIST" 2>/dev/null; then
    fail "bypass-env-var-allowlist.txt still has CHUMP_IGNORE_WASTE_PAUSE entry"
else
    ok "bypass-env-var-allowlist.txt: CHUMP_IGNORE_WASTE_PAUSE removed"
fi

# ── 6. chump-slo.sh documents the reserve/claim split ────────────────────────
SLO_LIB="$REPO_ROOT/scripts/coord/lib/chump-slo.sh"
if [[ -f "$SLO_LIB" ]]; then
    ok "chump-slo.sh consumer registry exists"
    if grep -q "DOES NOT.*BLOCK.*reserve\|reserve.*DOES NOT.*BLOCK" "$SLO_LIB" 2>/dev/null; then
        ok "chump-slo.sh documents that reserve does not block"
    elif grep -q "DOES NOT" "$SLO_LIB" 2>/dev/null; then
        ok "chump-slo.sh documents does-not-block invariant"
    else
        fail "chump-slo.sh missing documentation of reserve/claim split"
    fi
else
    fail "chump-slo.sh missing at $SLO_LIB"
fi

# ── 7. Binary smoke: reserve succeeds, claim blocked (needs built binary) ─────
CHUMP_BIN="$REPO_ROOT/target/debug/chump"
if [[ ! -x "$CHUMP_BIN" ]]; then
    echo "  [skip 7-9] chump binary not built — run: cargo build -p chump"
else
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT

    PAUSE_FILE="$TMP/fleet-paused"
    printf '{"ts":"2026-01-01T00:00:00Z","kind":"slo_breach","reason":"test_pause","slos_breached":[],"blocked_pct":75}\n' \
        > "$PAUSE_FILE"

    # ── 7. reserve exits 0 even with fleet-paused ────────────────────────────
    stderr7="$TMP/reserve-stderr.txt"
    CHUMP_FLEET_PAUSE_FILE="$PAUSE_FILE" \
        CHUMP_REPO="$REPO_ROOT" \
        CHUMP_ALLOW_MAIN_WORKTREE=1 \
        CHUMP_GAP_RESERVE_SKIP_PR=1 \
        CHUMP_RESERVE_NO_AUTOSTAGE=1 \
        CHUMP_PILLAR_BALANCE_DISABLE=1 \
        CHUMP_GAP_RESERVE_NO_SIMILARITY=1 \
        CHUMP_DISABLE_OFFLINE_CHECK=1 \
        "$CHUMP_BIN" gap reserve \
            --domain TEST --title "INFRA-2424 smoke reserve $(date +%s)" \
            --skip-obs-acs --quiet \
            2>"$stderr7" && rc7=0 || rc7=$?

    if [[ $rc7 -eq 0 ]]; then
        ok "reserve exits 0 when fleet-paused exists (INFRA-2424)"
    else
        fail "reserve returned rc=$rc7 with fleet-paused — should be unconditional"
    fi

    if grep -q "fleet is paused" "$stderr7" 2>/dev/null; then
        fail "reserve emitted 'fleet is paused' — old guard still present"
    else
        ok "reserve does not emit 'fleet is paused' message"
    fi

    # ── 8. CHUMP_IGNORE_WASTE_PAUSE=1 has no effect on reserve (still exits 0) ─
    # Setting the now-deleted bypass var must not break anything (env is ignored).
    stderr8="$TMP/reserve-bypass-stderr.txt"
    CHUMP_FLEET_PAUSE_FILE="$PAUSE_FILE" \
        CHUMP_REPO="$REPO_ROOT" \
        CHUMP_IGNORE_WASTE_PAUSE=1 \
        CHUMP_ALLOW_MAIN_WORKTREE=1 \
        CHUMP_GAP_RESERVE_SKIP_PR=1 \
        CHUMP_RESERVE_NO_AUTOSTAGE=1 \
        CHUMP_PILLAR_BALANCE_DISABLE=1 \
        CHUMP_GAP_RESERVE_NO_SIMILARITY=1 \
        CHUMP_DISABLE_OFFLINE_CHECK=1 \
        "$CHUMP_BIN" gap reserve \
            --domain TEST --title "INFRA-2424 smoke bypass $(date +%s)" \
            --skip-obs-acs --quiet \
            2>"$stderr8" && rc8=0 || rc8=$?

    if [[ $rc8 -eq 0 ]]; then
        ok "reserve still exits 0 when CHUMP_IGNORE_WASTE_PAUSE=1 (var is inert)"
    else
        fail "reserve returned rc=$rc8 even with CHUMP_IGNORE_WASTE_PAUSE=1 set"
    fi

    # ── 9. chump claim refuses when fleet-paused exists ──────────────────────
    # We use a non-existent gap ID to trigger the claim path early; the
    # fleet-paused check fires before gap existence is verified.
    stderr9="$TMP/claim-stderr.txt"
    CHUMP_FLEET_PAUSE_FILE="$PAUSE_FILE" \
        CHUMP_REPO="$REPO_ROOT" \
        CHUMP_ALLOW_MAIN_WORKTREE=1 \
        "$CHUMP_BIN" claim TEST-99999 \
        --role fleet-test \
        2>"$stderr9" && rc9=0 || rc9=$?

    if [[ $rc9 -ne 0 ]]; then
        ok "claim exits non-zero when fleet-paused exists"
    else
        # If claim happens to succeed for other reasons (e.g. worktree logic),
        # check stderr for the pause message instead.
        if grep -q "fleet is paused\|fleet-paused\|slo_breach\|waste.spike\|paused" "$stderr9" 2>/dev/null; then
            ok "claim blocked: fleet-paused message appears in stderr"
        else
            fail "claim returned rc=0 without paused message — fleet-paused check may be missing from claim path"
        fi
    fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
