#!/usr/bin/env bash
# install-reap-stale-leases-launchd.sh — install com.chump.reap-stale-leases LaunchAgent
#
# Installs the periodic lease reaper that cleans .chump-locks/ of expired sessions (INFRA-1208).
# Runs every 60 minutes to remove stale leases from crashed/disconnected sessions.
#
# Usage:
#   scripts/setup/install-reap-stale-leases-launchd.sh    # dry-run (shows what will be installed)
#   scripts/setup/install-reap-stale-leases-launchd.sh --apply
#
# After install:
#   launchctl list | grep chump.reap-stale-leases         # verify it's loaded
#   launchctl start com.chump.reap-stale-leases           # manual trigger
#   tail /tmp/chump-reap-stale-leases.out.log             # view logs

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 1
PLIST_SRC="$REPO_ROOT/launchd/com.chump.reap-stale-leases.plist"
PLIST_DEST="$HOME/Library/LaunchAgents/com.chump.reap-stale-leases.plist"
DRY_RUN=1

if [ "${1:-}" = "--apply" ]; then
    DRY_RUN=0
fi

if [ ! -f "$PLIST_SRC" ]; then
    echo "ERROR: plist not found at $PLIST_SRC"
    exit 1
fi

echo "[install-reap] Installing lease reaper LaunchAgent..."
echo "[install-reap]   Source: $PLIST_SRC"
echo "[install-reap]   Dest:   $PLIST_DEST"

# Substitute paths in the plist
# INFRA-8194 (R5 slice 2): the tracked plist is a placeholder template
# (__REPO_ROOT__ __HOME__ __BIN_DIR__ __BREW_PREFIX__), rendered for THIS host by
# chump_render_template (typed `chump node render-unit`, sed mirror fallback).
# shellcheck source=../lib/host-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/host-paths.sh"
_RENDERED="$(mktemp)"
chump_render_template "$PLIST_SRC" "$_RENDERED" "$REPO_ROOT"
PLIST_CONTENT=$(cat "$_RENDERED")
rm -f "$_RENDERED"

if [ "$DRY_RUN" = 1 ]; then
    echo "[install-reap] DRY RUN (pass --apply to install)"
    echo "[install-reap]"
    echo "$PLIST_CONTENT" | head -30
    echo "[install-reap] ... (showing first 30 lines)"
    echo "[install-reap]"
    echo "[install-reap] After install, run:"
    echo "[install-reap]   launchctl start com.chump.reap-stale-leases"
    exit 0
fi

# Create LaunchAgents directory if needed
mkdir -p "$HOME/Library/LaunchAgents"

# Write the plist
echo "$PLIST_CONTENT" > "$PLIST_DEST"
chmod 644 "$PLIST_DEST"

# Unload if already loaded, then load
launchctl unload "$PLIST_DEST" 2>/dev/null || true
launchctl load "$PLIST_DEST"

echo "[install-reap] ✓ Installed and loaded"
echo "[install-reap] Verify: launchctl list | grep chump.reap-stale-leases"
echo "[install-reap] Logs: tail /tmp/chump-reap-stale-leases.out.log"
