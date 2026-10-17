#!/usr/bin/env bash
# install-overnight-research-launchd.sh — install the nightly overnight-research
# LaunchAgent (macOS). Runs scripts/eval/run-overnight-research.sh once a day at
# 02:00 local time. Idempotent: safe to re-run.
#
# After install:
#   launchctl list | grep dev.chump.overnight-research
#
# To run on demand (smoke test):
#   launchctl start dev.chump.overnight-research
#
# To disable:
#   launchctl unload ~/Library/LaunchAgents/dev.chump.overnight-research.plist
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
PLIST_NAME="dev.chump.overnight-research.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

# Hour/minute can be overridden for testing (CHUMP_OVERNIGHT_HOUR=22 ./install...)
HOUR="${CHUMP_OVERNIGHT_HOUR:-2}"
MINUTE="${CHUMP_OVERNIGHT_MINUTE:-0}"

mkdir -p "$HOME/Library/LaunchAgents"

cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>dev.chump.overnight-research</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>$REPO/scripts/eval/run-overnight-research.sh</string>
  </array>
  <!-- Once per day at ${HOUR}:$(printf '%02d' "$MINUTE") local time. Runs every job
       in scripts/overnight/ in order, with a 1h per-job timeout. -->
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>$HOUR</integer>
    <key>Minute</key>
    <integer>$MINUTE</integer>
  </dict>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-overnight-research.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-overnight-research.err.log</string>
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

# Reload (unload first; ignore failure if not loaded).
launchctl unload "$DEST" 2>/dev/null || true
launchctl load "$DEST"

echo "Installed and loaded: $DEST"
echo "Schedule: ${HOUR}:$(printf '%02d' "$MINUTE") local, daily"
launchctl list | grep -F "dev.chump.overnight-research" || true
