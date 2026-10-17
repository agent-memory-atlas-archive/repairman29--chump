#!/usr/bin/env bash
# install-stale-branch-reaper-launchd.sh — INFRA-388: install daily launchd
# agent that runs scripts/ops/stale-branch-reaper.sh --execute.
#
# The stale-branch-reaper deletes remote branches that are 14+ days old
# AND have no open PR. Without this installer, the reaper script existed
# but only ran when an operator triggered it manually. The watchdog
# (INFRA-120) ALERTed kind=reaper_silent for "branch" 5+ times/day on
# 2026-05-03 because the heartbeat file was never stamped.
#
# Mirrors install-stale-pr-reaper-launchd.sh / install-pr-watch-shepherd-
# launchd.sh / install-ci-flake-rerun-launchd.sh — same template, different
# cadence (daily; the stale-branch threshold is itself 14 days, so daily
# is plenty and matches the watchdog's 48h threshold).
#
# Idempotent: safe to re-run.
# Disable:    launchctl unload ~/Library/LaunchAgents/dev.chump.stale-branch-reaper.plist
# Manual fire: launchctl start dev.chump.stale-branch-reaper
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
PLIST_NAME="dev.chump.stale-branch-reaper.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

mkdir -p "$HOME/Library/LaunchAgents"

cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>dev.chump.stale-branch-reaper</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>cd "$REPO" && bash scripts/ops/stale-branch-reaper.sh --execute</string>
  </array>
  <!-- Once per day (86400s). Stale-branch deletion is conservative
       (default STALE_DAYS_THRESHOLD=14 + must have no open PR), so
       daily is plenty. Watchdog (INFRA-120) ALERTs at 48h missed. -->
  <key>StartInterval</key>
  <integer>86400</integer>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-stale-branch-reaper.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-stale-branch-reaper.err.log</string>
  <key>WorkingDirectory</key>
  <string>$REPO</string>
  <key>EnvironmentVariables</key>
  <dict>
    <!-- gh CLI needs HOME for auth, PATH for git. -->
    <key>HOME</key>
    <string>$HOME</string>
    <key>PATH</key>
    <string>/usr/local/bin:${BREW_PREFIX}/bin:$HOME/.cargo/bin:$HOME/.local/bin:/usr/bin:/bin</string>
  </dict>
</dict>
</plist>
EOF

# Reload (unload + load) so the new plist takes effect immediately.
launchctl unload "$DEST" 2>/dev/null || true
launchctl load "$DEST"

echo "[install-stale-branch-reaper] Installed: $DEST"
echo "[install-stale-branch-reaper] Schedule:  every 1 day (86400s)"
echo "[install-stale-branch-reaper] Logs:      /tmp/chump-stale-branch-reaper.{out,err}.log"
echo "[install-stale-branch-reaper] Verify:    launchctl list | grep dev.chump.stale-branch-reaper"
echo "[install-stale-branch-reaper] Manual:    launchctl start dev.chump.stale-branch-reaper"
echo "[install-stale-branch-reaper] Disable:   launchctl unload $DEST"
