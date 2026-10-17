#!/usr/bin/env bash
# scripts/ci/test-dispatch-armed-exit-zero.sh — CREDIBLE-1506
#
# A fully successful zero-touch ship must exit 0. The 2026-10-16 proof run
# (chump dispatch CREDIBLE-301 --auto-merge --backend headless) armed PR #5500,
# which later auto-merged with zero manual steps — yet `chump dispatch` exited 1
# with reason=aborted, because a non-zero bot-merge exit from the post-arm
# INFRA-154 auto-close step (which expects a merge that cannot exist yet) was
# treated as a hard failure even though the PR had already shipped.
#
# This test pins the exit-code contract that fixes that:
#   1. ShipResult has an `Armed` variant distinct from `Aborted`.
#   2. classify_exit() maps Armed -> (exit 0, status "armed") and Shipped ->
#      (exit 0), while Aborted stays exit 1 and Blocked stays exit 2.
#   3. classify_ship() returns Armed when the PR is armed+pending and
#      auto-merge was requested, EVEN WHEN bot-merge.sh exited non-zero;
#      it returns Shipped when the PR merged on any non-zero exit; and it
#      stays Aborted when there is no landed/armed PR (genuine failure).
#   4. The single-exit path in run() carries `status` into both the printed
#      final line and the kind=dispatch_exit ambient event.
#   5. EVENT_REGISTRY.yaml lists `status` in dispatch_exit's fields_required.
#   6. The pure decision functions pass their Rust unit tests (the fixture:
#      an armed-but-unmerged PR makes classify_ship -> Armed -> exit 0).
#
# Pure grep-contract + a scoped `cargo test` on the decision table — no
# network, no real headless child, no gh calls. Mirrors the
# test-dispatch-ship-session-id.sh style.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DISPATCH_RS="${REPO_ROOT}/src/dispatch.rs"
REGISTRY="${REPO_ROOT}/docs/observability/EVENT_REGISTRY.yaml"

FAIL_COUNT=0
ok()   { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }

echo "=== CREDIBLE-1506 dispatch armed-ship exit-code contract ==="
echo

# ── 1. ShipResult::Armed variant exists ──────────────────────────────────────
echo "[1. ShipResult::Armed variant]"
if grep -qE 'Armed \{ pr_number: u64 \}' "$DISPATCH_RS"; then
    ok "ShipResult has an Armed { pr_number } variant"
else
    fail "ShipResult::Armed variant missing from src/dispatch.rs"
fi

# ── 2. classify_exit decision table ──────────────────────────────────────────
echo
echo "[2. classify_exit maps Armed and Shipped to exit 0, Aborted to 1]"
# Exact tuple literals from classify_exit() — (exit_code, line, status_token).
if grep -qF '(0, format!("armed pr=#{pr_number} awaiting merge"), "armed")' "$DISPATCH_RS"; then
    ok "classify_exit: Armed -> (exit 0, status \"armed\")"
else
    fail "classify_exit does not map Armed -> exit 0 / status armed"
fi
if grep -qF '(0, format!("shipped pr=#{pr_number}"), "shipped")' "$DISPATCH_RS"; then
    ok "classify_exit: Shipped -> exit 0"
else
    fail "classify_exit does not map Shipped -> exit 0"
fi
if grep -qF '(1, format!("aborted: {error}"), "failed")' "$DISPATCH_RS"; then
    ok "classify_exit: Aborted -> exit 1 (genuine failure)"
else
    fail "classify_exit does not keep Aborted -> exit 1"
fi

# ── 3. classify_ship trusts PR ground truth over bot-merge exit code ─────────
echo
echo "[3. classify_ship ground-truth decision table]"
_cs="$(awk '/fn classify_ship\(/,/^}/' "$DISPATCH_RS")"
if grep -q 'PrState::Merged' <<<"$_cs" \
   && grep -q 'PrState::Armed' <<<"$_cs" \
   && grep -q 'auto_merge_requested' <<<"$_cs"; then
    ok "classify_ship branches on Merged / Armed+requested ground truth"
else
    fail "classify_ship missing Merged/Armed ground-truth branches"
fi

# ── 4. run() carries status into the final line + ambient event ──────────────
echo
echo "[4. single-exit path reports status]"
if grep -qE 'classify_exit\(&result\)' "$DISPATCH_RS"; then
    ok "run() derives (exit_code, reason, status) via classify_exit"
else
    fail "run() does not call classify_exit"
fi
if grep -qE '"\[dispatch\] \{\} exit=\{\} status=\{\}' "$DISPATCH_RS"; then
    ok "final line prints status= alongside exit="
else
    fail "final [dispatch] line does not print status="
fi
if grep -qE '\\"status\\":\\"\{status\}\\"' "$DISPATCH_RS"; then
    ok "kind=dispatch_exit JSON includes the status field"
else
    fail "dispatch_exit emit is missing the status field"
fi

# ── 5. EVENT_REGISTRY lists status in dispatch_exit fields_required ──────────
echo
echo "[5. EVENT_REGISTRY fields_required]"
# Window the 15 lines after the kind line (the entry's trigger + consumers +
# fields_required all land inside it) and check fields_required lists status.
if grep -A15 'kind: dispatch_exit' "$REGISTRY" \
     | grep -A2 'fields_required' | grep -q 'status'; then
    ok "dispatch_exit fields_required includes status"
else
    fail "dispatch_exit fields_required missing status in EVENT_REGISTRY.yaml"
fi

# ── 6. Behavioral fixture: pure decision functions pass their unit tests ─────
#    The armed-but-unmerged PR fixture is encoded in the Rust unit tests
#    (classify_ship(false, 1, true, Some(5500), PrState::Armed) -> Armed, and
#    classify_exit(Armed) -> exit 0). Run just those so this stays fast; skip
#    gracefully if cargo is unavailable in the environment.
echo
echo "[6. decision-table unit tests]"
if command -v cargo >/dev/null 2>&1; then
    # libtest accepts multiple substring filters AFTER `--` (cargo itself only
    # takes one positional TESTNAME). These three cover the armed-but-unmerged
    # fixture (classify_ship -> Armed) and the exit-code contract (Armed/Shipped
    # -> 0, Aborted -> 1).
    if ( cd "$REPO_ROOT" && cargo test --bin chump --quiet -- \
            classify_ship_armed_pending_is_success_even_when_bot_merge_failed \
            classify_exit_landed_and_armed_are_success \
            classify_exit_genuine_failure_stays_exit_one 2>/dev/null ); then
        ok "classify_ship / classify_exit unit tests pass (armed fixture -> exit 0)"
    else
        fail "classify_ship / classify_exit unit tests failed"
    fi
else
    echo "SKIP: cargo not on PATH — unit-test leg skipped (grep-contract legs still ran)"
fi

echo
if [[ $FAIL_COUNT -eq 0 ]]; then
    echo "=== ALL PASS (CREDIBLE-1506) ==="
    exit 0
else
    echo "=== ${FAIL_COUNT} FAILURE(S) (CREDIBLE-1506) ===" >&2
    exit 1
fi
