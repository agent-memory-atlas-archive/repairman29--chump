#!/usr/bin/env bash
# test-trunk-recovery-reviver.sh — RESILIENT-1190
#
# Asserts the trunk-recovery reviver:
#   A. Pure victim decision (--decide fixtures):
#      1. reaper-marked + in-window + green-underneath  → revive
#      2. NOT reaper-marked (human close)               → skip:not_reaper_closed
#      3. hard_fail NOW                                 → skip:still_hard_fail
#      4. conflict NOW                                  → skip:still_conflict
#      5. closed out-of-window                          → skip:out_of_window
#      6. merged                                        → skip:merged
#      7. superseded (gap done)                         → skip:gap_done
#   B. Window derivation from ambient (onset = last red before recovery).
#   C. End-to-end DRY_RUN beat over a mock closed-PR list:
#      - a true trunk-red victim → pr_revived_post_trunk_recovery emitted
#      - a human-closed / hard-fail / out-of-window PR → NOT revived
#      - idempotent: a second beat does NOT re-emit for the same PR+recovery
#      - MAX_PER_RUN cap honored
#   D. Wiring: manifest + install roster + event registry + scanner-anchors.
#
# Hermetic: no gh, no network, no root. Uses --decide/--window fixture modes and
# CHUMP_TRUNK_REVIVE_MOCK_PRS_JSON + CHUMP_TRUNK_REVIVE_DRY_RUN for the beat.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REVIVER="$REPO_ROOT/scripts/coord/trunk-recovery-reviver.sh"

[[ -f "$REVIVER" ]] || { echo "FAIL: $REVIVER missing"; exit 1; }

pass=0; fail=0
ok()   { echo "PASS $1"; pass=$((pass+1)); }
bad()  { echo "FAIL $1"; fail=$((fail+1)); }
# grep -c prints "0" AND exits 1 on no-match; capture without a doubling `|| echo 0`.
cnt()  { local c; c="$(grep -c "$1" "$2" 2>/dev/null)"; echo "${c:-0}"; }

TMP="$(mktemp -d /tmp/test-trunk-revive.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# ── A. Pure victim decision ───────────────────────────────────────────────────
cat > "$TMP/decide.json" <<'EOF'
{"win_lo":1000,"win_hi":2000,"prs":[
 {"number":101,"state":"CLOSED","closedAt":"1970-01-01T00:25:00Z","mergedAt":"","reaper_marked":1,"gap_status":"","classify_verdict":"pending"},
 {"number":102,"state":"CLOSED","closedAt":"1970-01-01T00:25:00Z","mergedAt":"","reaper_marked":0,"gap_status":"","classify_verdict":"pending"},
 {"number":103,"state":"CLOSED","closedAt":"1970-01-01T00:25:00Z","mergedAt":"","reaper_marked":1,"gap_status":"","classify_verdict":"hard_fail"},
 {"number":104,"state":"CLOSED","closedAt":"1970-01-01T00:25:00Z","mergedAt":"","reaper_marked":1,"gap_status":"","classify_verdict":"conflict"},
 {"number":105,"state":"CLOSED","closedAt":"1970-01-01T05:00:00Z","mergedAt":"","reaper_marked":1,"gap_status":"","classify_verdict":"pending"},
 {"number":106,"state":"CLOSED","closedAt":"1970-01-01T00:25:00Z","mergedAt":"1970-01-01T00:26:00Z","reaper_marked":1,"gap_status":"","classify_verdict":"pending"},
 {"number":107,"state":"CLOSED","closedAt":"1970-01-01T00:25:00Z","mergedAt":"","reaper_marked":1,"gap_status":"done","classify_verdict":"pending"},
 {"number":108,"state":"CLOSED","closedAt":"1970-01-01T00:25:00Z","mergedAt":"","reaper_marked":1,"gap_status":"","classify_verdict":"blocked_no_failure"}
]}
EOF
D="$(bash "$REVIVER" --decide "$TMP/decide.json")"

check_decision() {  # <pr> <expected>
    local got; got="$(printf '%s\n' "$D" | awk -v p="$1" '$1==p{print $2}')"
    if [[ "$got" == "$2" ]]; then ok "A: PR $1 → $2"; else bad "A: PR $1 expected $2, got '$got'"; fi
}
check_decision 101 revive
check_decision 102 skip:not_reaper_closed
check_decision 103 skip:still_hard_fail
check_decision 104 skip:still_conflict
check_decision 105 skip:out_of_window
check_decision 106 skip:merged
check_decision 107 skip:gap_done
check_decision 108 revive

# ── B. Window derivation from ambient ─────────────────────────────────────────
AMB="$TMP/ambient.jsonl"
_iso() { python3 -c "from datetime import datetime,timezone,timedelta; print((datetime.now(timezone.utc)-timedelta(seconds=$1)).strftime('%Y-%m-%dT%H:%M:%SZ'))"; }
ONSET_ISO="$(_iso 1800)"   # red onset 30m ago
REC_ISO="$(_iso 120)"      # recovered 2m ago
{
  printf '{"ts":"%s","kind":"trunk_state_change","from":"TRUNK_GREEN","to":"TRUNK_RED"}\n' "$ONSET_ISO"
  printf '{"ts":"%s","kind":"trunk_red_persistent","red_minutes":10}\n' "$(_iso 1200)"
  printf '{"ts":"%s","kind":"trunk_recovered","closed_gaps_count":1}\n' "$REC_ISO"
} > "$AMB"

WIN_OUT="$(CHUMP_AMBIENT_PATH="$AMB" bash "$REVIVER" --window)"
rec_epoch="$(echo "$WIN_OUT" | sed -n 's/.*recovered_epoch=\([0-9]*\).*/\1/p')"
onset_epoch="$(echo "$WIN_OUT" | sed -n 's/.*onset_epoch=\([0-9]*\).*/\1/p')"
if [[ "${rec_epoch:-0}" -gt 0 && "${onset_epoch:-0}" -gt 0 && "$onset_epoch" -lt "$rec_epoch" ]]; then
    ok "B: window derived (onset=$onset_epoch < recovered=$rec_epoch)"
else
    bad "B: window mis-derived: $WIN_OUT"
fi

# Stale recovery (older than RECOVERY_MAX_AGE_MIN) → no actionable window.
AMB_STALE="$TMP/ambient-stale.jsonl"
{
  printf '{"ts":"%s","kind":"trunk_state_change","from":"TRUNK_GREEN","to":"TRUNK_RED"}\n' "$(_iso 90000)"
  printf '{"ts":"%s","kind":"trunk_recovered","closed_gaps_count":1}\n' "$(_iso 80000)"
} > "$AMB_STALE"
WIN_STALE="$(CHUMP_AMBIENT_PATH="$AMB_STALE" CHUMP_TRUNK_REVIVE_RECOVERY_MAX_AGE_MIN=180 bash "$REVIVER" --window)"
if echo "$WIN_STALE" | grep -q "recovered_epoch=0"; then
    ok "B: stale recovery (>max-age) → no actionable window"
else
    bad "B: stale recovery incorrectly actionable: $WIN_STALE"
fi

# ── C. End-to-end DRY_RUN beat ────────────────────────────────────────────────
# Build a mock closed-PR list. closedAt values sit inside the derived window.
CLOSED_IN="$(_iso 600)"     # 10m ago — inside [onset,recovered]
CLOSED_OUT="$(_iso 90000)"  # long before onset — outside
PRS="$TMP/prs.json"
cat > "$PRS" <<EOF
[
 {"number":201,"headRefName":"chump/infra-9001-fix","state":"CLOSED","closedAt":"$CLOSED_IN","mergedAt":"","labels":[{"name":"rot-reaped"}],"classify_verdict":"pending"},
 {"number":202,"headRefName":"chump/infra-9002-fix","state":"CLOSED","closedAt":"$CLOSED_IN","mergedAt":"","labels":[],"classify_verdict":"pending"},
 {"number":203,"headRefName":"chump/infra-9003-fix","state":"CLOSED","closedAt":"$CLOSED_IN","mergedAt":"","labels":[{"name":"rot-reaped"}],"classify_verdict":"hard_fail"},
 {"number":204,"headRefName":"chump/infra-9004-fix","state":"CLOSED","closedAt":"$CLOSED_OUT","mergedAt":"","labels":[{"name":"rot-reaped"}],"classify_verdict":"pending"}
]
EOF

STATE="$TMP/reviver-state.json"
run_beat() {
    CHUMP_AMBIENT_PATH="$AMB" \
    CHUMP_TRUNK_REVIVE_MOCK_PRS_JSON="$PRS" \
    CHUMP_TRUNK_REVIVE_DRY_RUN=1 \
    CHUMP_TRUNK_REVIVE_STATE_FILE="$STATE" \
    bash "$REVIVER" >/dev/null 2>&1
}

run_beat
n_201="$(cnt '"kind":"pr_revived_post_trunk_recovery".*"pr":201' "$AMB")"
n_202="$(cnt '"kind":"pr_revived_post_trunk_recovery".*"pr":202' "$AMB")"
n_203="$(cnt '"kind":"pr_revived_post_trunk_recovery".*"pr":203' "$AMB")"
n_204="$(cnt '"kind":"pr_revived_post_trunk_recovery".*"pr":204' "$AMB")"

[[ "$n_201" -eq 1 ]] && ok "C: victim PR #201 revived (event emitted)" || bad "C: PR #201 not revived (n=$n_201)"
[[ "$n_202" -eq 0 ]] && ok "C: human-closed PR #202 NOT revived" || bad "C: PR #202 wrongly revived (n=$n_202)"
[[ "$n_203" -eq 0 ]] && ok "C: hard-fail PR #203 NOT revived" || bad "C: PR #203 wrongly revived (n=$n_203)"
[[ "$n_204" -eq 0 ]] && ok "C: out-of-window PR #204 NOT revived" || bad "C: PR #204 wrongly revived (n=$n_204)"

# Idempotency: a second beat must not re-emit for #201.
run_beat
n_201_after="$(cnt '"kind":"pr_revived_post_trunk_recovery".*"pr":201' "$AMB")"
[[ "$n_201_after" -eq 1 ]] && ok "C: idempotent (PR #201 not re-revived on 2nd beat)" || bad "C: PR #201 re-revived (n=$n_201_after)"

# MAX_PER_RUN cap: with two in-window victims and cap=1, only one revives.
PRS2="$TMP/prs2.json"
cat > "$PRS2" <<EOF
[
 {"number":301,"headRefName":"chump/infra-9101-fix","state":"CLOSED","closedAt":"$CLOSED_IN","mergedAt":"","labels":[{"name":"rot-reaped"}],"classify_verdict":"pending"},
 {"number":302,"headRefName":"chump/infra-9102-fix","state":"CLOSED","closedAt":"$CLOSED_IN","mergedAt":"","labels":[{"name":"rot-reaped"}],"classify_verdict":"pending"}
]
EOF
AMB2="$TMP/ambient2.jsonl"
{
  printf '{"ts":"%s","kind":"trunk_state_change","from":"TRUNK_GREEN","to":"TRUNK_RED"}\n' "$ONSET_ISO"
  printf '{"ts":"%s","kind":"trunk_recovered","closed_gaps_count":1}\n' "$REC_ISO"
} > "$AMB2"
CHUMP_AMBIENT_PATH="$AMB2" CHUMP_TRUNK_REVIVE_MOCK_PRS_JSON="$PRS2" \
  CHUMP_TRUNK_REVIVE_DRY_RUN=1 CHUMP_TRUNK_REVIVE_STATE_FILE="$TMP/state2.json" \
  CHUMP_TRUNK_REVIVE_MAX_PER_RUN=1 bash "$REVIVER" >/dev/null 2>&1
cap_count="$(cnt '"kind":"pr_revived_post_trunk_recovery"' "$AMB2")"
[[ "$cap_count" -eq 1 ]] && ok "C: MAX_PER_RUN=1 cap honored (1 revive)" || bad "C: cap not honored (revived $cap_count)"

# ── D. Wiring ─────────────────────────────────────────────────────────────────
MANIFEST="$REPO_ROOT/scripts/ops/organ-manifest.txt"
INSTALL="$REPO_ROOT/scripts/setup/install-helsinki-atc.sh"
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
SVC="$REPO_ROOT/scripts/dispatch/chump-trunk-recovery-reviver.service"
TMR="$REPO_ROOT/scripts/dispatch/chump-trunk-recovery-reviver.timer"

grep -q '^enabled .*chump-trunk-recovery-reviver.timer' "$MANIFEST" \
    && ok "D: manifest declares chump-trunk-recovery-reviver.timer" \
    || bad "D: manifest missing reviver timer"

grep -q 'chump-trunk-recovery-reviver.service' "$INSTALL" && grep -q 'chump-trunk-recovery-reviver.timer' "$INSTALL" \
    && ok "D: install roster (SYSTEM_UNITS + SYSTEM_TIMERS) lists reviver" \
    || bad "D: install roster missing reviver unit(s)"

[[ -f "$SVC" && -f "$TMR" ]] && ok "D: systemd .service + .timer present" || bad "D: systemd units missing"

grep -q 'kind: pr_revived_post_trunk_recovery' "$REGISTRY" && grep -q 'kind: trunk_recovery_reviver_tick' "$REGISTRY" \
    && ok "D: both events registered in EVENT_REGISTRY.yaml" \
    || bad "D: events not registered in EVENT_REGISTRY.yaml"

# scanner-anchor comments present so the emit-coverage scanner sees the dynamic emit.
grep -q 'scanner-anchor: "kind":"pr_revived_post_trunk_recovery"' "$REVIVER" \
    && grep -q 'scanner-anchor: "kind":"trunk_recovery_reviver_tick"' "$REVIVER" \
    && ok "D: scanner-anchor comments present in reviver" \
    || bad "D: scanner-anchor comments missing"

echo
if [[ "$fail" -eq 0 ]]; then
    echo "test-trunk-recovery-reviver: ALL $pass passed"
    exit 0
else
    echo "test-trunk-recovery-reviver: $pass passed, $fail failed"
    exit 1
fi
