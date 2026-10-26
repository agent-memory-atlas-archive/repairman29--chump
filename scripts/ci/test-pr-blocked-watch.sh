#!/usr/bin/env bash
# test-pr-blocked-watch.sh — INFRA-550 smoke test.
#
# Verifies pr-blocked-watch.sh:
#   1. Honors CHUMP_PR_BLOCKED_WATCH=0 bypass.
#   2. Exits 0 and writes heartbeat + ambient event on a clean run
#      (no real BLOCKED PRs needed — the script exits cleanly when
#       gh returns an empty list, before any check-fetch).
#   3. Dry-run prints ALERT lines without writing to ambient.jsonl.
#   4. Watchdog recognizes the pr-blocked heartbeat target.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/scripts/ops/pr-blocked-watch.sh"

if [[ ! -x "$SCRIPT" ]]; then
    echo "[FAIL] $SCRIPT not executable"
    exit 1
fi

COMMON_DIR="$(git rev-parse --git-common-dir 2>/dev/null)"
if [[ "$COMMON_DIR" == ".git" || "$COMMON_DIR" == "$REPO_ROOT/.git" ]]; then
    MAIN_REPO="$REPO_ROOT"
else
    MAIN_REPO="$(cd "$COMMON_DIR/.." && pwd)"
fi
AMBIENT="$MAIN_REPO/.chump-locks/ambient.jsonl"
mkdir -p "$MAIN_REPO/.chump-locks"
touch "$AMBIENT"
HB=/tmp/chump-reaper-pr-blocked.heartbeat

# ── Test 1: bypass ────────────────────────────────────────────────────────────
echo "Test 1: CHUMP_PR_BLOCKED_WATCH=0 must exit 0 immediately"
out=$(CHUMP_PR_BLOCKED_WATCH=0 bash "$SCRIPT" 2>&1)
rc=$?
[[ $rc -eq 0 ]] || { echo "[FAIL] bypass exited $rc"; echo "$out"; exit 1; }
echo "$out" | grep -q "bypass" || { echo "[FAIL] bypass message missing"; echo "$out"; exit 1; }
echo "[PASS] bypass works"

# ── Test 2: clean run — heartbeat written + ambient event emitted ─────────────
echo ""
echo "Test 2: clean run writes heartbeat + ambient event"
rm -f "$HB"
lines_before=$(wc -l < "$AMBIENT" 2>/dev/null || echo 0)
# Use a very high threshold so no real BLOCKED PRs trigger alerts.
set +e
out=$(BLOCKED_THRESHOLD_HOURS=9999 bash "$SCRIPT" 2>&1)
rc=$?
set -e
[[ $rc -eq 0 ]] || { echo "[FAIL] clean run exited $rc"; echo "$out"; exit 1; }
[[ -f "$HB" ]] || { echo "[FAIL] heartbeat not written at $HB"; exit 1; }
lines_after=$(wc -l < "$AMBIENT" 2>/dev/null || echo 0)
new_lines=$(( lines_after - lines_before ))
(( new_lines >= 1 )) || {
    echo "[FAIL] no ambient event written (before=$lines_before after=$lines_after)"
    exit 1
}
new_event=$(tail -n "$new_lines" "$AMBIENT")
echo "$new_event" | grep -qE '"kind"[[:space:]]*:[[:space:]]*"reaper_run"' || {
    echo "[FAIL] expected reaper_run event, got: $new_event"; exit 1; }
echo "[PASS] heartbeat written; ambient event: $(echo "$new_event" | head -c 120)…"

# ── Test 3: dry-run does not write to ambient.jsonl ───────────────────────────
echo ""
echo "Test 3: --dry-run must not append to ambient.jsonl"
lines_before=$(wc -l < "$AMBIENT" 2>/dev/null || echo 0)
set +e
out=$(BLOCKED_THRESHOLD_HOURS=0 bash "$SCRIPT" --dry-run 2>&1)
rc=$?
set -e
[[ $rc -eq 0 ]] || { echo "[FAIL] dry-run exited $rc"; echo "$out"; exit 1; }
lines_after=$(wc -l < "$AMBIENT" 2>/dev/null || echo 0)
# reaper_finish still writes one reaper_run event even in dry-run; only
# ALERT events should be suppressed. Accept 0 or 1 new line (the reaper_run).
new_lines=$(( lines_after - lines_before ))
# dry-run should not print raw ALERT to ambient (only reaper_run is OK)
last_event=$(tail -1 "$AMBIENT" 2>/dev/null || echo "")
if echo "$last_event" | grep -qE '"kind"[[:space:]]*:[[:space:]]*"pr_blocked_long"'; then
    echo "[FAIL] dry-run wrote a pr_blocked_long ALERT event to ambient.jsonl"
    exit 1
fi
echo "[PASS] dry-run did not write pr_blocked_long alert"

# ── Test 4: watchdog recognizes pr-blocked ────────────────────────────────────
echo ""
echo "Test 4: reaper-heartbeat-watchdog includes pr-blocked in default targets"
WATCHDOG="$REPO_ROOT/scripts/ops/reaper-heartbeat-watchdog.sh"
out=$(bash "$WATCHDOG" pr-blocked 2>&1)
echo "$out" | grep -qE "pr-blocked (heartbeated|has)" || {
    echo "[FAIL] watchdog didn't recognize pr-blocked target. output:"; echo "$out"; exit 1; }
echo "[PASS] watchdog grades pr-blocked"

echo ""
echo "[OK] all 4 INFRA-550 pr-blocked-watch smoke cases passed"
