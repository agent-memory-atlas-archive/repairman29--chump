#!/usr/bin/env bash
# scripts/ci/test-wizard-daemon.sh — META-109 Phase 1 + META-107 Phase 2
#
# Smoke tests for wizard-daemon.sh (all phases).
#
# Phase 1 test cases (steps 1, 2, 6 + safety + bypass):
#   1. CHUMP_WIZARD_DAEMON_ENABLED unset → daemon exits 0, no action
#   2. CHUMP_WIZARD_DAEMON_PAUSE=1 → emits wizard_daemon_paused, exits 0
#   3. Floor temp HOT → emits wizard_daemon_safety_refusal, exits 0
#   4. Fleet-hold active → daemon stands down (step1 skipped), exits 0
#   5. Step 1: BEHIND+auto-armed PR → classified as BLOCKED+stale-base
#   6. Step 1: CONFLICTING PR → classified as CONFLICTING + safety refusal emitted
#   7. Step 2: BLOCKED+stale-base → recovery-queue-emit.sh called
#   8. Step 2: CONFLICTING → refused (safety guard), emit.sh NOT called
#   9. Step 2: rate limit (3 emits) → 4th PR is rate-limited
#  10. Step 6: fleet_stalled event in ambient → broadcast-urgent.sh called
#  11. Step 6: worker_stuck event in ambient → broadcast-urgent.sh called
#  12. Step 6: stall event outside lookback window → no broadcast
#  13. Step 6: dedup — second run doesn't re-broadcast within window
#  14. No open PRs → cycle completes cleanly
#
# Phase 2 test cases (steps 3, 4, 5 + rate limits + safety):
#  15. Step 3: BLOCKED+real-fails with known W-NNN check → wedge_detected emitted
#  16. Step 3: BLOCKED+real-fails with unknown check → URGENT-INBOX broadcast + author tagged
#  17. Step 3: BLOCKED+stale-base → step3 skipped (not real-fails)
#  18. Step 4: pickable gap dispatched → wizard_dispatch_executed emitted
#  19. Step 4: gap with wizard_skip:true → wizard_gap_skipped emitted, not dispatched
#  20. Step 4: at MAX_PARALLEL concurrent → wizard_dispatch_rate_limited emitted
#  21. Step 5: BEHIND PR from allowed author → cascade rebase triggered
#  22. Step 5: BEHIND PR from non-allowed author → cascade rebase refused (safety)

set -uo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { printf '  PASS: %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }
section() { printf '\n--- %s ---\n' "$1"; }

echo "=== META-109 Phase 1: wizard-daemon smoke tests ==="
echo

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
DAEMON="$REPO_ROOT/scripts/coord/wizard-daemon.sh"

[[ -x "$DAEMON" ]] || { echo "FATAL: $DAEMON not executable"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── Shared helper: build a fake repo environment ───────────────────────────────
make_env() {
    local dir="$1"
    mkdir -p "$dir/.chump-locks" "$dir/scripts/coord" "$dir/scripts/coord/lib"

    # Fake git so daemon can detect repo root
    mkdir -p "$dir/.git"

    # Stub github_cache.sh — returns empty (cache miss → fall through to gh)
    cat > "$dir/scripts/coord/lib/github_cache.sh" <<'CACHE'
[[ -n "${_CHUMP_GITHUB_CACHE_LIB:-}" ]] && return 0
_CHUMP_GITHUB_CACHE_LIB=1
cache_query_open_prs()   { return 0; }   # empty — forces gh fallback
cache_lookup_pr()        { return 2; }   # miss — forces gh fallback
CACHE

    # Stub recovery-queue-emit.sh
    cat > "$dir/scripts/coord/recovery-queue-emit.sh" <<'EMIT'
#!/usr/bin/env bash
echo "recovery-queue-emit called: $*" >> "${EMIT_CALL_LOG:-/dev/null}"
exit 0
EMIT
    chmod +x "$dir/scripts/coord/recovery-queue-emit.sh"

    # Stub broadcast-urgent.sh
    cat > "$dir/scripts/coord/broadcast-urgent.sh" <<'BCAST'
#!/usr/bin/env bash
echo "broadcast-urgent called: $*" >> "${BCAST_CALL_LOG:-/dev/null}"
exit 0
BCAST
    chmod +x "$dir/scripts/coord/broadcast-urgent.sh"

    # Stub fleet-hold-check.sh — default: no hold
    cat > "$dir/scripts/coord/fleet-hold-check.sh" <<'HOLD'
#!/usr/bin/env bash
# By default: no hold. Override by touching fleet-hold.txt in the fake repo.
HOLD_FILE="${CHUMP_FLEET_HOLD_FILE:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.chump-locks/fleet-hold.txt}"
[[ -f "$HOLD_FILE" ]] && exit 2
exit 0
HOLD
    chmod +x "$dir/scripts/coord/fleet-hold-check.sh"
}

# ── Helper: run daemon with specific env ──────────────────────────────────────
run_daemon() {
    local dir="$1"; shift
    local fake_gh="${1:-}"; shift || true

    env \
        CHUMP_REPO="$dir" \
        CHUMP_REPO_ROOT="$dir" \
        CHUMP_AMBIENT_LOG="$dir/.chump-locks/ambient.jsonl" \
        CHUMP_FLEET_HOLD_FILE="$dir/.chump-locks/fleet-hold.txt" \
        CHUMP_WIZARD_TEST_GH="${fake_gh:-/bin/false}" \
        CHUMP_WIZARD_TEST_CHUMP="${FAKE_CHUMP:-/bin/true}" \
        EMIT_CALL_LOG="$dir/emit-calls.log" \
        BCAST_CALL_LOG="$dir/bcast-calls.log" \
        "$@" \
        bash "$DAEMON" 2>&1
}

make_fake_gh() {
    local path="$1"
    local pr_list_json="${2:-}"; shift 2 || true
    pr_list_json="${pr_list_json:-[]}"
    local pr_view_json="${1:-}"
    mkdir -p "$(dirname "$path")"
    # Write the list JSON and view JSON into companion files so the heredoc
    # doesn't have to embed them directly (avoids quoting edge cases).
    local list_file; list_file="$(dirname "$path")/.gh-list-fixture"
    local view_file; view_file="$(dirname "$path")/.gh-view-fixture"
    printf '%s' "$pr_list_json" > "$list_file"
    printf '%s' "$pr_view_json" > "$view_file"
    cat > "$path" <<GH_EOF
#!/usr/bin/env bash
LIST_FILE="$(dirname "$path")/.gh-list-fixture"
VIEW_FILE="$(dirname "$path")/.gh-view-fixture"
case "\$*" in
    *"pr list"*)
        # If caller passes --jq '.[].number', extract numbers via python3
        if printf '%s\n' "\$@" | grep -q '\\[\\]\.number'; then
            python3 -c "
import json,sys
data=json.load(open('\$LIST_FILE'))
for pr in data: print(pr['number'])
" 2>/dev/null
        else
            cat "\$LIST_FILE"
        fi
        exit 0
        ;;
    *"pr view"*)
        if [[ -n "\${GH_PR_DATA_FILE:-}" ]] && [[ -f "\${GH_PR_DATA_FILE}" ]]; then
            cat "\${GH_PR_DATA_FILE}"
        else
            cat "\$VIEW_FILE"
        fi
        exit 0
        ;;
esac
exit 0
GH_EOF
    chmod +x "$path"
}

# ── Test 1: not enabled ────────────────────────────────────────────────────────
section "T1: ENABLED unset → silent exit"
D="$TMP/t1"; make_env "$D"
OUT="$(CHUMP_WIZARD_DAEMON_ENABLED=0 run_daemon "$D" "" 2>&1)"
RC=$?
if [[ "$RC" -eq 0 ]] && printf '%s\n' "$OUT" | grep -q "NOT enabled"; then
    ok "T1: exits 0 with NOT enabled message"
else
    fail "T1: expected exit 0 + NOT enabled message (rc=$RC output=$OUT)"
fi

# ── Test 2: PAUSE kill-switch ──────────────────────────────────────────────────
section "T2: PAUSE=1 → wizard_daemon_paused emitted"
D="$TMP/t2"; make_env "$D"
run_daemon "$D" "" \
    CHUMP_WIZARD_DAEMON_ENABLED=1 \
    CHUMP_WIZARD_DAEMON_PAUSE=1 >/dev/null 2>&1 || true
if grep -q '"kind":"wizard_daemon_paused"' "$D/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "T2: wizard_daemon_paused emitted"
else
    fail "T2: wizard_daemon_paused not found in ambient"
fi

# ── Test 3: HOT floor temp ─────────────────────────────────────────────────────
section "T3: HOT temp → safety refusal"
D="$TMP/t3"; make_env "$D"

# Fake chump that reports HOT
FAKE_CHUMP_HOT="$TMP/t3-chump"
cat > "$FAKE_CHUMP_HOT" <<'CHUMP'
#!/usr/bin/env bash
if [[ "$1 $2" == "health --temp" ]]; then
    echo "floor_temp: HOT"
    exit 0
fi
exit 0
CHUMP
chmod +x "$FAKE_CHUMP_HOT"

run_daemon "$D" "" \
    CHUMP_WIZARD_DAEMON_ENABLED=1 \
    CHUMP_WIZARD_TEST_CHUMP="$FAKE_CHUMP_HOT" >/dev/null 2>&1 || true

AMBIENT="$D/.chump-locks/ambient.jsonl"
if grep -q '"kind":"wizard_daemon_safety_refusal"' "$AMBIENT" 2>/dev/null \
   && grep -q '"reason":"floor_temp_HOT"' "$AMBIENT" 2>/dev/null; then
    ok "T3: wizard_daemon_safety_refusal emitted for HOT temp"
else
    fail "T3: safety_refusal not found (ambient=$(cat "$AMBIENT" 2>/dev/null || echo empty))"
fi

# ── Test 4: Fleet-hold active ─────────────────────────────────────────────────
section "T4: fleet-hold active → stand_down"
D="$TMP/t4"; make_env "$D"
echo '{"active":true,"reason":"ci_failure_cluster"}' > "$D/.chump-locks/fleet-hold.txt"

GH4="$TMP/t4-gh"
make_fake_gh "$GH4" '[]' '{}'

run_daemon "$D" "$GH4" \
    CHUMP_WIZARD_DAEMON_ENABLED=1 >/dev/null 2>&1 || true

AMBIENT="$D/.chump-locks/ambient.jsonl"
if grep -q '"decision":"stand_down"' "$AMBIENT" 2>/dev/null \
   && grep -q '"reason":"fleet_hold_active"' "$AMBIENT" 2>/dev/null; then
    ok "T4: stand_down emitted when fleet-hold active"
else
    fail "T4: expected stand_down with fleet_hold_active (ambient=$(cat "$AMBIENT" 2>/dev/null || echo empty))"
fi

# ── Test 5: Step 1 — BEHIND+auto-armed → BLOCKED+stale-base ──────────────────
section "T5: Step 1 — BEHIND+auto-armed PR classified BLOCKED+stale-base"
D="$TMP/t5"; make_env "$D"

GH5="$TMP/t5-gh"
make_fake_gh "$GH5" '[{"number":999}]' \
    '{"number":999,"title":"test PR","mergeable":"UNKNOWN","mergeStateStatus":"BEHIND","autoMergeRequest":{"enabledAt":"2026-01-01"},"isDraft":false}'

run_daemon "$D" "$GH5" \
    CHUMP_WIZARD_DAEMON_ENABLED=1 >/dev/null 2>&1 || true

AMBIENT="$D/.chump-locks/ambient.jsonl"
if grep -q '"pr_class":"BLOCKED+stale-base"' "$AMBIENT" 2>/dev/null; then
    ok "T5: BEHIND+auto-armed → BLOCKED+stale-base"
else
    fail "T5: expected BLOCKED+stale-base class (ambient=$(cat "$AMBIENT" 2>/dev/null || echo empty))"
fi

# ── Test 6: Step 1 — CONFLICTING → safety refusal ────────────────────────────
section "T6: Step 1 — CONFLICTING PR → safety refusal"
D="$TMP/t6"; make_env "$D"

GH6="$TMP/t6-gh"
make_fake_gh "$GH6" '[{"number":888}]' \
    '{"number":888,"title":"conflicting PR","mergeable":"CONFLICTING","mergeStateStatus":"CONFLICTING","autoMergeRequest":{"enabledAt":"2026-01-01"},"isDraft":false}'

run_daemon "$D" "$GH6" \
    CHUMP_WIZARD_DAEMON_ENABLED=1 >/dev/null 2>&1 || true

AMBIENT="$D/.chump-locks/ambient.jsonl"
if grep -q '"kind":"wizard_daemon_safety_refusal"' "$AMBIENT" 2>/dev/null \
   && grep -q '"reason":"pr_conflicting"' "$AMBIENT" 2>/dev/null; then
    ok "T6: CONFLICTING PR → wizard_daemon_safety_refusal emitted"
else
    fail "T6: expected safety_refusal for CONFLICTING (ambient=$(cat "$AMBIENT" 2>/dev/null || echo empty))"
fi

# ── Test 7: Step 2 — BLOCKED+stale-base → recovery-queue-emit called ─────────
section "T7: Step 2 — BLOCKED+stale-base → emit.sh called"
D="$TMP/t7"; make_env "$D"

GH7="$TMP/t7-gh"
make_fake_gh "$GH7" '[{"number":777}]' \
    '{"number":777,"title":"stale PR","mergeable":"UNKNOWN","mergeStateStatus":"BEHIND","autoMergeRequest":{"enabledAt":"2026-01-01"},"isDraft":false}'

run_daemon "$D" "$GH7" \
    CHUMP_WIZARD_DAEMON_ENABLED=1 >/dev/null 2>&1 || true

if [[ -f "$D/emit-calls.log" ]] && grep -q "777" "$D/emit-calls.log" 2>/dev/null; then
    ok "T7: recovery-queue-emit.sh called for BLOCKED+stale-base PR"
else
    fail "T7: emit.sh not called (emit-calls.log=$(cat "$D/emit-calls.log" 2>/dev/null || echo empty))"
fi

# Also check ambient has recovery_queue_emitted decision
AMBIENT="$D/.chump-locks/ambient.jsonl"
if grep -q '"decision":"recovery_queue_emitted"' "$AMBIENT" 2>/dev/null; then
    ok "T7b: wizard_daemon_action with recovery_queue_emitted emitted"
else
    fail "T7b: recovery_queue_emitted not found in ambient"
fi

# ── Test 8: Step 2 — CONFLICTING → refused, emit NOT called ──────────────────
section "T8: Step 2 — CONFLICTING → emit.sh NOT called"
D="$TMP/t8"; make_env "$D"

GH8="$TMP/t8-gh"
make_fake_gh "$GH8" '[{"number":666}]' \
    '{"number":666,"title":"conflict PR","mergeable":"CONFLICTING","mergeStateStatus":"CONFLICTING","autoMergeRequest":{"enabledAt":"2026-01-01"},"isDraft":false}'

run_daemon "$D" "$GH8" \
    CHUMP_WIZARD_DAEMON_ENABLED=1 >/dev/null 2>&1 || true

if [[ ! -f "$D/emit-calls.log" ]] || [[ ! -s "$D/emit-calls.log" ]]; then
    ok "T8: emit.sh NOT called for CONFLICTING PR"
else
    fail "T8: emit.sh was called for CONFLICTING PR (should be refused)"
fi

# ── Test 9: Step 2 — rate limit (3 emits, 4th is rate-limited) ───────────────
section "T9: Step 2 — rate limit: 4th PR skipped"
D="$TMP/t9"; make_env "$D"

# Fake gh that returns 4 BEHIND+armed PRs.
# Use single-quoted heredoc so ${...} is NOT expanded at write time.
GH9="$TMP/t9-gh"
cat > "$GH9" <<'GH9_EOF'
#!/usr/bin/env bash
case "$*" in
    *"pr list"*)
        # Emit numbers one per line (mimics --jq '.[].number')
        if printf '%s\n' "$@" | grep -q '\[\]\.number'; then
            printf '101\n102\n103\n104\n'
        else
            echo '[{"number":101},{"number":102},{"number":103},{"number":104}]'
        fi
        exit 0
        ;;
    *"pr view"*)
        # Extract last numeric argument as PR number
        N=""
        for arg in "$@"; do
            [[ "$arg" =~ ^[0-9]+$ ]] && N="$arg"
        done
        N="${N:-101}"
        printf '{"number":%s,"title":"PR %s","mergeable":"UNKNOWN","mergeStateStatus":"BEHIND","autoMergeRequest":{"enabledAt":"2026-01-01"},"isDraft":false}\n' "$N" "$N"
        exit 0
        ;;
esac
exit 0
GH9_EOF
chmod +x "$GH9"

run_daemon "$D" "$GH9" \
    CHUMP_WIZARD_DAEMON_ENABLED=1 \
    CHUMP_WIZARD_RECOVERY_RATE_LIMIT=3 >/dev/null 2>&1 || true

EMIT_COUNT=0
[[ -f "$D/emit-calls.log" ]] && EMIT_COUNT="$(wc -l < "$D/emit-calls.log" | tr -d ' ')"

AMBIENT="$D/.chump-locks/ambient.jsonl"
RATE_LIMITED="$(grep -c '"decision":"rate_limited"' "$AMBIENT" 2>/dev/null || true)"

if [[ "$EMIT_COUNT" -eq 3 ]]; then
    ok "T9: exactly 3 emit calls (rate limit=3)"
else
    fail "T9: expected 3 emit calls, got $EMIT_COUNT"
fi
if [[ "$RATE_LIMITED" -ge 1 ]]; then
    ok "T9b: rate_limited decision emitted for 4th PR"
else
    fail "T9b: no rate_limited decision found (rate_limited_count=$RATE_LIMITED)"
fi

# ── Test 10: Step 6 — fleet_stalled → broadcast CRIT ─────────────────────────
section "T10: Step 6 — fleet_stalled event → broadcast-urgent called"
D="$TMP/t10"; make_env "$D"

GH10="$TMP/t10-gh"
make_fake_gh "$GH10" '[]' '{}'

# Inject a recent fleet_stalled event into ambient
TS_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"ts":"%s","kind":"fleet_stalled","source":"fleet_brief","ships_1h":0,"blocked_prs":3}\n' \
    "$TS_NOW" > "$D/.chump-locks/ambient.jsonl"

run_daemon "$D" "$GH10" \
    CHUMP_WIZARD_DAEMON_ENABLED=1 \
    CHUMP_WIZARD_STALL_LOOKBACK_S=600 >/dev/null 2>&1 || true

AMBIENT="$D/.chump-locks/ambient.jsonl"
if [[ -f "$D/bcast-calls.log" ]] && grep -q "CRIT" "$D/bcast-calls.log" 2>/dev/null; then
    ok "T10: broadcast-urgent.sh called with CRIT for fleet_stalled"
else
    fail "T10: broadcast-urgent.sh not called (bcast-calls=$(cat "$D/bcast-calls.log" 2>/dev/null || echo empty))"
fi
if grep -q '"decision":"broadcast_crit"' "$AMBIENT" 2>/dev/null; then
    ok "T10b: wizard_daemon_action broadcast_crit emitted"
else
    fail "T10b: broadcast_crit decision not found in ambient"
fi

# ── Test 11: Step 6 — worker_stuck → broadcast CRIT ──────────────────────────
section "T11: Step 6 — worker_stuck event → broadcast-urgent called"
D="$TMP/t11"; make_env "$D"

GH11="$TMP/t11-gh"
make_fake_gh "$GH11" '[]' '{}'

TS_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"ts":"%s","kind":"worker_stuck","source":"worker","reason":"no_pickable_gap"}\n' \
    "$TS_NOW" > "$D/.chump-locks/ambient.jsonl"

run_daemon "$D" "$GH11" \
    CHUMP_WIZARD_DAEMON_ENABLED=1 \
    CHUMP_WIZARD_STALL_LOOKBACK_S=600 >/dev/null 2>&1 || true

if [[ -f "$D/bcast-calls.log" ]] && grep -q "CRIT" "$D/bcast-calls.log" 2>/dev/null; then
    ok "T11: broadcast-urgent.sh called with CRIT for worker_stuck"
else
    fail "T11: broadcast-urgent.sh not called for worker_stuck"
fi

# ── Test 12: Step 6 — stall event outside lookback window → no broadcast ──────
section "T12: Step 6 — old stall event → no broadcast"
D="$TMP/t12"; make_env "$D"

GH12="$TMP/t12-gh"
make_fake_gh "$GH12" '[]' '{}'

# Inject an OLD fleet_stalled event (2 hours ago)
TS_OLD="$(date -u -v-7200S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d '-7200 seconds' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || echo '2020-01-01T00:00:00Z')"
printf '{"ts":"%s","kind":"fleet_stalled","source":"fleet_brief","ships_1h":0,"blocked_prs":3}\n' \
    "$TS_OLD" > "$D/.chump-locks/ambient.jsonl"

run_daemon "$D" "$GH12" \
    CHUMP_WIZARD_DAEMON_ENABLED=1 \
    CHUMP_WIZARD_STALL_LOOKBACK_S=600 >/dev/null 2>&1 || true

if [[ ! -f "$D/bcast-calls.log" ]] || [[ ! -s "$D/bcast-calls.log" ]]; then
    ok "T12: no broadcast for stall event outside lookback window"
else
    fail "T12: unexpected broadcast for old stall event (bcast=$(cat "$D/bcast-calls.log"))"
fi

# ── Test 13: Step 6 — dedup: second run doesn't re-broadcast ─────────────────
section "T13: Step 6 — dedup: second run within window → no re-broadcast"
D="$TMP/t13"; make_env "$D"

GH13="$TMP/t13-gh"
make_fake_gh "$GH13" '[]' '{}'

TS_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"ts":"%s","kind":"fleet_stalled","source":"fleet_brief"}\n' "$TS_NOW" \
    > "$D/.chump-locks/ambient.jsonl"

# First run — should broadcast
run_daemon "$D" "$GH13" \
    CHUMP_WIZARD_DAEMON_ENABLED=1 \
    CHUMP_WIZARD_STALL_LOOKBACK_S=600 >/dev/null 2>&1 || true

FIRST_BCAST_COUNT=0
[[ -f "$D/bcast-calls.log" ]] && FIRST_BCAST_COUNT="$(wc -l < "$D/bcast-calls.log" | tr -d ' ')"

# Second run — should dedup (wizard_daemon_action broadcast_crit is now in ambient)
run_daemon "$D" "$GH13" \
    CHUMP_WIZARD_DAEMON_ENABLED=1 \
    CHUMP_WIZARD_STALL_LOOKBACK_S=600 >/dev/null 2>&1 || true

SECOND_BCAST_COUNT=0
[[ -f "$D/bcast-calls.log" ]] && SECOND_BCAST_COUNT="$(wc -l < "$D/bcast-calls.log" | tr -d ' ')"

AMBIENT="$D/.chump-locks/ambient.jsonl"
DEDUP_COUNT="$(grep -c '"decision":"broadcast_deduped"' "$AMBIENT" 2>/dev/null || true)"

if [[ "$FIRST_BCAST_COUNT" -ge 1 ]]; then
    ok "T13: first run broadcast (count=$FIRST_BCAST_COUNT)"
else
    fail "T13: first run did not broadcast"
fi
if [[ "$SECOND_BCAST_COUNT" -eq "$FIRST_BCAST_COUNT" ]]; then
    ok "T13b: second run did not add new broadcast (deduped)"
else
    fail "T13b: second run added broadcast (count went $FIRST_BCAST_COUNT → $SECOND_BCAST_COUNT)"
fi
if [[ "$DEDUP_COUNT" -ge 1 ]]; then
    ok "T13c: broadcast_deduped decision emitted on second run"
else
    fail "T13c: broadcast_deduped not found in ambient"
fi

# ── Test 14: No open PRs → cycle completes cleanly ────────────────────────────
section "T14: No open PRs → clean exit"
D="$TMP/t14"; make_env "$D"

GH14="$TMP/t14-gh"
make_fake_gh "$GH14" '[]' '{}'

OUT="$(run_daemon "$D" "$GH14" CHUMP_WIZARD_DAEMON_ENABLED=1 2>&1)"
RC=$?

AMBIENT="$D/.chump-locks/ambient.jsonl"
if [[ "$RC" -eq 0 ]] && grep -q '"decision":"done"' "$AMBIENT" 2>/dev/null; then
    ok "T14: clean exit with cycle_complete + done for empty PR queue"
else
    fail "T14: rc=$RC; ambient=$(cat "$AMBIENT" 2>/dev/null || echo empty)"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Phase 2 tests — Steps 3, 4, 5 (META-107)
# ══════════════════════════════════════════════════════════════════════════════

echo
echo "=== META-107 Phase 2: wizard-daemon steps 3+4+5 smoke tests ==="

# Helper: extend make_env with Phase 2 stubs
make_env_p2() {
    local dir="$1"
    make_env "$dir"

    # Stub chump binary with gap list + preflight + --execute-gap support
    local chump_bin="$dir/bin/chump"
    mkdir -p "$dir/bin"
    cat > "$chump_bin" <<'CHUMP'
#!/usr/bin/env bash
# Stub chump for Phase 2 tests
case "$*" in
    "health --temp")
        echo "floor_temp: COLD"
        exit 0
        ;;
    "gap list"*"--json"*)
        # Return from GAP_LIST_JSON env if set, else empty
        echo "${GAP_LIST_JSON:-[]}"
        exit 0
        ;;
    "gap preflight"*)
        # Return from GAP_PREFLIGHT_RC env if set, else 0
        exit "${GAP_PREFLIGHT_RC:-0}"
        ;;
    "--execute-gap"*)
        # Log the dispatch call
        echo "execute-gap: $*" >> "${EXECUTE_GAP_LOG:-/dev/null}"
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
CHUMP
    chmod +x "$chump_bin"
    export PATH="$dir/bin:$PATH"
}

# ── Test 15: Step 3 — known W-NNN failure → wedge_detected emitted ────────────
section "T15: Step 3 — BLOCKED+real-fails with known W-NNN check → wedge_detected"
D="$TMP/t15"; make_env_p2 "$D"

# Fake gh: returns 1 BLOCKED PR with a failing check matching W-004 (r2d2/sqlite)
GH15="$TMP/t15-gh"
cat > "$GH15" <<'GH15_EOF'
#!/usr/bin/env bash
case "$*" in
    *"pr list"*)
        if printf '%s\n' "$@" | grep -q '\[\]\.number'; then
            printf '500\n'
        else
            echo '[{"number":500}]'
        fi
        exit 0
        ;;
    *"pr view"*500*)
        # BLOCKED PR (real fails, no hold active)
        echo '{"number":500,"title":"test real-fails","mergeable":"UNKNOWN","mergeStateStatus":"BLOCKED","autoMergeRequest":{"enabledAt":"2026-01-01"},"isDraft":false,"headRefOid":"abc123","author":{"login":"repairman29"}}'
        exit 0
        ;;
    *"pr checks"*500*)
        # Returns a check that matches W-004 signature (sqlite/r2d2)
        echo '[{"name":"cargo-test / r2d2-lock","state":"FAILURE","conclusion":"failure"}]'
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
GH15_EOF
chmod +x "$GH15"

run_daemon "$D" "$GH15" \
    CHUMP_WIZARD_DAEMON_ENABLED=1 \
    CHUMP_WIZARD_TEST_CHUMP="$D/bin/chump" >/dev/null 2>&1 || true

AMBIENT="$D/.chump-locks/ambient.jsonl"
if grep -q '"kind":"wedge_detected"' "$AMBIENT" 2>/dev/null \
   && grep -q '"wedge_class":"W-004"' "$AMBIENT" 2>/dev/null; then
    ok "T15: wedge_detected with W-004 emitted for r2d2 failure"
else
    fail "T15: expected wedge_detected W-004 (ambient=$(cat "$AMBIENT" 2>/dev/null || echo empty))"
fi

# ── Test 16: Step 3 — unknown failure class → URGENT-INBOX broadcast + author tag ──
section "T16: Step 3 — unknown check name → URGENT-INBOX broadcast with author"
D="$TMP/t16"; make_env_p2 "$D"

GH16="$TMP/t16-gh"
cat > "$GH16" <<'GH16_EOF'
#!/usr/bin/env bash
case "$*" in
    *"pr list"*)
        if printf '%s\n' "$@" | grep -q '\[\]\.number'; then
            printf '501\n'
        else
            echo '[{"number":501}]'
        fi
        exit 0
        ;;
    *"pr view"*501*)
        echo '{"number":501,"title":"unknown fail PR","mergeable":"UNKNOWN","mergeStateStatus":"BLOCKED","autoMergeRequest":{"enabledAt":"2026-01-01"},"isDraft":false,"headRefOid":"def456","author":{"login":"somedev"}}'
        exit 0
        ;;
    *"pr checks"*501*)
        # Returns a check that does NOT match any W-NNN signature
        echo '[{"name":"totally-custom-check-xyz","state":"FAILURE","conclusion":"failure"}]'
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
GH16_EOF
chmod +x "$GH16"

run_daemon "$D" "$GH16" \
    CHUMP_WIZARD_DAEMON_ENABLED=1 \
    CHUMP_WIZARD_TEST_CHUMP="$D/bin/chump" >/dev/null 2>&1 || true

AMBIENT="$D/.chump-locks/ambient.jsonl"
# Should broadcast CRIT with author tag
if [[ -f "$D/bcast-calls.log" ]] && grep -q "CRIT" "$D/bcast-calls.log" 2>/dev/null; then
    ok "T16: URGENT-INBOX broadcast fired for unknown failure class"
else
    fail "T16: no CRIT broadcast for unknown failure (bcast=$(cat "$D/bcast-calls.log" 2>/dev/null || echo empty))"
fi
# Should mention the author in the broadcast
if [[ -f "$D/bcast-calls.log" ]] && grep -q "somedev" "$D/bcast-calls.log" 2>/dev/null; then
    ok "T16b: broadcast message contains author tag (somedev)"
else
    fail "T16b: author not found in broadcast (bcast=$(cat "$D/bcast-calls.log" 2>/dev/null || echo empty))"
fi
if grep -q '"decision":"urgent_inbox_broadcast"' "$AMBIENT" 2>/dev/null; then
    ok "T16c: urgent_inbox_broadcast action emitted in ambient"
else
    fail "T16c: urgent_inbox_broadcast not in ambient"
fi

# ── Test 17: Step 3 — BLOCKED+stale-base → step3 skipped ─────────────────────
section "T17: Step 3 — BLOCKED+stale-base PR → step3 not invoked"
D="$TMP/t17"; make_env_p2 "$D"

GH17="$TMP/t17-gh"
make_fake_gh "$GH17" '[{"number":502}]' \
    '{"number":502,"title":"stale-base PR","mergeable":"UNKNOWN","mergeStateStatus":"BEHIND","autoMergeRequest":{"enabledAt":"2026-01-01"},"isDraft":false}'

run_daemon "$D" "$GH17" \
    CHUMP_WIZARD_DAEMON_ENABLED=1 \
    CHUMP_WIZARD_TEST_CHUMP="$D/bin/chump" >/dev/null 2>&1 || true

AMBIENT="$D/.chump-locks/ambient.jsonl"
# wedge_detected must NOT appear for a stale-base PR
if ! grep -q '"kind":"wedge_detected"' "$AMBIENT" 2>/dev/null; then
    ok "T17: wedge_detected NOT emitted for BLOCKED+stale-base"
else
    fail "T17: wedge_detected wrongly emitted for stale-base PR"
fi

# ── Test 18: Step 4 — pickable gap dispatched ─────────────────────────────────
section "T18: Step 4 — pickable gap → wizard_dispatch_executed emitted"
D="$TMP/t18"; make_env_p2 "$D"

# Provide a gap list with one pickable gap
export GAP_LIST_JSON='[{"id":"TEST-001","priority":"P1","acceptance_criteria":"must do X","notes":""}]'

GH18="$TMP/t18-gh"
make_fake_gh "$GH18" '[]' '{}'

EXECUTE_GAP_LOG="$D/execute-gap.log"
run_daemon "$D" "$GH18" \
    CHUMP_WIZARD_DAEMON_ENABLED=1 \
    CHUMP_WIZARD_TEST_CHUMP="$D/bin/chump" \
    GAP_LIST_JSON="$GAP_LIST_JSON" \
    EXECUTE_GAP_LOG="$EXECUTE_GAP_LOG" >/dev/null 2>&1 || true

unset GAP_LIST_JSON

AMBIENT="$D/.chump-locks/ambient.jsonl"
if grep -q '"kind":"wizard_dispatch_executed"' "$AMBIENT" 2>/dev/null; then
    ok "T18: wizard_dispatch_executed emitted for pickable gap"
else
    fail "T18: wizard_dispatch_executed not found (ambient=$(cat "$AMBIENT" 2>/dev/null || echo empty))"
fi
if [[ -f "$EXECUTE_GAP_LOG" ]] && grep -q "TEST-001" "$EXECUTE_GAP_LOG" 2>/dev/null; then
    ok "T18b: chump --execute-gap called with TEST-001"
else
    fail "T18b: execute-gap log missing TEST-001 (log=$(cat "$EXECUTE_GAP_LOG" 2>/dev/null || echo empty))"
fi

# ── Test 19: Step 4 — wizard_skip:true gap → skipped ─────────────────────────
section "T19: Step 4 — gap with wizard_skip:true → wizard_gap_skipped"
D="$TMP/t19"; make_env_p2 "$D"

SKIP_GAP_JSON='[{"id":"SKIP-001","priority":"P1","acceptance_criteria":"must do X","notes":"wizard_skip: true"}]'

GH19="$TMP/t19-gh"
make_fake_gh "$GH19" '[]' '{}'

EXECUTE_GAP_LOG19="$D/execute-gap.log"
run_daemon "$D" "$GH19" \
    CHUMP_WIZARD_DAEMON_ENABLED=1 \
    CHUMP_WIZARD_TEST_CHUMP="$D/bin/chump" \
    GAP_LIST_JSON="$SKIP_GAP_JSON" \
    EXECUTE_GAP_LOG="$EXECUTE_GAP_LOG19" >/dev/null 2>&1 || true

AMBIENT="$D/.chump-locks/ambient.jsonl"
if grep -q '"kind":"wizard_gap_skipped"' "$AMBIENT" 2>/dev/null; then
    ok "T19: wizard_gap_skipped emitted for wizard_skip:true gap"
else
    fail "T19: wizard_gap_skipped not found (ambient=$(cat "$AMBIENT" 2>/dev/null || echo empty))"
fi
if [[ ! -f "$EXECUTE_GAP_LOG19" ]] || ! grep -q "SKIP-001" "$EXECUTE_GAP_LOG19" 2>/dev/null; then
    ok "T19b: SKIP-001 was NOT dispatched via --execute-gap"
else
    fail "T19b: SKIP-001 was wrongly dispatched"
fi

# ── Test 20: Step 4 — at MAX_PARALLEL → wizard_dispatch_rate_limited ─────────
section "T20: Step 4 — at MAX_PARALLEL concurrent → rate limited"
D="$TMP/t20"; make_env_p2 "$D"

GH20="$TMP/t20-gh"
make_fake_gh "$GH20" '[]' '{}'

# Pre-populate dispatch state with MAX_PARALLEL=2 active dispatches
# pid=0 → bypasses liveness check, always counted as active
TS_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$D/.chump-locks"
cat > "$D/.chump-locks/wizard-daemon-dispatch-state.json" <<STATE_EOF
{"dispatches":[
  {"gap_id":"OLD-001","ts":"${TS_NOW}","pid":0},
  {"gap_id":"OLD-002","ts":"${TS_NOW}","pid":0}
]}
STATE_EOF

MULTI_GAP_JSON='[{"id":"NEW-001","priority":"P1","acceptance_criteria":"AC","notes":""}]'

run_daemon "$D" "$GH20" \
    CHUMP_WIZARD_DAEMON_ENABLED=1 \
    CHUMP_WIZARD_TEST_CHUMP="$D/bin/chump" \
    GAP_LIST_JSON="$MULTI_GAP_JSON" \
    CHUMP_WIZARD_MAX_PARALLEL=2 \
    CHUMP_WIZARD_DISPATCH_STATE="$D/.chump-locks/wizard-daemon-dispatch-state.json" >/dev/null 2>&1 || true

AMBIENT="$D/.chump-locks/ambient.jsonl"
if grep -q '"kind":"wizard_dispatch_rate_limited"' "$AMBIENT" 2>/dev/null; then
    ok "T20: wizard_dispatch_rate_limited emitted when at MAX_PARALLEL"
else
    fail "T20: wizard_dispatch_rate_limited not found (ambient=$(cat "$AMBIENT" 2>/dev/null || echo empty))"
fi
# Must NOT have dispatched new gap
if ! grep -q '"kind":"wizard_dispatch_executed"' "$AMBIENT" 2>/dev/null; then
    ok "T20b: no dispatch_executed when rate limited"
else
    fail "T20b: dispatch_executed found despite rate limit"
fi

# ── Test 21: Step 5 — BEHIND PR from allowed author → cascade rebase ──────────
section "T21: Step 5 — BEHIND PR from allowed author → cascade rebase triggered"
D="$TMP/t21"; make_env_p2 "$D"

# Inject a recent gap_shipped event into ambient
TS_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"ts":"%s","kind":"gap_shipped","gap_id":"INFRA-999","cluster_id":"W-002","source":"fleet"}\n' \
    "$TS_NOW" > "$D/.chump-locks/ambient.jsonl"

# Track rebase calls
REBASE_LOG="$D/rebase-calls.log"

GH21="$TMP/t21-gh"
cat > "$GH21" <<GH21_EOF
#!/usr/bin/env bash
REBASE_LOG="${REBASE_LOG}"
case "\$*" in
    *"pr list"*)
        if printf '%s\n' "\$@" | grep -q '\[\]\.number'; then
            printf '600\n'
        else
            echo '[{"number":600}]'
        fi
        exit 0
        ;;
    *"pr view"*600*)
        echo '{"number":600,"title":"sibling PR","mergeable":"UNKNOWN","mergeStateStatus":"BEHIND","autoMergeRequest":{"enabledAt":"2026-01-01"},"isDraft":false,"headRefName":"chump/sibling","author":{"login":"repairman29"}}'
        exit 0
        ;;
    *"api"*"/protection"*)
        echo '{"required_status_checks":{"strict":true}}'
        exit 0
        ;;
    *"pr update-branch"*600*)
        echo "rebase called: \$*" >> "\${REBASE_LOG}"
        exit 0
        ;;
    *"pr checks"*)
        echo '[]'
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
GH21_EOF
chmod +x "$GH21"

run_daemon "$D" "$GH21" \
    CHUMP_WIZARD_DAEMON_ENABLED=1 \
    CHUMP_WIZARD_TEST_CHUMP="$D/bin/chump" \
    CHUMP_WIZARD_ALLOWED_REBASE_AUTHOR=repairman29 >/dev/null 2>&1 || true

AMBIENT="$D/.chump-locks/ambient.jsonl"
if grep -q '"kind":"wizard_cascade_rebase_triggered"' "$AMBIENT" 2>/dev/null; then
    ok "T21: wizard_cascade_rebase_triggered emitted for allowed-author PR"
else
    fail "T21: wizard_cascade_rebase_triggered not found (ambient=$(cat "$AMBIENT" 2>/dev/null || echo empty))"
fi
if [[ -f "$REBASE_LOG" ]] && grep -q "600" "$REBASE_LOG" 2>/dev/null; then
    ok "T21b: gh pr update-branch called for PR #600"
else
    fail "T21b: gh pr update-branch not called (log=$(cat "$REBASE_LOG" 2>/dev/null || echo empty))"
fi

# ── Test 22: Step 5 — BEHIND PR from non-allowed author → refused ─────────────
section "T22: Step 5 — BEHIND PR from non-allowed author → cascade rebase refused"
D="$TMP/t22"; make_env_p2 "$D"

TS_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"ts":"%s","kind":"gap_shipped","gap_id":"INFRA-998","source":"fleet"}\n' \
    "$TS_NOW" > "$D/.chump-locks/ambient.jsonl"

REBASE_LOG22="$D/rebase-calls.log"

GH22="$TMP/t22-gh"
cat > "$GH22" <<GH22_EOF
#!/usr/bin/env bash
REBASE_LOG22="${REBASE_LOG22}"
case "\$*" in
    *"pr list"*)
        if printf '%s\n' "\$@" | grep -q '\[\]\.number'; then
            printf '700\n'
        else
            echo '[{"number":700}]'
        fi
        exit 0
        ;;
    *"pr view"*700*)
        # PR from a FORK author — not allowed
        echo '{"number":700,"title":"fork PR","mergeable":"UNKNOWN","mergeStateStatus":"BEHIND","autoMergeRequest":{"enabledAt":"2026-01-01"},"isDraft":false,"headRefName":"fork/feature","author":{"login":"external-fork-user"}}'
        exit 0
        ;;
    *"api"*"/protection"*)
        echo '{"required_status_checks":{"strict":true}}'
        exit 0
        ;;
    *"pr update-branch"*700*)
        echo "rebase called: \$*" >> "\${REBASE_LOG22}"
        exit 0
        ;;
    *"pr checks"*)
        echo '[]'
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
GH22_EOF
chmod +x "$GH22"

run_daemon "$D" "$GH22" \
    CHUMP_WIZARD_DAEMON_ENABLED=1 \
    CHUMP_WIZARD_TEST_CHUMP="$D/bin/chump" \
    CHUMP_WIZARD_ALLOWED_REBASE_AUTHOR=repairman29 >/dev/null 2>&1 || true

AMBIENT="$D/.chump-locks/ambient.jsonl"
# Must NOT have triggered rebase
if ! grep -q '"kind":"wizard_cascade_rebase_triggered"' "$AMBIENT" 2>/dev/null; then
    ok "T22: cascade rebase NOT triggered for non-allowed author"
else
    fail "T22: cascade rebase wrongly triggered for fork user"
fi
if [[ ! -f "$REBASE_LOG22" ]] || [[ ! -s "$REBASE_LOG22" ]]; then
    ok "T22b: gh pr update-branch NOT called for non-allowed author"
else
    fail "T22b: gh pr update-branch was called for fork user (safety violation)"
fi
# Should emit skip_author_not_allowed action
if grep -q '"decision":"skip_author_not_allowed"' "$AMBIENT" 2>/dev/null; then
    ok "T22c: skip_author_not_allowed action emitted in ambient"
else
    fail "T22c: skip_author_not_allowed action not found in ambient"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "${#FAILS[@]}" -gt 0 ]]; then
    echo "Failed tests:"
    for f in "${FAILS[@]}"; do
        echo "  - $f"
    done
    exit 1
fi
exit 0
