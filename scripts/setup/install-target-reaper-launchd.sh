#!/usr/bin/env bash
# scripts/setup/install-target-reaper-launchd.sh — INFRA-1349
#
# Installs dev.chump.target-reaper.plist into the user's launchd. Idempotent:
# unloads any existing copy first, then loads the current plist. Runs the
# script every 30 min; the script itself self-throttles based on disk pressure.

set -uo pipefail
# INFRA-8194 (R5 slice 2): the tracked plist is a placeholder template
# (__REPO_ROOT__ __HOME__ __BREW_PREFIX__); render it for THIS host
# (chump_render_template: typed `chump node render-unit`, sed mirror fallback)
# instead of copying a file baked for one Mac.
# shellcheck source=../lib/host-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/host-paths.sh"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SRC="$REPO_ROOT/scripts/plists/dev.chump.target-reaper.plist"
DST="$HOME/Library/LaunchAgents/dev.chump.target-reaper.plist"

[ -f "$SRC" ] || { echo "missing source plist: $SRC" >&2; exit 1; }
[ -x "$REPO_ROOT/scripts/coord/target-dir-reaper.sh" ] || \
  { echo "target-dir-reaper.sh not executable" >&2; exit 1; }

mkdir -p "$(dirname "$DST")"
launchctl unload "$DST" 2>/dev/null || true
chump_render_template "$SRC" "$DST" "$REPO_ROOT"
launchctl load "$DST" || { echo "launchctl load failed" >&2; exit 1; }
echo "installed: $DST"
echo "running every 30 min. Logs: /tmp/chump-target-reaper.log"
echo "uninstall: launchctl unload $DST && rm $DST"
