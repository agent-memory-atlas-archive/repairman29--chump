#!/usr/bin/env bash
# install-conductor-launchd.sh — EFFECTIVE-264 (EFFECTIVE-088 activation)
#
# Installs the fleet self-rescue conductor LaunchAgent. Idempotent.
# Runs `chump self-rescue-loop` every 30 min: detects a wedged fleet by GROUND
# TRUTH (recent merges to origin/main + pickable P0/P1 count + fleet-paused
# sentinel), and on a confirmed wedge emits a consensus proposal (objection
# window; any -1 vetoes). This is the autonomous proposer that fills the empty
# consensus chair — "chump drives the loop" as a live daemon, not code-on-disk.
#
# DRY-RUN by default (observe + propose only). To ARM (let it clear a stale
# pause + kickstart ci-health-gate when a wedge is confirmed):
#   CHUMP_CONDUCTOR_ACT=1 ./install-conductor-launchd.sh
#
# After install:
#   launchctl list | grep chump.conductor
# Manual run (smoke test):
#   launchctl start com.chump.conductor
#   tail /tmp/chump-conductor.out.log     # expect: [conductor] HEALTHY ... / WEDGE ...
# Uninstall:
#   launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/com.chump.conductor.plist
#   rm ~/Library/LaunchAgents/com.chump.conductor.plist
#
# Override interval (seconds) for testing:
#   CHUMP_CONDUCTOR_INTERVAL=300 ./install-conductor-launchd.sh

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

PLIST_NAME="com.chump.conductor.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"
INTERVAL="${CHUMP_CONDUCTOR_INTERVAL:-1800}"

# PATH must let the conductor resolve `chump` + git + gh.
PATH_VALUE="/usr/local/bin:${BREW_PREFIX}/bin:${BREW_PREFIX}/sbin:${HOME}/.cargo/bin:/usr/bin:/bin"

# Opt-in arm: only emit the CHUMP_CONDUCTOR_ACT env entry when requested.
ACT_BLOCK=""
if [ "${CHUMP_CONDUCTOR_ACT:-0}" = "1" ]; then
    ACT_BLOCK=$'    <key>CHUMP_CONDUCTOR_ACT</key>\n    <string>1</string>'
fi

mkdir -p "$HOME/Library/LaunchAgents"

cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.chump.conductor</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>exec chump self-rescue-loop</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${REPO}</string>
  <key>StartInterval</key>
  <integer>${INTERVAL}</integer>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-conductor.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-conductor.err.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>${HOME}</string>
    <key>PATH</key>
    <string>${PATH_VALUE}</string>
${ACT_BLOCK}
  </dict>
  <key>ThrottleInterval</key>
  <integer>60</integer>
</dict>
</plist>
EOF

# Reload: bootout (uncomplain on missing) + bootstrap (uncomplain on already-loaded).
launchctl bootout "gui/$(id -u)" "$DEST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$DEST"

echo "Installed: $DEST"
echo "  command: chump self-rescue-loop ($([ "${CHUMP_CONDUCTOR_ACT:-0}" = "1" ] && echo ARMED || echo dry-run))"
echo "  interval: ${INTERVAL}s"
echo "  verify: launchctl list | grep chump.conductor"
echo "  on-demand: launchctl start com.chump.conductor"
