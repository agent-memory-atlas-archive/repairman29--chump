#!/usr/bin/env bash
# install-system-invariants-launchd.sh — install the system-invariants-monitor
# LaunchAgent. Idempotent: safe to re-run.
#
# After install:
#   launchctl list | grep dev.chump.system-invariants-monitor
#
# To disable:
#   launchctl unload ~/Library/LaunchAgents/dev.chump.system-invariants-monitor.plist
set -euo pipefail
# INFRA-8194 (R5 slice 2): the Homebrew prefix comes from the host resolver
# (chump_brew_prefix in scripts/lib/host-paths.sh, the shell mirror of
# chump_provision::brew_prefix; `chump node host --field brew-prefix`), not a
# baked Apple Silicon path.
# shellcheck source=../lib/host-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/host-paths.sh"
BREW_PREFIX="$(chump_brew_prefix)"

# Use resolve-main-worktree so the plist path survives worktree reaping.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
REPO="$(resolve_main_worktree "$0")"
PLIST_NAME="dev.chump.system-invariants-monitor.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

mkdir -p "$HOME/Library/LaunchAgents"

cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>dev.chump.system-invariants-monitor</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$REPO/scripts/ops/system-invariants-monitor.sh</string>
    <string>--quiet</string>
  </array>
  <!-- Every 10 minutes. Emits ambient ALERT kind=invariant_violation
       on any violation; auto-files INFRA cleanup gap after 2 consecutive
       failures of the same invariant. -->
  <key>StartInterval</key>
  <integer>600</integer>
  <key>ThrottleInterval</key>
  <integer>60</integer>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-system-invariants-monitor.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-system-invariants-monitor.err.log</string>
  <key>WorkingDirectory</key>
  <string>$REPO</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>$HOME</string>
    <key>PATH</key>
    <string>/usr/local/bin:${BREW_PREFIX}/bin:$HOME/.cargo/bin:/usr/bin:/bin</string>
  </dict>
</dict>
</plist>
EOF

launchctl unload "$DEST" 2>/dev/null || true
launchctl load "$DEST"

echo "Installed and loaded: $DEST"
launchctl list | grep -F "dev.chump.system-invariants-monitor" || true
