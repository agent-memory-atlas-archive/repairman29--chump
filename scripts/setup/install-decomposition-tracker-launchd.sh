#!/usr/bin/env bash
# install-decomposition-tracker-launchd.sh — FLEET-026.
#
# Daily 09:00-local launchd agent that runs scripts/dev/decomposition-hint-tracker.sh
# to update .chump/decomposition-outcomes.jsonl with current hint resolutions.
# 09:00 (rather than the usual 03:00 reaper slot) so the previous day's
# overnight ship pipeline has a chance to surface fix-up PRs first.
#
# Idempotent: safe to re-run.
# Disable: launchctl unload ~/Library/LaunchAgents/dev.chump.decomposition-tracker.plist
# Manually fire: launchctl start dev.chump.decomposition-tracker
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
PLIST_NAME="dev.chump.decomposition-tracker.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"
mkdir -p "$HOME/Library/LaunchAgents"

cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>dev.chump.decomposition-tracker</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>$REPO/scripts/dev/decomposition-hint-tracker.sh --since 14d</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>9</integer>
    <key>Minute</key>
    <integer>0</integer>
  </dict>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-decomposition-tracker.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-decomposition-tracker.err.log</string>
  <key>WorkingDirectory</key>
  <string>$REPO</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>$HOME</string>
    <key>PATH</key>
    <string>/usr/local/bin:${BREW_PREFIX}/bin:$HOME/.cargo/bin:$HOME/.local/bin:/usr/bin:/bin</string>
  </dict>
</dict>
</plist>
EOF

launchctl unload "$DEST" 2>/dev/null || true
launchctl load "$DEST"
echo "Installed and loaded: $DEST"
launchctl list | grep -F "dev.chump.decomposition-tracker" || true
echo
echo "Outcomes file: $REPO/.chump/decomposition-outcomes.jsonl"
echo "Manual fire  : launchctl start dev.chump.decomposition-tracker"
echo "Tail logs    : tail -f /tmp/chump-decomposition-tracker.{out,err}.log"
