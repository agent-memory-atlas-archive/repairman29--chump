#!/usr/bin/env bash
# test-poll-cross-workflow-checks.sh — CREDIBLE-269 (SHIP-INFRA 1/7)
#
# Proves scripts/ci/poll-cross-workflow-checks.sh correctly resolves
# cross-workflow check-run conclusions (audit, ACP protocol smoke test) by
# stubbing `gh api ... check-runs` with canned JSON. Also proves the
# fail-closed timeout path never leaves a lane "in_progress".
#
# Run locally: bash scripts/ci/test-poll-cross-workflow-checks.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
POLL="$REPO_ROOT/scripts/ci/poll-cross-workflow-checks.sh"

[[ -x "$POLL" ]] || { echo "FATAL: $POLL not found or not executable"; exit 2; }

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== CREDIBLE-269 poll-cross-workflow-checks.sh guard ==="
echo

# ---- Test 1: both checks already completed+success on first poll ----
gh() {
    echo '[
      {"name":"audit","status":"completed","conclusion":"success","started_at":"2026-08-20T00:00:00Z"},
      {"name":"ACP protocol smoke test (Zed / JetBrains compatible)","status":"completed","conclusion":"success","started_at":"2026-08-20T00:00:00Z"}
    ]'
}
export -f gh
out="$("$POLL" --sha deadbeef --check "audit" --check "ACP protocol smoke test (Zed / JetBrains compatible)" --timeout-s 5 --interval-s 1)"
if echo "$out" | grep -qx "audit=success" && echo "$out" | grep -qx "ACP protocol smoke test (Zed / JetBrains compatible)=success"; then
    ok "both checks success -> success,success"
else
    fail "both checks success: got: $out"
fi

# ---- Test 2: one check failed ----
gh() {
    echo '[
      {"name":"audit","status":"completed","conclusion":"failure","started_at":"2026-08-20T00:00:00Z"},
      {"name":"ACP protocol smoke test (Zed / JetBrains compatible)","status":"completed","conclusion":"success","started_at":"2026-08-20T00:00:00Z"}
    ]'
}
export -f gh
out="$("$POLL" --sha deadbeef --check "audit" --check "ACP protocol smoke test (Zed / JetBrains compatible)" --timeout-s 5 --interval-s 1)"
if echo "$out" | grep -qx "audit=failure"; then
    ok "audit failure surfaces as failure"
else
    fail "audit failure: got: $out"
fi

# ---- Test 3: cancelled + skipped map correctly ----
gh() {
    echo '[
      {"name":"audit","status":"completed","conclusion":"cancelled","started_at":"2026-08-20T00:00:00Z"},
      {"name":"ACP protocol smoke test (Zed / JetBrains compatible)","status":"completed","conclusion":"skipped","started_at":"2026-08-20T00:00:00Z"}
    ]'
}
export -f gh
out="$("$POLL" --sha deadbeef --check "audit" --check "ACP protocol smoke test (Zed / JetBrains compatible)" --timeout-s 5 --interval-s 1)"
if echo "$out" | grep -qx "audit=cancelled" && echo "$out" | grep -qx "ACP protocol smoke test (Zed / JetBrains compatible)=skipped"; then
    ok "cancelled/skipped conclusions map through"
else
    fail "cancelled/skipped: got: $out"
fi

# ---- Test 4: missing check-run entirely -> fail-closed after timeout, never "in_progress" ----
gh() { echo '[]'; }
export -f gh
out="$("$POLL" --sha deadbeef --check "audit" --timeout-s 2 --interval-s 1 2>/dev/null)"
if echo "$out" | grep -qx "audit=failure"; then
    ok "missing check-run times out fail-closed (not left in_progress)"
else
    fail "missing check-run timeout: got: $out"
fi

# ---- Test 4b (RESILIENT-1561): still running at timeout -> in_progress (pending), not failure ----
gh() { echo '[{"name":"audit","status":"in_progress","started_at":"2026-08-20T00:00:00Z"}]'; }
export -f gh
out="$("$POLL" --sha deadbeef --check "audit" --timeout-s 2 --interval-s 1 2>/dev/null)"
if echo "$out" | grep -qx "audit=in_progress"; then
    ok "still-running lane at timeout stays pending (no false-FAIL)"
else
    fail "still-running timeout: got: $out"
fi

# ---- Test 5: still in_progress on first poll, resolves on second ----
POLL_COUNT_FILE="$(mktemp)"
export POLL_COUNT_FILE
echo 0 > "$POLL_COUNT_FILE"
gh() {
    n=$(cat "$POLL_COUNT_FILE")
    n=$((n + 1))
    echo "$n" > "$POLL_COUNT_FILE"
    if [[ "$n" -lt 2 ]]; then
        echo '[{"name":"audit","status":"in_progress","started_at":"2026-08-20T00:00:00Z"}]'
    else
        echo '[{"name":"audit","status":"completed","conclusion":"success","started_at":"2026-08-20T00:00:00Z"}]'
    fi
}
export -f gh
out="$("$POLL" --sha deadbeef --check "audit" --timeout-s 10 --interval-s 1)"
rm -f "$POLL_COUNT_FILE"
if echo "$out" | grep -qx "audit=success"; then
    ok "resolves on later poll once check completes"
else
    fail "later-poll resolution: got: $out"
fi

# ---- Test 6: RESILIENT-338 failure-then-success retry pair -> lane reads success ----
# The retry (success) can report an EARLIER started_at than the failed attempt,
# so sort_by(.started_at)|last would pick the failure. ANY completed success for
# the SHA must win, else the sole-required `verified` aggregator blocks a
# mergeable PR (10 armed PRs hang). Failure sorts LAST here on purpose.
gh() {
    echo '[
      {"name":"audit","status":"completed","conclusion":"success","started_at":"2026-08-20T00:00:00Z"},
      {"name":"audit","status":"completed","conclusion":"failure","started_at":"2026-08-20T00:05:00Z"}
    ]'
}
export -f gh
out="$("$POLL" --sha deadbeef --check "audit" --timeout-s 5 --interval-s 1)"
if echo "$out" | grep -qx "audit=success"; then
    ok "failure-then-success retry pair reads success (ANY success wins)"
else
    fail "retry-to-success: got: $out"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
