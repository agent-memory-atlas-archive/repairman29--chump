#!/usr/bin/env bash
# test-offnode-deadman.sh — RESILIENT-1247 coverage for the off-node dead-man's
# switch. DEPTH: happy-path + adversarial (each dark failure mode) + hysteresis.
# GAPS: does not exercise the real gist fetch or real Discord delivery (those are
# network/credential paths verified live at deploy time, out of CI scope); it
# drives the watcher's DETECTION + PAGE-DECISION via fixture payloads and a page
# sink, plus the pusher's payload builder in dry-run.
#
# Simulates "CJ dark" three ways and asserts the OFF-NODE watcher fires; asserts
# a fresh CJ does NOT fire; asserts a transient unreadable read falls back to a
# fresh cache and does NOT fire (blip tolerance).
# shellcheck shell=bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCH="$HERE/../ops/offnode-deadman-watch.sh"
PUSH="$HERE/../ops/cj-deadman-push.sh"
[[ -f "$WATCH" ]] || WATCH="$HERE/offnode-deadman-watch.sh"   # flat-dir fallback (scratchpad)
[[ -f "$PUSH" ]]  || PUSH="$HERE/cj-deadman-push.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SINK="$WORK/pages.tsv"
STATE="$WORK/state"; mkdir -p "$STATE"
NOW=1789600000
STALE=1200

pass=0; fail=0
ok()   { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
# grep -c exits 1 on zero matches (printing "0"); capture without `|| echo`.
count_pages() { local c; c="$(grep -c PAGE "$SINK" 2>/dev/null)"; printf '%s' "${c:-0}"; }

# helper: run the watcher against a fixed payload, return page count written
run_watch() { # payload_json  now_epoch
    local pj="$1" now="$2" f="$WORK/payload.json"
    printf '%s' "$pj" > "$f"
    : > "$SINK"
    CHUMP_DEADMAN_PAYLOAD_FILE="$f" \
    CHUMP_DEADMAN_PAGE_SINK="$SINK" \
    CHUMP_DEADMAN_STATE_DIR="$STATE" \
    CHUMP_DEADMAN_STALE_SECS="$STALE" \
    CHUMP_DEADMAN_NOW_EPOCH="$now" \
    CHUMP_DEADMAN_GIST_ID="fixture" \
        bash "$WATCH" >/dev/null 2>&1 || true
    count_pages
}

echo "== 1. fresh CJ (both timestamps recent) → NO page =="
p="{\"schema\":\"chump-deadman/1\",\"node\":\"closetjunky\",\"farmer_hb_epoch\":$((NOW-60)),\"pushed_epoch\":$((NOW-60))}"
n="$(run_watch "$p" "$NOW")"
[[ "$n" == "0" ]] && ok "healthy CJ did not page (pages=$n)" || bad "healthy CJ paged (pages=$n)"

echo "== 2. CJ dark: pusher stopped (pushed_epoch stale) → PAGE =="
p="{\"schema\":\"chump-deadman/1\",\"node\":\"closetjunky\",\"farmer_hb_epoch\":$((NOW-60)),\"pushed_epoch\":$((NOW-STALE-600))}"
n="$(run_watch "$p" "$NOW")"
if [[ "$n" -ge 1 ]] && grep -q cj_deadman_dark "$SINK"; then ok "node-dark detected + paged (pages=$n)"; else bad "node-dark NOT paged (pages=$n)"; fi

echo "== 3. worker wedged: box beats but farmer heartbeat stale → PAGE =="
p="{\"schema\":\"chump-deadman/1\",\"node\":\"closetjunky\",\"farmer_hb_epoch\":$((NOW-STALE-600)),\"pushed_epoch\":$((NOW-60))}"
n="$(run_watch "$p" "$NOW")"
if [[ "$n" -ge 1 ]] && grep -q cj_deadman_worker_wedged "$SINK"; then ok "worker-wedge detected + paged (pages=$n)"; else bad "worker-wedge NOT paged (pages=$n)"; fi

echo "== 4. 13h-drought realism: both frozen ~13h → PAGE (the exact incident) =="
p="{\"schema\":\"chump-deadman/1\",\"node\":\"closetjunky\",\"farmer_hb_epoch\":$((NOW-46800)),\"pushed_epoch\":$((NOW-46800))}"
n="$(run_watch "$p" "$NOW")"
[[ "$n" -ge 1 ]] && ok "13h dark detected + paged (pages=$n)" || bad "13h dark NOT paged (pages=$n)"

echo "== 5. unreadable + no cache → PAGE (fail-loud, health UNKNOWN) =="
rm -rf "$STATE"; mkdir -p "$STATE"; : > "$SINK"
CHUMP_DEADMAN_PAYLOAD_FILE="$WORK/does-not-exist.json" \
CHUMP_DEADMAN_PAGE_SINK="$SINK" CHUMP_DEADMAN_STATE_DIR="$STATE" \
CHUMP_DEADMAN_STALE_SECS="$STALE" CHUMP_DEADMAN_NOW_EPOCH="$NOW" \
CHUMP_DEADMAN_GIST_ID="" bash "$WATCH" >/dev/null 2>&1 || true
n="$(count_pages)"
if [[ "$n" -ge 1 ]] && grep -q cj_deadman_unreadable "$SINK"; then ok "unreadable+no-cache paged (pages=$n)"; else bad "unreadable+no-cache NOT paged (pages=$n)"; fi

echo "== 6. blip tolerance: a FRESH cached beat + unreadable live read → NO page =="
rm -rf "$STATE"; mkdir -p "$STATE"
printf '{"schema":"chump-deadman/1","node":"closetjunky","farmer_hb_epoch":%s,"pushed_epoch":%s}\n' "$((NOW-60))" "$((NOW-60))" \
    > "$STATE/offnode-deadman.last-good.json"
: > "$SINK"
CHUMP_DEADMAN_PAYLOAD_FILE="$WORK/does-not-exist.json" \
CHUMP_DEADMAN_PAGE_SINK="$SINK" CHUMP_DEADMAN_STATE_DIR="$STATE" \
CHUMP_DEADMAN_STALE_SECS="$STALE" CHUMP_DEADMAN_NOW_EPOCH="$NOW" \
CHUMP_DEADMAN_GIST_ID="" bash "$WATCH" >/dev/null 2>&1 || true
n="$(count_pages)"
[[ "$n" == "0" ]] && ok "transient blip absorbed by fresh cache (pages=$n)" || bad "transient blip cried wolf (pages=$n)"

echo "== 7. pusher builds a well-formed payload in dry-run =="
out="$(CHUMP_DEADMAN_DRY_RUN=1 CHUMP_STATE_DIR="$WORK/nohb" bash "$PUSH" 2>/dev/null || true)"
if printf '%s' "$out" | grep -q '"pushed_epoch":[0-9]' && printf '%s' "$out" | grep -q '"schema":"chump-deadman/1"'; then
    ok "pusher dry-run emits valid payload"
else
    bad "pusher dry-run payload malformed: $out"
fi

echo
echo "== RESULT: pass=$pass fail=$fail =="
[[ "$fail" -eq 0 ]] || exit 1
