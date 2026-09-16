#!/usr/bin/env bash
# scripts/ops/fleet-health-sentinel.sh — RESILIENT-1052
#
# THE ANTI-MEMENTO ENFORCEMENT SENTINEL. "Make solved stay solved."
#
# WHY THIS EXISTS (verified live 2026-09-07). 33 chump systemd units sat
# `failed` across the fleet and NOBODY NOTICED until a human asked. Root cause:
# a launchd->systemd port baked a wrong $HOME into the units, so they failed
# CHDIR and only resurrected on their own timer ticks (RESILIENT-1051). Worse,
# the self-healers that were supposed to catch drift — organ-reconcile /
# organ-watchdog / reaper-watchdog — are INACTIVE-OR-ABSENT on cuphead AND
# mugman. Two of three nodes had zero drift protection running, and there was
# NO alarm for a healer being down. A healer that can die silently is the
# amnesia engine: it lets a solved problem quietly un-solve itself.
#
# This sentinel closes that hole. It watches the fleet, it watches the HEALERS,
# and — the whole point — it is watched too, so it cannot die silently either.
#
# WHAT IT COMPLEMENTS (mine-before-build; it does NOT replace these):
#   * scripts/ops/organ-watchdog.sh   — local failed-unit healer (helsinki,
#                                        system-scope). The sentinel watches
#                                        THAT it is alive, and heals the
#                                        --user-scope Oracle nodes it never
#                                        covered.
#   * scripts/ops/organ-reconcile.sh  — manifest convergence.
#   * scripts/ops/reaper-heartbeat-watchdog.sh — local heartbeat grader; the
#                                        sentinel stamps a heartbeat it can
#                                        grade, and adds the CROSS-NODE grade
#                                        that watchdog structurally cannot do.
#   * PR #4512 (RESILIENT-1016) timer-aware reap — the SAFE reconcile. When an
#                                        organ-reconcile unit is present the
#                                        sentinel triggers THAT rather than any
#                                        timer-blind reap.
#
# THREE JOBS:
#   1. DETECT, fleet-wide — (a) any failed chump-* systemd unit on any node;
#      (b) any required HEALER inactive-or-absent on any node; (c) any SYSTEM-
#      scope organ (the self-drive board-cycle/nba-dispatch/duty-officer, the
#      merge-serializer, organ-reconcile) inactive OR DEAD — active with no
#      scheduled next fire (RESILIENT-1055; the --user scan is blind to these);
#      (d) a force-push RACE: ≥2 rebaser organs active on one node at once.
#   2. ACT — where safe, self-heal (reset-failed+restart a failed oneshot,
#      enable --now an inactive healer/timer, or trigger the #4512 safe
#      reconcile). Where it cannot, emit a halt-class ambient event AND page
#      the board. Never JUST whisper to ambient.
#   3. BE WATCHED — every pass writes a heartbeat (local file + ambient tick +
#      best-effort POST to the fleet-server). A separate --fleet grade (run
#      from any host with fleet reach — the board today, the fleet-server
#      tomorrow) pages if any node's sentinel heartbeat is stale or the node
#      is unreachable. If the sentinel dies, something notices.
#
# MODES:
#   --local   (default)  scan+heal THIS node; write heartbeat; emit tick.
#   --fleet              cross-node grade: read every node's sentinel
#                        heartbeat + failed-unit count; page on stale/unreach.
#   --report-json        print this node's health snapshot as one JSON line
#                        (consumed by a remote --fleet grader / the fleet-server).
#
# FLAGS:
#   --dry-run            detect + report only; never heal, never page.
#   --loop [--cadence-min N]  run forever, one pass every N min (default 5) —
#                        for the Restart=always organ-service supervisor path.
#   --nodes FILE         node topology (default scripts/ops/fleet-nodes.conf).
#
# ENV:
#   CHUMP_STATE_DIR              heartbeat dir (default ~/.chump)
#   CHUMP_AMBIENT_LOG            ambient jsonl (default <repo>/.chump-locks/ambient.jsonl)
#   CHUMP_FLEET_SERVER_URL       POST heartbeat to $URL/api/sentinel-heartbeat
#                                (default http://127.0.0.1:7070; point at
#                                cuphead's tailnet addr on a non-server node).
#                                Authed with CHUMP_BATPHONE_TOKEN (from env or
#                                ~/.chump/providers.env), same as /api/gap.
#   CHUMP_SENTINEL_CADENCE_MIN   cadence for --loop / staleness math (default 5)
#   CHUMP_SENTINEL_STALE_MULT    heartbeat-stale multiplier (default 3 → 15min)
#   CHUMP_SENTINEL_PAGE_SINK     TEST/audit hook: also append page payloads here
#   CHUMP_SENTINEL_REQUIRED_HEALERS  space list, overrides the required set
#   CHUMP_SENTINEL_WATCHED_HEALERS   space list, overrides the watched-if-present set
#   CHUMP_SENTINEL_SYSTEM_ORGANS     space list, SYSTEM-scope organs to watch+re-arm
#                                    (self-drive + merge + reconcile; RESILIENT-1055)
#   CHUMP_SENTINEL_RACE_ORGANS       space list, force-push/rebaser organs; ≥2 active = PAGE
#   CHUMP_SENTINEL_SYSTEMCTL_SYS     SYSTEM systemctl binary/shim (default: systemctl)
#   CHUMP_SENTINEL_SUDO              privilege-escalation prefix for SYSTEM mutations
#                                    (default: "sudo -n"; tests set it empty w/ a fake)
#   CHUMP_SYSTEMCTL              systemctl binary/shim (default: systemctl --user)
#
# Bash 4+; runs on the Oracle nodes (bash 5.1) and the board. Fail-soft: a
# broken notifier or a single unreachable node never aborts the pass.

set -uo pipefail

# ── resolve repo root (worktree-safe) ────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
_common="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || true)"
if [[ -n "$_common" && "$_common" != ".git" ]]; then
    [[ "$_common" != /* ]] && _common="$REPO_ROOT/$_common"
    REPO_ROOT="$(cd "$(dirname "$_common")" && pwd)"
fi

STATE_DIR="${CHUMP_STATE_DIR:-$HOME/.chump}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
HEARTBEAT_FILE="$STATE_DIR/fleet-health-sentinel.heartbeat"
REAPER_HB="/tmp/chump-reaper-fleet-health-sentinel.heartbeat"
CADENCE_MIN="${CHUMP_SENTINEL_CADENCE_MIN:-5}"
STALE_MULT="${CHUMP_SENTINEL_STALE_MULT:-3}"
NODE_ID="$(hostname 2>/dev/null || echo unknown)"

# systemctl shim point — tests inject a fake here; prod uses --user scope.
SYSTEMCTL="${CHUMP_SYSTEMCTL:-systemctl --user}"

# Required healers: MUST be present AND active on an owned node. Absent → page
# (we cannot self-heal a unit that does not exist). These are the Oracle-node
# drift-protection organs plus the sentinel's own timer.
REQUIRED_HEALERS="${CHUMP_SENTINEL_REQUIRED_HEALERS:-chump-node-refresh.timer chump-node-deploy-lag-watchdog.timer chump-fleet-health-sentinel.timer}"
# Watched-if-present: the classic organ healers. Re-enable when present but
# inactive; ignore when a node legitimately never carried them.
WATCHED_HEALERS="${CHUMP_SENTINEL_WATCHED_HEALERS:-organ-watchdog.timer organ-reconcile.timer reaper-watchdog.timer chump-organ-watchdog.timer chump-organ-reconcile.timer}"

# ── SYSTEM-scope roster (RESILIENT-1055) ─────────────────────────────────────
# The full live self-drive + merge + reconcile roster runs under the SYSTEM
# systemd manager (/etc/systemd/system), NOT --user. This sentinel runs --user,
# so its --user is-active is BLIND to them — the structural hole that let
# closetjunky's organ-reconcile timer and cuphead's board-cycle timer decay to
# "no next elapse" completely unwatched (verified live 2026-09-08). We check
# these against the SYSTEM manager and heal with sudo. Watched-if-present:
# absent → skip (the manifest/install organ owns provisioning — we never invent
# a unit); present-but-inactive OR present-but-DEAD (active with no scheduled
# next fire) → re-arm.
SYSTEM_ORGANS="${CHUMP_SENTINEL_SYSTEM_ORGANS:-chump-organ-reconcile.timer chump-board-cycle.timer chump-nba-dispatch.timer chump-duty-officer.timer chump-merge-serializer.timer}"
# Force-push/rebaser organs. A node is meant to run AT MOST ONE. Two or more
# active at once is the force-push race that quietly clobbered ~2000 PRs — the
# operator neuters all-but-one with drop-ins on purpose, so if ≥2 come back
# active we PAGE (never auto-touch; disabling the wrong one could wedge merges).
RACE_ORGANS="${CHUMP_SENTINEL_RACE_ORGANS:-chump-armed-pr-rebaser.timer chump-pr-auto-rebase.timer chump-pr-rebase-loop.timer chump-rebaser.timer}"
# SYSTEM systemd manager. Reads (is-active/show) need no privilege even from a
# --user session; mutations go through $SUDO. Tests inject fakes at both.
SYSTEMCTL_SYS="${CHUMP_SENTINEL_SYSTEMCTL_SYS:-systemctl}"
# No colon: an explicitly-empty override ("") must be honored (tests run the
# heal with a fake systemctl and no privilege prefix), not fall back to sudo.
SUDO="${CHUMP_SENTINEL_SUDO-sudo -n}"

# ── RESILIENT-1309 / RESILIENT-1326: coordination organs run ONLY on the ──────
# coordination home (CJ). The self-drive / merge / paging organs (board-cycle,
# nba-dispatch, duty-officer, merge-serializer, next-best-action) must be active
# on exactly ONE node, co-located with the live canonical state.db. On a
# NON-coordination node the sentinel USED to re-arm them (via the SYSTEM_ORGANS
# default AND a host CHUMP_SENTINEL_WATCHED_HEALERS override), resurrecting the
# retired organs within ~2min and driving the split-brain paging + cross-node
# merge race. Node role lives in ~/.chump/node.env (CHUMP_NODE_ROLE,
# RESILIENT-1083) — the SAME lever organ-reconcile self-scopes on, and it
# survives the deploy mirror's `git reset --hard`. On any non-coordination role
# we STRIP the coordination organs from BOTH watch/heal sets regardless of
# source (built-in default OR env override), so a lingering host drop-in cannot
# re-introduce them. Back-compat: role brain / all / EMPTY = coordination home →
# lists unchanged (CJ and any pre-role node keep coordinating).
_SENTINEL_NODE_ENV="${CHUMP_STATE_DIR:-$HOME/.chump}/node.env"
# shellcheck disable=SC1090
[[ -f "$_SENTINEL_NODE_ENV" ]] && . "$_SENTINEL_NODE_ENV" 2>/dev/null || true
COORDINATION_ORGANS="${CHUMP_SENTINEL_COORDINATION_ORGANS:-chump-board-cycle.timer chump-nba-dispatch.timer chump-duty-officer.timer chump-merge-serializer.timer chump-next-best-action.timer}"
_sentinel_is_coordination_role() {  # brain / all / empty = coordination home
  case "${1:-}" in brain|all|"") return 0 ;; *) return 1 ;; esac
}
_sentinel_strip_coordination() {  # $1 = space-separated unit list -> filtered list
  local _in="$1" _out="" _tok _c _skip
  for _tok in $_in; do
    _skip=0
    for _c in $COORDINATION_ORGANS; do [[ "$_tok" == "$_c" ]] && { _skip=1; break; }; done
    [[ $_skip -eq 0 ]] && _out="$_out $_tok"
  done
  printf "%s" "${_out# }"
}
if ! _sentinel_is_coordination_role "${CHUMP_NODE_ROLE:-}"; then
  SYSTEM_ORGANS="$(_sentinel_strip_coordination "$SYSTEM_ORGANS")"
  WATCHED_HEALERS="$(_sentinel_strip_coordination "$WATCHED_HEALERS")"
  echo "[fleet-health-sentinel] RESILIENT-1309: node role=${CHUMP_NODE_ROLE:-<empty>} (non-coordination) — coordination organs excluded from watch/heal sets" >&2
fi

MODE="local"
DRY=0
LOOP=0
NODES_FILE="$SCRIPT_DIR/fleet-nodes.conf"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --local) MODE="local" ;;
        --fleet) MODE="fleet" ;;
        --report-json) MODE="report-json" ;;
        --dry-run) DRY=1 ;;
        --loop) LOOP=1 ;;
        --cadence-min) CADENCE_MIN="$2"; shift ;;
        --nodes) NODES_FILE="$2"; shift ;;
        -h|--help) sed -n '2,60p' "$0"; exit 0 ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
    shift
done

now_epoch() { date -u +%s; }
ts_iso()    { date -u +%Y-%m-%dT%H:%M:%SZ; }

log()  { echo "[fleet-health-sentinel] $*" >&2; }

# ── ambient emit (fail-soft) ─────────────────────────────────────────────────
# The kind is written via a printf %s (dynamic), so the event-registry coverage
# scanner cannot see the literals at the emit call. These anchors carry the
# literal "kind":"X" strings the scanner greps for, one per kind this file can
# emit, so emitted-set == registered-set (docs/observability/EVENT_REGISTRY.yaml).
# scanner-anchor: "kind":"fleet_health_sentinel_tick"
# scanner-anchor: "kind":"fleet_health_self_healed"
# scanner-anchor: "kind":"fleet_health_unit_failed"
# scanner-anchor: "kind":"fleet_health_healer_down"
# scanner-anchor: "kind":"fleet_health_sentinel_peer_dead"
# scanner-anchor: "kind":"fleet_health_race_signature"
emit() {
    # emit <kind> [k=v ...]
    local kind="$1"; shift || true
    mkdir -p "$(dirname "$AMBIENT_LOG")" 2>/dev/null || true
    local extra="" kv k v
    for kv in "$@"; do
        k="${kv%%=*}"; v="${kv#*=}"
        v="${v//\\/\\\\}"; v="${v//\"/\\\"}"
        extra="$extra,\"$k\":\"$v\""
    done
    printf '{"ts":"%s","kind":"%s","node":"%s","emitter":"fleet-health-sentinel"%s}\n' \
        "$(ts_iso)" "$kind" "$NODE_ID" "$extra" >> "$AMBIENT_LOG" 2>/dev/null || true
}

# ── page the board (never JUST ambient) ──────────────────────────────────────
# Always: emit a halt-class ambient event, log a PAGE: line, drop to the test
# sink if configured, and call notify_operator (Discord DM, severity=halt).
# notify_operator no-ops silently when unconfigured (no DISCORD_TOKEN), so the
# ambient halt event + sink are the durable receipts on a node without creds.
page() {
    local msg="$1" kind="${2:-fleet_health_alarm}"
    log "PAGE ($kind): $msg"
    emit "$kind" severity=halt msg="$msg"
    if [[ -n "${CHUMP_SENTINEL_PAGE_SINK:-}" ]]; then
        printf '%s\tPAGE\t%s\t%s\t%s\n' "$(ts_iso)" "$kind" "$NODE_ID" "$msg" \
            >> "$CHUMP_SENTINEL_PAGE_SINK" 2>/dev/null || true
    fi
    # Real page path. Fail-soft: a broken notifier must never break the sentinel.
    local notifier="$SCRIPT_DIR/../coord/lib/notify-operator.sh"
    if [[ -f "$notifier" ]]; then
        # shellcheck disable=SC1090
        ( CHUMP_NOTIFY_KIND="$kind" CHUMP_NOTIFY_SEVERITY=halt \
          bash -c 'source "$1"; notify_operator "$2"' _ "$notifier" \
          "[sentinel/$NODE_ID] $msg" ) >/dev/null 2>&1 || true
    fi
}

# ── systemctl helpers (honor the shim) ───────────────────────────────────────
sc() { $SYSTEMCTL "$@" 2>/dev/null; }

unit_exists() { sc list-unit-files "$1" --no-legend 2>/dev/null | grep -q "$1" \
    || sc cat "$1" >/dev/null 2>&1; }
unit_active() { [[ "$(sc is-active "$1" 2>/dev/null)" == "active" ]]; }

failed_chump_units() {
    # one unit name per line. systemctl prefixes a failed unit's line with a
    # `●` bullet in its own column ("● chump-foo.service loaded failed ..."),
    # so awk $1 grabs the bullet, not the unit — extract the chump-*.unit token
    # directly instead (works with or without the bullet, any locale).
    sc list-units 'chump-*' --state=failed --all --no-legend 2>/dev/null \
        | grep -oE 'chump-[A-Za-z0-9_.@:-]+\.(service|timer)' | sort -u || true
}

# ── SYSTEM-scope helpers (RESILIENT-1055) ────────────────────────────────────
sc_sys() { $SYSTEMCTL_SYS "$@" 2>/dev/null; }
sys_unit_exists() { sc_sys list-unit-files "$1" --no-legend 2>/dev/null | grep -q "$1"; }
sys_unit_active() { [[ "$(sc_sys is-active "$1" 2>/dev/null)" == "active" ]]; }

# timer_dead <unit.timer> — true when a timer is ACTIVE but has NO scheduled
# next fire. This is the OnUnitActiveSec-without-OnCalendar decay: the timer is
# (re)started well after boot, its oneshot service is never triggered by it, so
# the relative anchor never resolves and the timer sits active forever with
# NextElapse=infinity, silently never firing again. systemd reports it "active"
# so a plain is-active check calls it healthy — this is the trap that hid the
# decay. Healthy iff at least ONE NextElapse field names a real future time.
# Verified signatures (2026-09-08): healthy organ-reconcile mono="1w 22h 38min",
# dead board-cycle mono="infinity" rt="".
timer_dead() {
    local unit="$1" rt mono
    rt="$(sc_sys show "$unit" -p NextElapseUSecRealtime --value 2>/dev/null)"
    mono="$(sc_sys show "$unit" -p NextElapseUSecMonotonic --value 2>/dev/null)"
    case "$rt"   in ""|"0"|"n/a"|"infinity") ;; *) return 1 ;; esac
    case "$mono" in ""|"0"|"n/a"|"infinity") ;; *) return 1 ;; esac
    return 0
}

# heal_system_organ <unit.timer> — bring a present-but-broken system organ back.
# Inactive → enable --now. Dead (active/no-next) → start the ONESHOT SERVICE
# once: that both runs the beat now AND re-anchors OnUnitActiveSec so the timer
# computes a real next fire (a bare `timer restart` does NOT re-arm it — proven
# live: restarting board-cycle.timer left mono=infinity; starting the .service
# set mono to a real +15min). Returns 0 iff the timer ends active with a next.
heal_system_organ() {
    local timer="$1" svc="${1%.timer}.service"
    sys_unit_active "$timer" || $SUDO $SYSTEMCTL_SYS enable --now "$timer" >/dev/null 2>&1 || true
    if timer_dead "$timer"; then
        $SUDO $SYSTEMCTL_SYS start "$svc" >/dev/null 2>&1 || true
    fi
    sleep 1
    sys_unit_active "$timer" && ! timer_dead "$timer"
}

# ── LOCAL: scan + heal this node ─────────────────────────────────────────────
# Returns (via globals) counts for the snapshot/report.
SNAP_FAILED=0; SNAP_HEALED=0; SNAP_UNHEALED=0; SNAP_HEALERS_DOWN=0; SNAP_HEALERS_FIXED=0; SNAP_RACE_ACTIVE=0
scan_and_heal_local() {
    SNAP_FAILED=0; SNAP_HEALED=0; SNAP_UNHEALED=0; SNAP_HEALERS_DOWN=0; SNAP_HEALERS_FIXED=0; SNAP_RACE_ACTIVE=0

    # 1. failed chump units -----------------------------------------------------
    local u still
    while IFS= read -r u; do
        [[ -z "$u" ]] && continue
        SNAP_FAILED=$((SNAP_FAILED+1))
        log "FAILED unit: $u"
        if [[ $DRY -eq 1 ]]; then continue; fi
        # SAFE self-heal: clear the start-limit latch, then re-fire once. This is
        # NOT a timer-blind reap — we touch only units already in `failed`, and
        # we prefer the #4512 organ-reconcile safe path when it is installed.
        if unit_exists "chump-organ-reconcile.service"; then
            sc start chump-organ-reconcile.service >/dev/null 2>&1 || true
        fi
        sc reset-failed "$u" >/dev/null 2>&1 || true
        sc restart "$u"     >/dev/null 2>&1 || true
        sleep 1
        still="$(sc is-active "$u" 2>/dev/null)"
        if [[ "$still" == "failed" ]]; then
            SNAP_UNHEALED=$((SNAP_UNHEALED+1))
            page "chump unit $u is failed and did not recover after reset-failed+restart" \
                 "fleet_health_unit_failed"
        else
            SNAP_HEALED=$((SNAP_HEALED+1))
            emit "fleet_health_self_healed" unit="$u" action="reset-failed+restart"
            log "self-healed: $u -> $still"
        fi
    done < <(failed_chump_units)

    # 2. required healers: present-inactive → enable; absent → PAGE -------------
    local h
    for h in $REQUIRED_HEALERS; do
        if unit_exists "$h"; then
            if unit_active "$h"; then continue; fi
            SNAP_HEALERS_DOWN=$((SNAP_HEALERS_DOWN+1))
            log "HEALER inactive: $h"
            if [[ $DRY -eq 1 ]]; then continue; fi
            if sc enable --now "$h" >/dev/null 2>&1 && unit_active "$h"; then
                SNAP_HEALERS_FIXED=$((SNAP_HEALERS_FIXED+1))
                emit "fleet_health_self_healed" unit="$h" action="enable --now"
                log "re-enabled healer: $h"
            else
                page "required healer $h is present but inactive and could not be re-enabled" \
                     "fleet_health_healer_down"
            fi
        else
            SNAP_HEALERS_DOWN=$((SNAP_HEALERS_DOWN+1))
            log "HEALER ABSENT: $h"
            [[ $DRY -eq 1 ]] && continue
            page "required healer $h is ABSENT on $NODE_ID (no unit to enable — needs role-convergence install)" \
                 "fleet_health_healer_down"
        fi
    done

    # 3. watched-if-present healers: re-enable when present-inactive, else skip -
    for h in $WATCHED_HEALERS; do
        unit_exists "$h" || continue
        unit_active "$h" && continue
        SNAP_HEALERS_DOWN=$((SNAP_HEALERS_DOWN+1))
        log "watched healer inactive: $h"
        [[ $DRY -eq 1 ]] && continue
        if sc enable --now "$h" >/dev/null 2>&1 && unit_active "$h"; then
            SNAP_HEALERS_FIXED=$((SNAP_HEALERS_FIXED+1))
            emit "fleet_health_self_healed" unit="$h" action="enable --now"
            log "re-enabled watched healer: $h"
        fi
    done

    # 4. SYSTEM-scope roster: the self-drive + merge + reconcile organs the
    #    --user scan above is structurally blind to (RESILIENT-1055). ----------
    scan_and_heal_system_organs

    # 5. force-push RACE signature — page (never auto-touch). -------------------
    race_signature_check
}

# scan_and_heal_system_organs — watch the SYSTEM-scope roster the --user scan
# cannot see. Present-but-inactive OR present-but-DEAD (active/no-next) → re-arm
# with sudo; absent → skip (install organ owns provisioning); unrecoverable →
# page. This is the watch set that keeps organ-reconcile — and the self-drive
# organs — from decaying unnoticed the way they did on 2026-09-08.
scan_and_heal_system_organs() {
    local u state
    for u in $SYSTEM_ORGANS; do
        sys_unit_exists "$u" || continue
        if sys_unit_active "$u" && ! timer_dead "$u"; then continue; fi   # healthy
        if timer_dead "$u"; then state="dead(active,no-next-fire)"; else state="inactive"; fi
        SNAP_HEALERS_DOWN=$((SNAP_HEALERS_DOWN+1))
        log "SYSTEM organ needs heal: $u [$state]"
        [[ $DRY -eq 1 ]] && continue
        if heal_system_organ "$u"; then
            SNAP_HEALERS_FIXED=$((SNAP_HEALERS_FIXED+1))
            emit "fleet_health_self_healed" unit="$u" action="rearm-system-organ" was="$state"
            log "re-armed SYSTEM organ: $u (was $state)"
        else
            page "SYSTEM organ $u is $state and could not be re-armed (sudo start ${u%.timer}.service failed) on $NODE_ID" \
                 "fleet_health_healer_down"
        fi
    done
}

# race_signature_check — a node runs AT MOST ONE force-push/rebaser organ. Two
# or more active at once is the race that silently clobbered ~2000 PRs. We do
# NOT auto-disable (killing the wrong one can wedge the merge train) — we PAGE
# so a human/board neuters all-but-one deliberately.
race_signature_check() {
    local u active=0 names=""
    for u in $RACE_ORGANS; do
        sys_unit_exists "$u" || continue
        if sys_unit_active "$u"; then active=$((active+1)); names="$names $u"; fi
    done
    SNAP_RACE_ACTIVE=$active
    if [[ $active -ge 2 ]]; then
        log "RACE SIGNATURE: $active rebaser organs active:$names"
        [[ $DRY -eq 1 ]] && return 0
        page "RACE SIGNATURE on $NODE_ID: $active force-push/rebaser organs active at once —$names (the 2000-PR-loss pattern; neuter all but one)" \
             "fleet_health_race_signature"
    fi
}

# ── per-organ detail (RESILIENT-1055) ────────────────────────────────────────
# Print the CURRENTLY-failed chump unit NAMES + each healer's present/active
# state as JSON fragment: "failed_units":[...],"healers":[...]. Queried live at
# heartbeat time (post-heal), so it is ground truth of what is failed RIGHT NOW
# — the detail that turns "33 units failed and nobody noticed" into an API read.
# Portable to bash 3.2 (the Mac board): no arrays, plain string concatenation.
organ_detail_json() {
    local units_json="" u first=1
    while IFS= read -r u; do
        [[ -z "$u" ]] && continue
        [[ $first -eq 1 ]] && first=0 || units_json="$units_json,"
        units_json="$units_json\"$u\""
    done < <(failed_chump_units)

    local healers_json="" h active first_h=1
    for h in $REQUIRED_HEALERS; do
        if unit_exists "$h" && unit_active "$h"; then active=true; else active=false; fi
        [[ $first_h -eq 1 ]] && first_h=0 || healers_json="$healers_json,"
        healers_json="$healers_json{\"unit\":\"$h\",\"required\":true,\"active\":$active}"
    done
    for h in $WATCHED_HEALERS; do
        unit_exists "$h" || continue
        if unit_active "$h"; then active=true; else active=false; fi
        [[ $first_h -eq 1 ]] && first_h=0 || healers_json="$healers_json,"
        healers_json="$healers_json{\"unit\":\"$h\",\"required\":false,\"active\":$active}"
    done
    printf '"failed_units":[%s],"healers":[%s]' "$units_json" "$healers_json"
}

# ── push the heartbeat to the fleet-server ingest sink (RESILIENT-1055) ───────
# Defaults the URL to localhost:7070 (the canonical fleet-server bind) and
# authenticates with the SAME CHUMP_BATPHONE_TOKEN the fleet-server's other
# write routes require, sourcing it from providers.env when a systemd --user
# timer started with no interactive env. Fail-soft: a missing server/token/curl
# never breaks the pass. Non-server nodes point CHUMP_FLEET_SERVER_URL at
# cuphead's tailnet address to feed the cross-node aggregator.
push_heartbeat() {
    local server_url="${CHUMP_FLEET_SERVER_URL:-http://127.0.0.1:7070}"
    [[ -z "$server_url" ]] && return 0
    command -v curl >/dev/null 2>&1 || return 0
    local tok="${CHUMP_BATPHONE_TOKEN:-}"
    if [[ -z "$tok" && -f "$HOME/.chump/providers.env" ]]; then
        tok="$(grep -E '^(export )?CHUMP_BATPHONE_TOKEN=' "$HOME/.chump/providers.env" 2>/dev/null \
            | tail -1 | sed -E 's/^(export )?CHUMP_BATPHONE_TOKEN=//; s/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/')"
    fi
    curl -fsS -m 5 -X POST "${server_url%/}/api/sentinel-heartbeat" \
        -H 'content-type: application/json' \
        ${tok:+-H "Authorization: Bearer $tok"} \
        --data-binary @"$HEARTBEAT_FILE" >/dev/null 2>&1 || true
}

write_heartbeat() {
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    local ep detail; ep="$(now_epoch)"; detail="$(organ_detail_json)"
    printf '{"ts":"%s","epoch":%s,"node":"%s","failed":%s,"healed":%s,"unhealed":%s,"healers_down":%s,"healers_fixed":%s,"race_active":%s,%s}\n' \
        "$(ts_iso)" "$ep" "$NODE_ID" "$SNAP_FAILED" "$SNAP_HEALED" "$SNAP_UNHEALED" "$SNAP_HEALERS_DOWN" "$SNAP_HEALERS_FIXED" "$SNAP_RACE_ACTIVE" "$detail" \
        > "$HEARTBEAT_FILE" 2>/dev/null || true
    echo "$ep" > "$REAPER_HB" 2>/dev/null || true
    push_heartbeat
}

snapshot_json() {
    printf '{"node":"%s","epoch":%s,"failed":%s,"healed":%s,"unhealed":%s,"healers_down":%s,"healers_fixed":%s,"race_active":%s,%s}\n' \
        "$NODE_ID" "$(now_epoch)" "$SNAP_FAILED" "$SNAP_HEALED" "$SNAP_UNHEALED" "$SNAP_HEALERS_DOWN" "$SNAP_HEALERS_FIXED" "$SNAP_RACE_ACTIVE" "$(organ_detail_json)"
}

do_local_pass() {
    scan_and_heal_local
    write_heartbeat
    emit "fleet_health_sentinel_tick" mode=local failed="$SNAP_FAILED" \
        healed="$SNAP_HEALED" unhealed="$SNAP_UNHEALED" healers_down="$SNAP_HEALERS_DOWN" race_active="$SNAP_RACE_ACTIVE"
    log "local pass: failed=$SNAP_FAILED healed=$SNAP_HEALED unhealed=$SNAP_UNHEALED healers_down=$SNAP_HEALERS_DOWN healers_fixed=$SNAP_HEALERS_FIXED race_active=$SNAP_RACE_ACTIVE"
}

# ── FLEET: cross-node grade (the sentinel-is-watched-too closure) ────────────
# Reads node topology, reaches each node, grades its sentinel heartbeat
# freshness + failed-unit count. A stale heartbeat or an unreachable node is a
# dead sentinel → PAGE. Runs wherever fleet reach exists (the board today).
load_nodes() {
    # emits: name<TAB>sshtarget<TAB>sshopts  (sshtarget empty for local host)
    [[ -f "$NODES_FILE" ]] || { log "no nodes file: $NODES_FILE"; return 1; }
    grep -vE '^\s*#|^\s*$' "$NODES_FILE"
}

do_fleet_pass() {
    local stale_secs=$(( CADENCE_MIN * 60 * STALE_MULT ))
    local checked=0 dead=0
    local line name target opts hb_epoch age reachable failed
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        name="$(echo "$line"  | awk -F'\t' '{print $1}')"
        target="$(echo "$line" | awk -F'\t' '{print $2}')"
        opts="$(echo "$line"   | awk -F'\t' '{print $3}')"
        # tilde does not expand out of a variable; do it ourselves so
        # "-i ~/.ssh/key" resolves to a real path when passed to ssh.
        opts="${opts//\~/$HOME}"
        [[ -z "$name" ]] && continue
        checked=$((checked+1))

        if [[ -z "$target" || "$name" == "$NODE_ID" ]]; then
            # local host: read our own heartbeat
            reachable=1
            hb_epoch="$(grep -oE '"epoch":[0-9]+' "$HEARTBEAT_FILE" 2>/dev/null | head -1 | grep -oE '[0-9]+' || echo 0)"
            failed="$(grep -oE '"failed":[0-9]+' "$HEARTBEAT_FILE" 2>/dev/null | head -1 | grep -oE '[0-9]+' || echo 0)"
        else
            # remote: read the node's heartbeat epoch over ssh (bounded)
            # shellcheck disable=SC2086
            hb_epoch="$(timeout 20 ssh -n -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10 $opts "$target" \
                'grep -oE "\"epoch\":[0-9]+" ~/.chump/fleet-health-sentinel.heartbeat 2>/dev/null | head -1 | grep -oE "[0-9]+"' 2>/dev/null)"
            if [[ -z "$hb_epoch" ]]; then
                # distinguish unreachable from present-but-no-heartbeat
                if timeout 15 ssh -n -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10 $opts "$target" true >/dev/null 2>&1; then
                    reachable=1; hb_epoch=0
                else
                    reachable=0
                fi
            else
                reachable=1
            fi
            failed=0
        fi

        if [[ "$reachable" -eq 0 ]]; then
            dead=$((dead+1))
            page "node $name ($target) is UNREACHABLE — its sentinel cannot be confirmed alive" \
                 "fleet_health_sentinel_peer_dead"
            continue
        fi
        if [[ -z "$hb_epoch" || "$hb_epoch" -eq 0 ]]; then
            dead=$((dead+1))
            page "node $name has NO sentinel heartbeat — sentinel not running" \
                 "fleet_health_sentinel_peer_dead"
            continue
        fi
        age=$(( $(now_epoch) - hb_epoch ))
        if [[ "$age" -gt "$stale_secs" ]]; then
            dead=$((dead+1))
            page "node $name sentinel heartbeat is STALE (${age}s > ${stale_secs}s) — sentinel likely dead" \
                 "fleet_health_sentinel_peer_dead"
        else
            log "node $name sentinel alive (heartbeat ${age}s ago, failed=$failed)"
        fi
    done < <(load_nodes)

    emit "fleet_health_sentinel_tick" mode=fleet nodes_checked="$checked" sentinels_dead="$dead"
    log "fleet pass: nodes_checked=$checked sentinels_dead=$dead (stale threshold ${stale_secs}s)"
}

# ── main ─────────────────────────────────────────────────────────────────────
run_once() {
    case "$MODE" in
        local)       do_local_pass ;;
        fleet)       do_fleet_pass ;;
        report-json) scan_and_heal_local >/dev/null 2>&1; snapshot_json ;;
    esac
}

if [[ $LOOP -eq 1 ]]; then
    log "loop mode: mode=$MODE cadence=${CADENCE_MIN}m"
    while true; do
        run_once || true
        sleep $(( CADENCE_MIN * 60 ))
    done
else
    run_once
fi
