#!/usr/bin/env bash
# install-claude-reaper.sh — INFRA-1662
# Idempotently install the launchd agent that reaps orphan claude subprocesses
# leaked by long-running autonomous loops. Runs every 2 minutes (INFRA-1930:
# tightened from 5 min so PTY-pressure mode catches rising pressure before
# saturation instead of reacting after it).
#
# Usage:  scripts/setup/install-claude-reaper.sh
# Unload: launchctl unload ~/Library/LaunchAgents/com.chump.claude-reaper.plist
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
REAPER_SCRIPT="$REPO_ROOT/scripts/ops/reap-orphan-claude-procs.sh"
PLIST_LABEL="com.chump.claude-reaper"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"

if [[ ! -x "$REAPER_SCRIPT" ]]; then
    echo "ERROR: reaper script not found or not executable: $REAPER_SCRIPT" >&2
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
        <string>${REAPER_SCRIPT}</string>
    </array>

    <key>WorkingDirectory</key>
    <string>${REPO_ROOT}</string>

    <key>StartInterval</key>
    <integer>120</integer>

    <key>ThrottleInterval</key>
    <integer>60</integer>

    <key>RunAtLoad</key>
    <false/>

    <key>StandardOutPath</key>
    <string>/tmp/chump-claude-reaper.out.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/chump-claude-reaper.err.log</string>

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

echo "[install-claude-reaper] installed: $PLIST_PATH"
echo "[install-claude-reaper] verify : launchctl list | grep $PLIST_LABEL"
echo "[install-claude-reaper] test   : launchctl start $PLIST_LABEL"
echo "[install-claude-reaper] logs   : /tmp/chump-claude-reaper.{out,err}.log"
echo "[install-claude-reaper] unload : launchctl unload $PLIST_PATH"
