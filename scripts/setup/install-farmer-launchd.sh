#!/usr/bin/env bash
# install-farmer-launchd.sh — RESILIENT-068: install the dev.chump.farmer
# un-killable control-plane tender as a launchd agent.
#
# Idempotent: safe to re-run.
# Disable:    launchctl unload ~/Library/LaunchAgents/dev.chump.farmer.plist
# Force fire: launchctl start dev.chump.farmer
# Dry-run:    FARMER_DRY_RUN=1 bash scripts/coord/farmer.sh
set -euo pipefail
# INFRA-8194 (R5 slice 2): the tracked plist is a placeholder template
# (__REPO_ROOT__ __HOME__ __BIN_DIR__ __BREW_PREFIX__), rendered for THIS host by
# chump_render_template (typed `chump node render-unit`, sed mirror fallback).
# shellcheck source=../lib/host-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/host-paths.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# resolve-main-worktree: resolves linked worktrees back to main repo root
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
REPO="$(resolve_main_worktree "$0")"
PLIST_SRC="$REPO/launchd/dev.chump.farmer.plist"
LABEL="dev.chump.farmer"
DEST="$HOME/Library/LaunchAgents/${LABEL}.plist"

echo "[install-farmer] repo=$REPO"
echo "[install-farmer] dest=$DEST"

mkdir -p "$HOME/Library/LaunchAgents"

# Write the plist with real paths substituted
chump_render_template "$PLIST_SRC" "$DEST" "$REPO"

echo "[install-farmer] plist written"

# Unload first (idempotent — ignore error if not loaded)
launchctl unload "$DEST" 2>/dev/null || true

# Load
launchctl load "$DEST"

echo "[install-farmer] loaded dev.chump.farmer"
echo ""
echo "Status:"
launchctl list | grep -F "$LABEL" || echo "  (not yet visible — may take a moment)"
echo ""
echo "Logs:      tail -F /tmp/chump-farmer.out.log"
echo "Errors:    tail -F /tmp/chump-farmer.err.log"
echo "Heartbeat: cat $REPO/.chump/farmer-heartbeat"
echo "Dry-run:   FARMER_DRY_RUN=1 bash $REPO/scripts/coord/farmer.sh"
echo ""
echo "Force fire: launchctl start $LABEL"
echo "Uninstall:  launchctl unload $DEST && rm $DEST"
