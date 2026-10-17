#!/usr/bin/env bash
# install-inbox-prune-launchd.sh — install the hourly inbox-prune LaunchAgent.
# Idempotent: safe to re-run. Installs com.chump.inbox-prune at :05 past each hour.
#
# After install:
#   launchctl list | grep chump.inbox-prune
#
# To run on demand (smoke test):
#   launchctl start com.chump.inbox-prune
#   tail /tmp/chump-inbox-prune.out.log
#
# To uninstall:
#   launchctl unload ~/Library/LaunchAgents/com.chump.inbox-prune.plist
#   rm ~/Library/LaunchAgents/com.chump.inbox-prune.plist
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

PLIST_NAME="com.chump.inbox-prune.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

# Minute can be overridden for testing:
#   CHUMP_INBOX_PRUNE_MINUTE=30 ./install-inbox-prune-launchd.sh
MINUTE="${CHUMP_INBOX_PRUNE_MINUTE:-5}"

mkdir -p "$HOME/Library/LaunchAgents"

cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.chump.inbox-prune</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>$REPO/scripts/coord/chump-inbox-prune.sh prune</string>
  </array>
  <!-- Hourly at :$(printf '%02d' "$MINUTE") past each hour. -->
  <key>StartCalendarInterval</key>
  <array>
    <dict>
      <key>Minute</key>
      <integer>$MINUTE</integer>
    </dict>
  </array>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-inbox-prune.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-inbox-prune.err.log</string>
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
echo "Schedule : hourly at :$(printf '%02d' "$MINUTE") past each hour"
