#!/usr/bin/env bash
# install-active-target-reaper-launchd.sh — install LaunchAgent that purges
# stale `target/` directories in linked worktrees and /tmp/chump-*. Idempotent.
#
# Runs every 4h (StartInterval 14400) with --age-days 1 so worktrees that
# go quiet for 24h get their cargo cache reclaimed before disk fills.
#
# Verify:
#   launchctl list | grep dev.chump.active-target-reaper
# Logs:
#   /tmp/chump-active-target-reaper.out.log
#   /tmp/chump-active-target-reaper.err.log
# Disable:
#   launchctl unload ~/Library/LaunchAgents/dev.chump.active-target-reaper.plist
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
PLIST_NAME="dev.chump.active-target-reaper.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

mkdir -p "$HOME/Library/LaunchAgents"

cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>dev.chump.active-target-reaper</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>$REPO/scripts/ops/active-target-reaper.sh --execute --age-days 1</string>
  </array>
  <!-- Every 4h. Purges target/ in worktrees (including /tmp/chump-*) idle >1d. -->
  <key>StartInterval</key>
  <integer>14400</integer>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-active-target-reaper.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-active-target-reaper.err.log</string>
  <key>WorkingDirectory</key>
  <string>$REPO</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>$HOME</string>
    <key>PATH</key>
    <string>/usr/local/bin:${BREW_PREFIX}/bin:$HOME/.cargo/bin:/usr/bin:/bin</string>
  </dict>
</dict>
</plist>
EOF

launchctl unload "$DEST" 2>/dev/null || true
launchctl load "$DEST"

echo "Installed and loaded: $DEST"
launchctl list | grep -F "dev.chump.active-target-reaper" || true
