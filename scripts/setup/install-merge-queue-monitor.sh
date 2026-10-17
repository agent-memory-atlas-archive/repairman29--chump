#!/usr/bin/env bash
# install-merge-queue-monitor.sh — CREDIBLE-068
#
# Idempotently install the launchd agent that runs the merge-queue health
# monitor (scripts/coord/monitor-merge-queue.sh). The daemon polls GH every
# 10s by default and emits kind=merge_queue_health to ambient.jsonl so the
# fleet's backpressure logic + dashboards can see queue depth in real time.
#
# Unlike the claude-reaper plist (StartInterval=300), this daemon is
# long-running — KeepAlive=true. launchd will restart it if it exits.
# The script itself sleeps between ticks; launchd just keeps the process up.
#
# Usage : scripts/setup/install-merge-queue-monitor.sh
# Verify: launchctl print "gui/$(id -u)/com.chump.merge-queue-monitor"
# Logs  : /tmp/chump-merge-queue-monitor.{out,err}.log
# Unload: launchctl bootout "gui/$(id -u)/com.chump.merge-queue-monitor"
# Bypass: CHUMP_MERGE_QUEUE_MONITOR=0 in launchd EnvironmentVariables (set below)
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

# RESILIENT-168: refuse to bake a temp-clone path into a persistent plist.
# This exact installer once ran from /private/tmp/chump-install/ — the plist
# survived, the clone didn't, and the monitor sat at exit 78 for weeks.
case "$REPO_ROOT" in
    /tmp/*|/private/tmp/*|/var/folders/*)
        if [[ "${CHUMP_INSTALL_ALLOW_TMP:-0}" != "1" ]]; then
            echo "ERROR: refusing to install a persistent daemon from temp path $REPO_ROOT" >&2
            echo "  (run from the canonical checkout, or CHUMP_INSTALL_ALLOW_TMP=1 to override)" >&2
            exit 1
        fi
        ;;
esac

MONITOR_SCRIPT="$REPO_ROOT/scripts/coord/monitor-merge-queue.sh"
PLIST_LABEL="com.chump.merge-queue-monitor"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"

if [[ ! -x "$MONITOR_SCRIPT" ]]; then
    echo "ERROR: monitor script not found or not executable: $MONITOR_SCRIPT" >&2
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
        <string>${MONITOR_SCRIPT}</string>
    </array>

    <key>WorkingDirectory</key>
    <string>${REPO_ROOT}</string>

    <!-- Long-running daemon: the script's own sleep loop paces ticks. -->
    <key>KeepAlive</key>
    <true/>

    <!-- Backoff between restarts so a broken daemon doesn't restart-storm. -->
    <key>ThrottleInterval</key>
    <integer>30</integer>

    <!-- Start at load so the fleet has live queue-health from boot. -->
    <key>RunAtLoad</key>
    <true/>

    <key>StandardOutPath</key>
    <string>/tmp/chump-merge-queue-monitor.out.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/chump-merge-queue-monitor.err.log</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:${BREW_PREFIX}/bin:${BREW_PREFIX}/sbin</string>
    </dict>
</dict>
</plist>
PLIST

# Reload idempotently. The newer launchctl prefers bootstrap/bootout over
# load/unload, but the old verbs still work on every macOS version we ship
# on. Try bootout first (newer) then fall back to unload.
launchctl bootout "gui/$(id -u)/${PLIST_LABEL}" 2>/dev/null || \
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
# RESILIENT-168: clear any disabled-override first — a disabled service makes
# bootstrap fail rc=5 forever, silently, across every reinstall.
launchctl enable "gui/$(id -u)/${PLIST_LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || \
    launchctl load "$PLIST_PATH"

echo "[install-merge-queue-monitor] installed: $PLIST_PATH"
echo "[install-merge-queue-monitor] verify  : launchctl print \"gui/\$(id -u)/${PLIST_LABEL}\""
echo "[install-merge-queue-monitor] kick    : launchctl kickstart \"gui/\$(id -u)/${PLIST_LABEL}\""
echo "[install-merge-queue-monitor] logs    : /tmp/chump-merge-queue-monitor.{out,err}.log"
echo "[install-merge-queue-monitor] unload  : launchctl bootout \"gui/\$(id -u)/${PLIST_LABEL}\""
