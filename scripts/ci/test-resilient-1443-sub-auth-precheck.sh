#!/usr/bin/env bash
# scripts/ci/test-resilient-1443-sub-auth-precheck.sh — RESILIENT-1443
#
# Verifies the sub-auth precheck added to worker.sh + operator-recall.sh:
#
#   2026-09-21 CJ incident: after a reboot the claude CLI OAuth session
#   lapsed (not durable across reboot). The worker was configured with
#   CHUMP_AUTH_MODE=oauth but had NO liveness check before dispatching — it
#   silently fell through to the dead free-tier floor while farmer_heartbeat
#   stayed green, shipping 0 PRs for hours (false-healthy).
#
#   1. worker.sh: dead sub (CHUMP_FAKE_SUB_PROBE=dead) emits
#      kind=worker_sub_auth_dead to ambient.jsonl and skips the dispatch
#      path this cycle (never silently falls through).
#   2. worker.sh: live sub (CHUMP_FAKE_SUB_PROBE=live) emits nothing and
#      falls through to dispatch (AC3: resumes on the sub once it recovers).
#   3. worker.sh: precheck is a no-op when CHUMP_AUTH_MODE != oauth (the
#      chump-local-with-API-key path is untouched).
#   4. operator-recall.sh: a single worker_sub_auth_dead event trips the
#      AUTH_DEAD halt condition (threshold=1 — unambiguous "logged out"
#      signal, not a probabilistic storm).
#   5. operator-recall.sh: no worker_sub_auth_dead event → no AUTH_DEAD.
#
# Exit 0 = all pass. Exit 1 = at least one failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"
RECALL="$REPO_ROOT/scripts/dispatch/operator-recall.sh"

PASS=0
FAIL=0
ok()   { echo "[PASS] $*"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $*" >&2; FAIL=$((FAIL+1)); }

[[ -f "$WORKER" ]] || { echo "FATAL: worker.sh missing"; exit 2; }
[[ -f "$RECALL" ]] || { echo "FATAL: operator-recall.sh missing"; exit 2; }

echo "=== RESILIENT-1443 sub-auth precheck test ==="
echo

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# ── Extract the precheck block as a sourceable snippet ──────────────────────
DETECTOR="$TMPDIR_BASE/detector.sh"
awk '/^    # ── RESILIENT-1443: sub-auth precheck/,/^    # ── end RESILIENT-1443/' "$WORKER" \
    | sed '1d;$d' > "$DETECTOR"   # drop the start/end marker comment lines
sed -i.bak 's/^    //' "$DETECTOR" && rm -f "$DETECTOR.bak"

if [[ ! -s "$DETECTOR" ]]; then
    fail "could not extract RESILIENT-1443 block from worker.sh (marker comments moved?)"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# probe_sub_live is defined earlier in worker.sh; extract it too so the
# snippet is self-contained (mirrors the real CI seam: CHUMP_FAKE_SUB_PROBE).
PROBE_FN="$TMPDIR_BASE/probe.sh"
awk '/^probe_sub_live\(\) \{$/,/^}$/' "$WORKER" > "$PROBE_FN"

LOG_FN='log() { printf "[test-log %s] %s\n" "$(date +%H:%M:%S)" "$*" >&2; }'

WRAPPED="$TMPDIR_BASE/wrapped.sh"
{
    echo "$LOG_FN"
    cat "$PROBE_FN"
    echo 'run_precheck() {'
    echo '  local _dispatched=0'
    echo '  for cycle in "$cycle"; do'   # real worker.sh runs this inside a `while` loop; `continue` needs one to bind to
    cat "$DETECTOR"
    echo '    _dispatched=1'
    echo '    echo "DISPATCHED"'
    echo '  done'
    echo '}'
} > "$WRAPPED"

_run_precheck() {
    # $1=CHUMP_AUTH_MODE $2=CHUMP_FAKE_SUB_PROBE $3=cycle $4=ambient_path $5=agent_id
    (
        set -e
        # shellcheck disable=SC1090
        source "$WRAPPED"
        REPO_ROOT="$REPO_ROOT"
        CHUMP_AUTH_MODE="$1"
        CHUMP_FAKE_SUB_PROBE="$2"
        cycle="$3"
        CHUMP_AMBIENT_LOG="$4"
        AGENT_ID="$5"
        CHUMP_SUB_AUTH_PRECHECK_EVERY_CYCLES=1
        run_precheck
    )
}

# ── Test 1: dead sub → emits worker_sub_auth_dead, does NOT reach dispatch ──
AMBIENT1="$TMPDIR_BASE/ambient1.jsonl"
: > "$AMBIENT1"
_out1="$(_run_precheck oauth dead 1 "$AMBIENT1" 1 2>/dev/null || true)"
if echo "$_out1" | grep -q "DISPATCHED"; then
    fail "Test 1: dead sub fell through to dispatch (should pause+continue, never demote silently)"
else
    ok "Test 1: dead sub did NOT fall through to dispatch"
fi
if grep -q '"kind":"worker_sub_auth_dead"' "$AMBIENT1"; then
    ok "Test 1: dead sub emitted kind=worker_sub_auth_dead to ambient.jsonl"
else
    fail "Test 1: no worker_sub_auth_dead event in ambient: $(cat "$AMBIENT1")"
fi
if [[ -f "$REPO_ROOT/.chump-locks/backend-outage/agent-1.sub-auth-dead" ]]; then
    rm -f "$REPO_ROOT/.chump-locks/backend-outage/agent-1.sub-auth-dead"
fi

# ── Test 2: live sub → no event, falls through to dispatch (AC3) ────────────
AMBIENT2="$TMPDIR_BASE/ambient2.jsonl"
: > "$AMBIENT2"
_out2="$(_run_precheck oauth live 1 "$AMBIENT2" 2 2>/dev/null || true)"
if echo "$_out2" | grep -q "DISPATCHED"; then
    ok "Test 2: live sub fell through to dispatch (resumes normally)"
else
    fail "Test 2: live sub incorrectly paused/skipped dispatch"
fi
if grep -q '"kind":"worker_sub_auth_dead"' "$AMBIENT2" 2>/dev/null; then
    fail "Test 2: live sub incorrectly emitted worker_sub_auth_dead"
else
    ok "Test 2: live sub emitted no worker_sub_auth_dead event"
fi

# ── Test 3: CHUMP_AUTH_MODE != oauth → precheck is a no-op ──────────────────
AMBIENT3="$TMPDIR_BASE/ambient3.jsonl"
: > "$AMBIENT3"
_out3="$(_run_precheck api-key dead 1 "$AMBIENT3" 3 2>/dev/null || true)"
if echo "$_out3" | grep -q "DISPATCHED"; then
    ok "Test 3: CHUMP_AUTH_MODE=api-key skips the sub-auth precheck entirely"
else
    fail "Test 3: precheck incorrectly ran under CHUMP_AUTH_MODE=api-key"
fi
if grep -q '"kind":"worker_sub_auth_dead"' "$AMBIENT3" 2>/dev/null; then
    fail "Test 3: precheck emitted worker_sub_auth_dead despite CHUMP_AUTH_MODE!=oauth"
else
    ok "Test 3: no worker_sub_auth_dead event emitted under CHUMP_AUTH_MODE=api-key"
fi

# ── operator-recall.sh: AUTH_DEAD wiring ─────────────────────────────────────
FAKE_HOME="$(mktemp -d)"
FAKE_AMBIENT="$FAKE_HOME/ambient.jsonl"
export CHUMP_ZERO_SHIP_MIN_CYCLES=999999
export CHUMP_AUTONOMY_HALT_MIN_SECS=999999999
export CHUMP_QUEUE_STARVE_SECS=999999999
export CHUMP_RUNNER_GHOST_ONLINE_DETECT=0
export REPO_ROOT

_emit() {
    local kind="$1"
    printf '{"ts":"%s","kind":"%s","agent_id":"test"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$kind" >> "$FAKE_AMBIENT"
}

_run_recall() {
    HOME="$FAKE_HOME" CHUMP_AMBIENT_LOG="$FAKE_AMBIENT" REPO_ROOT="$REPO_ROOT" \
        bash "$RECALL" --check-only
}

# ── Test 4: single worker_sub_auth_dead event trips AUTH_DEAD ───────────────
: > "$FAKE_AMBIENT"
_emit worker_sub_auth_dead
_out4="$(_run_recall 2>&1)"; _rc4=$?
if echo "$_out4" | grep -q "HALT condition=AUTH_DEAD"; then
    ok "Test 4: single worker_sub_auth_dead event tripped AUTH_DEAD"
else
    fail "Test 4: worker_sub_auth_dead did NOT trip AUTH_DEAD: $_out4"
fi
if [[ "$_rc4" -eq 1 ]]; then
    ok "Test 4: --check-only exited 1 on AUTH_DEAD"
else
    fail "Test 4: --check-only expected exit 1, got $_rc4"
fi

# ── Test 5: no worker_sub_auth_dead event → no AUTH_DEAD from this signal ──
: > "$FAKE_AMBIENT"
_out5="$(_run_recall 2>&1)"; _rc5=$?
if echo "$_out5" | grep -q "HALT condition=AUTH_DEAD"; then
    fail "Test 5: AUTH_DEAD tripped with no auth signal present: $_out5"
else
    ok "Test 5: no auth signal present → no AUTH_DEAD"
fi

rm -rf "$FAKE_HOME"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
