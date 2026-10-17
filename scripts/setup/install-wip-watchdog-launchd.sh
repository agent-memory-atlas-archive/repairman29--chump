#!/usr/bin/env bash
# install-wip-watchdog-launchd.sh — RESILIENT-256 (2026-08-09)
#
# Install the uncommitted-WIP watchdog LaunchAgent. Runs every 5 minutes;
# snapshots any checkout whose uncommitted work has gone idle past the
# threshold into refs/wip/… (object store), and ALERTs into ambient.jsonl.
#
# 5 minutes, not 30, and the threshold is 15 MINUTES, not 3 hours. The old
# pairing only ever caught ABANDONED work — "idle" is measured from the newest
# mtime among dirty files, so anything actively being edited had an age near
# zero and was never snapshotted. What protects a live session is a threshold
# short enough that ordinary pauses checkpoint you.
#
# This cadence is only affordable because snapshots now dedup by tree hash and
# prune to CHUMP_WIP_RETAIN per branch. Without those, idle work minted a fresh
# anchored ref every single run.
#
# Exactly the shape of scripts/setup/install-reaper-watchdog-launchd.sh
# (dev.chump.reaper-watchdog), so the fleet has one launchd pattern, not two.
#
# Idempotent. After install:
#   launchctl list | grep dev.chump.wip-watchdog
#
# To disable:
#   launchctl unload ~/Library/LaunchAgents/dev.chump.wip-watchdog.plist

set -euo pipefail
# INFRA-8194 (R5 slice 2): the Homebrew prefix comes from the host resolver
# (chump_brew_prefix in scripts/lib/host-paths.sh, the shell mirror of
# chump_provision::brew_prefix; `chump node host --field brew-prefix`), not a
# baked Apple Silicon path.
# shellcheck source=../lib/host-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/host-paths.sh"
BREW_PREFIX="$(chump_brew_prefix)"

# Resolve to the *main* worktree so the plist's absolute path survives
# worktree reaping (same reason as INFRA-451).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
REPO="$(resolve_main_worktree "$0")"
PLIST_NAME="dev.chump.wip-watchdog.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

mkdir -p "$HOME/Library/LaunchAgents"

cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>dev.chump.wip-watchdog</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>$REPO/scripts/ops/uncommitted-wip-watchdog.sh --quiet</string>
  </array>
  <!-- Every 30 minutes. Cheap: one `git status` per checkout, and a snapshot
       only for trees that have been idle past the threshold. -->
  <key>StartInterval</key>
  <integer>300</integer>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-wip-watchdog.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-wip-watchdog.err.log</string>
  <key>WorkingDirectory</key>
  <string>$REPO</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>$HOME</string>
    <key>PATH</key>
    <string>/usr/local/bin:${BREW_PREFIX}/bin:$HOME/.local/bin:$HOME/.cargo/bin:/usr/bin:/bin</string>
  </dict>
</dict>
</plist>
EOF

launchctl unload "$DEST" 2>/dev/null || true
launchctl load "$DEST"

echo "Installed and loaded: $DEST"
launchctl list | grep -F "dev.chump.wip-watchdog" || true
