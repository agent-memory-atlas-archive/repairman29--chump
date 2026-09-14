#!/usr/bin/env bash
# test-rot-reaper-systemic-red-hold.sh — RESILIENT-1188 (systemic-red guard)
#
# #4637 taught the rot-reaper's CLASS 2 to SPARE an INDIVIDUAL PR whose real
# gates are green underneath a red `verified` aggregate. But when a SHARED /
# trunk gate breaks, the required aggregate goes RED across MANY open PRs at
# once — each with a genuine COMPLETED failure on that gate — so #4637's per-PR
# classifier reads every one as hard_fail and the reaper closes them ALL. That
# is the fleet-wide self-strangle (INFRA-3542 / auto-rescue-reaps-systemic-red).
#
# THE RELIABLE SYSTEMIC SIGNAL IS MAIN-RED, NOT "N PRs share a gate". Two open
# PRs failing the SAME-NAMED required gate is NOT proof of a shared break — each
# can have its OWN independent real failure in that gate, and those SHOULD still
# reap. The one thing that distinguishes a shared/trunk break from independent
# failures is whether MAIN ITSELF is red — which the reaper CONSUMES from the
# trunk-sentinel-daemon's ambient signal (scripts/coord/trunk-sentinel-daemon.sh).
# When main is green, a required-red PR reaps as before; when main is RED, the
# whole required-red class is HELD (its redness is inherited from the trunk).
#
# This test drives the REAL reaper against its own selection logic
# (CHUMP_ROT_REAPER_PR_JSON fixture, gh/chump stubbed, hermetic ambient) and
# proves:
#   • MAIN GREEN, two PRs failing the SAME-NAMED gate + one failing another →
#     ALL reap (closed=3, held=0) — the exact independent-failure case that must
#     NOT be held (the regression this guard's definition avoids);
#   • MAIN RED (trunk-sentinel ambient) → EVERY required-red PR is HELD
#     (closed=0), and a pr_reap_held_systemic event is emitted;
#   • a STALE trunk-red (older than the freshness window) is ignored → reaps as
#     if main were green.
# plus source-wiring + event-registration asserts.
#
# Depth tier: EDGE — decision-path fixtures across the main-green / main-red /
# stale-red matrix driven through the REAL reaper with stubbed gh/chump and a
# hermetic ambient log, plus source-wiring and EVENT_REGISTRY asserts. Gaps:
# does not spin up a live GitHub, a real `verified` aggregate run, the live
# trunk-sentinel daemon, or the auto-merge-armer / operator-page side effects
# (the re-arm + page glue is covered by source-wiring + counts + the emitted
# event, not live delivery).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REAPER="$REPO_ROOT/scripts/ops/rot-reaper.sh"
REGISTRY_YAML="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
SENTINEL="$REPO_ROOT/scripts/coord/trunk-sentinel-daemon.sh"
for f in "$REAPER" "$REGISTRY_YAML" "$SENTINEL"; do
    [[ -f "$f" ]] || { echo "FAIL: required file missing: $f"; exit 1; }
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

# ── stub gh + chump; unconfigure the operator notifier so it stays a no-op ─────
STUB="$TMP/bin"; mkdir -p "$STUB"
cat > "$STUB/gh" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "api" && "$2" == "user" ]] && { echo "repairman29"; exit 0; }
exit 0
EOF
cat > "$STUB/chump" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$STUB"/*
export PATH="$STUB:$PATH"
unset DISCORD_TOKEN CHUMP_READY_DM_USER_ID 2>/dev/null || true

iso() { python3 -c "from datetime import datetime,timezone,timedelta;print((datetime.now(timezone.utc)-timedelta(hours=$1)).strftime('%Y-%m-%dT%H:%M:%SZ'))"; }
iso_min() { python3 -c "from datetime import datetime,timezone,timedelta;print((datetime.now(timezone.utc)-timedelta(minutes=$1)).strftime('%Y-%m-%dT%H:%M:%SZ'))"; }
OLD="$(iso 12)"   # past every age gate (realfail 8h)

REQ='verified,cargo-test-required,clippy-required,audit-required'

# Hermetic ambient + spare/flake state entirely inside TMP.
export NODE_AMBIENT="$TMP/ambient.jsonl"
export CHUMP_ROT_REAPER_SPARE_STATE_DIR="$TMP/spare-state"
export CHUMP_ROT_REAPER_FLAKE_COOLDOWN_DIR="$TMP/flake-cooldown"
: > "$NODE_AMBIENT"   # no trunk events → main NOT red

# #401/#402 both hard-fail the SAME-NAMED gate (cargo-test-required) — this is
# the INDEPENDENT-failure case the coordinator flagged: same-named gate, but no
# proof of a shared break. #403 hard-fails a different gate (clippy-required).
# With main GREEN, all three are individual failures and MUST reap.
CF='[{"name":"cargo-test-required","status":"COMPLETED","conclusion":"FAILURE"},{"name":"verified","status":"COMPLETED","conclusion":"FAILURE"}]'
KF='[{"name":"clippy-required","status":"COMPLETED","conclusion":"FAILURE"},{"name":"cargo-test-required","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"verified","status":"COMPLETED","conclusion":"FAILURE"}]'

FIX="$TMP/prs.json"
cat > "$FIX" <<EOF
[
  {"number":401,"title":"RESILIENT-1401: its OWN cargo-test-required failed (independent)","mergeStateStatus":"BLOCKED","mergeable":"MERGEABLE","createdAt":"$OLD","headRefName":"rs-1401","isDraft":false,"autoMergeRequest":{"enabledAt":"x"},"statusCheckRollup":$CF},
  {"number":402,"title":"RESILIENT-1402: its OWN cargo-test-required failed (independent, same-named gate)","mergeStateStatus":"BLOCKED","mergeable":"MERGEABLE","createdAt":"$OLD","headRefName":"rs-1402","isDraft":false,"autoMergeRequest":{"enabledAt":"x"},"statusCheckRollup":$CF},
  {"number":403,"title":"RESILIENT-1403: its OWN clippy-required failed","mergeStateStatus":"BLOCKED","mergeable":"MERGEABLE","createdAt":"$OLD","headRefName":"rs-1403","isDraft":false,"autoMergeRequest":{"enabledAt":"x"},"statusCheckRollup":$KF}
]
EOF

# ── RUN 1: MAIN GREEN — same-named gate failures are INDEPENDENT → all reap ────
# The regression guard: two PRs failing the same-named gate with a GREEN main
# must NOT be held. (This is exactly what broke the existing suite before.)
out="$(CHUMP_ROT_REAPER_PR_JSON="$FIX" CHUMP_ROT_REAPER_REQUIRED_CHECKS="$REQ" bash "$REAPER" 2>&1)"
echo "$out"; echo "---"
echo "$out" | grep -q 'held=0'   && ok "MAIN GREEN: nothing held (held=0) — same-named gate failures treated as independent" || bad "MAIN GREEN held a PR (regression: independent same-gate failures must reap)"
echo "$out" | grep -q 'closed=3' && ok "MAIN GREEN: all three required-red PRs reap individually (closed=3)"                   || bad "MAIN GREEN close count wrong (expected closed=3)"
for n in 401 402 403; do
    echo "$out" | grep -qE "PR #$n .*→ REAP" && ok "#$n reaped (individual required-red, main green)" || bad "#$n not reaped under green main"
done

# ── RUN 2: MAIN RED (trunk-sentinel ambient) → every required-red PR HELD ──────
: > "$NODE_AMBIENT"
FRESH="$(iso_min 3)"
printf '{"ts":"%s","kind":"trunk_red_persistent","source":"trunk_sentinel_daemon","red_minutes":3,"failing_jobs":"cargo-test-required","run_id":9,"head_sha":"deadbeef"}\n' "$FRESH" >> "$NODE_AMBIENT"
out2="$(CHUMP_ROT_REAPER_PR_JSON="$FIX" CHUMP_ROT_REAPER_REQUIRED_CHECKS="$REQ" bash "$REAPER" 2>&1)"
echo "$out2"; echo "---"
echo "$out2" | grep -q 'closed=0' && ok "MAIN RED: NOTHING closed (closed=0) — trunk-red holds the whole required-red class" || bad "MAIN RED run closed a PR (expected closed=0)"
echo "$out2" | grep -q 'held=3'   && ok "MAIN RED: all three required-red PRs HELD (held=3)"                                  || bad "MAIN RED hold count wrong (expected held=3)"
echo "$out2" | grep -qiE 'main RED' && ok "MAIN RED: trunk-sentinel signal consumed + surfaced"                               || bad "MAIN RED signal not surfaced"
grep -q '"kind":"pr_reap_held_systemic"' "$NODE_AMBIENT"       && ok "pr_reap_held_systemic emitted to ambient" || bad "no pr_reap_held_systemic event emitted"
grep -q '"kind":"pr_reap_held_systemic".*"pr":401' "$NODE_AMBIENT" && ok "held event carries the PR number (401)" || bad "held event missing pr 401"

# ── RUN 3: STALE trunk-red (older than the freshness window) is IGNORED ────────
: > "$NODE_AMBIENT"
STALE="$(iso_min 600)"   # 10h old, well past the 90m default window
printf '{"ts":"%s","kind":"trunk_red_persistent","source":"trunk_sentinel_daemon","red_minutes":600,"failing_jobs":"cargo-test-required","run_id":1,"head_sha":"old"}\n' "$STALE" >> "$NODE_AMBIENT"
out3="$(CHUMP_ROT_REAPER_PR_JSON="$FIX" CHUMP_ROT_REAPER_REQUIRED_CHECKS="$REQ" bash "$REAPER" 2>&1)"
echo "$out3" | grep -q 'closed=3' && ok "stale trunk-red ignored (closed=3, reaps as if main green)" || bad "stale trunk-red not ignored (closed != 3)"
echo "$out3" | grep -q 'held=0'   && ok "stale trunk-red ignored (held=0)"                            || bad "stale trunk-red still held a PR"

echo ""
echo "=== reaper end-to-end: $pass passed so far ==="

# ── source-wiring asserts ─────────────────────────────────────────────────────
grep -q 'is_systemic_red'   "$REAPER" && ok "reaper: has is_systemic_red guard"    || bad "reaper: no is_systemic_red guard"
grep -q 'hold_systemic_red' "$REAPER" && ok "reaper: has hold_systemic_red action" || bad "reaper: no hold_systemic_red action"
grep -q 'trunk_red_persistent' "$REAPER" && ok "reaper: consumes the trunk-sentinel main-red signal" || bad "reaper: does not consume the trunk-sentinel signal"
grep -q 'trunk-sentinel' "$REAPER" && ok "reaper: cites the trunk-sentinel-daemon as the systemic source" || bad "reaper: does not reference the trunk-sentinel"
# Main-red must be the GATE: is_systemic_red returns true only on MAIN_RED.
grep -qE 'is_systemic_red\(\)[[:space:]]*\{' "$REAPER" && ok "reaper: is_systemic_red is a zero-arg predicate (main-red gate)" || bad "reaper: is_systemic_red signature changed unexpectedly"
# There must be NO env toggle to DISABLE the systemic hold (safety must be unconditional).
grep -qE 'CHUMP_ROT_REAPER_SYSTEMIC_(DISABLED|OFF)' "$REAPER" && bad "reaper: a disable toggle for the systemic hold exists (forbidden — safety must be unconditional)" || ok "reaper: no disable toggle for the systemic hold (unconditional safety)"

# The systemic guard must precede the CLASS-2 close in source order.
_guard_line=$(grep -n 'if is_systemic_red;' "$REAPER" | head -1 | cut -d: -f1)
_close_line=$(grep -n 'label_and_close "\$PR_NUM" "\$MSG"' "$REAPER" | tail -1 | cut -d: -f1)
if [[ -n "$_guard_line" && -n "$_close_line" && "$_guard_line" -lt "$_close_line" ]]; then
    ok "systemic guard (L$_guard_line) precedes the CLASS-2 close (L$_close_line)"
else
    bad "systemic guard does not precede the close (guard=$_guard_line close=$_close_line)"
fi

# ── new event kind registered in EVENT_REGISTRY.yaml ──────────────────────────
grep -qE '^\s*-\s+kind:\s*pr_reap_held_systemic\b' "$REGISTRY_YAML" \
    && ok "event registered: pr_reap_held_systemic" \
    || bad "event NOT registered in EVENT_REGISTRY.yaml: pr_reap_held_systemic"

echo ""
if [[ "$fail" -eq 0 ]]; then
    echo "test-rot-reaper-systemic-red-hold: ALL $pass passed"
    exit 0
else
    echo "test-rot-reaper-systemic-red-hold: $pass passed, $fail failed"
    exit 1
fi
