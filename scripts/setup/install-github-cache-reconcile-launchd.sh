#!/usr/bin/env bash
# install-github-cache-reconcile-launchd.sh — INFRA-1105
# Installs the every-5-min github-cache-reconcile LaunchAgent. Idempotent.
#
# Prerequisites: INFRA-1081 receiver + cache infrastructure (in main as of #1777).
#
# After install:
#   launchctl list | grep chump.github-cache-reconcile
#
# Manual run:
#   launchctl start com.chump.github-cache-reconcile
#   tail /tmp/chump-cache-reconcile.out.log
#
# Override interval for testing:
#   CHUMP_RECONCILE_INTERVAL=60 ./install-github-cache-reconcile-launchd.sh

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

PLIST_NAME="com.chump.github-cache-reconcile.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"
INTERVAL="${CHUMP_RECONCILE_INTERVAL:-300}"
PATH_VALUE="/usr/local/bin:${BREW_PREFIX}/bin:${BREW_PREFIX}/sbin:${HOME}/.cargo/bin:/usr/bin:/bin"

mkdir -p "$HOME/Library/LaunchAgents"

cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.chump.github-cache-reconcile</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>${REPO}/scripts/ops/github-cache-reconcile.sh</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${REPO}</string>
  <key>StartInterval</key>
  <integer>${INTERVAL}</integer>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-cache-reconcile.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-cache-reconcile.err.log</string>
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
echo "  interval: ${INTERVAL}s"
echo "  log:      /tmp/chump-cache-reconcile.out.log"
echo "  verify:   launchctl list | grep chump.github-cache-reconcile"
echo "  on-demand:launchctl start com.chump.github-cache-reconcile"
