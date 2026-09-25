#!/usr/bin/env bash
# test-gap-closed-pr-cli.sh — acceptance test for INFRA-152.
#
# INFRA-152 was filed slightly before its duplicate INFRA-156 — both ask
# for the same feature: `chump gap set --closed-pr N` and
# `chump gap ship --closed-pr N` accept the flag, persist it to
# .chump/state.db, and emit it to the per-file YAML mirror under
# docs/gaps/<ID>.yaml (post-INFRA-188).
#
# INFRA-156 (PR #637, 2026-04-28) shipped the implementation. INFRA-188
# (PR #731, 2026-05-02) cut the YAML mirror over from monolithic
# docs/gaps.yaml to per-file docs/gaps/<DOMAIN>-<NNN>.yaml. This test
# verifies the acceptance criteria of INFRA-152 still hold against the
# live per-file mirror as it exists on origin/main:
#
#   (1) `chump gap set --help` advertises --closed-pr.
#   (2) `chump gap ship --help` (or its source-of-truth usage in
#        src/main.rs) advertises --closed-pr.
#   (3) At least one per-file YAML under docs/gaps/ contains a
#        numeric `closed_pr:` line emitted by the dump path.
#
# Run from repo root:
#   ./scripts/ci/test-gap-closed-pr-cli.sh
#
# Exits non-zero on any check failure.

set -euo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-152 chump gap --closed-pr acceptance ==="
echo

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

MAIN_RS="$REPO_ROOT/src/main.rs"
# INFRA-1214: use source-grep.sh library instead of inline if/else
source "$SCRIPT_DIR/lib/source-grep.sh"
GAP_STORE_RS=$(find_gap_store_path)
GAPS_DIR="$REPO_ROOT/docs/gaps"

# ── Test 1: src/main.rs `gap set` usage advertises --closed-pr ──────────────
echo "--- Test 1: 'chump gap set' usage advertises --closed-pr ---"
# Look in the help/usage block printed when args fail validation.
# NOTE: capture blocks into variables (not `grep A | grep -q B`) — under
# `set -o pipefail`, a `grep -q` consumer that finds its match on an early
# line exits before the producer finishes writing, so the producer dies of
# SIGPIPE (rc=141) and pipefail turns that into a false failure regardless
# of whether the match was found.
GAP_CMD_BLOCK=$(grep -A 20 "fn .*gap_cmd\|\"gap\".*=>\|\"set\" => {" "$MAIN_RS" 2>/dev/null || true)
GAP_SET_USAGE_BLOCK=$(grep -B 2 -A 30 'chump gap set:' "$MAIN_RS" 2>/dev/null || true)
if echo "$GAP_CMD_BLOCK" | grep -q -- "--closed-pr" \
   || echo "$GAP_SET_USAGE_BLOCK" | grep -q -- "--closed-pr"; then
    ok "src/main.rs documents --closed-pr in 'gap set' usage"
else
    fail "src/main.rs does not document --closed-pr in 'gap set' usage"
fi

# ── Test 2: src/main.rs `gap ship` usage advertises --closed-pr ─────────────
echo "--- Test 2: 'chump gap ship' usage advertises --closed-pr ---"
if grep -B 2 -A 5 'Usage: chump gap ship' "$MAIN_RS" | grep -q -- "--closed-pr"; then
    ok "src/main.rs documents --closed-pr in 'gap ship' usage line"
else
    fail "src/main.rs 'gap ship' usage line missing --closed-pr"
fi

# ── Test 3: GapStore::ship signature accepts Option<i64> closed_pr ──────────
echo "--- Test 3: GapStore::ship accepts closed_pr: Option<i64> ---"
if grep -q "pub fn ship(&self, gap_id: &str, session_id: &str, closed_pr: Option<i64>)" "$GAP_STORE_RS"; then
    ok "GapStore::ship signature plumbs closed_pr through to SQL"
else
    fail "GapStore::ship signature missing closed_pr: Option<i64> param"
fi

# ── Test 4: SetFields struct exposes closed_pr ──────────────────────────────
echo "--- Test 4: SetFields exposes pub closed_pr: Option<i64> ---"
if grep -B 2 -A 1 "pub closed_pr: Option<i64>" "$GAP_STORE_RS" | grep -q "closed_pr"; then
    ok "SetFields.closed_pr field present (gap set --closed-pr binding)"
else
    fail "SetFields struct missing pub closed_pr: Option<i64>"
fi

# ── Test 5: dump_yaml path emits closed_pr: <number> ────────────────────────
echo "--- Test 5: dump_yaml emits 'closed_pr: <n>' for set rows ---"
if grep -q '"  closed_pr: {}\\n"' "$GAP_STORE_RS"; then
    ok "dump_yaml writes 'closed_pr: <n>' line when set"
else
    fail "dump_yaml does not appear to emit 'closed_pr: <n>' line"
fi

# ── Test 6: live per-file YAML mirror contains closed_pr ─────────────────────
echo "--- Test 6: live docs/gaps/*.yaml shows closed_pr round-trip ---"
if [ ! -d "$GAPS_DIR" ]; then
    fail "docs/gaps/ directory not found at $GAPS_DIR"
else
    HITS=$(grep -lE '^  closed_pr: [0-9]+$' "$GAPS_DIR"/*.yaml 2>/dev/null | wc -l | tr -d ' ')
    if [ "${HITS:-0}" -gt 0 ]; then
        ok "$HITS per-file YAML(s) under docs/gaps/ emit numeric closed_pr (post-INFRA-188 path verified)"
    else
        fail "no per-file YAML under docs/gaps/ shows 'closed_pr: <n>' — emit path may be broken"
    fi
fi

# ── Test 7: closed_pr round-trip unit tests in gap_store.rs are present ─────
echo "--- Test 7: gap_store.rs has closed_pr round-trip tests ---"
if grep -q "fn test_set_closed_pr_persists_and_emits_to_yaml" "$GAP_STORE_RS" \
   && grep -q "fn test_ship_with_closed_pr_stamps_pr_number" "$GAP_STORE_RS"; then
    ok "both round-trip tests (set + ship) present"
else
    fail "gap_store.rs missing one or both closed_pr round-trip tests"
fi

# ── Test 8: webhook receiver routes auto-flip through 'gap ship --closed-pr' ─
# CREDIBLE-1073: _auto_flip_gaps_done must invoke the CLI 'chump gap ship'
# with '--closed-pr' for every gap ID extracted from a merged PR — not
# 'gap set' (which bypasses the INFRA-1392 PROOF-OF-MERGE guard and never
# stamps closed_date).
echo "--- Test 8: webhook _auto_flip_gaps_done routes through 'gap ship' + '--closed-pr' (CREDIBLE-1073) ---"
WEBHOOK_PY="$REPO_ROOT/scripts/ops/github-webhook-receiver.py"
if [ ! -f "$WEBHOOK_PY" ]; then
    fail "scripts/ops/github-webhook-receiver.py not found"
else
    FLIP_FN=$(awk '/^def _auto_flip_gaps_done/,/^def _auto_prune_worktree_on_merge/' "$WEBHOOK_PY")
    if echo "$FLIP_FN" | grep -q '"gap", "ship"' \
       && echo "$FLIP_FN" | grep -q -- '"--closed-pr"'; then
        echo "  found: subprocess call uses 'gap ship' with '--closed-pr' argument"
        ok "_auto_flip_gaps_done invokes 'chump gap ship' with the '--closed-pr' argument"
    else
        fail "_auto_flip_gaps_done does not invoke 'chump gap ship' with '--closed-pr'"
    fi
    if echo "$FLIP_FN" | grep -q "gap ship"; then
        ok "_auto_flip_gaps_done logs a line containing 'gap ship' (INFRA-1392 guard visibility)"
    else
        fail "_auto_flip_gaps_done has no log line mentioning 'gap ship'"
    fi
    if echo "$FLIP_FN" | grep -q '"gap", "set"'; then
        fail "_auto_flip_gaps_done still invokes 'gap set' — must route through 'gap ship' only"
    else
        ok "_auto_flip_gaps_done does not invoke 'gap set' for closure"
    fi
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
