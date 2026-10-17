#!/usr/bin/env bash
# scripts/setup/install-daemon-silence-monitor-launchd.sh — INFRA-2352
#
# Installs the daemon-silence-monitor as a 5-min launchd interval process.
# Reads scripts/coord/daemon-expectations.yaml, counts each daemon's
# expected ambient kinds over the last hour, and emits kind=daemon_silent
# when a daemon is LOADED + emitting nothing + has work to do.
#
# Idempotent: if already loaded, bootout-then-bootstrap to pick up plist changes.

set -euo pipefail
# INFRA-8194 (R5 slice 2): the tracked plist is a placeholder template
# (__REPO_ROOT__ __HOME__ __BREW_PREFIX__); render it for THIS host
# (chump_render_template: typed `chump node render-unit`, sed mirror fallback)
# instead of copying a file baked for one Mac.
# shellcheck source=../lib/host-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/host-paths.sh"

# shellcheck source=../lib/resolve-main-worktree.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/resolve-main-worktree.sh"
REPO_ROOT="${CHUMP_REPO:-$(resolve_main_worktree "$0")}"
LABEL="dev.chump.daemon-silence-monitor"
SRC_PLIST="$REPO_ROOT/scripts/plists/${LABEL}.plist"
DST_PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
UID_DOMAIN="gui/$(id -u)"

if [[ ! -f "$SRC_PLIST" ]]; then
  echo "ERROR: source plist not found at $SRC_PLIST" >&2
  exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents"
chump_render_template "$SRC_PLIST" "$DST_PLIST" "$REPO_ROOT"
chmod 644 "$DST_PLIST"

# Bootout if currently loaded (idempotent reload).
if launchctl print "${UID_DOMAIN}/${LABEL}" >/dev/null 2>&1; then
  launchctl bootout "${UID_DOMAIN}/${LABEL}" 2>/dev/null || true
fi

# Bootstrap.
launchctl bootstrap "$UID_DOMAIN" "$DST_PLIST"
launchctl enable "${UID_DOMAIN}/${LABEL}"
launchctl kickstart "${UID_DOMAIN}/${LABEL}" 2>/dev/null || true

echo "✓ installed $LABEL"
echo "  plist  : $DST_PLIST"
echo "  cadence: every 5 min"
echo "  reads  : scripts/coord/daemon-expectations.yaml"
echo "  emits  : kind=daemon_silent (on LOADED+0-emit+eligible) and kind=daemon_silence_monitor_tick (per cycle)"
echo
echo "Verify with:"
echo "  tail -F /tmp/chump-daemon-silence-monitor.out.log"
echo "  grep daemon_silent .chump-locks/ambient.jsonl | tail -5"
