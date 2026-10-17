#!/usr/bin/env bash
# install-api-cost-digest-launchd.sh — INFRA-1077
# Installs the daily INFRA-999 API cost leaderboard digest LaunchAgent.
# Idempotent.
#
# After install:
#   launchctl list | grep chump.api-cost-digest
#
# Manual run:
#   launchctl start com.chump.api-cost-digest
#   tail /tmp/chump-api-cost-digest.out.log
#
# Override schedule for testing:
#   CHUMP_APICOST_HOUR=10 CHUMP_APICOST_MINUTE=30 ./install-api-cost-digest-launchd.sh

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

PLIST_NAME="com.chump.api-cost-digest.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"
HOUR="${CHUMP_APICOST_HOUR:-9}"
MINUTE="${CHUMP_APICOST_MINUTE:-0}"
PATH_VALUE="/usr/local/bin:${BREW_PREFIX}/bin:${BREW_PREFIX}/sbin:${HOME}/.cargo/bin:/usr/bin:/bin"

mkdir -p "$HOME/Library/LaunchAgents"
cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.chump.api-cost-digest</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>${REPO}/scripts/dev/api-cost-leaderboard.sh --window 24h --emit-ambient</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${REPO}</string>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>${HOUR}</integer>
    <key>Minute</key>
    <integer>${MINUTE}</integer>
  </dict>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-api-cost-digest.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-api-cost-digest.err.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>${HOME}</string>
    <key>PATH</key>
    <string>${PATH_VALUE}</string>
  </dict>
  <key>ThrottleInterval</key>
  <integer>300</integer>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)" "$DEST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$DEST"

echo "Installed: $DEST"
echo "  schedule: daily at ${HOUR}:$(printf '%02d' "$MINUTE")"
echo "  verify: launchctl list | grep chump.api-cost-digest"
echo "  on-demand: launchctl start com.chump.api-cost-digest"
