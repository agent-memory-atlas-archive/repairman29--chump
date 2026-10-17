#!/usr/bin/env bash
# install-daily-self-productize-launchd.sh — META-098: install daily launchd
# agent that runs scripts/coord/daily-self-productize.sh.
#
# Fires once per day (at 09:03 local; non-:00 minute per scheduler convention),
# sends 6 A2A broadcast.sh DMs (one per curator role) asking the curator
# to add delta-AC for their lane. Cost: 6 file-writes per run; no LLM call
# directly (curators contemplate when their inbox-poll surfaces the message).
#
# Mirrors install-pr-watch-shepherd-launchd.sh / install-stale-branch-reaper-
# launchd.sh — same template, daily cadence (~86400s).
#
# Idempotent: safe to re-run.
# Disable:    launchctl unload ~/Library/LaunchAgents/dev.chump.daily-self-productize.plist
# Manual fire: launchctl start dev.chump.daily-self-productize
set -euo pipefail
# INFRA-8194 (R5 slice 2): the Homebrew prefix comes from the host resolver
# (chump_brew_prefix in scripts/lib/host-paths.sh, the shell mirror of
# chump_provision::brew_prefix; `chump node host --field brew-prefix`), not a
# baked Apple Silicon path.
# shellcheck source=../lib/host-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/host-paths.sh"
BREW_PREFIX="$(chump_brew_prefix)"

# INFRA-451: resolve to the *main* worktree
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
REPO="$(resolve_main_worktree "$0")"
PLIST_NAME="dev.chump.daily-self-productize.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

mkdir -p "$HOME/Library/LaunchAgents"

cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>dev.chump.daily-self-productize</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>cd "$REPO" && bash scripts/coord/daily-self-productize.sh</string>
  </array>
  <!-- StartCalendarInterval: 09:03 local every day. Non-:00 minute per
       fleet convention to avoid scheduler thundering-herd. -->
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>9</integer>
    <key>Minute</key>
    <integer>3</integer>
  </dict>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-daily-self-productize.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-daily-self-productize.err.log</string>
  <key>WorkingDirectory</key>
  <string>$REPO</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>$HOME</string>
    <key>PATH</key>
    <string>/usr/local/bin:${BREW_PREFIX}/bin:$HOME/.cargo/bin:$HOME/.local/bin:/usr/bin:/bin</string>
  </dict>
</dict>
</plist>
EOF

# Reload (unload + load)
launchctl unload "$DEST" 2>/dev/null || true
launchctl load "$DEST"

echo "[install-daily-self-productize] Installed: $DEST"
echo "[install-daily-self-productize] Schedule:  09:03 local daily"
echo "[install-daily-self-productize] Logs:      /tmp/chump-daily-self-productize.{out,err}.log"
echo "[install-daily-self-productize] Verify:    launchctl list | grep dev.chump.daily-self-productize"
echo "[install-daily-self-productize] Manual:    launchctl start dev.chump.daily-self-productize"
echo "[install-daily-self-productize] Disable:   launchctl unload $DEST"
echo ""
echo "Manual test (immediate, idempotent on today):"
echo "  bash $REPO/scripts/coord/daily-self-productize.sh"
echo ""
echo "Bypass: CHUMP_DAILY_PRODUCTIZE_DISABLED=1"
