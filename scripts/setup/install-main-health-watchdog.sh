#!/usr/bin/env bash
# install-main-health-watchdog.sh — INFRA-1656
# Idempotently install the launchd agent that detects red main and files
# a P0 INFRA-NEW-MAIN-RED-<date> gap. Runs once daily at 02:00 local.
#
# Usage:  scripts/setup/install-main-health-watchdog.sh
# Unload: launchctl unload ~/Library/LaunchAgents/com.chump.main-health-watchdog.plist
set -euo pipefail
# INFRA-8194 (R5 slice 2): the Homebrew prefix comes from the host resolver
# (chump_brew_prefix in scripts/lib/host-paths.sh, the shell mirror of
# chump_provision::brew_prefix; `chump node host --field brew-prefix`), not a
# baked Apple Silicon path.
# shellcheck source=../lib/host-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/host-paths.sh"
BREW_PREFIX="$(chump_brew_prefix)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WATCHDOG_SCRIPT="$REPO_ROOT/scripts/ops/main-health-watchdog.sh"
PLIST_LABEL="com.chump.main-health-watchdog"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"

if [[ ! -x "$WATCHDOG_SCRIPT" ]]; then
    echo "ERROR: watchdog script not found or not executable: $WATCHDOG_SCRIPT" >&2
    exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents"

cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_LABEL}</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>-lc</string>
        <string>${WATCHDOG_SCRIPT}</string>
    </array>

    <key>WorkingDirectory</key>
    <string>${REPO_ROOT}</string>

    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>2</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>

    <key>ThrottleInterval</key>
    <integer>60</integer>

    <key>RunAtLoad</key>
    <false/>

    <key>StandardOutPath</key>
    <string>/tmp/chump-main-health-watchdog.out.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/chump-main-health-watchdog.err.log</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:${BREW_PREFIX}/bin:${BREW_PREFIX}/sbin</string>
    </dict>
</dict>
</plist>
PLIST

# Reload (idempotent: unload first, ignore failure if not loaded).
launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"

echo "[install-main-health-watchdog] installed: $PLIST_PATH"
echo "[install-main-health-watchdog] verify : launchctl list | grep $PLIST_LABEL"
echo "[install-main-health-watchdog] test   : launchctl start $PLIST_LABEL"
echo "[install-main-health-watchdog] logs   : /tmp/chump-main-health-watchdog.{out,err}.log"
echo "[install-main-health-watchdog] unload : launchctl unload $PLIST_PATH"
