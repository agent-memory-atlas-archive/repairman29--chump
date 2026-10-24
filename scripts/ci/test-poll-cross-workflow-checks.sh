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

# ---- Test 6a (CREDIBLE-1562): earlier failure then later success on same SHA -> success (PASS) ----
gh() {
    echo '[
      {"id":101,"name":"audit","status":"completed","conclusion":"failure","started_at":"2026-08-20T00:00:00Z","completed_at":"2026-08-20T00:01:00Z"},
      {"id":102,"name":"audit","status":"completed","conclusion":"success","started_at":"2026-08-20T00:05:00Z","completed_at":"2026-08-20T00:06:00Z"}
    ]'
}
export -f gh
out="$("$POLL" --sha deadbeef --check "audit" --timeout-s 5 --interval-s 1)"
if echo "$out" | grep -qx "audit=success"; then
    ok "CREDIBLE-1562: earlier failure then later success classifies success"
else
    fail "CREDIBLE-1562 earlier-failure-later-success: got: $out"
fi

# ---- Test 6b (CREDIBLE-1562): earlier success then later failure on same SHA -> failure (FAIL) ----
gh() {
    echo '[
      {"id":201,"name":"audit","status":"completed","conclusion":"success","started_at":"2026-08-20T00:00:00Z","completed_at":"2026-08-20T00:01:00Z"},
      {"id":202,"name":"audit","status":"completed","conclusion":"failure","started_at":"2026-08-20T00:05:00Z","completed_at":"2026-08-20T00:06:00Z"}
    ]'
}
export -f gh
out="$("$POLL" --sha deadbeef --check "audit" --timeout-s 5 --interval-s 1)"
if echo "$out" | grep -qx "audit=failure"; then
    ok "CREDIBLE-1562: earlier success then later failure classifies failure"
else
    fail "CREDIBLE-1562 earlier-success-later-failure: got: $out"
fi

# ---- Test 7 (RESILIENT-1617): audit aggregate check-run absent, shards in_progress ----
# The `audit` aggregate job gets no check-run until its shard matrix finishes,
# so at timeout there is no check-run named `audit` — only `audit-shard (N)`.
# The shard members mark the lane SEEN-but-running: poll must emit
# `audit=in_progress`, and the aggregator must then classify PENDING (exit 2),
# NOT fail-close to failure. Regression guard for the #5565 false-FAIL class.
AGG="$REPO_ROOT/scripts/ci/aggregator-verified.sh"
gh() {
    if [[ "${1:-}" == "run" ]]; then
        # gh run list --workflow audit.yml --commit SHA --json status
        echo '[{"status":"in_progress"}]'
    else
        # gh api .../check-runs  — shards running, no `audit` aggregate yet
        echo '[
          {"name":"audit-shard (1)","status":"in_progress","started_at":"2026-10-17T18:54:00Z"},
          {"name":"audit-shard (2)","status":"in_progress","started_at":"2026-10-17T18:54:00Z"}
        ]'
    fi
}
export -f gh
out="$("$POLL" --sha deadbeef --check "audit" --timeout-s 2 --interval-s 1 2>/dev/null)"
if echo "$out" | grep -qx "audit=in_progress"; then
    ok "shards in_progress + no audit check-run -> audit=in_progress (seen, not fail-closed)"
else
    fail "shards in_progress: got: $out"
fi
# and the aggregator classifies that PENDING (exit 2), never FAIL
agg_rc=0
"$AGG" --lane "audit=in_progress" >/dev/null 2>&1 || agg_rc=$?
if [[ "$agg_rc" -eq 2 ]]; then
    ok "audit=in_progress aggregates to PENDING (exit 2)"
else
    fail "expected aggregator exit 2 (PENDING) for audit=in_progress, got exit $agg_rc"
fi

# ---- Test 7b (RESILIENT-1617): shards gone, aggregate not posted, workflow still running ----
# Transient where every shard completed but the `audit` aggregate check-run has
# not posted yet; the backing audit.yml run is still not completed, so the lane
# stays SEEN-but-running (in_progress), never fail-closed.
gh() {
    if [[ "${1:-}" == "run" ]]; then
        echo '[{"status":"in_progress"}]'
    else
        echo '[]'
    fi
}
export -f gh
out="$("$POLL" --sha deadbeef --check "audit" --timeout-s 2 --interval-s 1 2>/dev/null)"
if echo "$out" | grep -qx "audit=in_progress"; then
    ok "no check-runs but audit.yml run still running -> audit=in_progress (workflow-run fallback)"
else
    fail "workflow-run fallback: got: $out"
fi

# ---- Test 8 (RESILIENT-1617): no audit run exists at all -> failure (fail-closed stays) ----
# No check-runs and no audit.yml workflow run for the SHA: the lane is genuinely
# never-seen, so fail-closed behavior is preserved — poll emits failure and the
# aggregator classifies FAIL (exit 1).
gh() {
    if [[ "${1:-}" == "run" ]]; then
        echo '[]'
    else
        echo '[]'
    fi
}
export -f gh
out="$("$POLL" --sha deadbeef --check "audit" --timeout-s 2 --interval-s 1 2>/dev/null)"
if echo "$out" | grep -qx "audit=failure"; then
    ok "no audit run at all -> audit=failure (fail-closed stays)"
else
    fail "no-audit-run fail-closed: got: $out"
fi
agg_rc=0
"$AGG" --lane "audit=failure" >/dev/null 2>&1 || agg_rc=$?
if [[ "$agg_rc" -eq 1 ]]; then
    ok "audit=failure aggregates to FAIL (exit 1)"
else
    fail "expected aggregator exit 1 (FAIL) for audit=failure, got exit $agg_rc"
fi

# ---- Test 9 (CREDIBLE-1560): neutral conclusion on audit and ACP smoke maps to failure ----
gh() {
    echo '[
      {"id":301,"name":"audit","status":"completed","conclusion":"neutral","started_at":"2026-10-19T00:00:00Z","completed_at":"2026-10-19T00:01:00Z"},
      {"id":302,"name":"ACP protocol smoke test (Zed / JetBrains compatible)","status":"completed","conclusion":"neutral","started_at":"2026-10-19T00:00:00Z","completed_at":"2026-10-19T00:01:00Z"}
    ]'
}
export -f gh
out="$("$POLL" --sha deadbeef --check "audit" --check "ACP protocol smoke test (Zed / JetBrains compatible)" --timeout-s 5 --interval-s 1)"
if echo "$out" | grep -qx "audit=failure" && echo "$out" | grep -qx "ACP protocol smoke test (Zed / JetBrains compatible)=failure"; then
    ok "CREDIBLE-1560: neutral conclusion on audit and ACP smoke maps to failure"
else
    fail "CREDIBLE-1560 neutral mapping: got: $out"
fi
agg_rc=0
"$AGG" --lane "audit=failure" --lane "ACP protocol smoke test (Zed / JetBrains compatible)=failure" >/dev/null 2>&1 || agg_rc=$?
if [[ "$agg_rc" -eq 1 ]]; then
    ok "CREDIBLE-1560: neutral-mapped cross-workflow lanes aggregate to FAIL (exit 1)"
else
    fail "CREDIBLE-1560 aggregator exit code: expected 1, got $agg_rc"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
