#!/usr/bin/env bash
# install-installer-audit-launchd.sh — INFRA-2394
#
# Installs a LaunchAgent that re-runs scripts/audit/audit-launchd-installers.sh
# weekly (Sunday 22:00 local) so the WIRED/DOCUMENTED/UNWIRED breakdown of
# scripts/setup/install-*-launchd.sh doesn't go stale as new installers land.
# Each UNWIRED installer gets a kind=installer_audit_finding ambient event —
# no deletions happen automatically; the operator triages from there.
#
# Idempotent — safe to re-run after upgrades.
#
# Verify:
#   launchctl list | grep com.chump.installer-audit
# Logs:
#   /tmp/chump-installer-audit.out.log
#   /tmp/chump-installer-audit.err.log
# Disable:
#   launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.chump.installer-audit.plist
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

PLIST_NAME="com.chump.installer-audit.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"
RUNNER="$REPO/scripts/audit/audit-launchd-installers.sh"

mkdir -p "$HOME/Library/LaunchAgents"

cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.chump.installer-audit</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>$RUNNER --json</string>
  </array>
  <!-- Run every Sunday at 22:00. Weekday=0 is Sunday on macOS launchd. -->
  <key>StartCalendarInterval</key>
  <dict>
    <key>Weekday</key>
    <integer>0</integer>
    <key>Hour</key>
    <integer>22</integer>
    <key>Minute</key>
    <integer>0</integer>
  </dict>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-installer-audit.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-installer-audit.err.log</string>
  <key>WorkingDirectory</key>
  <string>$REPO</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>$HOME</string>
    <key>PATH</key>
    <string>/usr/local/bin:${BREW_PREFIX}/bin:$HOME/.cargo/bin:/usr/bin:/bin</string>
    <key>CHUMP_AMBIENT_LOG</key>
    <string>$REPO/.chump-locks/ambient.jsonl</string>
  </dict>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)" "$DEST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$DEST"

echo "Installed: $DEST"
echo "  runner: $RUNNER --json"
echo "  cadence: weekly, Sunday 22:00 local"
echo "  verify: launchctl list | grep com.chump.installer-audit"
echo "  manual smoke: launchctl start com.chump.installer-audit && tail -5 /tmp/chump-installer-audit.out.log"
