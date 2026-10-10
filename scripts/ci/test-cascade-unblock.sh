#!/usr/bin/env bash
# scripts/ci/test-cascade-unblock.sh — INFRA-2070 (META-118 sub-gap 4)
#
# Smoke tests for cascade-unblock-detector.sh
#
# Tests:
#   1. SKIP env → silent no-op
#   2. No merged fix PRs → exit clean (no ambient emit)
#   3. Fix PR merged + 2 blocked PRs with same signature → gh pr update-branch called for both
#      + kind=cascade_unblocked emitted with matched_pr_numbers including both
#   4. Safety guard: PR with CHUMP_HOLD label → cascade_unblock_skipped reason=chump_hold_label
#   5. Safety guard: rebase conflict → cascade_unblock_skipped reason=rebase_conflict
#   6. Rate limit: more PRs than CHUMP_UNBLOCK_RATE_LIMIT → stops at limit
#   RESILIENT-1521 generic stale sweep (no wedge_auto_fix label / sibling needed):
#   7. BLOCKED + DIRTY PRs stale vs main → update-branch'd; real conflict escalated
#   8. Refreshed PR still BLOCKED but up to date → routed to ci-audit once, no re-loop
#   9. BLOCKED PR not stale (behind_by=0, never refreshed) → untouched

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$(( PASS + 1 )); }
fail() { echo "  FAIL: $1"; FAIL=$(( FAIL + 1 )); FAILS+=("$1"); }

echo "=== INFRA-2070 cascade-unblock-detector tests ==="

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
DETECTOR="$REPO_ROOT/scripts/coord/cascade-unblock-detector.sh"

[[ -x "$DETECTOR" ]] || chmod +x "$DETECTOR"
[[ -f "$DETECTOR" ]] || { echo "FATAL: $DETECTOR not found"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset CHUMP_REPO CHUMP_LOCK_DIR CHUMP_AMBIENT_LOG

FAKE="$TMP/repo"
mkdir -p "$FAKE/.chump-locks" "$FAKE/.git"
# Minimal git stub so git rev-parse --show-toplevel returns FAKE
echo "gitdir: $FAKE/.git" > "$FAKE/.git/config"

AMBIENT="$FAKE/.chump-locks/ambient.jsonl"

# ── Mock gh binary ─────────────────────────────────────────────────────────────
# Emulates the gh commands used by cascade-unblock-detector.sh:
#   gh pr list --state merged --label wedge_auto_fix ...  → JSON array
#   gh pr view N --json comments ...                      → JSON (no recent comments)
#   gh pr view N --json labels ...                        → JSON (labels list)
#   gh pr update-branch N                                 → exit 0 (success)
#
# Test-specific behavior injected via $FAKE/gh_behavior:
#   "hold_label:<N>"       → gh pr view N labels returns CHUMP_HOLD
#   "conflict_pr:<N>"      → gh pr update-branch N exits 1
#   "merged_prs:<json>"    → override merged PR list

MOCK_GH="$TMP/mock_gh"
cat > "$MOCK_GH" <<'GHEOF'
#!/usr/bin/env bash
# Mock gh binary for cascade-unblock tests.
# The detector does NOT use --jq flags (uses python3 for parsing), so this mock
# returns raw JSON for --json <field> calls.

FAKE_DIR="${CHUMP_FAKE_DIR:-/tmp/fake}"
BEHAVIOR_FILE="$FAKE_DIR/gh_behavior"

read_behavior() {
    local key="$1"
    grep -s "^${key}:" "$BEHAVIOR_FILE" | head -1 | cut -d: -f2- || true
}

# Extract first bare integer argument as PR number
get_pr_num() {
    for a in "$@"; do
        [[ "$a" =~ ^[0-9]+$ ]] && echo "$a" && return
    done
}

# Build arg string for pattern matching (strips env-var prefixes)
ARGS="$*"

case "$ARGS" in
    *"pr list"*"--state open"*)
        read_behavior "open_prs" | grep . || printf '[]\n'
        ;;
    *"api"*"compare/"*)
        # head sha encodes the PR: "head<N>" -> behind_by from behavior key behind_<N>
        head="${ARGS##*...}"; n="${head#head}"
        b="$(read_behavior "behind_$n")"
        printf '{"behind_by":%s,"merge_base_commit":{"sha":"mb%s"}}\n' "${b:-0}" "$(read_behavior "main_sha")"
        ;;
    *"pr list"*"merged"*"wedge_auto_fix"*|*"pr list"*"wedge_auto_fix"*"merged"*)
        override="$(read_behavior "merged_prs")"
        if [[ -n "$override" ]]; then
            printf '%s\n' "$override"
        else
            now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            printf '[{"number":100,"mergedAt":"%s","title":"fix: wedge_auto_fix: signature_hash=abc123"}]\n' "$now"
        fi
        ;;
    *"pr view"*"comments"*)
        # Return empty comments list (no operator activity by default)
        printf '{"comments":[]}\n'
        ;;
    *"pr view"*"labels"*)
        pr_num="$(get_pr_num "$@")"
        hold_prs="$(read_behavior "hold_label" || true)"
        if [[ -n "$pr_num" && -n "$hold_prs" ]] && \
           printf '%s' "$hold_prs" | tr ',' '\n' | grep -qx "$pr_num"; then
            printf '{"labels":[{"name":"CHUMP_HOLD"}]}\n'
        else
            printf '{"labels":[]}\n'
        fi
        ;;
    *"api"*"/protection"*)
        printf '{"required_status_checks":{"strict":true}}\n'
        ;;
    *"pr update-branch"*)
        pr_num="$(get_pr_num "$@")"
        if [[ -n "$pr_num" ]]; then
            printf '%s\n' "$pr_num" >> "$FAKE_DIR/update_branch_calls"
        fi
        conflict_prs="$(read_behavior "conflict_pr" || true)"
        if [[ -n "$pr_num" && -n "$conflict_prs" ]] && \
           printf '%s' "$conflict_prs" | tr ',' '\n' | grep -qx "$pr_num"; then
            exit 1
        fi
        exit 0
        ;;
    *"pr list"*)
        printf '[]\n'
        ;;
    *)
        printf '[]\n'
        ;;
esac
exit 0
GHEOF
chmod +x "$MOCK_GH"

run_detector() {
    cd "$FAKE" || return 2
    env CHUMP_REPO="$FAKE" \
        CHUMP_REPO_ROOT="$FAKE" \
        CHUMP_AMBIENT_LOG="$AMBIENT" \
        CHUMP_UNBLOCK_TEST_GH="$MOCK_GH" \
        CHUMP_FAKE_DIR="$FAKE" \
        CHUMP_UNBLOCK_PR_LOOKBACK_S=7200 \
        CHUMP_UNBLOCK_LOOKBACK_S=600 \
        "$@" \
        bash "$DETECTOR" 2>&1
    local rc=$?
    cd - >/dev/null
    return "$rc"
}

emit_pr_failed() {
    local pr_num="$1" sig="$2"
    printf '{"ts":"%s","kind":"pr_failed","source":"test","pr_number":%d,"failure_signature":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$pr_num" "$sig" \
        >> "$AMBIENT"
}

# ── Test 1: SKIP env → no-op ─────────────────────────────────────────────────
echo "--- Test 1: CHUMP_UNBLOCK_SKIP=1 → no-op ---"
> "$AMBIENT"
OUT="$(run_detector CHUMP_UNBLOCK_SKIP=1)"
if echo "$OUT" | grep -q "skipped"; then
    ok "SKIP env → no-op with message"
else
    fail "expected skip message (got: $OUT)"
fi

# ── Test 2: No merged fix PRs → exit clean ────────────────────────────────────
echo "--- Test 2: no merged fix PRs → clean exit ---"
> "$AMBIENT"
# Override merged PRs to empty list
printf 'merged_prs:[]\n' > "$FAKE/gh_behavior"
OUT="$(run_detector)" || true
# No cascade_unblocked should be emitted
if ! grep -q '"kind":"cascade_unblocked"' "$AMBIENT"; then
    ok "no fix PRs → no cascade_unblocked emit"
else
    fail "unexpected cascade_unblocked emit (ambient=$(cat "$AMBIENT"))"
fi
rm -f "$FAKE/gh_behavior"

# ── Test 3: Core flow — fix PR + 2 blocked PRs → both rebased ────────────────
echo "--- Test 3: fix PR merged + 2 matched blocked PRs → both rebased ---"
> "$AMBIENT"
> "$FAKE/update_branch_calls"
rm -f "$FAKE/gh_behavior"

# Synth: 2 open PRs with pr_failed events matching signature abc123
emit_pr_failed 201 "abc123"
emit_pr_failed 202 "abc123"

# Default mock gh returns fix PR #100 with signature_hash=abc123
OUT="$(run_detector)" || true

# Assert gh pr update-branch called for both PR 201 and 202
CALLS="$(cat "$FAKE/update_branch_calls" 2>/dev/null || echo "")"
if printf '%s' "$CALLS" | grep -qx "201" && printf '%s' "$CALLS" | grep -qx "202"; then
    ok "gh pr update-branch called for both PR 201 and 202"
else
    fail "expected update-branch for 201+202, got calls: $(printf '%s' "$CALLS" | tr '\n' ',')"
fi

# Assert cascade_unblocked emitted with matched_pr_numbers including both PRs
UNBLOCKED="$(grep '"kind":"cascade_unblocked"' "$AMBIENT" | tail -1)"
if [[ -n "$UNBLOCKED" ]]; then
    ok "kind=cascade_unblocked emitted"
    if printf '%s' "$UNBLOCKED" | grep -q '"matched_pr_numbers"'; then
        ok "cascade_unblocked has matched_pr_numbers field"
    else
        fail "cascade_unblocked missing matched_pr_numbers (event: $UNBLOCKED)"
    fi
    # Check matched count = 2
    if printf '%s' "$UNBLOCKED" | python3 -c "
import json, sys
d=json.loads(sys.stdin.read())
nums=d.get('matched_pr_numbers','')
count=len([x for x in nums.split(',') if x.strip()])
sys.exit(0 if count == 2 else 1)
" 2>/dev/null; then
        ok "cascade_unblocked matched_pr_numbers=[2 PRs]"
    else
        fail "cascade_unblocked matched_pr_numbers did not contain 2 entries (event: $UNBLOCKED)"
    fi
    if printf '%s' "$UNBLOCKED" | grep -q '"source_pr":100'; then
        ok "cascade_unblocked source_pr=100"
    else
        fail "cascade_unblocked source_pr wrong (event: $UNBLOCKED)"
    fi
else
    fail "kind=cascade_unblocked not emitted (ambient: $(cat "$AMBIENT"))"
fi

# ── Test 4: Safety — CHUMP_HOLD label → skipped ──────────────────────────────
echo "--- Test 4: PR with CHUMP_HOLD label → cascade_unblock_skipped ---"
> "$AMBIENT"
> "$FAKE/update_branch_calls"
# PR 203 has CHUMP_HOLD, PR 204 is normal
printf 'hold_label:203\n' > "$FAKE/gh_behavior"
emit_pr_failed 203 "abc123"
emit_pr_failed 204 "abc123"

OUT="$(run_detector)" || true

# PR 203 should be skipped
SKIPPED_203="$(grep '"kind":"cascade_unblock_skipped"' "$AMBIENT" | grep '"pr_number":203')"
if [[ -n "$SKIPPED_203" ]] && printf '%s' "$SKIPPED_203" | grep -q '"reason":"chump_hold_label"'; then
    ok "PR 203 with CHUMP_HOLD → cascade_unblock_skipped reason=chump_hold_label"
else
    fail "expected cascade_unblock_skipped reason=chump_hold_label for PR 203 (ambient: $(cat "$AMBIENT"))"
fi

# PR 204 should still be rebased (no hold)
CALLS="$(cat "$FAKE/update_branch_calls" 2>/dev/null || echo "")"
if printf '%s' "$CALLS" | grep -qx "204"; then
    ok "PR 204 (no hold) → gh pr update-branch called"
else
    fail "expected update-branch for PR 204 (calls: $(printf '%s' "$CALLS" | tr '\n' ','))"
fi
rm -f "$FAKE/gh_behavior"

# ── Test 5: Safety — rebase conflict → cascade_unblock_skipped ───────────────
echo "--- Test 5: rebase conflict → cascade_unblock_skipped reason=rebase_conflict ---"
> "$AMBIENT"
> "$FAKE/update_branch_calls"
# PR 205 will conflict; PR 206 is normal
printf 'conflict_pr:205\n' > "$FAKE/gh_behavior"
emit_pr_failed 205 "abc123"
emit_pr_failed 206 "abc123"

OUT="$(run_detector)" || true

SKIPPED_205="$(grep '"kind":"cascade_unblock_skipped"' "$AMBIENT" | grep '"pr_number":205')"
if [[ -n "$SKIPPED_205" ]] && printf '%s' "$SKIPPED_205" | grep -q '"reason":"rebase_conflict"'; then
    ok "conflict PR 205 → cascade_unblock_skipped reason=rebase_conflict"
else
    fail "expected cascade_unblock_skipped reason=rebase_conflict for PR 205 (ambient: $(cat "$AMBIENT"))"
fi

# PR 206 should succeed
CALLS="$(cat "$FAKE/update_branch_calls" 2>/dev/null || echo "")"
if printf '%s' "$CALLS" | grep -qx "206"; then
    ok "PR 206 (no conflict) → gh pr update-branch called"
else
    fail "expected update-branch for PR 206 (calls: $(printf '%s' "$CALLS" | tr '\n' ','))"
fi
rm -f "$FAKE/gh_behavior"

# ── Test 6: Rate limit — more PRs than limit ──────────────────────────────────
echo "--- Test 6: rate limit respected ---"
> "$AMBIENT"
> "$FAKE/update_branch_calls"
rm -f "$FAKE/gh_behavior"

# Synth 5 PRs with matching signature
for n in 301 302 303 304 305; do
    emit_pr_failed "$n" "abc123"
done

OUT="$(run_detector CHUMP_UNBLOCK_RATE_LIMIT=3)" || true

CALLS="$(cat "$FAKE/update_branch_calls" 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$CALLS" -le 3 ]]; then
    ok "rate limit 3 respected: only $CALLS update-branch calls"
else
    fail "rate limit 3 exceeded: $CALLS update-branch calls fired"
fi

# At least one rate_limit_reached skip event
RATE_SKIPS="$(grep '"reason":"rate_limit_reached"' "$AMBIENT" | wc -l | tr -d ' ')"
if [[ "$RATE_SKIPS" -ge 1 ]]; then
    ok "cascade_unblock_skipped reason=rate_limit_reached emitted"
else
    fail "expected cascade_unblock_skipped reason=rate_limit_reached (ambient: $(cat "$AMBIENT"))"
fi

# ── RESILIENT-1521 generic stale sweep ───────────────────────────────────────
STATE="$FAKE/state.tsv"
open_prs() {  # args: "num:STATE" ...
    local out="[" first=1 a
    for a in "$@"; do
        [[ $first == 1 ]] || out+=","; first=0
        out+="{\"number\":${a%%:*},\"mergeStateStatus\":\"${a#*:}\",\"baseRefName\":\"main\",\"headRefOid\":\"head${a%%:*}\"}"
    done
    printf '%s]' "$out"
}
sweep_env() { run_detector CHUMP_UNBLOCK_STATE="$STATE" "$@"; }

echo "--- Test 7: stale BLOCKED/DIRTY PRs update-branch'd without any wedge label ---"
> "$AMBIENT"; > "$FAKE/update_branch_calls"; rm -f "$STATE"
{
    printf 'merged_prs:[]\n'
    printf 'open_prs:%s\n' "$(open_prs 5112:BLOCKED 5136:BLOCKED 5129:DIRTY 5150:CLEAN)"
    printf 'behind_5112:3\nbehind_5136:3\nbehind_5129:3\nbehind_5150:3\nmain_sha:A\n'
    printf 'conflict_pr:5129\n'
} > "$FAKE/gh_behavior"
sweep_env >/dev/null || true
CALLS="$(cat "$FAKE/update_branch_calls")"
if printf '%s' "$CALLS" | grep -qx 5112 && printf '%s' "$CALLS" | grep -qx 5136 && printf '%s' "$CALLS" | grep -qx 5129; then
    ok "stale BLOCKED (5112, 5136) and DIRTY (5129) all attempted"
else
    fail "expected update-branch for 5112/5136/5129 (calls: $(printf '%s' "$CALLS" | tr '\n' ','))"
fi
if printf '%s' "$CALLS" | grep -qx 5150; then fail "CLEAN PR 5150 must not be touched"; else ok "CLEAN PR untouched"; fi
if grep '"kind":"cascade_unblock_skipped"' "$AMBIENT" | grep '"pr_number":5129' | grep -q '"reason":"rebase_conflict"'; then
    ok "DIRTY conflict 5129 escalated as rebase_conflict (not force-resolved)"
else
    fail "expected rebase_conflict skip for 5129 (ambient: $(cat "$AMBIENT"))"
fi
# conflict is not retried until main moves again
> "$FAKE/update_branch_calls"
sweep_env >/dev/null || true
if grep -qx 5129 "$FAKE/update_branch_calls"; then fail "conflicted PR 5129 re-attempted on same base"; else ok "conflict not re-looped on same base"; fi

echo "--- Test 8: refreshed PR still BLOCKED on fresh base → ci-audit once ---"
> "$AMBIENT"; > "$FAKE/update_branch_calls"
{
    printf 'merged_prs:[]\n'
    printf 'open_prs:%s\n' "$(open_prs 5112:BLOCKED)"
    printf 'behind_5112:0\nmain_sha:A\n'
} > "$FAKE/gh_behavior"
sweep_env >/dev/null || true
sweep_env >/dev/null || true
ROUTED="$(grep '"kind":"pr_stuck"' "$AMBIENT" | grep -c '"pr_number":5112')"
if [[ "$ROUTED" == "1" ]] && grep '"kind":"pr_stuck"' "$AMBIENT" | grep -q 'failing_after_fresh_base'; then
    ok "5112 routed to ci-audit exactly once (pr_stuck failing_after_fresh_base)"
else
    fail "expected exactly one pr_stuck for 5112, got $ROUTED (ambient: $(cat "$AMBIENT"))"
fi
if [[ -s "$FAKE/update_branch_calls" ]]; then fail "routed PR must not be re-updated"; else ok "no re-loop after fresh-base failure"; fi

echo "--- Test 9: BLOCKED but not stale and never refreshed → untouched ---"
> "$AMBIENT"; > "$FAKE/update_branch_calls"; rm -f "$STATE"
{
    printf 'merged_prs:[]\n'
    printf 'open_prs:%s\n' "$(open_prs 7000:BLOCKED)"
    printf 'behind_7000:0\nmain_sha:A\n'
} > "$FAKE/gh_behavior"
sweep_env >/dev/null || true
if [[ -s "$FAKE/update_branch_calls" ]] || grep -q '"kind":"pr_stuck"' "$AMBIENT"; then
    fail "non-stale BLOCKED PR should be left alone"
else
    ok "non-stale BLOCKED PR untouched"
fi
rm -f "$FAKE/gh_behavior"

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "${#FAILS[@]}" -gt 0 ]]; then
    echo "Failed tests:"
    for f in "${FAILS[@]}"; do
        echo "  - $f"
    done
    exit 1
fi
exit 0
