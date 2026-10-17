#!/usr/bin/env bash
# install-queue-driver-launchd.sh — INFRA-1304
#
# Installs the launchd agent that runs scripts/coord/queue-driver.sh
# every 5 min. Closes the last manual gap in the PR drain:
#   - INFRA-1081: BEHIND PR scan (cache-first, REST update-branch)
#   - INFRA-1137: DIRTY PR scan (rebase + .gitattributes merge-driver
#     auto-resolve for ci.yml/EVENT_REGISTRY.yaml/docs/gaps/*.yaml/etc.)
#
# Without this plist, queue-driver only runs when an agent invokes it
# manually. Every DIRTY rescue on 2026-05-14 was a manual operator
# action via /tmp/rescue-dirty-prs.sh. Post-install, drain is hands-off.
#
# Mirrors install-pr-watch-shepherd-launchd.sh + install-stale-pr-reaper-launchd.sh.
#
# Idempotent: safe to re-run.
# Disable:     launchctl unload ~/Library/LaunchAgents/dev.chump.queue-driver.plist
# Manual fire: launchctl start dev.chump.queue-driver
# Uninstall:   bash scripts/setup/install-queue-driver-launchd.sh --uninstall

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
PLIST_NAME="dev.chump.queue-driver.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

if [[ "${1:-}" == "--uninstall" ]]; then
    if [[ -f "$DEST" ]]; then
        launchctl unload "$DEST" 2>/dev/null || true
        rm -f "$DEST"
        echo "[install-queue-driver] Uninstalled: $DEST"
    else
        echo "[install-queue-driver] Not installed (no $DEST)"
    fi
    exit 0
fi

mkdir -p "$HOME/Library/LaunchAgents"

cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>dev.chump.queue-driver</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>cd "$REPO" &amp;&amp; bash scripts/coord/queue-driver.sh</string>
  </array>
  <!-- INFRA-1304: every 5 minutes (300s).
       - INFRA-1081 BEHIND scan: cache_query_behind_prs + gh pr update-branch
       - INFRA-1137 DIRTY scan: rebase + .gitattributes merge-driver auto-resolve
       Closes the last manual gap in the PR drain. -->
  <key>StartInterval</key>
  <integer>300</integer>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-queue-driver.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-queue-driver.err.log</string>
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

# Reload so the new plist takes effect immediately.
launchctl unload "$DEST" 2>/dev/null || true
launchctl load "$DEST"

echo "[install-queue-driver] Installed: $DEST"
echo "[install-queue-driver] Schedule:  every 5 minutes (300s)"
echo "[install-queue-driver] Logs:      /tmp/chump-queue-driver.{out,err}.log"
echo "[install-queue-driver] Verify:    launchctl list | grep dev.chump.queue-driver"
echo "[install-queue-driver] Manual:    launchctl start dev.chump.queue-driver"
echo "[install-queue-driver] Disable:   launchctl unload $DEST"
echo "[install-queue-driver] Uninstall: bash $0 --uninstall"
