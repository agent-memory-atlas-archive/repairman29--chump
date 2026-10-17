#!/usr/bin/env bash
# install-load-aware-deadman.sh — RESILIENT-1611
#
# Install the load-aware node dead-man systemd service and timer.
# This monitors node load/memory pressure and kills runaway processes before sshd wedges.
#
# Idempotent: safe to run multiple times (systemd sees unit as already installed).
# Reversible: `systemctl --user disable --now chump-load-aware-deadman.timer`.
#
# Exit codes:
#   0  success (service installed or already present)
#   1  installation failed (permissions, systemd unavailable, etc.)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

log() { printf '%s [install-load-aware-deadman] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }

# Check if systemd is available
if ! command -v systemctl >/dev/null 2>&1; then
    log "ERROR: systemctl not found — systemd required"
    exit 1
fi

# Ensure systemd user service directory exists
mkdir -p "$HOME/.config/systemd/user"

# Install the script to ~/.local/bin
mkdir -p "$HOME/.local/bin"
cp -f "$REPO_ROOT/scripts/ops/load-aware-deadman.sh" "$HOME/.local/bin/" || {
    log "ERROR: failed to copy load-aware-deadman.sh to ~/.local/bin"
    exit 1
}
chmod +x "$HOME/.local/bin/load-aware-deadman.sh"

# Install the systemd unit files
if [[ ! -d "$REPO_ROOT/scripts/ops/systemd" ]]; then
    log "ERROR: systemd directory not found at $REPO_ROOT/scripts/ops/systemd"
    exit 1
fi

for unit_file in chump-load-aware-deadman.service chump-load-aware-deadman.timer; do
    src="$REPO_ROOT/scripts/ops/systemd/$unit_file"
    dst="$HOME/.config/systemd/user/$unit_file"
    if [[ ! -f "$src" ]]; then
        log "ERROR: unit file not found: $src"
        exit 1
    fi
    cp -f "$src" "$dst" || {
        log "ERROR: failed to copy $unit_file"
        exit 1
    }
done

# Reload systemd and enable the timer
if ! systemctl --user daemon-reload; then
    log "ERROR: systemctl daemon-reload failed"
    exit 1
fi

if ! systemctl --user enable chump-load-aware-deadman.timer; then
    log "ERROR: failed to enable chump-load-aware-deadman.timer"
    exit 1
fi

# Start the timer
if ! systemctl --user start chump-load-aware-deadman.timer; then
    log "WARN: failed to start timer (might already be running)"
else
    log "OK: started chump-load-aware-deadman.timer"
fi

# Print status
log "Installation complete. Status:"
systemctl --user status chump-load-aware-deadman.timer 2>/dev/null || true
systemctl --user status chump-load-aware-deadman.service 2>/dev/null || true

exit 0
