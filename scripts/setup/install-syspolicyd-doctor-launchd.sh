#!/usr/bin/env bash
# install-syspolicyd-doctor-launchd.sh — INFRA-675: install 30-min launchd
# agent that runs scripts/dev/chump-binary-unwedge.sh to auto-heal a wedged chump
# binary before fleet workers see a hung 'chump gap …' call.
#
# Root cause (macOS Sequoia): syspolicyd gets a binary's inode into a wedged
# pending-decision state, causing every subsequent launch to hang at _dyld_start.
# Without this heartbeat, the wedge silently starves the fleet for hours.
#
# chump-binary-unwedge.sh exit codes (both acceptable for launchd):
#   0 — probe OK (binary healthy) OR probe-fail + heal applied + post-heal OK
#   1 — post-heal probe still timed out (operator action needed)
#
# Idempotent: safe to re-run.
# Disable:    launchctl unload ~/Library/LaunchAgents/dev.chump.syspolicyd-doctor.plist
# Manual fire: launchctl start dev.chump.syspolicyd-doctor
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
PLIST_NAME="dev.chump.syspolicyd-doctor.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

mkdir -p "$HOME/Library/LaunchAgents"

cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>dev.chump.syspolicyd-doctor</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>cd "$REPO" && CHUMP_DOCTOR_QUIET=1 bash scripts/dev/chump-binary-unwedge.sh</string>
  </array>
  <!-- Every 30 minutes (1800s). Probes chump binary health; replaces wedged
       inode so workers are never silently starved by syspolicyd. -->
  <key>StartInterval</key>
  <integer>1800</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-syspolicyd-doctor.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-syspolicyd-doctor.err.log</string>
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

# Reload (unload + load) so the new plist takes effect immediately.
launchctl unload "$DEST" 2>/dev/null || true
launchctl load "$DEST"

echo "[install-syspolicyd-doctor] Installed: $DEST"
echo "[install-syspolicyd-doctor] Schedule:  every 30 min, runs at load"
echo "[install-syspolicyd-doctor] Logs:      /tmp/chump-syspolicyd-doctor.{out,err}.log"
echo "[install-syspolicyd-doctor] Verify:    launchctl list | grep dev.chump.syspolicyd-doctor"
echo "[install-syspolicyd-doctor] Manual:    launchctl start dev.chump.syspolicyd-doctor"
echo "[install-syspolicyd-doctor] Disable:   launchctl unload $DEST"
