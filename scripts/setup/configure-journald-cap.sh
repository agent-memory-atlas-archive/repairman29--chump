#!/usr/bin/env bash
# configure-journald-cap.sh — INFRA-7890: cap journald disk usage.
#
# systemd-journald defaults to using up to 10% of the filesystem it lives on
# with no hard ceiling wired in by this fleet — observed at 4.0G uncapped
# (`journalctl --disk-usage`) with no drop-in enforcing a cap, so it grows
# unbounded alongside the same disk that cargo-target-reaper is defending.
# This writes a small systemd drop-in that caps SystemMaxUse and reloads
# journald so the cap takes effect immediately.
#
# Idempotent: re-running with the same CHUMP_JOURNALD_MAX_USE is a no-op
# (file content unchanged -> no restart triggered).
#
# Env:
#   CHUMP_JOURNALD_MAX_USE     cap value, systemd size syntax (default 1G)
#   CHUMP_JOURNALD_CONF_DIR    override drop-in directory (default
#                              /etc/systemd/journald.conf.d — override for
#                              tests so this never touches the real system)
#   CHUMP_JOURNALD_DRY_RUN     1 = print what would change, don't write/restart
#
# Rust-First-Bypass: one-shot host-config glue over systemd files; no state
# mutation of chump's own canonical stores, <200 LOC, no regression-test
# maintenance burden beyond the smoke test it ships with.

set -euo pipefail

MAX_USE="${CHUMP_JOURNALD_MAX_USE:-1G}"
CONF_DIR="${CHUMP_JOURNALD_CONF_DIR:-/etc/systemd/journald.conf.d}"
DRY_RUN="${CHUMP_JOURNALD_DRY_RUN:-0}"
CONF_FILE="${CONF_DIR}/chump-cap.conf"

log()  { echo "[configure-journald-cap] $*"; }
warn() { echo "[configure-journald-cap] WARN: $*" >&2; }

desired_content="[Journal]
SystemMaxUse=${MAX_USE}
"

if [[ -f "$CONF_FILE" ]] && [[ "$(cat "$CONF_FILE")" == "$desired_content" ]]; then
    log "already capped at SystemMaxUse=${MAX_USE} (${CONF_FILE} unchanged) — no-op"
    exit 0
fi

if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY-RUN: would write ${CONF_FILE} with SystemMaxUse=${MAX_USE}"
    printf '%s' "$desired_content"
    exit 0
fi

mkdir -p "$CONF_DIR"
printf '%s' "$desired_content" > "$CONF_FILE"
log "wrote ${CONF_FILE} (SystemMaxUse=${MAX_USE})"

if command -v systemctl >/dev/null 2>&1; then
    if systemctl restart systemd-journald 2>/dev/null; then
        log "restarted systemd-journald — cap active"
    else
        warn "could not restart systemd-journald (needs root) — cap will take effect on next boot/restart"
    fi
else
    warn "systemctl not found — wrote config but could not reload journald"
fi
