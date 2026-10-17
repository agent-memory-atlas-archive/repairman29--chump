#!/usr/bin/env bash
# install-ambient-rotate-launchd.sh — INFRA-122: install daily launchd agent
# that runs scripts/dev/ambient-rotate.sh.
#
# Without scheduled rotation, .chump-locks/ambient.jsonl grows unbounded
# (~4MB / 21k lines on a single busy day; would reach multi-GB over a few
# weeks of fleet activity). The rotate script archives events older than
# 7 days to .chump-locks/ambient.jsonl.YYYY-MM-DD.gz; ambient-query.sh
# transparently reads from both live + archives.
#
# Idempotent: safe to re-run.
# Disable: launchctl unload ~/Library/LaunchAgents/dev.chump.ambient-rotate.plist
# Manually fire: launchctl start dev.chump.ambient-rotate
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
PLIST_NAME="dev.chump.ambient-rotate.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

mkdir -p "$HOME/Library/LaunchAgents"

cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>dev.chump.ambient-rotate</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>$REPO/scripts/dev/ambient-rotate.sh</string>
  </array>
  <!-- Daily at 03:00 local. Archives events older than AMBIENT_RETAIN_DAYS
       (default 7) to .chump-locks/ambient.jsonl.YYYY-MM-DD.gz and writes a
       {"event":"rotated",...} summary line to the live log. Override
       retention with AMBIENT_RETAIN_DAYS in this plist's EnvironmentVariables
       if you want different windows. -->
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>3</integer>
    <key>Minute</key>
    <integer>0</integer>
  </dict>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-ambient-rotate.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-ambient-rotate.err.log</string>
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
launchctl list | grep -F "dev.chump.ambient-rotate" || true
echo
echo "Smoke test (dry-run): $REPO/scripts/dev/ambient-rotate.sh --dry-run"
echo "Manually fire        : launchctl start dev.chump.ambient-rotate"
echo "Tail logs            : tail -f /tmp/chump-ambient-rotate.{out,err}.log"
