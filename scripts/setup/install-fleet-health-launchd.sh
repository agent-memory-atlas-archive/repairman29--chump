#!/usr/bin/env bash
# install-fleet-health-launchd.sh — INFRA-644: install launchd agent that
# runs `chump health` every hour, emitting a kind=fleet_health event to
# .chump-locks/ambient.jsonl so operators always have a fresh composite score.
#
# Idempotent: safe to re-run.
# Disable:    launchctl unload ~/Library/LaunchAgents/dev.chump.fleet-health.plist
# Force fire: launchctl start dev.chump.fleet-health
set -euo pipefail
# INFRA-8194 (R5 slice 2): the Homebrew prefix comes from the host resolver
# (chump_brew_prefix in scripts/lib/host-paths.sh, the shell mirror of
# chump_provision::brew_prefix; `chump node host --field brew-prefix`), not a
# baked Apple Silicon path.
# shellcheck source=../lib/host-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/host-paths.sh"
BREW_PREFIX="$(chump_brew_prefix)"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
REPO="$(resolve_main_worktree "$0")"
PLIST_NAME="dev.chump.fleet-health.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

mkdir -p "$HOME/Library/LaunchAgents"

cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>dev.chump.fleet-health</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>$HOME/.cargo/bin/chump health</string>
  </array>
  <!-- Every 60 minutes. Emits kind=fleet_health to ambient.jsonl so the
       operator dashboard and fleet workers can check composite health
       without running the subcommand manually. -->
  <key>StartInterval</key>
  <integer>3600</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-fleet-health.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-fleet-health.err.log</string>
  <key>WorkingDirectory</key>
  <string>$REPO</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>$HOME</string>
    <key>PATH</key>
    <string>/usr/local/bin:${BREW_PREFIX}/bin:$HOME/.cargo/bin:/usr/bin:/bin</string>
    <key>CHUMP_REPO_ROOT</key>
    <string>$REPO</string>
  </dict>
</dict>
</plist>
EOF

launchctl unload "$DEST" 2>/dev/null || true
launchctl load "$DEST"

echo "Installed and loaded: $DEST"
launchctl list | grep -F "dev.chump.fleet-health" || true
echo
echo "Fires every 60 min (RunAtLoad=true so it runs now too)."
echo "Force fire  : launchctl start dev.chump.fleet-health"
echo "Tail logs   : tail -f /tmp/chump-fleet-health.{out,err}.log"
echo "Check event : tail -5 $REPO/.chump-locks/ambient.jsonl | grep fleet_health"
