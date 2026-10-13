#!/usr/bin/env bash
# scripts/coord/no-ship-loop-detector.sh — RESILIENT-1573
#
# Harness-agnostic belt-and-suspenders loop detector. Consumes signals already
# in ambient.jsonl (cycle_end) and systemd (NRestarts) so loops are caught even
# when worker-internal counters are defeated (RESILIENT-1572) and when the only
# exit-loop watcher (daemon-exit-loop-watcher-daemon.sh) is launchd-only.
#
#  Pass 1: group cycle_end by gap_id; trailing run of >=N (default 5) cycles with
#          kind in unverified_ship|failed|timeout|wedge and no shipped after them
#          -> chump gap set GAP --status blocked + dep-gate note; file ONE gap
#          (dedup by state file). On every later observed re-pick (new bad cycles
#          past the last block) it re-blocks, so it survives the auto-flip.
#  Pass 2: systemctl show -p NRestarts for user + system scope units; NRestarts
#          over threshold (default 50) -> service_crash_loop + file/alarm ONCE per
#          unit (re-alarms only if NRestarts doubles).
#
# scanner-anchor: "kind":"no_ship_loop_detected"
# scanner-anchor: "kind":"service_crash_loop"
#
# Env: CHUMP_NOSHIP_LOOP_DISABLED, CHUMP_NOSHIP_LOOP_THRESHOLD (5),
#      CHUMP_NOSHIP_LOOP_WINDOW_LINES (20000), CHUMP_CRASH_LOOP_THRESHOLD (50),
#      CHUMP_NOSHIP_LOOP_STATE_FILE, CHUMP_NOSHIP_LOOP_DRY_RUN,
#      CHUMP_NOSHIP_LOOP_CHUMP_CMD, CHUMP_NOSHIP_LOOP_SYSTEMCTL (mock),
#      CHUMP_AMBIENT_PATH / CHUMP_AMBIENT_LOG.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AMBIENT="${CHUMP_AMBIENT_PATH:-${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}}"
STATE_FILE="${CHUMP_NOSHIP_LOOP_STATE_FILE:-$REPO_ROOT/.chump/no-ship-loop-state.json}"
THRESHOLD="${CHUMP_NOSHIP_LOOP_THRESHOLD:-5}"
WINDOW="${CHUMP_NOSHIP_LOOP_WINDOW_LINES:-20000}"
CRASH_THRESHOLD="${CHUMP_CRASH_LOOP_THRESHOLD:-50}"
DRY_RUN="${CHUMP_NOSHIP_LOOP_DRY_RUN:-}"
CHUMP_BIN="${CHUMP_NOSHIP_LOOP_CHUMP_CMD:-chump}"
SYSTEMCTL="${CHUMP_NOSHIP_LOOP_SYSTEMCTL:-systemctl}"

_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '[no-ship-loop-detector] %s\n' "$*" >&2; }
mkdir -p "$(dirname "$AMBIENT")" "$(dirname "$STATE_FILE")" 2>/dev/null || true

emit() { printf '{"ts":"%s","kind":"%s","dry_run":%s,%s}\n' "$(_ts)" "$1" \
    "$([[ -n "$DRY_RUN" ]] && echo true || echo false)" "$2" >> "$AMBIENT"; }

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    sed -n 2,22p "${BASH_SOURCE[0]}"; exit 0
fi
if [[ -n "${CHUMP_NOSHIP_LOOP_DISABLED:-}" ]]; then
    log "CHUMP_NOSHIP_LOOP_DISABLED set — exiting"; exit 0
fi
command -v jq >/dev/null 2>&1 || { log "jq missing"; exit 0; }

STATE='{}'
[[ -f "$STATE_FILE" ]] && STATE="$(jq -c . "$STATE_FILE" 2>/dev/null || echo '{}')"
save_state() { printf '%s\n' "$STATE" > "$STATE_FILE"; }

file_gap() { # title desc -> prints new id or empty
    [[ -n "$DRY_RUN" ]] && return 0
    "$CHUMP_BIN" gap reserve --domain RESILIENT --priority P2 --title "$1" 2>/dev/null \
        | grep -Eo '[A-Z]+-[0-9]+' | head -1
}

# ── Pass 1: no-ship loops ─────────────────────────────────────────────────────
if [[ -f "$AMBIENT" ]]; then
    loops="$(tail -n "$WINDOW" "$AMBIENT" | jq -Rrs --argjson n "$THRESHOLD" '
        [split("\n")[] | (try fromjson catch empty)
         | select((.event // .kind) == "cycle_end" and (.gap_id // "") != "")
         | {g: .gap_id, k: (if .event == "cycle_end" then .kind else .cycle_kind end)}]
        | group_by(.g)[]
        | . as $c | $c[0].g as $g
        | ($c | map(.k)) as $ks
        | (reduce $ks[] as $k (0; if $k == "shipped" then 0
              elif ($k|IN("unverified_ship","failed","timeout","wedge")) then .+1 else . end)) as $run
        | select($run >= $n) | "\($g)\t\($run)"' 2>/dev/null)"
    while IFS=$'\t' read -r gap run; do
        [[ -z "$gap" ]] && continue
        prev="$(jq -r --arg g "$gap" '.gaps[$g].blocked_at_run // 0' <<<"$STATE")"
        filed="$(jq -r --arg g "$gap" '.gaps[$g].filed // ""' <<<"$STATE")"
        # re-block only when new bad cycles appeared since the last block (re-pick)
        if [[ "$run" -le "$prev" ]]; then continue; fi
        log "loop: $gap run=$run (prev=$prev)"
        emit no_ship_loop_detected "\"gap_id\":\"$gap\",\"cycles\":$run,\"reblock\":$([[ "$prev" -gt 0 ]] && echo true || echo false)"
        if [[ -z "$DRY_RUN" ]]; then
            "$CHUMP_BIN" gap set "$gap" --status blocked \
                --add-note "no-ship-loop-detector (RESILIENT-1573): $run consecutive non-shipping cycles; blocked. Dep-gate: do not re-pick until root cause is fixed and a human/ATC reopens." \
                >/dev/null 2>&1 || log "gap set failed for $gap"
        fi
        if [[ -z "$filed" ]]; then
            filed="$(file_gap "no-ship loop on $gap: $run consecutive non-shipping cycles (auto-detected)")"
        fi
        STATE="$(jq -c --arg g "$gap" --argjson r "$run" --arg f "${filed:-}" \
            '.gaps[$g] = {blocked_at_run:$r, filed:$f}' <<<"$STATE")"
    done <<<"$loops"
fi

# ── Pass 2: systemd crash loops (user + system scope) ─────────────────────────
if command -v "$SYSTEMCTL" >/dev/null 2>&1; then
    for scope in --user --system; do
        units="$("$SYSTEMCTL" $scope list-units --type=service --all --no-legend --plain 2>/dev/null \
            | awk '{print $1}' | grep -E '\.service$' || true)"
        for unit in $units; do
            n="$("$SYSTEMCTL" $scope show -p NRestarts --value "$unit" 2>/dev/null | head -1)"
            [[ "$n" =~ ^[0-9]+$ ]] || continue
            [[ "$n" -gt "$CRASH_THRESHOLD" ]] || continue
            key="${scope#--}:$unit"
            last="$(jq -r --arg k "$key" '.units[$k] // 0' <<<"$STATE")"
            if [[ "$last" -gt 0 && "$n" -lt $(( last * 2 )) ]]; then continue; fi
            log "crash-loop: $key NRestarts=$n"
            emit service_crash_loop "\"unit\":\"$unit\",\"scope\":\"${scope#--}\",\"nrestarts\":$n"
            [[ "$last" -eq 0 ]] && file_gap "service crash-loop: $unit (${scope#--} scope) NRestarts=$n" >/dev/null
            STATE="$(jq -c --arg k "$key" --argjson n "$n" '.units[$k] = $n' <<<"$STATE")"
        done
    done
fi

save_state
exit 0
