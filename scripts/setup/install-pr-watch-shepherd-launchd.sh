#!/usr/bin/env bash
# install-pr-watch-shepherd-launchd.sh — INFRA-354: install 10-min launchd
# agent that runs scripts/ops/pr-watch-shepherd.sh.
#
# Without this, pr-watch.sh only runs as a per-PR detached child of
# bot-merge.sh — which dies if the host cycles or the author's worktree
# is reaped. The shepherd scans ALL open ARMED PRs every 10 min and
# auto-recovers DIRTY-after-arm ones from a clean ephemeral worktree.
#
# Mirrors install-stale-pr-reaper-launchd.sh / install-gap-doctor-cron-launchd.sh.
#
# Idempotent: safe to re-run.
# Disable:    launchctl unload ~/Library/LaunchAgents/dev.chump.pr-watch-shepherd.plist
# Manual fire: launchctl start dev.chump.pr-watch-shepherd
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
PLIST_NAME="dev.chump.pr-watch-shepherd.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

mkdir -p "$HOME/Library/LaunchAgents"

cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>dev.chump.pr-watch-shepherd</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>cd "$REPO" && bash scripts/ops/pr-watch-shepherd.sh</string>
  </array>
  <!-- Every 10 minutes (600s). Scans all open ARMED PRs and runs
       pr-watch.sh on DIRTY-after-arm ones from an ephemeral worktree.
       Cooldown (default 1h on same head_sha) prevents thrash on
       conflict cases that need operator attention. -->
  <key>StartInterval</key>
  <integer>600</integer>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-pr-watch-shepherd.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-pr-watch-shepherd.err.log</string>
  <key>WorkingDirectory</key>
  <string>$REPO</string>
  <key>EnvironmentVariables</key>
  <dict>
    <!-- gh CLI needs HOME for auth token, PATH for git/python3. -->
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

echo "[install-pr-watch-shepherd] Installed: $DEST"
echo "[install-pr-watch-shepherd] Schedule:  every 10 minutes"
echo "[install-pr-watch-shepherd] Logs:      /tmp/chump-pr-watch-shepherd.{out,err}.log"
echo "[install-pr-watch-shepherd] Verify:    launchctl list | grep dev.chump.pr-watch-shepherd"
echo "[install-pr-watch-shepherd] Manual:    launchctl start dev.chump.pr-watch-shepherd"
echo "[install-pr-watch-shepherd] Disable:   launchctl unload $DEST"
