#!/usr/bin/env bash
# install-binary-refresh-launchd.sh — INFRA-1065
# Installs the hourly chump-binary refresh LaunchAgent. Idempotent.
#
# After install:
#   launchctl list | grep chump.binary-refresh
#
# Manual run (smoke test):
#   launchctl start com.chump.binary-refresh
#   tail /tmp/chump-binary-refresh.out.log
#
# Uninstall:
#   launchctl unload ~/Library/LaunchAgents/com.chump.binary-refresh.plist
#   rm ~/Library/LaunchAgents/com.chump.binary-refresh.plist
#
# Override interval (seconds) for testing:
#   CHUMP_BINARY_REFRESH_INTERVAL=300 ./install-binary-refresh-launchd.sh

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

PLIST_NAME="com.chump.binary-refresh.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"
INTERVAL="${CHUMP_BINARY_REFRESH_INTERVAL:-3600}"

# PATH must include cargo + brew binaries for `cargo install` to find rustc.
CARGO_BIN="$HOME/.cargo/bin"
PATH_VALUE="/usr/local/bin:${BREW_PREFIX}/bin:${BREW_PREFIX}/sbin:${CARGO_BIN}:/usr/bin:/bin"

mkdir -p "$HOME/Library/LaunchAgents"

cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.chump.binary-refresh</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>${REPO}/scripts/ops/refresh-chump-binary.sh</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${REPO}</string>
  <key>StartInterval</key>
  <integer>${INTERVAL}</integer>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-binary-refresh.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-binary-refresh.err.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>${HOME}</string>
    <key>PATH</key>
    <string>${PATH_VALUE}</string>
  </dict>
  <key>ThrottleInterval</key>
  <integer>600</integer>
</dict>
</plist>
EOF

# Reload: bootout (uncomplain on missing) + bootstrap (uncomplain on already-loaded).
launchctl bootout "gui/$(id -u)" "$DEST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$DEST"

echo "Installed: $DEST"
echo "  refresh script: ${REPO}/scripts/ops/refresh-chump-binary.sh"
echo "  interval: ${INTERVAL}s"
echo "  verify: launchctl list | grep chump.binary-refresh"
echo "  on-demand: launchctl start com.chump.binary-refresh"
