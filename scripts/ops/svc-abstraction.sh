#!/usr/bin/env bash
# svc-abstraction.sh — INFRA-3723 (INFRA-3649 slice, MISSION-010).
#
# WHY THIS EXISTS. scripts/ops/process-organ-heal.sh already knows how to
# pgrep-check and nohup-respawn a registered process-organ, but that logic
# is inlined in the heal loop's while-read — nothing else in the fleet can
# reuse "is this organ alive" / "revive this organ" without copy-pasting the
# same pgrep/nohup incantation. This is that reusable abstraction: two
# functions, sourceable from any script, over the SAME on-disk organ shape
# (~/.chump/organs/<name>.sh, matching install-node-housekeeping.sh's
# $STATE/organs/$name.sh layout) so every future svc consumer (INFRA-3649's
# other slices) shares one liveness/revival primitive instead of reinventing
# pgrep patterns per-script.
#
# This is a LIBRARY, not an entrypoint — source it, don't execute it:
#   source scripts/ops/svc-abstraction.sh
#   svc_is_alive almanac-vision-keeper || svc_revive almanac-vision-keeper
#
# Functions:
#   svc_is_alive <organ_name>
#     Checks if the organ is alive via the appropriate supervisor:
#     - For unit organs on systemd-capable nodes: uses systemctl is-active
#     - For process organs: uses pgrep -f "organs/${organ_name}.sh"
#     Returns 0 if alive, 1 if not.
#
#   svc_revive <organ_name>
#     Revives the organ using the appropriate supervisor:
#     - For unit organs on systemd-capable nodes: runs systemctl reset-failed && systemctl restart
#     - For process organs: launches ~/.chump/organs/<organ_name>.sh detached via setsid/nohup
#     Output is appended to ~/.chump/logs/organ_<organ_name>.log.
#     Returns 0 on success, 1 if organ script not found.
#
# Env:
#   CHUMP_SVC_ORGANS_DIR   — override organs dir (default ~/.chump/organs)
#   CHUMP_SVC_LOGS_DIR     — override logs dir (default ~/.chump/logs)
#   CHUMP_SVC_PGREP_BIN    — override `pgrep` binary (test hook)
set -uo pipefail

CHUMP_SVC_ORGANS_DIR="${CHUMP_SVC_ORGANS_DIR:-$HOME/.chump/organs}"
CHUMP_SVC_LOGS_DIR="${CHUMP_SVC_LOGS_DIR:-$HOME/.chump/logs}"
CHUMP_SVC_PGREP_BIN="${CHUMP_SVC_PGREP_BIN:-pgrep}"

# Helper: determine if an organ is a unit organ by checking for a unit file
_is_unit_organ() {
    local organ_name="$1"
    # Check user systemd directory first (common for user-installed organs)
    if [[ -f "$HOME/.config/systemd/user/${organ_name}.service" ]]; then
        return 0
    fi
    # Then check system systemd directory
    if [[ -f "/etc/systemd/system/${organ_name}.service" ]]; then
        return 0
    fi
    return 1
}

# Helper: get systemctl options based on unit file location
_systemctl_opts() {
    local organ_name="$1"
    if [[ -f "/etc/systemd/system/${organ_name}.service" ]]; then
        echo ""  # system unit, no --user
    elif [[ -f "$HOME/.config/systemd/user/${organ_name}.service" ]]; then
        echo "--user"  # user unit
    else
        # Fallback to empty (will likely fail, but caller should have checked _is_unit_organ)
        echo ""
    fi
}

svc_is_alive() {
    local organ_name="$1"
    
    # If node has systemd and organ is a unit organ, use systemd check
    if command -v systemctl >/dev/null 2>&1 && _is_unit_organ "$organ_name"; then
        local opts="$(_systemctl_opts "$organ_name")"
        systemctl $opts is-active "$organ_name" >/dev/null 2>&1
        return $?
    fi
    
    # Fallback to process check for process-organs or when systemd not available
    if ! command -v "$CHUMP_SVC_PGREP_BIN" >/dev/null 2>&1; then
        echo "[svc-abstraction] WARN: $CHUMP_SVC_PGREP_BIN unavailable — cannot check liveness for $organ_name" >&2
        return 1
    fi
    "$CHUMP_SVC_PGREP_BIN" -f "organs/${organ_name}.sh" >/dev/null 2>&1
}

svc_revive() {
    local organ_name="$1"
    local organ_path="$CHUMP_SVC_ORGANS_DIR/${organ_name}.sh"

    if [[ ! -f "$organ_path" ]]; then
        echo "[svc-abstraction] ERROR: organ script not found at $organ_path — cannot revive $organ_name" >&2
        return 1
    fi

    # If node has systemd and organ is a unit organ, use systemd revive
    if command -v systemctl >/dev/null 2>&1 && _is_unit_organ "$organ_name"; then
        local opts="$(_systemctl_opts "$organ_name")"
        # Reset failed state then restart
        if systemctl $opts reset-failed "$organ_name" && systemctl $opts restart "$organ_name"; then
            echo "[svc-abstraction] revived unit organ $organ_name via systemd"
            return 0
        else
            echo "[svc-abstraction] ERROR: failed to revive unit organ $organ_name via systemd" >&2
            return 1
        fi
    fi

    # Fallback to process organ revival
    mkdir -p "$CHUMP_SVC_LOGS_DIR" 2>/dev/null || true
    local log_file="$CHUMP_SVC_LOGS_DIR/organ_${organ_name}.log"

    if command -v setsid >/dev/null 2>&1; then
        setsid bash "$organ_path" >>"$log_file" 2>&1 < /dev/null &
    else
        nohup bash "$organ_path" >>"$log_file" 2>&1 < /dev/null &
        disown 2>/dev/null || true
    fi
    echo "[svc-abstraction] revived $organ_name (pid $!, log $log_file)"
    return 0
}
