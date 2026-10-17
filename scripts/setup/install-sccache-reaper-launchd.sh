#!/usr/bin/env bash
# install-sccache-reaper-launchd.sh — install 6h LaunchAgent that reaps
# ~/Library/Caches/Mozilla.sccache when it exceeds SCCACHE_CACHE_CAP_GB (10G).
# Idempotent. INFRA-2303.
#
# Verify:
#   launchctl list | grep dev.chump.sccache-reaper
# Logs:
#   /tmp/chump-sccache-reaper.out.log
#   /tmp/chump-sccache-reaper.err.log
# Disable:
#   launchctl unload ~/Library/LaunchAgents/dev.chump.sccache-reaper.plist

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
PLIST_NAME="dev.chump.sccache-reaper.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

mkdir -p "$HOME/Library/LaunchAgents"

cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>dev.chump.sccache-reaper</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>$REPO/scripts/coord/sccache-reaper.sh --execute</string>
  </array>
  <!-- Every 6 hours. Prunes oldest files from Mozilla.sccache when over cap.
       Emits kind=sccache_reaped to ambient.jsonl. INFRA-2303. -->
  <key>StartInterval</key>
  <integer>21600</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-sccache-reaper.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-sccache-reaper.err.log</string>
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
launchctl list | grep -F "dev.chump.sccache-reaper" || true
