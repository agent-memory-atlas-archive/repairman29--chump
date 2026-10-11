#!/usr/bin/env bash
# outcome-verify-heal-consumer.sh — INFRA-3654 (PEER-VERI-07, MISSION-010).
#
# WHY THIS EXISTS. crates/chump-verify/src/external_verify_merge.rs emits
# kind=outcome_probe_failed when a PR's claimed live outcome cannot be
# confirmed post-merge, and crates/chump-verify/src/pr_ac_coverage.rs emits
# kind=ac_coverage_proof_miss when a "PROVEN-BY <live outcome>" acceptance
# bullet fails its live-outcome check. Both were EMITTERS with no CONSUMER —
# the exact "wrote a log line and alerted nobody" shape RESILIENT-263's
# notify-operator.sh was built to close for other channels (see that file's
# header). A PR can land, claim a live outcome, have that claim mechanically
# proven false, and nothing holds the gap open or tells anyone. This is the
# consumer that closes that hole for the verify layer specifically.
#
# Algorithm, every cycle (oneshot, run via a timer):
#   1. Tail ambient.jsonl from the last processed cursor (line-count based,
#      stored per ambient-log path so tests never collide with the real log).
#   2. For each new event with kind in (outcome_probe_failed,
#      ac_coverage_proof_miss):
#        a. Extract the gap id (event carries "gap" or "gap_id" — the two
#           emitters use different field names for the same concept).
#        b. Dedup: if this exact (kind, gap) pair was already handled within
#           CHUMP_OUTCOME_VERIFY_DEDUP_WINDOW_S (default 3600s), skip the
#           hold + page — AC3's "exactly one page ... within the dedup
#           window". A repeat sighting of the SAME failure inside the window
#           still advances the cursor so it is never reprocessed later.
#        c. Hold/reopen the named gap via `chump gap set <id> --status open
#           --add-note "HELD: ..."` so the picker/reviewer sees it needs
#           attention again instead of sitting closed on a false claim.
#        d. Page the duty officer via notify_operator (scripts/coord/lib/
#           notify-operator.sh) — CHUMP_NOTIFY_KIND is unset from the
#           operator-escalation-registry.txt (RESILIENT-274), so an unlisted
#           kind defaults to PAGE (fail loud: "no playbook -> tell me"),
#           which is correct here — a proven-false live-outcome claim has no
#           auto-heal.
#   3. Persist the new cursor and emit a heartbeat tick (AC2: chump-*.service
#      naming makes this generically Roll-Call/organ-watchdog-visible — see
#      scripts/ops/organ-manifest.txt's matching "enabled" line and
#      scripts/ops/organ-watchdog.sh, which scans ALL chump-*.service units
#      by name, not a hardcoded list).
#
# Usage:
#   scripts/coord/outcome-verify-heal-consumer.sh
#   scripts/coord/outcome-verify-heal-consumer.sh --ambient-log PATH   # test hook
#
# Env:
#   CHUMP_AMBIENT_LOG                        override ambient.jsonl path
#   CHUMP_OUTCOME_VERIFY_STATE_DIR            override cursor/dedup state dir
#   CHUMP_OUTCOME_VERIFY_DEDUP_WINDOW_S       default 3600 (1h)
#   CHUMP_OUTCOME_VERIFY_GAP_BIN              override `chump` binary (test hook)
#   REPO_ROOT / CHUMP_REPO_ROOT               repo checkout root
#
# Exit codes:
#   0  normal (whether or not any event needed handling)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-${CHUMP_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}}"
AMB="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
STATE_DIR="${CHUMP_OUTCOME_VERIFY_STATE_DIR:-$REPO_ROOT/.chump-locks/outcome-verify-heal-consumer}"
DEDUP_WINDOW_S="${CHUMP_OUTCOME_VERIFY_DEDUP_WINDOW_S:-3600}"
GAP_BIN="${CHUMP_OUTCOME_VERIFY_GAP_BIN:-chump}"
# shellcheck source=scripts/lib/safe-reopen-gap.sh
source "$SCRIPT_DIR/../lib/safe-reopen-gap.sh"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ambient-log) AMB="$2"; shift 2 ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

mkdir -p "$STATE_DIR" 2>/dev/null || true
mkdir -p "$(dirname "$AMB")" 2>/dev/null || true
touch "$AMB" 2>/dev/null || true

# notify-operator.sh's own _notify_emit (operator_paged / operator_notify_
# suppressed) reads CHUMP_AMBIENT_LOG, not our local $AMB — export it so
# both write to the SAME log (load-bearing for tests using --ambient-log,
# and for any future consumer of the standard ambient path).
export CHUMP_AMBIENT_LOG="$AMB"

# shellcheck source=lib/notify-operator.sh
if [[ -f "$SCRIPT_DIR/lib/notify-operator.sh" ]]; then
    source "$SCRIPT_DIR/lib/notify-operator.sh"
else
    notify_operator() { echo "[outcome-verify-heal-consumer] notify-operator.sh MISSING" >&2; return 1; }
fi

_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
_now_epoch() { date -u +%s; }

_emit() {  # kind, extra-json (no leading/trailing comma)
    local kind="$1" extra="${2:-}"
    local ts; ts="$(_ts)"
    local line
    if [[ -n "$extra" ]]; then line="{\"ts\":\"$ts\",\"kind\":\"$kind\",$extra}"
    else line="{\"ts\":\"$ts\",\"kind\":\"$kind\"}"; fi
    printf '%s\n' "$line" >> "$AMB" 2>/dev/null || true
}

# Cursor is keyed on a hash of the ambient-log path so a test run against a
# temp file never shares (or corrupts) the real log's cursor.
_cursor_key() { printf '%s' "$AMB" | cksum | awk '{print $1}'; }
CURSOR_FILE="$STATE_DIR/cursor.$(_cursor_key)"

total_lines="$(wc -l < "$AMB" 2>/dev/null | tr -d ' ')"
[[ "$total_lines" =~ ^[0-9]+$ ]] || total_lines=0

start_line=1
if [[ -f "$CURSOR_FILE" ]]; then
    last="$(cat "$CURSOR_FILE" 2>/dev/null || echo 0)"
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    # Log rotation (ambient.jsonl -> ambient.jsonl.1) shrinks the line count
    # below the saved cursor; without this reset every new event would be
    # skipped until the fresh log re-grew past the old cursor.
    (( last > total_lines )) && last=0
    start_line=$((last + 1))
fi

handled=0
paged=0
suppressed=0

if [[ "$start_line" -le "$total_lines" ]]; then
    # Pre-filter with grep so only the two kinds we handle reach the per-line
    # python3 parsing below. With no cursor yet (first run / state wiped) the
    # window is the WHOLE log; at 2 python3 spawns per line a ~10 MB ambient log
    # took ~1 line/sec and never finished (24+ min CPU, killed before the cursor
    # was ever written, so it restarted from line 1 every time — the 2026-10-10
    # wedge). grep keeps it O(file) in one process; python still validates.
    new_lines="$(sed -n "${start_line},${total_lines}p" "$AMB" 2>/dev/null \
        | grep -E '"kind"[[:space:]]*:[[:space:]]*"(outcome_probe_failed|ac_coverage_proof_miss)"' || true)"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        kind="$(printf '%s' "$line" | python3 -c 'import sys,json
try:
    print(json.load(sys.stdin).get("kind",""))
except Exception:
    print("")' 2>/dev/null)"
        case "$kind" in
            outcome_probe_failed|ac_coverage_proof_miss) ;;
            *) continue ;;
        esac

        gap="$(printf '%s' "$line" | python3 -c 'import sys,json
try:
    ev = json.load(sys.stdin)
except Exception:
    ev = {}
print(ev.get("gap_id") or ev.get("gap") or "")' 2>/dev/null)"
        note="$(printf '%s' "$line" | python3 -c 'import sys,json
try:
    ev = json.load(sys.stdin)
except Exception:
    ev = {}
print(ev.get("note") or ev.get("detail") or "")' 2>/dev/null)"

        handled=$((handled + 1))

        if [[ -z "$gap" ]]; then
            # scanner-anchor: "kind":"outcome_verify_heal_consumer_no_gap"
            _emit "outcome_verify_heal_consumer_no_gap" \
                "\"source_kind\":\"$kind\""
            continue
        fi

        dedup_file="$STATE_DIR/$(printf '%s__%s' "$kind" "$gap" | tr '/ ' '__').json"
        skip=0
        if [[ -f "$dedup_file" ]]; then
            last_ts="$(python3 -c "import json;print(json.load(open('$dedup_file')).get('last_epoch',0))" 2>/dev/null || echo 0)"
            [[ "$last_ts" =~ ^[0-9]+$ ]] || last_ts=0
            now_epoch="$(_now_epoch)"
            if (( now_epoch - last_ts < DEDUP_WINDOW_S )); then
                skip=1
            fi
        fi

        if [[ "$skip" == "1" ]]; then
            suppressed=$((suppressed + 1))
            # scanner-anchor: "kind":"outcome_verify_heal_consumer_dedup_skip"
            _emit "outcome_verify_heal_consumer_dedup_skip" \
                "\"gap\":\"$gap\",\"source_kind\":\"$kind\""
            continue
        fi

        # Hold/reopen — AC1. --add-note is best-effort; a gap already open
        # (never closed, or already held) still gets the note so the trail
        # is visible even when the status transition itself is a no-op.
        note_text="HELD: ${kind} — ${note:-live verification failed}"
        if CHUMP_BIN="$GAP_BIN" gap_reopen_allowed "$gap"; then
            timeout 60 "$GAP_BIN" gap set "$gap" --status open --add-note "$note_text" >/dev/null 2>&1
            held_rc=$?
        else
            timeout 60 "$GAP_BIN" gap set "$gap" --add-note "$note_text" >/dev/null 2>&1
            held_rc=$?
        fi

        # Page the duty officer — AC1. Unlisted in operator-escalation-
        # registry.txt, so notify_operator's default verdict is PAGE.
        CHUMP_NOTIFY_KIND="$kind" \
        notify_operator "🛑 **Live verification failed for ${gap}.**

kind=${kind}
${note:-no detail supplied}

Gap held/reopened for re-verification. This page fires once per gap per $((DEDUP_WINDOW_S / 60))m (dedup window) — see outcome-verify-heal-consumer.sh." \
            >/dev/null 2>&1
        page_rc=$?

        python3 -c "
import json
json.dump({'gap':'$gap','kind':'$kind','last_epoch':$(_now_epoch)}, open('$dedup_file','w'))
" 2>/dev/null || true

        paged=$((paged + 1))
        # scanner-anchor: "kind":"outcome_verify_heal_consumer_held"
        _emit "outcome_verify_heal_consumer_held" \
            "\"gap\":\"$gap\",\"source_kind\":\"$kind\",\"gap_set_rc\":$held_rc,\"notify_rc\":$page_rc"
    done <<< "$new_lines"
fi

printf '%s' "$total_lines" > "$CURSOR_FILE" 2>/dev/null || true

# scanner-anchor: "kind":"outcome_verify_heal_consumer_tick"
_emit "outcome_verify_heal_consumer_tick" \
    "\"handled\":$handled,\"held\":$paged,\"dedup_skipped\":$suppressed"

echo "[outcome-verify-heal-consumer] cycle complete: handled=$handled held=$paged dedup_skipped=$suppressed"

# Self-registration: standard reaper heartbeat, mirrors process-organ-heal.sh
# (INFRA-3650) so a dead heal loop is itself caught by reaper-heartbeat-
# watchdog.sh's existing cadence-grading pattern.
# shellcheck source=../lib/reaper-instrumentation.sh
source "$SCRIPT_DIR/../lib/reaper-instrumentation.sh" 2>/dev/null && {
    reaper_setup outcome-verify-heal-consumer
    reaper_emit_run outcome-verify-heal-consumer ok "{\"handled\":$handled,\"held\":$paged}"
}

exit 0
