#!/usr/bin/env bash
# install-oauth-refresh-launchd.sh — INFRA-2124
#
# Installs the 5-min OAuth token refresh LaunchAgent that keeps
# ~/.chump/oauth-token.json fresh by re-extracting the Claude Code access
# token from macOS Keychain. This is the daemon CLAUDE.md INFRA-622
# promised but that never actually existed.
#
# After install:
#   launchctl list | grep com.chump.oauth-refresh
#
# Manual smoke (force one cycle):
#   launchctl start com.chump.oauth-refresh
#   tail -1 /tmp/chump-oauth-refresh.out.log
#
# Uninstall:
#   launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.chump.oauth-refresh.plist
#   rm ~/Library/LaunchAgents/com.chump.oauth-refresh.plist
#
# Override interval (seconds) for testing:
#   CHUMP_OAUTH_REFRESH_INTERVAL=60 ./install-oauth-refresh-launchd.sh

set -euo pipefail
# INFRA-8194 (R5 slice 2): the Homebrew prefix comes from the host resolver
# (chump_brew_prefix in scripts/lib/host-paths.sh, the shell mirror of
# chump_provision::brew_prefix; `chump node host --field brew-prefix`), not a
# baked Apple Silicon path.
# shellcheck source=../lib/host-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/host-paths.sh"
BREW_PREFIX="$(chump_brew_prefix)"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/resolve-main-worktree.sh
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
REPO="$(resolve_main_worktree "$0")"

PLIST_NAME="com.chump.oauth-refresh.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"
INTERVAL="${CHUMP_OAUTH_REFRESH_INTERVAL:-300}"

PATH_VALUE="/usr/local/bin:${BREW_PREFIX}/bin:${BREW_PREFIX}/sbin:/usr/bin:/bin"

mkdir -p "$HOME/Library/LaunchAgents"

cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.chump.oauth-refresh</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>${REPO}/scripts/coord/oauth-token-refresh.sh refresh-once</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${REPO}</string>
  <key>StartInterval</key>
  <integer>${INTERVAL}</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-oauth-refresh.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-oauth-refresh.err.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>${HOME}</string>
    <key>PATH</key>
    <string>${PATH_VALUE}</string>
  </dict>
  <key>ThrottleInterval</key>
  <integer>60</integer>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)" "$DEST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$DEST"

echo "Installed: $DEST"
echo "  refresh script: ${REPO}/scripts/coord/oauth-token-refresh.sh refresh-once"
echo "  interval: ${INTERVAL}s"
echo "  verify: launchctl list | grep com.chump.oauth-refresh"
echo "  manual smoke: launchctl start com.chump.oauth-refresh && tail -1 /tmp/chump-oauth-refresh.out.log"
echo "  token file: ~/.chump/oauth-token.json"
