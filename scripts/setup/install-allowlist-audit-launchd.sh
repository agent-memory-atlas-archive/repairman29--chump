#!/usr/bin/env bash
# install-allowlist-audit-launchd.sh — INFRA-1868 daily LaunchAgent.
# Installs the daily allowlist-staleness audit cron (once per day at 08:30).
# Idempotent: safe to re-run.
#
# After install: launchctl list | grep chump.allowlist-audit
# Disable: launchctl unload ~/Library/LaunchAgents/com.chump.allowlist-audit.plist
# Manual run: launchctl start com.chump.allowlist-audit
# Logs: /tmp/chump-allowlist-audit.out.log  /tmp/chump-allowlist-audit.err.log
#
# Override schedule for testing:
#   CHUMP_ALLOWLIST_AUDIT_HOUR=10 CHUMP_ALLOWLIST_AUDIT_MINUTE=30 ./install-allowlist-audit-launchd.sh

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

PLIST_NAME="com.chump.allowlist-audit.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"
HOUR="${CHUMP_ALLOWLIST_AUDIT_HOUR:-8}"
MINUTE="${CHUMP_ALLOWLIST_AUDIT_MINUTE:-30}"
PATH_VALUE="/usr/local/bin:${BREW_PREFIX}/bin:${BREW_PREFIX}/sbin:${HOME}/.cargo/bin:/usr/bin:/bin"

mkdir -p "$HOME/Library/LaunchAgents"

cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.chump.allowlist-audit</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>${REPO}/scripts/ops/audit-allowlist-staleness.sh</string>
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
  <string>/tmp/chump-allowlist-audit.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-allowlist-audit.err.log</string>
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
echo "  verify:   launchctl list | grep chump.allowlist-audit"
echo "  on-demand: launchctl start com.chump.allowlist-audit"
echo "  logs:     /tmp/chump-allowlist-audit.{out,err}.log"
