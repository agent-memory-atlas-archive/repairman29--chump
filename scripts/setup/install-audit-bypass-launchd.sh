#!/usr/bin/env bash
# install-audit-bypass-launchd.sh — INFRA-1837
# Installs the daily bypass-frequency auditor LaunchAgent. Idempotent.
#
# After install:
#   launchctl list | grep chump.audit-bypass-frequency
#
# Manual run:
#   launchctl start com.chump.audit-bypass-frequency
#   tail /tmp/chump-audit-bypass-frequency.out.log
#
# Override schedule for testing:
#   CHUMP_BYPASSAUDIT_HOUR=10 CHUMP_BYPASSAUDIT_MINUTE=30 ./install-audit-bypass-launchd.sh

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

PLIST_NAME="com.chump.audit-bypass-frequency.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"
HOUR="${CHUMP_BYPASSAUDIT_HOUR:-9}"
MINUTE="${CHUMP_BYPASSAUDIT_MINUTE:-15}"
PATH_VALUE="/usr/local/bin:${BREW_PREFIX}/bin:${BREW_PREFIX}/sbin:${HOME}/.cargo/bin:/usr/bin:/bin"

mkdir -p "$HOME/Library/LaunchAgents"
cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.chump.audit-bypass-frequency</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>${REPO}/scripts/ops/audit-bypass-frequency.sh</string>
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
  <string>/tmp/chump-audit-bypass-frequency.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-audit-bypass-frequency.err.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>${HOME}</string>
    <key>PATH</key>
    <string>${PATH_VALUE}</string>
  </dict>
</dict>
</plist>
EOF

# Reload to pick up changes.
launchctl unload "$DEST" 2>/dev/null || true
launchctl load "$DEST"

echo "[install-audit-bypass-launchd] installed $DEST (daily ${HOUR}:${MINUTE} local)"
echo "[install-audit-bypass-launchd] verify: launchctl list | grep chump.audit-bypass-frequency"
