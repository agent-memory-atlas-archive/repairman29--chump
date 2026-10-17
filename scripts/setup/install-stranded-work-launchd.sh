#!/usr/bin/env bash
# install-stranded-work-launchd.sh — ZERO-WASTE-039
#
# Install the daily stranded-work sweeper LaunchAgent. Runs once a day,
# scans every checkout under ~/Projects (+ registered external repos),
# snapshots any dirty diff to a dated zero-loss patch under
# .chump/stranded/ BEFORE warning, and appends kind=stranded_work to
# ambient.jsonl. Never auto-commits, never auto-files a gap — surface only
# (MISSION-045).
#
# Same shape as scripts/setup/install-wip-watchdog-launchd.sh (RESILIENT-256)
# so the fleet has one launchd pattern, not two.
#
# Idempotent. After install:
#   launchctl list | grep dev.chump.stranded-work
#
# To disable:
#   launchctl unload ~/Library/LaunchAgents/dev.chump.stranded-work.plist

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
PLIST_NAME="dev.chump.stranded-work.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

mkdir -p "$HOME/Library/LaunchAgents"

cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>dev.chump.stranded-work</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>$REPO/scripts/coord/stranded-work-detector.sh --quiet</string>
  </array>
  <!-- Once a day (86400s). This is a fleet-wide sweep (every checkout +
       linked worktree under ~/Projects, plus registered external repos) —
       not a per-session check, so daily is the right cadence. The
       per-session digest signal lives in freshness-preamble.sh via
       --checkout (single-repo, cheap, runs every session start). -->
  <key>StartInterval</key>
  <integer>86400</integer>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-stranded-work.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-stranded-work.err.log</string>
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
launchctl list | grep -F "dev.chump.stranded-work" || true
