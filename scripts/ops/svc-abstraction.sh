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
# Env:
#   CHUMP_SVC_ORGANS_DIR   — override organs dir (default ~/.chump/organs)
#   CHUMP_SVC_LOGS_DIR     — override logs dir (default ~/.chump/logs)
#   CHUMP_SVC_PGREP_BIN    — override `pgrep` binary (test hook)
#   CHUMP_SVC_SYSTEMCTL_BIN — override `systemctl` binary (test hook)
#   CHUMP_SVC_FORCE_MECHANISM — "systemd" | "process" | unset (auto-detect,
#                                default). Test hook / explicit override.
set -uo pipefail

CHUMP_SVC_ORGANS_DIR="${CHUMP_SVC_ORGANS_DIR:-$HOME/.chump/organs}"
CHUMP_SVC_LOGS_DIR="${CHUMP_SVC_LOGS_DIR:-$HOME/.chump/logs}"
CHUMP_SVC_PGREP_BIN="${CHUMP_SVC_PGREP_BIN:-pgrep}"
CHUMP_SVC_SYSTEMCTL_BIN="${CHUMP_SVC_SYSTEMCTL_BIN:-systemctl}"
CHUMP_SVC_FORCE_MECHANISM="${CHUMP_SVC_FORCE_MECHANISM:-}"

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
    return 0
}
