#!/usr/bin/env bash
# install-branch-protection-drift-launchd.sh — INFRA-121 LaunchAgent installer.
#
# Installs the daily branch-protection drift detector
# (scripts/ops/branch-protection-drift.sh). Idempotent: safe to re-run.
#
# After install:
#   launchctl list | grep dev.chump.branch-protection-drift
#
# To run immediately (verify):
#   launchctl start dev.chump.branch-protection-drift
#   tail -f /tmp/chump-branch-protection-drift.out.log
#
# To disable:
#   launchctl unload ~/Library/LaunchAgents/dev.chump.branch-protection-drift.plist

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
PLIST_NAME="dev.chump.branch-protection-drift.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

mkdir -p "$HOME/Library/LaunchAgents"

cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>dev.chump.branch-protection-drift</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>$REPO/scripts/ops/branch-protection-drift.sh --quiet</string>
  </array>
  <!-- Daily. Diffs live branch protection for main vs the checked-in
       baseline at docs/baselines/branch-protection-main.json. On drift,
       writes ALERT kind=queue_config_drift to ambient.jsonl + .chump/alerts.log
       so sibling agents see it in their FLEET-019 SessionStart digest.
       Closes the silent-disarm hole described in CLAUDE.md "If the merge
       queue is stuck" recovery section. -->
  <key>StartInterval</key>
  <integer>86400</integer>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-branch-protection-drift.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-branch-protection-drift.err.log</string>
  <key>WorkingDirectory</key>
  <string>$REPO</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>$HOME</string>
    <key>PATH</key>
    <string>/usr/local/bin:${BREW_PREFIX}/bin:$HOME/.cargo/bin:/usr/bin:/bin</string>
  </dict>
  <key>ThrottleInterval</key>
  <integer>60</integer>
</dict>
</plist>
EOF

launchctl unload "$DEST" 2>/dev/null || true
launchctl load "$DEST"

echo "Installed and loaded: $DEST"
launchctl list | grep -F "dev.chump.branch-protection-drift" || true
echo
echo "First run is in 24 hours. To run immediately:"
echo "  launchctl start dev.chump.branch-protection-drift"
echo "  tail -f /tmp/chump-branch-protection-drift.out.log"
