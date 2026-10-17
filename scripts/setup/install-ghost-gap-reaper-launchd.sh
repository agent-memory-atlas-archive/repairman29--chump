#!/usr/bin/env bash
# install-ghost-gap-reaper-launchd.sh — RESILIENT-066
#
# Idempotently installs the launchd agent that runs ghost-gap-reaper.sh
# every 15 minutes (StartInterval: 900).
#
# The reaper rolls back gaps that are status=done but whose closed_pr was
# closed without merging (bounced PRs). Without a launchd cadence the reaper
# only ran on demand; missed runs let ghost-gap counts accumulate until
# SLO-L2-SLO-5 breaches and writes .chump/fleet-paused.
#
# This daemon is intentionally pause-immune: the ghost-gap-reaper is part of
# the RECOVERY LAYER that lifts the pause, not a fleet worker. It must keep
# running during a pause so it can clear the ghost gaps that CAUSED the pause.
# It does not call `chump claim`, only `chump gap set --status open` (which is
# always allowed regardless of fleet-paused state since INFRA-2424).
#
# Usage:
#   bash scripts/setup/install-ghost-gap-reaper-launchd.sh        # install + load
#   bash scripts/setup/install-ghost-gap-reaper-launchd.sh --check    # exit 0 if loaded
#   bash scripts/setup/install-ghost-gap-reaper-launchd.sh --uninstall # remove + unload
#
# Env knobs (read at install time):
#   CHUMP_GHOST_REAPER_INTERVAL_S  — cadence in seconds (default 900 = 15 min)

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

LABEL="com.chump.ghost-gap-reaper"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
DAEMON_SCRIPT="$ROOT/scripts/coord/ghost-gap-reaper.sh"
LOG_OUT="$HOME/.chump/logs/ghost-gap-reaper.out"
LOG_ERR="$HOME/.chump/logs/ghost-gap-reaper.err"
INTERVAL_S="${CHUMP_GHOST_REAPER_INTERVAL_S:-900}"

log() { printf '[install-ghost-gap-reaper] %s\n' "$*"; }

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
    </array>
    <key>WorkingDirectory</key>
    <string>${ROOT}</string>
    <key>StartInterval</key>
    <integer>${INTERVAL_S}</integer>
    <!-- RunAtLoad=true: exercises the daemon immediately on install so
         "did the plist land correctly?" is answered at install time, not
         15 minutes later (INFRA-351 lesson). -->
    <key>RunAtLoad</key>
    <true/>
    <!-- KeepAlive=false: ghost-gap-reaper.sh is a single-shot script.
         launchd re-launches it every StartInterval seconds. -->
    <key>KeepAlive</key>
    <false/>
    <key>StandardOutPath</key>
    <string>${LOG_OUT}</string>
    <key>StandardErrorPath</key>
    <string>${LOG_ERR}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <!-- gh CLI needs HOME for auth token; PATH for git + python3 (INFRA-802). -->
        <key>HOME</key>
        <string>${HOME}</string>
        <key>PATH</key>
        <string>${BREW_PREFIX}/bin:/usr/local/bin:/usr/bin:/bin</string>
        <!-- CHUMP_AMBIENT_PATH: explicit absolute path to ambient.jsonl (META-248). -->
        <key>CHUMP_AMBIENT_PATH</key>
        <string>${ROOT}/.chump-locks/ambient.jsonl</string>
        <!-- RESILIENT-066: ghost-gap-reaper is a RECOVERY daemon.
             It must run during a fleet pause (it's what clears the ghost gaps
             that caused the pause). `chump gap set --status open` is always
             allowed since INFRA-2424 removed the reserve/set guard. -->
        <key>CHUMP_GHOST_REAPER</key>
        <string>1</string>
    </dict>
</dict>
</plist>
PLISTEOF

log "wrote $PLIST"

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
log "  Cadence:  every $((INTERVAL_S / 60)) min (RunAtLoad=true, KeepAlive=false)"
log "  WorkDir:  ${ROOT}"
log "  Stdout:   ${LOG_OUT}"
log "  Stderr:   ${LOG_ERR}"
log "  Verify:   launchctl list | grep ${LABEL}"
log "  Disable:  launchctl bootout gui/${UID_VAL}/${LABEL}"
