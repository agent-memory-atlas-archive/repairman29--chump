#!/usr/bin/env bash
# reaper-heartbeat-watchdog.sh — Detect when a stale-* reaper has stopped
# running and ALERT the fleet via ambient.jsonl.
#
# INFRA-120 (2026-05-01): the three reapers (stale-pr, stale-worktree,
# stale-branch) each run on their own launchd cadence. If the launchd plist
# isn't installed, or its job silently fails (broken PATH, dead python3, etc.),
# nothing alerts the fleet. Worktrees and branches accumulate for days before
# anyone notices. This watchdog grades the heartbeat files written by
# scripts/lib/reaper-instrumentation.sh and emits ALERT events so the staleness
# is visible in the standard pre-flight `tail -30 .chump-locks/ambient.jsonl`.
#
# Per-reaper cadence (the launchd plists configure these; numbers below match):
#
#   pr        | StartInterval 3600s   (1h)  → ALERT if no heartbeat in 4h
#   worktree  | StartInterval 3600s   (1h)  → ALERT if no heartbeat in 4h
#   branch    | StartInterval 86400s (24h)  → ALERT if no heartbeat in 48h
#
# Multipliers default to 4x cadence (worktree, branch) and 2x for the
# faster-cadence pr reaper, matching the gap acceptance criteria.
#
# Usage:
#   scripts/ops/reaper-heartbeat-watchdog.sh                    # check all reapers
#   scripts/ops/reaper-heartbeat-watchdog.sh pr worktree        # subset
#   scripts/ops/reaper-heartbeat-watchdog.sh --quiet            # ALERT only on failure
#
# Cron / launchd: install via scripts/setup/install-reaper-watchdog-launchd.sh
# (runs every 30 min). The watchdog itself is fail-closed: if it can't write
# to ambient.jsonl, it prints to stderr and exits non-zero so the launchd
# stderr log captures the issue.

set -euo pipefail

# shellcheck source=../lib/reaper-instrumentation.sh
source "$(dirname "$0")/../lib/reaper-instrumentation.sh"

QUIET=0
declare -a TARGETS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --quiet) QUIET=1 ;;
        -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
        --*) echo "Unknown flag: $1" >&2; exit 2 ;;
        *) TARGETS+=("$1") ;;
    esac
    shift
done
# INFRA-452: include 'watchdog' in default TARGETS so the watchdog also
# grades ITSELF. The for-loop reads the heartbeat BEFORE reaper_finish
# stamps a fresh one at exit, so the read reflects the *previous* run —
# which is exactly the gap we want to detect (the canary died with the
# canaries it was supposed to grade).
# INFRA-683: added pr-watch and distill as non-reaper heartbeat targets.
# RESILIENT-246: added curator-supervisor. The curator is chump's
# product-management layer (pillar balance, PR unstick, backlog restock) and it
# died on ~2026-08-01 with launchd exit 78, unnoticed for twelve days, because
# nothing graded it. It is graded HERE rather than by a new bespoke watchdog:
# scripts/ops/curator-supervisor-run.sh calls reaper_setup/reaper_finish, so it
# stamps /tmp/chump-reaper-curator-supervisor.heartbeat on the standard path
# this loop already reads. No new mechanism, one new name.
# RESILIENT-256: added `wip`. The uncommitted-WIP watchdog is the only thing
# standing between a 13-hour-old dirty tree and a permanent loss, so a silent
# one is worse than a noisy one — it grades here like every other canary.
# INFRA-3650: added `process-organ-heal`. It heals raw background bash
# procs (e.g. almanac-vision-keeper) that aren't systemd units, so nothing
# else revives them if it dies — same "the healer can never stay dead"
# closure RESILIENT-356 gave organ-watchdog.sh, one layer down the stack.
# INFRA-3654: added `outcome-verify-heal-consumer`. It is the consumer for
# kind=outcome_probe_failed / kind=ac_coverage_proof_miss — both emitters
# existed with no consumer before this gap, so a dead consumer here would
# quietly reopen the same "proved-false live outcome, nobody told" hole.
[[ ${#TARGETS[@]} -eq 0 ]] && TARGETS=(pr worktree branch stuck-pr pr-watch watchdog ci-flake pr-blocked distill curator-supervisor wip process-organ-heal outcome-verify-heal-consumer)

# Per-reaper alert thresholds (seconds since last heartbeat).
threshold_secs() {
    case "$1" in
        pr)          echo $((2 * 3600)) ;;   # 2h (cadence 1h × 2x)
        worktree)    echo $((4 * 3600)) ;;   # 4h (cadence 1h × 4x)
        branch)      echo $((48 * 3600)) ;;  # 48h (cadence 24h × 2x)
        stuck-pr)    echo $((2 * 3600)) ;;   # 2h (cadence 1h × 2x — INFRA-307)
        pr-watch)    echo $((5 * 60)) ;;     # 5m (INFRA-683: async process, not a reaper)
        watchdog)    echo $((90 * 60)) ;;    # 90min (cadence 30min × 3x — INFRA-452)
        ci-flake)    echo $((2 * 3600)) ;;   # 2h (cadence 1h × 2x — INFRA-375)
        pr-blocked)  echo $((2 * 3600)) ;;   # 2h (cadence 1h × 2x — INFRA-550)
        distill)     echo $((1 * 3600)) ;;   # 1h (INFRA-683: async process, not a reaper)
        # RESILIENT-246: supervisor cadence is 300s, so 1h is 12 missed cycles.
        # Deliberately not 2x cadence: this laptop sleeps, and a 10-minute
        # threshold would cry wolf every morning. 1h still turns a twelve-day
        # silence into an alert within one watchdog run (30 min).
        curator-supervisor) echo $((1 * 3600)) ;;
        wip)         echo $((2 * 3600)) ;;   # 2h (cadence 30min × 4x — RESILIENT-256)
        # INFRA-3650: process-organ-heal's install cadence is 5min (see
        # chump-node-install.sh's process-organ-heal organ wrapper) — 1h is
        # 12 missed cycles, generous enough that a laptop that slept for a
        # bit doesn't cry wolf, tight enough to catch a genuinely dead loop
        # same-session.
        process-organ-heal) echo $((1 * 3600)) ;;
        # INFRA-3654: this consumer's timer cadence is 10min (see its .timer
        # unit) — 1h is 6 missed cycles, same "generous but catches a real
        # death same-session" reasoning as process-organ-heal above.
        outcome-verify-heal-consumer) echo $((1 * 3600)) ;;
        *)           echo $((4 * 3600)) ;;
    esac
}

# RESILIENT-246: launchd_exit_status LABEL — second column of `launchctl list`,
# or "absent" when the job is not loaded at all.
#
# Heartbeat freshness alone cannot see the failure that caused this gap. When
# launchd cannot spawn ProgramArguments[0] it returns 78 (EX_CONFIG) BEFORE the
# process exists, so no heartbeat is written, no log line appears, and both
# StandardOutPath and StandardErrorPath stay empty. A missing heartbeat is
# indistinguishable from "never installed". Reading the exit status is what
# turns that silence into a diagnosis.
# scanner-anchor: "kind":"curator_silent"
launchd_exit_status() {
    launchctl list 2>/dev/null \
        | awk -v l="$1" '$3 == l {print $2; found=1} END {if (!found) print "absent"}'
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-${CHUMP_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}}"
# INFRA-8583: read the ONE shared pause detector (_nc_paused -> chump node is-paused /
# node.env CHUMP_NODE_MODE=paused / state_dir/.chump/fleet-paused / repo .chump/fleet-paused).
# When paused on purpose, report PAUSED (state=paused_expected) instead of alerting reaper_silent.
if [[ -f "$SCRIPT_DIR/node-converge.sh" ]]; then
    eval "$(sed -n '/^_nc_paused()/,/^}/p' "$SCRIPT_DIR/node-converge.sh" 2>/dev/null)" 2>/dev/null || true
fi
_watchdog_node_paused() {
    local sd="${CHUMP_STATE_DIR:-${HOME:-/root}/.chump}"
    if declare -f _nc_paused >/dev/null 2>&1; then
        CHUMP_STATE_DIR="$sd" REPO_ROOT="$REPO_ROOT" _nc_paused && return 0
    fi
    [[ -f "$REPO_ROOT/.chump/fleet-paused" ]] && return 0
    [[ -f "$sd/.chump/fleet-paused" ]] && return 0
    local ne="$sd/node.env"
    if [[ -f "$ne" ]]; then
        grep -Eq "^(export )?CHUMP_NODE_MODE=paused([[:space:]]|$)" "$ne" && return 0
    fi
    [[ "${CHUMP_NODE_MODE:-}" == "paused" ]] && return 0
    return 1
}

reaper_setup watchdog
reaper_check_disk_headroom  # INFRA-453: exit 0 + ALERT if <5% free

ALERTS=0
OK=0
NOW=$(date +%s)

if _watchdog_node_paused; then
    for name in "${TARGETS[@]}"; do
        OK=$((OK + 1))
        [[ $QUIET -eq 0 ]] && printf "  PAUSED (state=paused_expected): %s skipped on paused node\n" "$name"
    done
    if [[ $QUIET -eq 0 ]]; then
        printf "=== watchdog done (PAUSED): %d expected-paused, %d ALERT(s) ===\n" "$OK" "$ALERTS"
    fi
    reaper_finish ok "{\"checked\":${#TARGETS[@]},\"ok\":$OK,\"alerts\":0,\"state\":\"paused_expected\"}"
    exit 0
fi

for name in "${TARGETS[@]}"; do
    # INFRA-683: pr-watch and distill are non-reaper processes that write heartbeats
    is_daemon=0
    is_curator=0
    case "$name" in
        pr-watch) hb="/tmp/chump-pr-watch.heartbeat"; is_daemon=1 ;;
        distill)  hb="/tmp/chump-distill.heartbeat"; is_daemon=1 ;;
        # RESILIENT-246: standard heartbeat path, but a launchd-managed job, so
        # the alert text names the label and its real exit status.
        curator-supervisor) hb="/tmp/chump-reaper-${name}.heartbeat"; is_curator=1 ;;
        *)        hb="/tmp/chump-reaper-${name}.heartbeat" ;;
    esac

    # RESILIENT-246: for launchd-managed targets, read the job's exit status so
    # the alert can say WHY it is silent instead of only that it is silent.
    curator_hint=""
    if [[ $is_curator -eq 1 ]]; then
        _cst="$(launchd_exit_status com.chump.curator-supervisor)"
        case "$_cst" in
            absent) curator_hint=" launchd job com.chump.curator-supervisor is NOT LOADED — reinstall: bash scripts/setup/install-curator-supervisor.sh" ;;
            0)      curator_hint=" launchd reports last exit 0, so the job is spawning but not stamping a heartbeat — check ~/Library/Logs/Chump/curator-supervisor.err.log" ;;
            78)     curator_hint=" launchd reports exit 78 (EX_CONFIG): it CANNOT SPAWN the program, so no logs are written at all. This is the RESILIENT-246 failure. Reinstall: bash scripts/setup/install-curator-supervisor.sh" ;;
            *)      curator_hint=" launchd reports last exit ${_cst} — see ~/Library/Logs/Chump/curator-supervisor.err.log" ;;
        esac
    fi

    threshold=$(threshold_secs "$name")
    if [[ ! -f "$hb" ]]; then
        if [[ $is_curator -eq 1 ]]; then
            msg="curator-supervisor has never heartbeated — heartbeat file missing at $hb. The curator is chump's product-management layer; while it is silent nothing rebalances pillars or unsticks PRs.${curator_hint}"
            alert_kind="curator_silent"
        elif [[ $is_daemon -eq 1 ]]; then
            msg="daemon process ${name} has never heartbeated — heartbeat file missing at $hb. Check if the process is running."
            alert_kind="daemon_silent"
        else
            # RESILIENT-256: `wip` is installed by its own launchd script, not
            # by the install-stale-*-reaper-launchd.sh family. Naming the
            # wrong installer in the ALERT is how an alert gets ignored.
            installer="scripts/setup/install-stale-${name}-reaper-launchd.sh"
            [[ "$name" == "wip" ]] && installer="scripts/setup/install-wip-watchdog-launchd.sh"
            msg="reaper ${name} has never heartbeated — heartbeat file missing at $hb. Install the launchd job (${installer}) or run the reaper manually once."
            alert_kind="reaper_silent"
        fi
        printf 'ALERT [%s] %s\n' "$alert_kind" "$msg" >&2
        # Emit ALERT to ambient.jsonl directly (use raw JSON so we don't
        # depend on the broadcast.sh wrapper for fail-safety).
        ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        printf '{"event":"ALERT","kind":"%s","reaper":"%s","ts":"%s","reason":%s}\n' \
            "$alert_kind" "$name" "$ts" \
            "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$msg" 2>/dev/null || echo "\"$msg\"")" \
            >> "$REAPER_LOCK_DIR/ambient.jsonl" 2>/dev/null || true
        ALERTS=$((ALERTS + 1))
        continue
    fi
    # Heartbeat file format is `key=value` lines; ts=... is the canonical key.
    ts_line=$(grep '^ts=' "$hb" 2>/dev/null | head -1 | cut -d= -f2- || true)
    if [[ -z "$ts_line" ]]; then
        # Fall back to mtime.
        last=$(stat -f%m "$hb" 2>/dev/null || stat -c%Y "$hb" 2>/dev/null || echo 0)
    else
        # Parse ISO-8601 UTC. macOS date(1) needs explicit -j -f.
        if last=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts_line" "+%s" 2>/dev/null); then
            :
        else
            last=$(date -u -d "$ts_line" "+%s" 2>/dev/null || stat -f%m "$hb" 2>/dev/null || echo 0)
        fi
    fi
    age=$(( NOW - last ))
    age_h=$(( age / 3600 ))
    threshold_h=$(( threshold / 3600 ))

    if [[ $age -gt $threshold ]]; then
        if [[ $is_curator -eq 1 ]]; then
            msg="curator-supervisor has not run in ${age_h}h (threshold ${threshold_h}h). Last heartbeat at ${ts_line:-unknown}. The curator is chump's product-management layer; while it is silent nothing rebalances pillars or unsticks PRs.${curator_hint}"
            alert_kind="curator_silent"
        elif [[ $is_daemon -eq 1 ]]; then
            msg="daemon process ${name} has not run in ${age_h}h (threshold ${threshold_h}h). Last heartbeat at ${ts_line:-unknown}. Check if the process is running."
            alert_kind="daemon_silent"
        else
            msg="reaper ${name} has not run in ${age_h}h (threshold ${threshold_h}h). Last heartbeat at ${ts_line:-unknown}. Check launchctl list | grep dev.chump.stale-${name}-reaper and /tmp/chump-stale-${name}-reaper.err.log."
            alert_kind="reaper_silent"
        fi
        printf 'ALERT [%s] %s\n' "$alert_kind" "$msg" >&2
        ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        printf '{"event":"ALERT","kind":"%s","reaper":"%s","ts":"%s","age_hours":%d,"threshold_hours":%d,"reason":%s}\n' \
            "$alert_kind" "$name" "$ts" "$age_h" "$threshold_h" \
            "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$msg" 2>/dev/null || echo "\"$msg\"")" \
            >> "$REAPER_LOCK_DIR/ambient.jsonl" 2>/dev/null || true
        ALERTS=$((ALERTS + 1))
    else
        OK=$((OK + 1))
        [[ $QUIET -eq 0 ]] && printf '  ok: %s heartbeated %dh ago (threshold %dh)\n' "$name" "$age_h" "$threshold_h"
    fi
done

if [[ $QUIET -eq 0 ]]; then
    printf '=== watchdog done: %d ok, %d ALERT(s) ===\n' "$OK" "$ALERTS"
fi

# Emit our own reaper_run so the watchdog also has a heartbeat (the watchdog
# guards the reapers; nothing else guards the watchdog, but at least its
# run history is in the ambient stream).
reaper_finish ok "{\"checked\":${#TARGETS[@]},\"ok\":$OK,\"alerts\":$ALERTS}"

exit 0
