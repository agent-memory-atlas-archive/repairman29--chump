#!/usr/bin/env bash
# install-chump-fleet-daemon.sh — INFRA-964
#
# Install the chump fleet daemon launchd job. The daemon is the load-bearing
# replacement for the Claude-Code-hosted scheduled-tasks MCP path; once
# installed, the OS keeps it alive whether or not Claude Code is running.
#
# Usage:
#   scripts/setup/install-chump-fleet-daemon.sh           # install + load
#   scripts/setup/install-chump-fleet-daemon.sh --uninstall

set -euo pipefail
# INFRA-8194 (R5 slice 2): the tracked plist is a placeholder template
# (__REPO_ROOT__ __HOME__ __BIN_DIR__ __BREW_PREFIX__), rendered for THIS host by
# chump_render_template (typed `chump node render-unit`, sed mirror fallback).
# shellcheck source=../lib/host-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/host-paths.sh"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLIST_SRC="$REPO_ROOT/launchd/com.chump.fleet-daemon.plist"
PLIST_DST="$HOME/Library/LaunchAgents/com.chump.fleet-daemon.plist"
LABEL="com.chump.fleet-daemon"

if [[ "${1:-}" == "--uninstall" ]]; then
  echo "[install-chump-fleet-daemon] unloading $LABEL …"
  launchctl unload "$PLIST_DST" 2>/dev/null || true
  rm -f "$PLIST_DST"
  echo "[install-chump-fleet-daemon] uninstalled."
  exit 0
fi

[[ -f "$PLIST_SRC" ]] || { echo "FAIL: missing $PLIST_SRC"; exit 1; }

# Resolve runtime paths and substitute them into the plist before install.
mkdir -p "$HOME/Library/LaunchAgents"

# Substitute placeholders.
chump_render_template "$PLIST_SRC" "$PLIST_DST" "$REPO_ROOT"

echo "[install-chump-fleet-daemon] wrote $PLIST_DST"

# Re-load (unload first in case it's already there).
launchctl unload "$PLIST_DST" 2>/dev/null || true
launchctl load "$PLIST_DST"
echo "[install-chump-fleet-daemon] loaded $LABEL"

# Smoke check.
sleep 2
if launchctl list | grep -q "$LABEL"; then
  echo "[install-chump-fleet-daemon] ✓ $LABEL is running"
  echo "[install-chump-fleet-daemon] tail -F /tmp/chump-fleet-daemon.{out,err}.log to watch"
  echo "[install-chump-fleet-daemon] tail -F .chump-locks/ambient.jsonl | grep daemon_tick to verify firing"
else
  echo "[install-chump-fleet-daemon] WARNING: $LABEL not visible in launchctl list" >&2
  echo "[install-chump-fleet-daemon] check /tmp/chump-fleet-daemon.err.log" >&2
  exit 1
fi
