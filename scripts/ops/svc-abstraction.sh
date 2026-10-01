#!/usr/bin/env bash
# svc-abstraction.sh — INFRA-3723 + INFRA-7330 (INFRA-3649 / INFRA-7093 slices, MISSION-010).
#
# WHY THIS EXISTS. scripts/ops/process-organ-heal.sh already knows how to
# pgrep-check and nohup-respawn a registered process-organ, and
# scripts/ops/organ-watchdog.sh separately knows how to `systemctl
# reset-failed` + `systemctl restart` a failed systemd unit organ — but both
# incantations were inlined in their own loops, so nothing else in the fleet
# could reuse "is this organ alive" / "revive this organ" without
# copy-pasting one or the other. This is that reusable abstraction: two
# functions, sourceable from any script, that SELECT the mechanism based on
# what the organ actually IS on this node — a registered systemd unit
# (chump-<name>.service, root or --user scope) or a bare backgrounded
# process (~/.chump/organs/<name>.sh, matching install-node-housekeeping.sh's
# $STATE/organs/$name.sh layout) — so every future svc consumer (INFRA-3649's
# other slices) shares one liveness/revival primitive instead of reinventing
# pgrep or systemctl patterns per-script.
#
# This is a LIBRARY, not an entrypoint — source it, don't execute it:
#   source scripts/ops/svc-abstraction.sh
#   svc_is_alive almanac-vision-keeper || svc_revive almanac-vision-keeper
#
# Mechanism selection (per-organ, per-call — not a global node flag): if
# systemd is present on this node AND a chump-<organ_name>.service unit is
# registered with it (root scope, then --user scope), the systemd mechanism
# is used. Otherwise it falls back to the process mechanism. This means the
# same call site works unmodified on a systemd node (Linux w/ launchd-style
# unit organs) and a non-systemd node (macOS, termux, bare process organs).
#
# Functions:
#   svc_is_alive <organ_name>
#     Systemd mechanism: `systemctl is-active chump-<organ_name>.service`
#     (root scope first, then `--user`) — returns 0 iff the unit reports
#     "active".
#     Process mechanism (fallback, no matching unit found): pgrep -f match
#     against "organs/${organ_name}.sh" (relative match, so it hits
#     regardless of which $HOME the organ was installed under).
#     Returns 0 if alive, 1 if not (or if neither mechanism is available).
#
#   svc_revive <organ_name>
#     Systemd mechanism: `systemctl reset-failed chump-<organ_name>.service`
#     (clears a start-limit-hit latch, ignored if the unit wasn't failed)
#     then `systemctl restart chump-<organ_name>.service`. Root scope first,
#     then `--user`. Returns the restart's exit code.
#     Process mechanism (fallback): launches ~/.chump/organs/<organ_name>.sh
#     detached (setsid, falling back to nohup+disown if setsid is
#     unavailable), stdout/stderr appended to
#     ~/.chump/logs/organ_<organ_name>.log. Returns 0 once launched, 1 if the
#     organ script doesn't exist on disk.
#
#     BACKOFF GUARD (INFRA-3649 AC4): shares organ-reconcile.sh's backoff
#     registry (CHUMP_ORGAN_RECONCILE_BACKOFF_DIR) so an organ that dies again
#     immediately after being revived is not respawn-looped every tick. Each
#     call records its own attempt timestamp (svc-<organ_name>.last-revive);
#     if the PRIOR attempt was less than CHUMP_SVC_RAPID_DEATH_S ago, that's a
#     repeated-death signal — this attempt still proceeds (one more try) but a
#     backoff file (svc-<organ_name>.json) is written so the NEXT call within
#     CHUMP_SVC_BACKOFF_COOLDOWN_S is skipped outright (kind=
#     organ_self_heal_backoff_skip, no revive attempted). A call that is
#     SKIPPED due to an active backoff returns 1.
#
#     EMIT (INFRA-3649 AC2): every successful revive emits
#     kind=organ_self_healed with organ/node/mechanism=systemd|process to
#     ambient.jsonl, matching organ-watchdog.sh's existing contract — so any
#     consumer watching that event doesn't care which heal loop produced it.
#
# Env:
#   CHUMP_SVC_ORGANS_DIR   — override organs dir (default ~/.chump/organs)
#   CHUMP_SVC_LOGS_DIR     — override logs dir (default ~/.chump/logs)
#   CHUMP_SVC_PGREP_BIN    — override `pgrep` binary (test hook)
#   CHUMP_SVC_SYSTEMCTL_BIN — override `systemctl` binary (test hook)
#   CHUMP_SVC_FORCE_MECHANISM — "systemd" | "process" | unset (auto-detect,
#                                default). Test hook / explicit override.
#   CHUMP_AMBIENT_LOG      — override ambient.jsonl path (default
#                             <repo>/.chump-locks/ambient.jsonl)
#   CHUMP_SVC_NODE         — override node id reported in organ_self_healed
#                             (default: hostname -s)
#   CHUMP_ORGAN_RECONCILE_BACKOFF_DIR — shared backoff registry dir (default
#                             <repo>/.chump-locks/organ-backoff), same var
#                             organ-reconcile.sh / organ-watchdog.sh read
#   CHUMP_SVC_BACKOFF_COOLDOWN_S — how long a repeated-death backoff lasts
#                             (default 1800s)
#   CHUMP_SVC_RAPID_DEATH_S — a revive attempt sooner than this after the
#                             prior one counts as "died again immediately"
#                             (default 120s)
set -uo pipefail

CHUMP_SVC_ORGANS_DIR="${CHUMP_SVC_ORGANS_DIR:-$HOME/.chump/organs}"
CHUMP_SVC_LOGS_DIR="${CHUMP_SVC_LOGS_DIR:-$HOME/.chump/logs}"
CHUMP_SVC_PGREP_BIN="${CHUMP_SVC_PGREP_BIN:-pgrep}"
CHUMP_SVC_SYSTEMCTL_BIN="${CHUMP_SVC_SYSTEMCTL_BIN:-systemctl}"
CHUMP_SVC_FORCE_MECHANISM="${CHUMP_SVC_FORCE_MECHANISM:-}"

_SVC_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_SVC_REPO_ROOT="${REPO_ROOT:-${CHUMP_REPO_ROOT:-$(cd "$_SVC_SCRIPT_DIR/../.." && pwd)}}"
# NB: resolved into _SVC_-prefixed names, deliberately NOT reusing the
# CHUMP_* env-var names on the right-hand side as the assignment target.
# `VAR=val source svc-abstraction.sh` (the pattern this repo's own CI tests
# and several callers use to scope an override to one sourcing) only exports
# VAR for the duration of that single `source` command — if the resolved
# default were assigned back into the SAME name, the var reverts to unset
# the moment `source` returns, and every later call in the caller's script
# (e.g. node-orchestrator.sh's heal(), invoked ticks after sourcing) would
# hit `set -u`'s unbound-variable error. Fixed values below survive because
# their names differ from the env vars that seed them.
_SVC_AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$_SVC_REPO_ROOT/.chump-locks/ambient.jsonl}"
CHUMP_SVC_NODE="${CHUMP_SVC_NODE:-$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)}"
_SVC_BACKOFF_DIR="${CHUMP_ORGAN_RECONCILE_BACKOFF_DIR:-$_SVC_REPO_ROOT/.chump-locks/organ-backoff}"
CHUMP_SVC_BACKOFF_COOLDOWN_S="${CHUMP_SVC_BACKOFF_COOLDOWN_S:-1800}"
CHUMP_SVC_RAPID_DEATH_S="${CHUMP_SVC_RAPID_DEATH_S:-120}"

_svc_emit() {  # kind, extra-json (no leading/trailing comma)
    local kind="$1" extra="${2:-}"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local line
    if [[ -n "$extra" ]]; then line="{\"ts\":\"$ts\",\"kind\":\"$kind\",$extra}"
    else line="{\"ts\":\"$ts\",\"kind\":\"$kind\"}"; fi
    mkdir -p "$(dirname "$_SVC_AMBIENT_LOG")" 2>/dev/null || true
    printf '%s\n' "$line" >> "$_SVC_AMBIENT_LOG" 2>/dev/null || true
}

_svc_backoff_file() { echo "$_SVC_BACKOFF_DIR/svc-${1}.json"; }
_svc_last_revive_file() { echo "$_SVC_BACKOFF_DIR/svc-${1}.last-revive"; }

# _svc_in_backoff <organ_name> — true (0) while a prior rapid-repeated-death
# backoff for this organ hasn't cooled down yet.
_svc_in_backoff() {
    local organ_name="$1" f; f="$(_svc_backoff_file "$organ_name")"
    [[ -f "$f" ]] || return 1
    local since; since="$(grep -o '"since":[0-9]*' "$f" 2>/dev/null | head -1 | cut -d: -f2)"
    [[ "$since" =~ ^[0-9]+$ ]] || return 1
    local now; now="$(date +%s)"
    (( now - since < CHUMP_SVC_BACKOFF_COOLDOWN_S ))
}

_svc_record_backoff() {  # organ_name, reason
    local organ_name="$1" reason="$2"
    mkdir -p "$_SVC_BACKOFF_DIR" 2>/dev/null || return 0
    printf '{"organ":"%s","since":%d,"reason":"%s"}\n' "$organ_name" "$(date +%s)" "$reason" \
        > "$(_svc_backoff_file "$organ_name")" 2>/dev/null || true
}

# _svc_unit_scope_args <organ_name> — echoes the systemctl scope flag ("" for
# root/system scope, "--user" for user scope) that has chump-<organ_name>.service
# registered, or returns 1 if neither scope knows about the unit.
_svc_unit_scope_args() {
    local organ_name="$1"
    local unit="chump-${organ_name}.service"
    if ! command -v "$CHUMP_SVC_SYSTEMCTL_BIN" >/dev/null 2>&1; then
        return 1
    fi
    if "$CHUMP_SVC_SYSTEMCTL_BIN" list-unit-files "$unit" --no-legend 2>/dev/null | grep -q .; then
        echo ""
        return 0
    fi
    if "$CHUMP_SVC_SYSTEMCTL_BIN" --user list-unit-files "$unit" --no-legend 2>/dev/null | grep -q .; then
        echo "--user"
        return 0
    fi
    return 1
}

# _svc_mechanism <organ_name> — echoes "systemd" or "process" and returns 0.
_svc_mechanism() {
    local organ_name="$1"
    case "$CHUMP_SVC_FORCE_MECHANISM" in
        systemd) echo "systemd"; return 0 ;;
        process) echo "process"; return 0 ;;
    esac
    if _svc_unit_scope_args "$organ_name" >/dev/null 2>&1; then
        echo "systemd"
    else
        echo "process"
    fi
}

svc_is_alive() {
    local organ_name="$1"
    local mechanism; mechanism="$(_svc_mechanism "$organ_name")"

    if [[ "$mechanism" == "systemd" ]]; then
        local scope; scope="$(_svc_unit_scope_args "$organ_name")" || {
            echo "[svc-abstraction] WARN: no chump-${organ_name}.service unit registered — cannot check liveness for $organ_name" >&2
            return 1
        }
        local unit="chump-${organ_name}.service"
        # shellcheck disable=SC2086
        "$CHUMP_SVC_SYSTEMCTL_BIN" $scope is-active "$unit" >/dev/null 2>&1
        return $?
    fi

    if ! command -v "$CHUMP_SVC_PGREP_BIN" >/dev/null 2>&1; then
        echo "[svc-abstraction] WARN: $CHUMP_SVC_PGREP_BIN unavailable — cannot check liveness for $organ_name" >&2
        return 1
    fi
    "$CHUMP_SVC_PGREP_BIN" -f "organs/${organ_name}.sh" >/dev/null 2>&1
}

svc_revive() {
    local organ_name="$1"

    if _svc_in_backoff "$organ_name"; then
        echo "[svc-abstraction] SKIP (backoff): $organ_name revived too recently and died again — cooling down" >&2
        # scanner-anchor: "kind":"organ_self_heal_backoff_skip" (INFRA-3649
        # AC4; fires when a repeated-death backoff is still active for this
        # organ — the revive is deliberately skipped instead of respawn-
        # looping it every tick)
        _svc_emit organ_self_heal_backoff_skip "\"organ\":\"$organ_name\",\"node\":\"$CHUMP_SVC_NODE\""
        return 1
    fi

    # Rapid-repeated-death detection: if the PRIOR revive attempt for this
    # organ was less than CHUMP_SVC_RAPID_DEATH_S ago, the organ died again
    # almost immediately — give it this one more attempt, but arm a backoff
    # so the NEXT call (if it dies again) is skipped rather than retried.
    mkdir -p "$_SVC_BACKOFF_DIR" 2>/dev/null || true
    local last_file; last_file="$(_svc_last_revive_file "$organ_name")"
    local now; now="$(date +%s)"
    local last; last="$(cat "$last_file" 2>/dev/null || echo "")"
    echo "$now" > "$last_file" 2>/dev/null || true
    if [[ "$last" =~ ^[0-9]+$ ]] && (( now - last < CHUMP_SVC_RAPID_DEATH_S )); then
        echo "[svc-abstraction] WARN: $organ_name died again ${CHUMP_SVC_RAPID_DEATH_S}s or less after its last revive — arming backoff" >&2
        _svc_record_backoff "$organ_name" "rapid_repeated_death"
        # scanner-anchor: "kind":"organ_self_heal_backoff" (INFRA-3649 AC4;
        # fires when two revive attempts for the same organ land within
        # CHUMP_SVC_RAPID_DEATH_S of each other — the backoff that prevents
        # the NEXT attempt from respawn-looping)
        _svc_emit organ_self_heal_backoff "\"organ\":\"$organ_name\",\"node\":\"$CHUMP_SVC_NODE\",\"reason\":\"rapid_repeated_death\""
    fi

    local mechanism; mechanism="$(_svc_mechanism "$organ_name")"

    if [[ "$mechanism" == "systemd" ]]; then
        local scope; scope="$(_svc_unit_scope_args "$organ_name")" || {
            echo "[svc-abstraction] ERROR: no chump-${organ_name}.service unit registered — cannot revive $organ_name" >&2
            return 1
        }
        local unit="chump-${organ_name}.service"
        # shellcheck disable=SC2086
        "$CHUMP_SVC_SYSTEMCTL_BIN" $scope reset-failed "$unit" >/dev/null 2>&1 || true
        # shellcheck disable=SC2086
        if "$CHUMP_SVC_SYSTEMCTL_BIN" $scope restart "$unit" 2>&1; then
            echo "[svc-abstraction] revived $organ_name via systemd (unit $unit, scope ${scope:-system})"
            # scanner-anchor: "kind":"organ_self_healed" (INFRA-3649 AC2;
            # shared contract with organ-watchdog.sh — any revive through
            # this abstraction, systemd or process, emits the same kind)
            _svc_emit organ_self_healed "\"organ\":\"$organ_name\",\"node\":\"$CHUMP_SVC_NODE\",\"mechanism\":\"systemd\""
            return 0
        else
            echo "[svc-abstraction] ERROR: systemctl restart failed for $unit" >&2
            return 1
        fi
    fi

    local organ_path="$CHUMP_SVC_ORGANS_DIR/${organ_name}.sh"

    if [[ ! -f "$organ_path" ]]; then
        echo "[svc-abstraction] ERROR: organ script not found at $organ_path — cannot revive $organ_name" >&2
        return 1
    fi

    mkdir -p "$CHUMP_SVC_LOGS_DIR" 2>/dev/null || true
    local log_file="$CHUMP_SVC_LOGS_DIR/organ_${organ_name}.log"

    if command -v setsid >/dev/null 2>&1; then
        setsid bash "$organ_path" >>"$log_file" 2>&1 < /dev/null &
    else
        nohup bash "$organ_path" >>"$log_file" 2>&1 < /dev/null &
        disown 2>/dev/null || true
    fi
    echo "[svc-abstraction] revived $organ_name via process (pid $!, log $log_file)"
    # scanner-anchor: "kind":"organ_self_healed" (INFRA-3649 AC2; process
    # mechanism side of the shared revive-event contract)
    _svc_emit organ_self_healed "\"organ\":\"$organ_name\",\"node\":\"$CHUMP_SVC_NODE\",\"mechanism\":\"process\""
    return 0
}
