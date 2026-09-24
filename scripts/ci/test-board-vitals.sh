#!/usr/bin/env bash
# scripts/ci/test-board-vitals.sh — RESILIENT-371 smoke/behaviour test for
# scripts/coord/lib/board-vitals.sh, the resident board's non-merge vital-signs
# watch.
#
# Self-contained + offline: synthetic ambient logs, a temp dedup state dir, and
# DRY_RUN so nothing is DM'd and no LLM is called. Disk paging is exercised by
# forcing the threshold below the node's real usage (a deterministic way to make
# ONE real incident fire), which drives the real _bv_maybe_page dedup path. Runs
# in well under a second, mutates no fleet state.

set -uo pipefail   # NOT -e: we assert exit codes / emissions explicitly

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LIB="$REPO_ROOT/scripts/coord/lib/board-vitals.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

# CREDIBLE-1303: every scenario below is about SOMETHING ELSE — without this,
# each subshell would fall through to the real $HOME/.almanac/vision-acuity.state
# (if any) and the almanac_coverage_low check could non-deterministically fire
# and pollute unrelated assertions. Point at a path that never exists by
# default; the dedicated almanac tests below override it per-case.
export CHUMP_BOARD_VITALS_ALMANAC_STATE="$TMP/no-such-almanac.state"

_ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
_fail() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }
_emitted()   { if grep -qE "$3" "$2" 2>/dev/null; then _ok "$1"; else _fail "$1 (no /$3/ in $2)"; fi; }
_notemitted(){ if grep -qE "$3" "$2" 2>/dev/null; then _fail "$1 (unexpected /$3/)"; else _ok "$1"; fi; }
_count()     { grep -cE "$2" "$1" 2>/dev/null || echo 0; }

[[ -f "$LIB" ]] || { printf 'FATAL: %s not found\n' "$LIB" >&2; exit 1; }

echo "[test-board-vitals] sourcing contract"
( source "$LIB" && declare -F board_vitals_check >/dev/null ) \
    && _ok "sourcing defines board_vitals_check" \
    || _fail "sourcing defines board_vitals_check"

# ── disk incident: force threshold below real usage, DRY_RUN, dedup ──────────
echo "[test-board-vitals] disk incident pages once then dedupes"
A="$TMP/disk.jsonl"; : > "$A"     # empty ambient → worker_ep=0 → worker checks inert
SD="$TMP/state-disk"
run_disk() {
    ( set -a
      CHUMP_AMBIENT_LOG="$A"; CHUMP_BOARD_VITALS_STATE_DIR="$SD"
      CHUMP_BOARD_VITALS_DRY_RUN=1; CHUMP_BOARD_VITALS_ESCALATE=0
  CHUMP_BOARD_VITALS_MAIN_RED_LIVE=0        # keep pre-RESILIENT-414 tests hermetic (no live gh/watchdog call)
      CHUMP_BOARD_VITALS_DISK_PCT=1          # real usage always exceeds 1%
      CHUMP_BOARD_VITALS_DROUGHT_MIN=999999  # never fire drought in the test
      set +a
      source "$LIB"; board_vitals_check )
}
rc=0; run_disk >/dev/null 2>&1 || rc=$?
_ok "first run exits 0 (rc=$rc)"
_emitted "first run would-page (dryrun) for disk_full" "$A" '"board_vitals_page_dryrun".*"disk_full"'
_emitted "first run emits board_vitals_tick with incidents>=1" "$A" '"board_vitals_tick","incidents":[1-9]'
run_disk >/dev/null 2>&1
dd_count="$(_count "$A" '"board_vitals_page_deduped".*"disk_full"')"
[[ "$dd_count" -ge 1 ]] && _ok "second run dedupes the disk page (anti-firehose)" \
    || _fail "second run did not dedupe (deduped count=$dd_count)"
dryrun_count="$(_count "$A" '"board_vitals_page_dryrun".*"disk_full"')"
[[ "$dryrun_count" -eq 1 ]] && _ok "disk paged exactly once across two runs" \
    || _fail "disk pages != 1 (got $dryrun_count)"

# ── CREDIBLE-1303: almanac summarized_pct guard ──────────────────────────────
echo "[test-board-vitals] almanac coverage below floor pages once then dedupes"
AL="$TMP/almanac.jsonl"; : > "$AL"
ALSTATE="$TMP/almanac-low.state"; printf '20 68\n' > "$ALSTATE"   # summary_pct=68 <= 95
SDA="$TMP/state-almanac"
run_almanac() {
    ( set -a
      CHUMP_AMBIENT_LOG="$AL"; CHUMP_BOARD_VITALS_STATE_DIR="$SDA"
      CHUMP_BOARD_VITALS_DRY_RUN=1; CHUMP_BOARD_VITALS_ESCALATE=0
      CHUMP_BOARD_VITALS_MAIN_RED_LIVE=0
      CHUMP_BOARD_VITALS_DISK_PCT=100; CHUMP_BOARD_VITALS_DROUGHT_MIN=999999
      CHUMP_BOARD_VITALS_ALMANAC_STATE="$ALSTATE"
      set +a
      source "$LIB"; board_vitals_check )
}
run_almanac >/dev/null 2>&1
_emitted "68% summarized (<=95 floor) → pages almanac_coverage_low" "$AL" '"board_vitals_page_dryrun".*"almanac_coverage_low"'
run_almanac >/dev/null 2>&1
al_pages="$(_count "$AL" '"board_vitals_page_dryrun".*"almanac_coverage_low"')"
[[ "$al_pages" -eq 1 ]] && _ok "almanac coverage paged exactly once across two runs (dedup)" \
    || _fail "almanac coverage pages != 1 (got $al_pages)"

echo "[test-board-vitals] almanac coverage above floor never pages"
AH="$TMP/almanac-healthy.jsonl"; : > "$AH"
ALSTATE_HEALTHY="$TMP/almanac-healthy.state"; printf '99 97\n' > "$ALSTATE_HEALTHY"  # summary_pct=97 > 95
( set -a
  CHUMP_AMBIENT_LOG="$AH"; CHUMP_BOARD_VITALS_STATE_DIR="$TMP/state-almanac-healthy"
  CHUMP_BOARD_VITALS_DRY_RUN=1; CHUMP_BOARD_VITALS_ESCALATE=0
  CHUMP_BOARD_VITALS_MAIN_RED_LIVE=0
  CHUMP_BOARD_VITALS_DISK_PCT=100; CHUMP_BOARD_VITALS_DROUGHT_MIN=999999
  CHUMP_BOARD_VITALS_ALMANAC_STATE="$ALSTATE_HEALTHY"
  set +a
  source "$LIB"; board_vitals_check ) >/dev/null 2>&1
_notemitted "97% summarized (>95 floor) → no page" "$AH" '"board_vitals_page_(dryrun|sent)".*"almanac_coverage_low"'

echo "[test-board-vitals] almanac coverage state file missing → unknown, never pages"
AM="$TMP/almanac-missing.jsonl"; : > "$AM"
( set -a
  CHUMP_AMBIENT_LOG="$AM"; CHUMP_BOARD_VITALS_STATE_DIR="$TMP/state-almanac-missing"
  CHUMP_BOARD_VITALS_DRY_RUN=1; CHUMP_BOARD_VITALS_ESCALATE=0
  CHUMP_BOARD_VITALS_MAIN_RED_LIVE=0
  CHUMP_BOARD_VITALS_DISK_PCT=100; CHUMP_BOARD_VITALS_DROUGHT_MIN=999999
  CHUMP_BOARD_VITALS_ALMANAC_STATE="$TMP/definitely-does-not-exist.state"
  set +a
  source "$LIB"; board_vitals_check ) >/dev/null 2>&1
_notemitted "missing acuity state → unknown coverage, no page (not treated as 0%)" \
    "$AM" '"board_vitals_page_(dryrun|sent)".*"almanac_coverage_low"'

# ── CREDIBLE-1340: guard is a strict >95%, not >=95% ────────────────────────
# The mission floor is "summarized_pct must be >95%" (CREDIBLE-300) — the
# check in board-vitals.sh is `coverage <= almanac_floor`, so a repo sitting
# exactly AT 95% must still page. If the guard were ever loosened to `<`
# (i.e. only strictly-below-floor pages), this is the case that would go
# silent first and this assertion would fail.
echo "[test-board-vitals] almanac coverage exactly AT the 95% floor still pages (strict >95% guard)"
AB="$TMP/almanac-boundary.jsonl"; : > "$AB"
ALSTATE_BOUNDARY="$TMP/almanac-boundary.state"; printf '50 95\n' > "$ALSTATE_BOUNDARY"  # summary_pct=95, exactly at floor
( set -a
  CHUMP_AMBIENT_LOG="$AB"; CHUMP_BOARD_VITALS_STATE_DIR="$TMP/state-almanac-boundary"
  CHUMP_BOARD_VITALS_DRY_RUN=1; CHUMP_BOARD_VITALS_ESCALATE=0
  CHUMP_BOARD_VITALS_MAIN_RED_LIVE=0
  CHUMP_BOARD_VITALS_DISK_PCT=100; CHUMP_BOARD_VITALS_DROUGHT_MIN=999999
  CHUMP_BOARD_VITALS_ALMANAC_STATE="$ALSTATE_BOUNDARY"
  set +a
  source "$LIB"; board_vitals_check ) >/dev/null 2>&1
_emitted "exactly 95% (not >95) → still pages almanac_coverage_low" "$AB" '"board_vitals_page_dryrun".*"almanac_coverage_low"'

# ── clean cycle never pages ──────────────────────────────────────────────────
echo "[test-board-vitals] clean cycle is phone-quiet"
B="$TMP/clean.jsonl"; : > "$B"
( set -a
  CHUMP_AMBIENT_LOG="$B"; CHUMP_BOARD_VITALS_STATE_DIR="$TMP/state-clean"
  CHUMP_BOARD_VITALS_DRY_RUN=1; CHUMP_BOARD_VITALS_ESCALATE=0
  CHUMP_BOARD_VITALS_MAIN_RED_LIVE=0        # keep pre-RESILIENT-414 tests hermetic (no live gh/watchdog call)
  CHUMP_BOARD_VITALS_DISK_PCT=100           # unreachable → no disk incident
  CHUMP_BOARD_VITALS_DROUGHT_MIN=999999
  set +a
  source "$LIB"; board_vitals_check ) >/dev/null 2>&1
_notemitted "clean cycle sends no page" "$B" '"board_vitals_page_(dryrun|sent)"'

# ── proof-of-life: unconditional stdout line (journal-visible, RESILIENT-410) ─
echo "[test-board-vitals] proof-of-life stdout line every run"
pol="$( ( set -a
  CHUMP_AMBIENT_LOG="$TMP/pol.jsonl"; CHUMP_BOARD_VITALS_STATE_DIR="$TMP/state-pol"
  CHUMP_BOARD_VITALS_DRY_RUN=1; CHUMP_BOARD_VITALS_ESCALATE=0
  CHUMP_BOARD_VITALS_MAIN_RED_LIVE=0        # keep pre-RESILIENT-414 tests hermetic (no live gh/watchdog call)
  CHUMP_BOARD_VITALS_DISK_PCT=100; CHUMP_BOARD_VITALS_DROUGHT_MIN=999999
  set +a
  source "$LIB"; board_vitals_check ) 2>/dev/null )"
echo "$pol" | grep -qE '^\[board-vitals\] tick — incidents=0 ' \
    && _ok "healthy run prints proof-of-life tick to stdout (incidents=0)" \
    || _fail "no proof-of-life stdout line (got: $pol)"
_emitted "clean cycle still emits a tick heartbeat" "$B" '"board_vitals_tick","incidents":0'

# ── RESILIENT-411: worker-silence ALONE must NOT page (no transient-lull page) ─
echo "[test-board-vitals] worker silence alone never pages"
S="$TMP/silence.jsonl"
# a stale worker signal (2h old) → worker_silent=1, but no merge stall / disk
printf '{"ts":"%s","kind":"token_usage_partial"}\n' \
    "$(date -u -d '-120 min' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-120M +%Y-%m-%dT%H:%M:%SZ)" > "$S"
( set -a
  CHUMP_AMBIENT_LOG="$S"; CHUMP_BOARD_VITALS_STATE_DIR="$TMP/state-sil"
  CHUMP_BOARD_VITALS_DRY_RUN=1; CHUMP_BOARD_VITALS_ESCALATE=0
  CHUMP_BOARD_VITALS_MAIN_RED_LIVE=0        # keep pre-RESILIENT-414 tests hermetic (no live gh/watchdog call)
  CHUMP_BOARD_VITALS_DISK_PCT=100
  CHUMP_BOARD_VITALS_DROUGHT_MIN=999999   # merge-stall can't fire → isolates silence
  set +a
  source "$LIB"; board_vitals_check ) >/dev/null 2>&1
_notemitted "silent worker + no stall/disk → NO page (recovering lull is not Jeff's problem)" \
    "$S" '"board_vitals_page_(dryrun|sent)"'
grep -qE '"board_vitals_tick","incidents":0' "$S" \
    && _ok "silence-alone still ticks incidents=0 (watched, not paged)" \
    || _fail "silence-alone tick missing/incidents!=0"

# ── RESILIENT-411: oauth GENUINELY expired pages; a recovery does not ────────
echo "[test-board-vitals] floor — oauth expired pages, recovery does not"
OA="$TMP/oauth.jsonl"
nowts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
{ printf '{"ts":"%s","kind":"oauth_token_refresh_failed"}\n' "$(nowts)"
  printf '{"ts":"%s","kind":"oauth_token_refresh_failed"}\n' "$(nowts)"
  printf '{"ts":"%s","kind":"oauth_token_refresh_failed"}\n' "$(nowts)"; } > "$OA"
( set -a
  CHUMP_AMBIENT_LOG="$OA"; CHUMP_BOARD_VITALS_STATE_DIR="$TMP/state-oa"
  CHUMP_BOARD_VITALS_DRY_RUN=1; CHUMP_BOARD_VITALS_ESCALATE=0
  CHUMP_BOARD_VITALS_MAIN_RED_LIVE=0        # keep pre-RESILIENT-414 tests hermetic (no live gh/watchdog call)
  CHUMP_BOARD_VITALS_DISK_PCT=100; CHUMP_BOARD_VITALS_DROUGHT_MIN=999999
  set +a
  source "$LIB"; board_vitals_check ) >/dev/null 2>&1
_emitted "3 oauth failures (newest=failure) → pages oauth_expired" "$OA" '"board_vitals_page_dryrun".*"oauth_expired"'
# a success lands AFTER the failures → recovered → must NOT page. Build a FRESH
# log (not a copy of the paged one) so we measure only this run's pages.
OA2LOG="$TMP/oauth2.jsonl"
oldts() { date -u -d '-2 min' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-2M +%Y-%m-%dT%H:%M:%SZ; }
{ printf '{"ts":"%s","kind":"oauth_token_refresh_failed"}\n' "$(oldts)"
  printf '{"ts":"%s","kind":"oauth_token_refresh_failed"}\n' "$(oldts)"
  printf '{"ts":"%s","kind":"oauth_token_refresh_failed"}\n' "$(oldts)"
  printf '{"ts":"%s","kind":"oauth_token_refreshed"}\n'      "$(nowts)"; } > "$OA2LOG"
( set -a
  CHUMP_AMBIENT_LOG="$OA2LOG"; CHUMP_BOARD_VITALS_STATE_DIR="$TMP/state-oa2"
  CHUMP_BOARD_VITALS_DRY_RUN=1; CHUMP_BOARD_VITALS_ESCALATE=0
  CHUMP_BOARD_VITALS_MAIN_RED_LIVE=0        # keep pre-RESILIENT-414 tests hermetic (no live gh/watchdog call)
  CHUMP_BOARD_VITALS_DISK_PCT=100; CHUMP_BOARD_VITALS_DROUGHT_MIN=999999
  set +a
  source "$LIB"; board_vitals_check ) >/dev/null 2>&1
# grep -c prints "0" on no match; do NOT append `|| echo 0` (that doubles it).
oa2_pages="$(grep -c '"board_vitals_page_dryrun".*"oauth_expired"' "$OA2LOG" 2>/dev/null)"
[[ "${oa2_pages:-0}" -eq 0 ]] && _ok "oauth recovered (success after failures) → NO page" \
    || _fail "oauth recovery still paged ($oa2_pages)"

# ── RESILIENT-411: cost/credit cap pages ─────────────────────────────────────
echo "[test-board-vitals] floor — cost_cap_exceeded pages"
CC="$TMP/cost.jsonl"
printf '{"ts":"%s","kind":"cost_cap_exceeded","daily_usd":9.9}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$CC"
( set -a
  CHUMP_AMBIENT_LOG="$CC"; CHUMP_BOARD_VITALS_STATE_DIR="$TMP/state-cc"
  CHUMP_BOARD_VITALS_DRY_RUN=1; CHUMP_BOARD_VITALS_ESCALATE=0
  CHUMP_BOARD_VITALS_MAIN_RED_LIVE=0        # keep pre-RESILIENT-414 tests hermetic (no live gh/watchdog call)
  CHUMP_BOARD_VITALS_DISK_PCT=100; CHUMP_BOARD_VITALS_DROUGHT_MIN=999999
  set +a
  source "$LIB"; board_vitals_check ) >/dev/null 2>&1
_emitted "cost_cap_exceeded in-window → pages cost_cap" "$CC" '"board_vitals_page_dryrun".*"cost_cap"'

# ── helper: main-red span (consecutive real-red run) ─────────────────────────
echo "[test-board-vitals] _bv_main_red_span_min"
MR="$TMP/mainred.jsonl"
{
  echo '{"ts":"2026-08-27T10:00:00Z","kind":"main_red_detected","status":"red"}'
  echo '{"ts":"2026-08-27T10:40:00Z","kind":"main_red_detected","status":"red"}'
} > "$MR"
span="$( CHUMP_AMBIENT_LOG="$MR" bash -c 'source "'"$LIB"'"; _bv_main_red_span_min' 2>/dev/null )"
[[ "$span" == "40" ]] && _ok "two 40m-apart red lines → span 40" || _fail "main-red span wrong (got '$span', want 40)"
echo '{"ts":"2026-08-27T10:50:00Z","kind":"main_red_detected","status":"no_runs"}' >> "$MR"
span2="$( CHUMP_AMBIENT_LOG="$MR" bash -c 'source "'"$LIB"'"; _bv_main_red_span_min' 2>/dev/null )"
[[ "$span2" == "0" ]] && _ok "benign newest line → span 0 (not paged)" || _fail "benign newest not 0 (got '$span2')"

# ── helper: prs-in-flight from newest board_cycle_report_posted ──────────────
echo "[test-board-vitals] _bv_prs_in_flight"
PF="$TMP/prs.jsonl"
echo '{"ts":"2026-08-27T11:00:00Z","kind":"board_cycle_report_posted","sla_breaches":2,"stalls_classified":3}' > "$PF"
inflight="$( CHUMP_AMBIENT_LOG="$PF" bash -c 'source "'"$LIB"'"; _bv_prs_in_flight' 2>/dev/null )"
[[ "$inflight" == "5" ]] && _ok "sla_breaches(2)+stalls(3) → in_flight 5" || _fail "in_flight wrong (got '$inflight', want 5)"
empty_pf="$TMP/empty.jsonl"; : > "$empty_pf"
inflight2="$( CHUMP_AMBIENT_LOG="$empty_pf" bash -c 'source "'"$LIB"'"; _bv_prs_in_flight' 2>/dev/null )"
[[ "$inflight2" == "-1" ]] && _ok "no report → in_flight -1 (unknown, not zero)" || _fail "no-report in_flight not -1 (got '$inflight2')"

# ── RESILIENT-414: live main-red emit — no pre-existing ambient line needed ──
# Proves board_vitals_check now invokes the watchdog live each beat instead of
# depending solely on its macOS-launchd-only daily cron (dark on non-mac
# hosts, e.g. CJ). A stub watchdog binary emits ONE fresh red line; with the
# threshold forced to 0 (a single line always spans 0m), that alone must page.
echo "[test-board-vitals] RESILIENT-414: live main-red emit pages without pre-existing ambient"
LR="$TMP/liveemit.jsonl"; : > "$LR"
STUB="$TMP/stub-main-health.sh"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
printf '{"ts":"%s","kind":"main_red_detected","status":"failure"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${CHUMP_AMBIENT_LOG}"
STUBEOF
chmod +x "$STUB"
( set -a
  CHUMP_AMBIENT_LOG="$LR"; CHUMP_BOARD_VITALS_STATE_DIR="$TMP/state-liveemit"
  CHUMP_BOARD_VITALS_DRY_RUN=1; CHUMP_BOARD_VITALS_ESCALATE=0
  CHUMP_BOARD_VITALS_DISK_PCT=100; CHUMP_BOARD_VITALS_DROUGHT_MIN=999999
  CHUMP_BOARD_VITALS_MAIN_RED_MIN=0             # a single fresh red line (span=0) must be enough
  CHUMP_BOARD_VITALS_MAIN_HEALTH_BIN="$STUB"
  set +a
  source "$LIB"; board_vitals_check ) >/dev/null 2>&1
_emitted "board_vitals_check itself invoked the stub watchdog (wrote a fresh main_red_detected line)" \
    "$LR" '"kind":"main_red_detected","status":"failure"'
_emitted "empty ambient + live-invoked watchdog stub → main_red pages this beat" \
    "$LR" '"board_vitals_page_dryrun".*"main_red"'

echo "[test-board-vitals] RESILIENT-414: MAIN_RED_LIVE=0 skips the live invocation"
LR2="$TMP/liveemit-off.jsonl"; : > "$LR2"
( set -a
  CHUMP_AMBIENT_LOG="$LR2"; CHUMP_BOARD_VITALS_STATE_DIR="$TMP/state-liveemit-off"
  CHUMP_BOARD_VITALS_DRY_RUN=1; CHUMP_BOARD_VITALS_ESCALATE=0
  CHUMP_BOARD_VITALS_DISK_PCT=100; CHUMP_BOARD_VITALS_DROUGHT_MIN=999999
  # NOTE: threshold left at the real default (30) on purpose — with NO red
  # lines at all, _bv_main_red_span_min returns 0, and 0 >= 0 would trivially
  # "page" on an all-green history regardless of live-emit; a nonzero
  # threshold is required for this assertion to mean anything.
  CHUMP_BOARD_VITALS_MAIN_HEALTH_BIN="$STUB"
  CHUMP_BOARD_VITALS_MAIN_RED_LIVE=0            # disabled → stub never runs → no red line → no page
  set +a
  source "$LIB"; board_vitals_check ) >/dev/null 2>&1
_notemitted "MAIN_RED_LIVE=0 → stub not invoked → no main_red page" \
    "$LR2" '"board_vitals_page_(dryrun|sent)".*"main_red"'

# ── RESILIENT-414: merge_stall must page when the queue is BLOCKED behind red
# main, even though _bv_prs_in_flight counts those BLOCKED PRs as non-zero ──
echo "[test-board-vitals] RESILIENT-414: merge_stall pages despite BLOCKED-PRs-in-flight when main is red"
BR="$TMP/blocked-red.jsonl"
{
  printf '{"ts":"%s","kind":"token_usage_partial"}\n' \
      "$(date -u -d '-120 min' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-120M +%Y-%m-%dT%H:%M:%SZ)"
  echo '{"ts":"2026-08-27T11:00:00Z","kind":"board_cycle_report_posted","sla_breaches":0,"stalls_classified":5}'
  echo '{"ts":"2026-08-27T10:00:00Z","kind":"main_red_detected","status":"red"}'
  echo '{"ts":"2026-08-27T10:05:00Z","kind":"main_red_detected","status":"red"}'
} > "$BR"
( set -a
  CHUMP_AMBIENT_LOG="$BR"; CHUMP_BOARD_VITALS_STATE_DIR="$TMP/state-br"
  CHUMP_BOARD_VITALS_DRY_RUN=1; CHUMP_BOARD_VITALS_ESCALATE=0
  CHUMP_BOARD_VITALS_DISK_PCT=100
  CHUMP_BOARD_VITALS_DROUGHT_MIN=0              # last git-log merge is always "old enough"
  CHUMP_BOARD_VITALS_MAIN_RED_MIN=999999        # isolate: main_red itself must NOT page here
  CHUMP_BOARD_VITALS_MAIN_RED_LIVE=0            # use the synthetic ambient lines above, not a live call
  set +a
  source "$LIB"; board_vitals_check ) >/dev/null 2>&1
_emitted "5 BLOCKED-behind-red-main PRs (in_flight=5) still pages merge_stall" \
    "$BR" '"board_vitals_page_dryrun".*"merge_stall"'
_notemitted "main_red itself does not page in this run (isolated assertion)" \
    "$BR" '"board_vitals_page_dryrun".*"main_red"'

# ── control: same BLOCKED-in-flight count, but main is GREEN → old suppression
# behavior is preserved (in-flight PRs genuinely being nursed still hold off
# the page) ────────────────────────────────────────────────────────────────
echo "[test-board-vitals] RESILIENT-414: in-flight PRs still suppress merge_stall when main is green"
BG="$TMP/blocked-green.jsonl"
{
  printf '{"ts":"%s","kind":"token_usage_partial"}\n' \
      "$(date -u -d '-120 min' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-120M +%Y-%m-%dT%H:%M:%SZ)"
  echo '{"ts":"2026-08-27T11:00:00Z","kind":"board_cycle_report_posted","sla_breaches":0,"stalls_classified":5}'
  echo '{"ts":"2026-08-27T10:00:00Z","kind":"main_red_detected","status":"green"}'
} > "$BG"
( set -a
  CHUMP_AMBIENT_LOG="$BG"; CHUMP_BOARD_VITALS_STATE_DIR="$TMP/state-bg"
  CHUMP_BOARD_VITALS_DRY_RUN=1; CHUMP_BOARD_VITALS_ESCALATE=0
  CHUMP_BOARD_VITALS_DISK_PCT=100
  CHUMP_BOARD_VITALS_DROUGHT_MIN=0
  CHUMP_BOARD_VITALS_MAIN_RED_MIN=999999
  CHUMP_BOARD_VITALS_MAIN_RED_LIVE=0
  set +a
  source "$LIB"; board_vitals_check ) >/dev/null 2>&1
_notemitted "5 in-flight PRs + main GREEN → merge_stall still suppressed (unchanged behavior)" \
    "$BG" '"board_vitals_page_(dryrun|sent)".*"merge_stall"'

# ── RESILIENT-1128 (RESILIENT-417 slice): sustained_main_red past 48h ────────
echo "[test-board-vitals] RESILIENT-1128: sustained_main_red fires past the 48h threshold"
SR="$TMP/sustained-red.jsonl"
{
  echo '{"ts":"2026-08-25T00:00:00Z","kind":"main_red_detected","status":"red"}'
  echo '{"ts":"2026-08-27T10:00:00Z","kind":"main_red_detected","status":"red"}'
} > "$SR"
( set -a
  CHUMP_AMBIENT_LOG="$SR"; CHUMP_BOARD_VITALS_STATE_DIR="$TMP/state-sr"
  CHUMP_BOARD_VITALS_DRY_RUN=1; CHUMP_BOARD_VITALS_ESCALATE=0
  CHUMP_BOARD_VITALS_MAIN_RED_LIVE=0
  CHUMP_BOARD_VITALS_DISK_PCT=100; CHUMP_BOARD_VITALS_DROUGHT_MIN=999999
  CHUMP_BOARD_VITALS_MAIN_RED_MIN=999999          # isolate: the 30m page is not what's under test
  CHUMP_BOARD_VITALS_SUSTAINED_MAIN_RED_MIN=2880  # default (48h), spelled out for clarity
  set +a
  source "$LIB"; board_vitals_check ) >/dev/null 2>&1
_emitted "58h consecutive real-red span → sustained_main_red emitted" \
    "$SR" '"kind":"sustained_main_red".*"main_red_span_min":3480'

echo "[test-board-vitals] RESILIENT-1128: no false positive — span under the 48h threshold"
SR2="$TMP/sustained-red-short.jsonl"
{
  echo '{"ts":"2026-08-27T10:00:00Z","kind":"main_red_detected","status":"red"}'
  echo '{"ts":"2026-08-27T10:40:00Z","kind":"main_red_detected","status":"red"}'
} > "$SR2"
( set -a
  CHUMP_AMBIENT_LOG="$SR2"; CHUMP_BOARD_VITALS_STATE_DIR="$TMP/state-sr2"
  CHUMP_BOARD_VITALS_DRY_RUN=1; CHUMP_BOARD_VITALS_ESCALATE=0
  CHUMP_BOARD_VITALS_MAIN_RED_LIVE=0
  CHUMP_BOARD_VITALS_DISK_PCT=100; CHUMP_BOARD_VITALS_DROUGHT_MIN=999999
  CHUMP_BOARD_VITALS_MAIN_RED_MIN=999999
  set +a
  source "$LIB"; board_vitals_check ) >/dev/null 2>&1
_notemitted "40m red span (well under 48h) → sustained_main_red NOT emitted" \
    "$SR2" '"kind":"sustained_main_red"'

echo "[test-board-vitals] RESILIENT-1128: no false positive — transient red cleared by a later benign line"
SR3="$TMP/sustained-red-transient.jsonl"
{
  echo '{"ts":"2026-08-20T00:00:00Z","kind":"main_red_detected","status":"red"}'
  echo '{"ts":"2026-08-27T10:00:00Z","kind":"main_red_detected","status":"green"}'
} > "$SR3"
( set -a
  CHUMP_AMBIENT_LOG="$SR3"; CHUMP_BOARD_VITALS_STATE_DIR="$TMP/state-sr3"
  CHUMP_BOARD_VITALS_DRY_RUN=1; CHUMP_BOARD_VITALS_ESCALATE=0
  CHUMP_BOARD_VITALS_MAIN_RED_LIVE=0
  CHUMP_BOARD_VITALS_DISK_PCT=100; CHUMP_BOARD_VITALS_DROUGHT_MIN=999999
  CHUMP_BOARD_VITALS_MAIN_RED_MIN=999999
  set +a
  source "$LIB"; board_vitals_check ) >/dev/null 2>&1
_notemitted "long-past red span since recovered to green → sustained_main_red NOT emitted" \
    "$SR3" '"kind":"sustained_main_red"'

echo
echo "[test-board-vitals] PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
