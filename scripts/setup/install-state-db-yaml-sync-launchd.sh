#!/usr/bin/env bash
# install-state-db-yaml-sync-launchd.sh — INFRA-1495
#
# Idempotently installs the launchd agent that runs state-db-yaml-sync.sh
# hourly (StartInterval: 3600). Backfills docs/gaps/<ID>.yaml mirrors for
# OPEN gaps in state.db that have none (CREDIBLE-012 gap_drift_orphan class).
#
# Defaults to --dry-run (report-only, no writes/commits) per INFRA-1495 AC5 —
# bump CHUMP_STATE_DB_YAML_SYNC_MODE=--apply once the sweep has run clean in
# --dry-run for a while and the operator is comfortable with it writing +
# committing unattended.
#
# Usage:
#   bash scripts/setup/install-state-db-yaml-sync-launchd.sh        # install + load
#   bash scripts/setup/install-state-db-yaml-sync-launchd.sh --check    # exit 0 if loaded
#   bash scripts/setup/install-state-db-yaml-sync-launchd.sh --uninstall # remove + unload
#
# Env knobs (read at install time):
#   CHUMP_STATE_DB_YAML_SYNC_INTERVAL_S  — cadence in seconds (default 3600 = 1h)
#   CHUMP_STATE_DB_YAML_SYNC_MODE        — --dry-run (default) or --apply

set -euo pipefail
# INFRA-8194 (R5 slice 2): the Homebrew prefix comes from the host resolver
# (chump_brew_prefix in scripts/lib/host-paths.sh, the shell mirror of
# chump_provision::brew_prefix; `chump node host --field brew-prefix`), not a
# baked Apple Silicon path.
# shellcheck source=../lib/host-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/host-paths.sh"
BREW_PREFIX="$(chump_brew_prefix)"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Resolve main worktree so the plist path survives worktree reaping (INFRA-451).
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
ROOT="$(resolve_main_worktree "$0")"

LABEL="com.chump.state-db-yaml-sync"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
DAEMON_SCRIPT="$ROOT/scripts/coord/state-db-yaml-sync.sh"
LOG_OUT="$HOME/.chump/logs/state-db-yaml-sync.out"
LOG_ERR="$HOME/.chump/logs/state-db-yaml-sync.err"
INTERVAL_S="${CHUMP_STATE_DB_YAML_SYNC_INTERVAL_S:-3600}"
MODE="${CHUMP_STATE_DB_YAML_SYNC_MODE:---dry-run}"

log() { printf '[install-state-db-yaml-sync] %s\n' "$*"; }

is_loaded() {
    launchctl list 2>/dev/null | grep -qF "$LABEL"
}

# ── --check ────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--check" ]]; then
    if is_loaded; then
        log "LOADED — $LABEL is running"
        exit 0
    else
        log "NOT LOADED — $LABEL is not running"
        exit 1
    fi
fi

# ── --uninstall ────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--uninstall" ]]; then
    UID_VAL="$(id -u)"
    if is_loaded; then
        launchctl bootout "gui/${UID_VAL}/${LABEL}" 2>/dev/null || \
            launchctl unload "$PLIST" 2>/dev/null || true
        log "unloaded $LABEL"
    fi
    rm -f "$PLIST"
    log "removed $PLIST"
    exit 0
fi

# ── install ────────────────────────────────────────────────────────────────
if [[ ! -f "$DAEMON_SCRIPT" ]]; then
    log "ERROR: $DAEMON_SCRIPT not found" >&2
    exit 2
fi
[[ -x "$DAEMON_SCRIPT" ]] || chmod +x "$DAEMON_SCRIPT"

mkdir -p "$HOME/Library/LaunchAgents"
mkdir -p "$HOME/.chump/logs"

UID_VAL="$(id -u)"

cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${DAEMON_SCRIPT}</string>
        <string>${MODE}</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${ROOT}</string>
    <key>StartInterval</key>
    <integer>${INTERVAL_S}</integer>
    <!-- RunAtLoad=true: exercises the daemon immediately on install so
         "did the plist land correctly?" is answered at install time, not
         an hour later (INFRA-351 lesson). -->
    <key>RunAtLoad</key>
    <true/>
    <!-- KeepAlive=false: state-db-yaml-sync.sh is a single-shot script.
         launchd re-launches it every StartInterval seconds. -->
    <key>KeepAlive</key>
    <false/>
    <key>StandardOutPath</key>
    <string>${LOG_OUT}</string>
    <key>StandardErrorPath</key>
    <string>${LOG_ERR}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>${HOME}</string>
        <key>PATH</key>
        <string>${BREW_PREFIX}/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
</dict>
</plist>
PLISTEOF

log "wrote $PLIST (mode=${MODE})"

# Unload first (idempotent — fails silently if not loaded).
if launchctl bootout "gui/${UID_VAL}/${LABEL}" 2>/dev/null; then
    log "unloaded existing $LABEL via bootout"
else
    launchctl unload "$PLIST" 2>/dev/null || true
fi

if launchctl bootstrap "gui/${UID_VAL}" "$PLIST" 2>/dev/null; then
    log "loaded $LABEL via bootstrap"
else
    launchctl load "$PLIST"
fi

log ""
log "Loaded launchd job ${LABEL}"
log "  Mode:     ${MODE} (bump to --apply via CHUMP_STATE_DB_YAML_SYNC_MODE once stable)"
log "  Cadence:  every $((INTERVAL_S / 60)) min (RunAtLoad=true, KeepAlive=false)"
log "  WorkDir:  ${ROOT}"
log "  Stdout:   ${LOG_OUT}"
log "  Stderr:   ${LOG_ERR}"
log "  Verify:   launchctl list | grep ${LABEL}"
log "  Disable:  launchctl bootout gui/${UID_VAL}/${LABEL}"
