#!/usr/bin/env bash
# install-operator-leverage-launchd.sh — CREDIBLE-049
# Installs the daily and weekly operator-leverage LaunchAgents.
# Idempotent.
#
# After install:
#   launchctl list | grep chump.operator-leverage
#
# Manual run:
#   launchctl start com.chump.operator-leverage-daily
#   launchctl start com.chump.operator-leverage-weekly
#   tail /tmp/chump-operator-leverage-daily.out.log

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

DAILY_HOUR="${CHUMP_LEVERAGE_DAILY_HOUR:-8}"
DAILY_MINUTE="${CHUMP_LEVERAGE_DAILY_MINUTE:-30}"
WEEKLY_DAY="${CHUMP_LEVERAGE_WEEKLY_DAY:-0}"   # 0=Sunday
WEEKLY_HOUR="${CHUMP_LEVERAGE_WEEKLY_HOUR:-8}"
WEEKLY_MINUTE="${CHUMP_LEVERAGE_WEEKLY_MINUTE:-45}"

PATH_VALUE="/usr/local/bin:${BREW_PREFIX}/bin:${BREW_PREFIX}/sbin:${HOME}/.cargo/bin:/usr/bin:/bin"
mkdir -p "$HOME/Library/LaunchAgents"

# ── Daily agent (--window 1) ─────────────────────────────────────────────────
DAILY_PLIST="com.chump.operator-leverage-daily.plist"
DAILY_DEST="$HOME/Library/LaunchAgents/$DAILY_PLIST"
cat >"$DAILY_DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.chump.operator-leverage-daily</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>${REPO}/scripts/dispatch/operator-leverage.sh --daily --window 1</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${REPO}</string>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>${DAILY_HOUR}</integer>
    <key>Minute</key>
    <integer>${DAILY_MINUTE}</integer>
  </dict>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-operator-leverage-daily.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-operator-leverage-daily.err.log</string>
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

# ── Weekly agent (--weekly --window 7) ───────────────────────────────────────
WEEKLY_PLIST="com.chump.operator-leverage-weekly.plist"
WEEKLY_DEST="$HOME/Library/LaunchAgents/$WEEKLY_PLIST"
cat >"$WEEKLY_DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.chump.operator-leverage-weekly</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>${REPO}/scripts/dispatch/operator-leverage.sh --weekly --window 7</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${REPO}</string>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Weekday</key>
    <integer>${WEEKLY_DAY}</integer>
    <key>Hour</key>
    <integer>${WEEKLY_HOUR}</integer>
    <key>Minute</key>
    <integer>${WEEKLY_MINUTE}</integer>
  </dict>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-operator-leverage-weekly.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-operator-leverage-weekly.err.log</string>
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

# ── Register both ─────────────────────────────────────────────────────────────
launchctl bootout "gui/$(id -u)" "$DAILY_DEST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$DAILY_DEST"

launchctl bootout "gui/$(id -u)" "$WEEKLY_DEST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$WEEKLY_DEST"

echo "Installed: $DAILY_DEST"
echo "  daily at ${DAILY_HOUR}:$(printf '%02d' "$DAILY_MINUTE")"
echo "Installed: $WEEKLY_DEST"
echo "  weekly on day ${WEEKLY_DAY} at ${WEEKLY_HOUR}:$(printf '%02d' "$WEEKLY_MINUTE")"
echo "  verify: launchctl list | grep chump.operator-leverage"
echo "  on-demand: launchctl start com.chump.operator-leverage-daily"
