#!/usr/bin/env bash
# install-prune-worktrees-launchd.sh — install the daily prune-worktrees LaunchAgent.
# Idempotent: safe to re-run. Installs com.chump.prune-worktrees at 03:00 daily.
#
# After install:
#   launchctl list | grep chump.prune-worktrees
#
# To run on demand (smoke test):
#   launchctl start com.chump.prune-worktrees
#   tail /tmp/chump-prune-worktrees.out.log
#
# To uninstall:
#   launchctl unload ~/Library/LaunchAgents/com.chump.prune-worktrees.plist
#   rm ~/Library/LaunchAgents/com.chump.prune-worktrees.plist
set -euo pipefail
# INFRA-8194 (R5 slice 2): the Homebrew prefix comes from the host resolver
# (chump_brew_prefix in scripts/lib/host-paths.sh, the shell mirror of
# chump_provision::brew_prefix; `chump node host --field brew-prefix`), not a
# baked Apple Silicon path.
# shellcheck source=../lib/host-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/host-paths.sh"
BREW_PREFIX="$(chump_brew_prefix)"

# INFRA-451: resolve to the *main* worktree (not the linked worktree this
# install script may be running from), so the plist path survives worktree reaping.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
REPO="$(resolve_main_worktree "$0")"

PLIST_NAME="com.chump.prune-worktrees.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

# Hour/minute can be overridden for testing:
#   CHUMP_PRUNE_HOUR=4 ./install-prune-worktrees-launchd.sh
HOUR="${CHUMP_PRUNE_HOUR:-3}"
MINUTE="${CHUMP_PRUNE_MINUTE:-0}"

mkdir -p "$HOME/Library/LaunchAgents"

cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.chump.prune-worktrees</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>chump fleet prune-worktrees --apply</string>
  </array>
  <!-- Daily at ${HOUR}:$(printf '%02d' "$MINUTE") local time. -->
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>$HOUR</integer>
    <key>Minute</key>
    <integer>$MINUTE</integer>
  </dict>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-prune-worktrees.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-prune-worktrees.err.log</string>
  <key>WorkingDirectory</key>
  <string>$REPO</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>$HOME</string>
    <key>PATH</key>
    <string>/usr/local/bin:${BREW_PREFIX}/bin:${BREW_PREFIX}/sbin:$HOME/.cargo/bin:/usr/bin:/bin</string>
  </dict>
  <key>ThrottleInterval</key>
  <integer>300</integer>
</dict>
</plist>
EOF

# Reload (unload first; ignore failure if not already loaded).
launchctl unload "$DEST" 2>/dev/null || true
launchctl load "$DEST"

echo "Installed: $DEST"
echo "Schedule : daily ${HOUR}:$(printf '%02d' "$MINUTE") local time"
launchctl list | grep -F "com.chump.prune-worktrees" || true
