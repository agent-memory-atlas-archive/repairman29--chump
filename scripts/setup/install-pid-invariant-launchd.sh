#!/usr/bin/env bash
# install-pid-invariant-launchd.sh — INFRA-649
#
# Installs a macOS LaunchAgent that runs `chump fleet audit-pids --apply`
# every 5 minutes (StartInterval 300).
#
# The job checks that claude_pid_count == 2 * worker_count (±1 tolerance).
# When violated for consecutive checks it prunes orphans or respawns workers.
# Exits immediately as a no-op when no fleet-desired-size file exists.
#
# Verify:
#   launchctl list | grep dev.chump.fleet-pid-invariant
# Logs:
#   /tmp/chump-fleet-pid-invariant.out.log
#   /tmp/chump-fleet-pid-invariant.err.log
# Disable:
#   launchctl unload ~/Library/LaunchAgents/dev.chump.fleet-pid-invariant.plist
# Re-enable:
#   launchctl load ~/Library/LaunchAgents/dev.chump.fleet-pid-invariant.plist

set -euo pipefail
# INFRA-8194 (R5 slice 2): the Homebrew prefix comes from the host resolver
# (chump_brew_prefix in scripts/lib/host-paths.sh, the shell mirror of
# chump_provision::brew_prefix; `chump node host --field brew-prefix`), not a
# baked Apple Silicon path.
# shellcheck source=../lib/host-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/host-paths.sh"
BREW_PREFIX="$(chump_brew_prefix)"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
REPO="$(resolve_main_worktree "$0")"

PLIST_NAME="dev.chump.fleet-pid-invariant.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

mkdir -p "$HOME/Library/LaunchAgents"

cat > "$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>dev.chump.fleet-pid-invariant</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>$REPO/bin/chump fleet audit-pids --apply</string>
  </array>
  <!-- Run every 5 minutes. No-ops when fleet-desired-size is absent or zero. -->
  <key>StartInterval</key>
  <integer>300</integer>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-fleet-pid-invariant.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-fleet-pid-invariant.err.log</string>
  <key>WorkingDirectory</key>
  <string>$REPO</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>$HOME</string>
    <key>PATH</key>
    <string>/usr/local/bin:${BREW_PREFIX}/bin:$HOME/.cargo/bin:/usr/bin:/bin</string>
    <key>REPO_ROOT</key>
    <string>$REPO</string>
  </dict>
</dict>
</plist>
EOF

launchctl unload "$DEST" 2>/dev/null || true
launchctl load "$DEST"

echo "Installed and loaded: $DEST"
launchctl list | grep -F "dev.chump.fleet-pid-invariant" || true
