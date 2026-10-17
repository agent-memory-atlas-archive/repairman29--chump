#!/usr/bin/env bash
# install-distill-pr-skills-launchd.sh — INFRA-1926: install hourly launchd
# agent that runs scripts/ops/distill-pr-skills.sh.
#
# The distill script scans the most recently merged PR (or last N) and
# INSERTs chump_improvement_targets rows for cross-agent skill sharing
# (INFRA-195 v1). Without this installer the script existed on disk but
# never ran, so improvement_targets only grew via manual sqlite3 INSERT
# (i.e. never). reaper-heartbeat-watchdog emits kind=daemon_silent for
# "distill" because /tmp/chump-distill.heartbeat never appears.
#
# Mirrors install-stale-branch-reaper-launchd.sh / install-pr-watch-
# shepherd-launchd.sh — same template, hourly cadence (matches how often
# new PRs land in a typical fleet day).
#
# Idempotent: safe to re-run.
# Disable:    launchctl unload ~/Library/LaunchAgents/dev.chump.distill-pr-skills.plist
# Manual fire: launchctl start dev.chump.distill-pr-skills
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
PLIST_NAME="dev.chump.distill-pr-skills.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

mkdir -p "$HOME/Library/LaunchAgents"

cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>dev.chump.distill-pr-skills</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>cd "$REPO" && bash scripts/ops/distill-pr-skills.sh</string>
  </array>
  <!-- Every hour (3600s). Scans last N merged PRs and INSERTs
       improvement_targets rows for rule-pattern matches. Heartbeat at
       /tmp/chump-distill.heartbeat consumed by reaper-heartbeat-watchdog. -->
  <key>StartInterval</key>
  <integer>3600</integer>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-distill-pr-skills.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-distill-pr-skills.err.log</string>
  <key>WorkingDirectory</key>
  <string>$REPO</string>
  <key>EnvironmentVariables</key>
  <dict>
    <!-- gh CLI needs HOME for auth token, PATH for git/python3/sqlite3. -->
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

echo "[install-distill-pr-skills] Installed: $DEST"
echo "[install-distill-pr-skills] Schedule:  every hour (3600s)"
echo "[install-distill-pr-skills] Logs:      /tmp/chump-distill-pr-skills.{out,err}.log"
echo "[install-distill-pr-skills] Heartbeat: /tmp/chump-distill.heartbeat"
echo "[install-distill-pr-skills] Verify:    launchctl list | grep dev.chump.distill-pr-skills"
echo "[install-distill-pr-skills] Manual:    launchctl start dev.chump.distill-pr-skills"
echo "[install-distill-pr-skills] Disable:   launchctl unload $DEST"
