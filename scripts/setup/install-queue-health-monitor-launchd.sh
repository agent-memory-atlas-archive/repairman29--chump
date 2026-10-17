#!/usr/bin/env bash
# install-queue-health-monitor-launchd.sh — INFRA-052 LaunchAgent installer.
#
# Installs the hourly queue health monitor (scripts/ops/queue-health-monitor.sh).
# Idempotent: safe to re-run.
#
# After install:
#   launchctl list | grep dev.chump.queue-health-monitor
#
# To run immediately (verify it works):
#   launchctl start dev.chump.queue-health-monitor
#   tail -f /tmp/chump-queue-health-monitor.out.log
#
# To disable:
#   launchctl unload ~/Library/LaunchAgents/dev.chump.queue-health-monitor.plist

set -euo pipefail
# INFRA-8194 (R5 slice 2): the Homebrew prefix comes from the host resolver
# (chump_brew_prefix in scripts/lib/host-paths.sh, the shell mirror of
# chump_provision::brew_prefix; `chump node host --field brew-prefix`), not a
# baked Apple Silicon path.
# shellcheck source=../lib/host-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/host-paths.sh"
BREW_PREFIX="$(chump_brew_prefix)"

# INFRA-451: resolve to the *main* worktree (not the linked worktree this
# install script may be running from), so the plist absolute path survives
# worktree reaping.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
REPO="$(resolve_main_worktree "$0")"
PLIST_NAME="dev.chump.queue-health-monitor.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

mkdir -p "$HOME/Library/LaunchAgents"

cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>dev.chump.queue-health-monitor</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>$REPO/scripts/ops/queue-health-monitor.sh --quiet</string>
  </array>
  <!-- Hourly. Detects: stuck PRs (>45m BLOCKED/DIRTY), silent agents
       (>90m no commits), fat worktrees (>5GB target/). Writes to
       .chump/health.jsonl and .chump/alerts.log; emits ALERT events to
       .chump-locks/ambient.jsonl so sibling agents see findings in their
       FLEET-019 SessionStart digest. -->
  <key>StartInterval</key>
  <integer>3600</integer>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-queue-health-monitor.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-queue-health-monitor.err.log</string>
  <key>WorkingDirectory</key>
  <string>$REPO</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>$HOME</string>
    <key>PATH</key>
    <string>/usr/local/bin:${BREW_PREFIX}/bin:$HOME/.cargo/bin:/usr/bin:/bin</string>
  </dict>
  <key>ThrottleInterval</key>
  <integer>60</integer>
</dict>
</plist>
EOF

# Reload (unload first; ignore failure if not loaded).
launchctl unload "$DEST" 2>/dev/null || true
launchctl load "$DEST"

echo "Installed and loaded: $DEST"
launchctl list | grep -F "dev.chump.queue-health-monitor" || true
echo
echo "First run is in 1 hour. To run immediately:"
echo "  launchctl start dev.chump.queue-health-monitor"
echo "  tail -f /tmp/chump-queue-health-monitor.out.log"
