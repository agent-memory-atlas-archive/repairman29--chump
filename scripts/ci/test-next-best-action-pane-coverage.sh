#!/usr/bin/env bash
# scripts/ci/test-next-best-action-pane-coverage.sh — RESILIENT-422
#
# Proves next-best-action.sh's pane_coverage_pct() signal:
#   1. no chump-fleet tmux session -> 0% coverage
#   2. session up, worker panes == target -> 100% coverage
#   3. session up, worker panes < target -> partial pct, clamped [0,100]
#   4. the GAP_CAND dispatch_worker_p0/p1 p_success is DISCOUNTED by pane
#      coverage even when no journey-odds file exists (falls back to the
#      ACTION_TABLE default, not left un-discounted) — this is the actual
#      "NBA engine scored not vibed" behavior: a starved worker pool must
#      measurably lower the EV of "dispatch the top P0 gap", not silently
#      keep reporting the table default as if the pool were healthy.
#
# Without the RESILIENT-422 change, pane_coverage_pct() does not exist and
# dispatch_worker_* p_success is a flat p_default regardless of live pane
# count — this test fails on both counts against the pre-change script.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NBA="$REPO_ROOT/scripts/coord/next-best-action.sh"
[[ -f "$NBA" ]] || { echo "FATAL: $NBA not found" >&2; exit 1; }

PASS=0; FAIL=0
_ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
_fail() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }

# ── Load the REAL pane_coverage_pct() straight out of the script ────────────
eval "$(sed -n '/^pane_coverage_pct() {/,/^}/p' "$NBA")"
type pane_coverage_pct >/dev/null 2>&1 || { echo "FATAL: pane_coverage_pct() did not load from $NBA" >&2; exit 1; }
_ok "pane_coverage_pct() loaded from next-best-action.sh"

# Stub tmux: MOCK_SESSION (0/1) and MOCK_LIVE_PANES (count of pane_dead==0
# lines, INCLUDING the control pane — matches real tmux list-panes output).
tmux() {
  case "${1:-}" in
    has-session) [[ "${MOCK_SESSION:-0}" == "1" ]] && return 0 || return 1 ;;
    list-panes)  local i; for ((i=0;i<${MOCK_LIVE_PANES:-0};i++)); do echo 0; done ;;
    *) return 0 ;;
  esac
}

# ── 1. no session -> 0% ──────────────────────────────────────────────────────
MOCK_SESSION=0 MOCK_LIVE_PANES=0
pct="$(CHUMP_FLEET_TARGET_SIZE=2 pane_coverage_pct)"
[[ "$pct" == "0" ]] && _ok "no tmux session -> 0% coverage" || _fail "expected 0, got $pct"

# ── 2. session up, control + 2 workers, target=2 -> 100% ────────────────────
MOCK_SESSION=1 MOCK_LIVE_PANES=3
pct="$(CHUMP_FLEET_TARGET_SIZE=2 pane_coverage_pct)"
[[ "$pct" == "100" ]] && _ok "3 live panes (1 control + 2 workers), target=2 -> 100%" || _fail "expected 100, got $pct"

# ── 3. session up, control + 1 worker, target=2 -> 50% ───────────────────────
MOCK_SESSION=1 MOCK_LIVE_PANES=2
pct="$(CHUMP_FLEET_TARGET_SIZE=2 pane_coverage_pct)"
[[ "$pct" == "50" ]] && _ok "2 live panes (1 control + 1 worker), target=2 -> 50%" || _fail "expected 50, got $pct"

# ── 4. over-provisioned pool clamps to 100, never exceeds ────────────────────
MOCK_SESSION=1 MOCK_LIVE_PANES=10
pct="$(CHUMP_FLEET_TARGET_SIZE=2 pane_coverage_pct)"
[[ "$pct" == "100" ]] && _ok "over-provisioned pool clamps to 100% (not >100)" || _fail "expected 100, got $pct"

# ── 5. GAP_CAND p_success discount: replicate the real jq filter from the
#    script verbatim (extracted, not re-derived) and assert the dispatch_worker_p0
#    bet is scaled by pane_frac even with jo=null (no journey-odds file). ─────
GAP_CAND_JQ='
  ( if $p0>0 then [ { source:"gap", action:"dispatch_worker_p0",
       target:("top of \($p0) open P0 gaps"),
       label:("\($p0) open P0 gaps waiting for a worker"),
       p_success:(( (if $jo != null then $jo else $tbl.dispatch_worker_p0.p_default end) * $pane_frac )) } ] else [] end )
  + ( if $p1>0 then [ { source:"gap", action:"dispatch_worker_p1",
       target:("top of \($p1) open P1 gaps"),
       label:("\($p1) open P1 gaps waiting for a worker"),
       p_success:(( (if $jo != null then $jo else $tbl.dispatch_worker_p1.p_default end) * $pane_frac )) } ] else [] end )'
grep -qF "$GAP_CAND_JQ" "$NBA" && _ok "GAP_CAND jq filter present verbatim in next-best-action.sh" \
  || _fail "GAP_CAND pane-discount filter missing/changed in next-best-action.sh"

TBL='{"dispatch_worker_p0":{"p_default":0.55},"dispatch_worker_p1":{"p_default":0.55}}'
RES="$(jq -n -c --argjson p0 1 --argjson p1 1 --argjson jo null --argjson tbl "$TBL" --argjson pane_frac 0.5 "$GAP_CAND_JQ")"
P0_SUCCESS="$(echo "$RES" | jq -r '.[0].p_success')"
[[ "$P0_SUCCESS" == "0.275" ]] && _ok "no journey-odds + 50% pane coverage -> p_success 0.55*0.5=0.275 (discounted, not flat default)" \
  || { echo "$RES"; _fail "expected p_success 0.275, got $P0_SUCCESS"; }

RES_FULL="$(jq -n -c --argjson p0 1 --argjson p1 1 --argjson jo null --argjson tbl "$TBL" --argjson pane_frac 1.0 "$GAP_CAND_JQ")"
P0_FULL="$(echo "$RES_FULL" | jq -r '.[0].p_success')"
[[ "$P0_FULL" == "0.55" ]] && _ok "100% pane coverage -> p_success == table default (0.55), no spurious discount" \
  || { echo "$RES_FULL"; _fail "expected p_success 0.55, got $P0_FULL"; }

# ── 6. INFRA-8592: current-head-only check evaluation + stale cache row ignored + head SHA named ──
TMP_NBA="$(mktemp -d "${TMPDIR:-/tmp}/nba-infra8592.XXXXXX")"
trap 'rm -rf "$TMP_NBA"' EXIT
: > "$TMP_NBA/failed-units.txt"
echo "[]" > "$TMP_NBA/gaps.json"

# AC1: red on old head (e882a794a), 3 pending on current head (a472c09d1), mergeStateStatus=UNSTABLE -> wait_ci
cat > "$TMP_NBA/prs-ac1.json" <<'EOF'
[
  {
    "number": 5589,
    "title": "INFRA: example repair push",
    "mergeStateStatus": "UNSTABLE",
    "createdAt": "2026-10-18T14:00:00Z",
    "updatedAt": "2026-10-18T15:38:00Z",
    "headCommittedAt": "2026-10-18T15:38:00Z",
    "isDraft": false,
    "headRefOid": "a472c09d1",
    "statusCheckRollup": [
      {"name": "unit-test", "status": "COMPLETED", "conclusion": "FAILURE", "headSha": "e882a794a", "completedAt": "2026-10-18T15:20:00Z"},
      {"name": "unit-test", "status": "IN_PROGRESS", "conclusion": null, "headSha": "a472c09d1", "startedAt": "2026-10-18T15:38:10Z"},
      {"name": "clippy", "status": "QUEUED", "conclusion": null, "headSha": "a472c09d1", "startedAt": "2026-10-18T15:38:11Z"},
      {"name": "verified", "status": "PENDING", "conclusion": null, "headSha": "a472c09d1", "startedAt": "2026-10-18T15:38:12Z"}
    ]
  }
]
EOF

CHUMP_NBA_OUT="$TMP_NBA/out-ac1.json" \
CHUMP_NBA_PR_FIXTURE="$TMP_NBA/prs-ac1.json" \
CHUMP_NBA_FAILED_UNITS_FIXTURE="$TMP_NBA/failed-units.txt" \
CHUMP_NBA_GAPS_FIXTURE="$TMP_NBA/gaps.json" \
CHUMP_FACULTY_OUT="$TMP_NBA/no-faculty.json" \
CHUMP_JOURNEY_ODDS="$TMP_NBA/no-journey.json" \
CHUMP_CACHE_DB="$TMP_NBA/no-cache.db" \
  bash "$NBA" --no-emit >/dev/null 2>&1

AC1_ACT="$(jq -r '.recommendations[0].action // empty' "$TMP_NBA/out-ac1.json")"
AC1_HEAD="$(jq -r '.recommendations[0].head_sha // empty' "$TMP_NBA/out-ac1.json")"
AC1_WHY="$(jq -r '.recommendations[0].why // empty' "$TMP_NBA/out-ac1.json")"
[[ "$AC1_ACT" == "wait_ci" ]] && _ok "INFRA-8592 AC1: red on old head + pending on current head -> wait_ci (not fix_own_red)" \
  || _fail "INFRA-8592 AC1: expected wait_ci, got $AC1_ACT ($(cat "$TMP_NBA/out-ac1.json"))"
[[ "$AC1_HEAD" == "a472c09d1" && "$AC1_WHY" == *"a472c09d1"* ]] \
  && _ok "INFRA-8592 AC3: recommendation names evaluated head SHA (a472c09d1)" \
  || _fail "INFRA-8592 AC3: expected head_sha=a472c09d1 in recommendation, got head_sha=$AC1_HEAD why=$AC1_WHY"

# AC2: stale cache rows (old head e882a794a AND row with timestamp older than headCommittedAt) are ignored
sqlite3 "$TMP_NBA/cache.db" <<'SQL'
CREATE TABLE pr_state (
    number INTEGER PRIMARY KEY,
    head_ref TEXT, head_sha TEXT, base_ref TEXT, base_sha TEXT,
    mergeable_state TEXT, auto_merge_enabled INTEGER NOT NULL DEFAULT 0,
    draft INTEGER NOT NULL DEFAULT 0, merged_at TEXT, title TEXT, user_login TEXT,
    updated_at_api TEXT NOT NULL, fetched_at_local TEXT NOT NULL,
    raw_payload_json TEXT, merge_state_status TEXT
);
CREATE TABLE check_runs (
    head_sha TEXT NOT NULL, name TEXT NOT NULL, status TEXT, conclusion TEXT,
    started_at TEXT, completed_at TEXT, fetched_at_local TEXT NOT NULL,
    PRIMARY KEY (head_sha, name)
);
INSERT INTO pr_state (number, head_sha, updated_at_api, fetched_at_local, raw_payload_json)
VALUES (5589, 'e882a794a', '2026-10-18T15:25:00Z', '2026-10-18T15:25:00Z',
        '{"statusCheckRollup":[{"name":"unit-test","status":"COMPLETED","conclusion":"FAILURE"}]}');
INSERT INTO check_runs VALUES ('e882a794a', 'unit-test', 'COMPLETED', 'FAILURE', '2026-10-18T15:18:00Z', '2026-10-18T15:20:00Z', '2026-10-18T15:20:00Z');
INSERT INTO check_runs VALUES ('a472c09d1', 'stale-row', 'COMPLETED', 'FAILURE', '2026-10-18T15:30:00Z', '2026-10-18T15:31:00Z', '2026-10-18T15:31:00Z');
SQL

CHUMP_NBA_OUT="$TMP_NBA/out-ac2.json" \
CHUMP_NBA_PR_FIXTURE="$TMP_NBA/prs-ac1.json" \
CHUMP_NBA_FAILED_UNITS_FIXTURE="$TMP_NBA/failed-units.txt" \
CHUMP_NBA_GAPS_FIXTURE="$TMP_NBA/gaps.json" \
CHUMP_FACULTY_OUT="$TMP_NBA/no-faculty.json" \
CHUMP_JOURNEY_ODDS="$TMP_NBA/no-journey.json" \
CHUMP_CACHE_DB="$TMP_NBA/cache.db" \
  bash "$NBA" --no-emit >/dev/null 2>&1

AC2_ACT="$(jq -r '.recommendations[0].action // empty' "$TMP_NBA/out-ac2.json")"
[[ "$AC2_ACT" == "wait_ci" ]] && _ok "INFRA-8592 AC2: stale cache rows (old head + timestamp older than head) ignored -> wait_ci" \
  || _fail "INFRA-8592 AC2: expected wait_ci with stale cache, got $AC2_ACT ($(cat "$TMP_NBA/out-ac2.json"))"

# Control: genuine failure on the current head still produces fix_own_red
cat > "$TMP_NBA/prs-red.json" <<'EOF'
[
  {
    "number": 5590,
    "title": "INFRA: genuinely broken on current head",
    "mergeStateStatus": "BLOCKED",
    "createdAt": "2026-10-18T14:00:00Z",
    "updatedAt": "2026-10-18T15:38:00Z",
    "headCommittedAt": "2026-10-18T15:38:00Z",
    "isDraft": false,
    "headRefOid": "deadbeef1",
    "statusCheckRollup": [
      {"name": " bespoke-unit-test", "status": "COMPLETED", "conclusion": "FAILURE", "headSha": "deadbeef1", "completedAt": "2026-10-18T15:40:00Z"}
    ]
  }
]
EOF

CHUMP_NBA_OUT="$TMP_NBA/out-red.json" \
CHUMP_NBA_PR_FIXTURE="$TMP_NBA/prs-red.json" \
CHUMP_NBA_FAILED_UNITS_FIXTURE="$TMP_NBA/failed-units.txt" \
CHUMP_NBA_GAPS_FIXTURE="$TMP_NBA/gaps.json" \
CHUMP_FACULTY_OUT="$TMP_NBA/no-faculty.json" \
CHUMP_JOURNEY_ODDS="$TMP_NBA/no-journey.json" \
CHUMP_CACHE_DB="$TMP_NBA/no-cache.db" \
  bash "$NBA" --no-emit >/dev/null 2>&1

RED_ACT="$(jq -r '.recommendations[0].action // empty' "$TMP_NBA/out-red.json")"
RED_HEAD="$(jq -r '.recommendations[0].head_sha // empty' "$TMP_NBA/out-red.json")"
[[ "$RED_ACT" == "fix_own_red" && "$RED_HEAD" == "deadbeef1" ]] \
  && _ok "INFRA-8592 control: real FAILURE on current head still scores fix_own_red with head_sha=deadbeef1" \
  || _fail "INFRA-8592 control: expected fix_own_red/deadbeef1, got $RED_ACT/$RED_HEAD"

echo ""
if [[ "$FAIL" -eq 0 ]]; then
  echo "PASS: test-next-best-action-pane-coverage ($PASS checks)"
  exit 0
else
  echo "FAIL: test-next-best-action-pane-coverage ($FAIL failed, $PASS passed)"
  exit 1
fi
