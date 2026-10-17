#!/usr/bin/env bash
# scripts/setup/install-disk-critical-reactor-launchd.sh — INFRA-2304
#
# Installs the disk-critical-reactor as a long-lived launchd KeepAlive process
# that consumes disk_critical events from ambient.jsonl and triggers reactive
# escalation (reaper at higher tier, operator-recall if reaper insufficient).
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
LABEL="dev.chump.disk-critical-reactor"
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
echo "  status : $(launchctl print "${UID_DOMAIN}/${LABEL}" 2>/dev/null | grep -E 'state =|last exit code' | head -2)"
echo
echo "Verify with:"
echo "  tail -F /tmp/chump-disk-critical-reactor.out.log"
echo
echo "Emit a synthetic disk_critical to test (will run real reaper if disk is tight):"
echo '  printf "{\"ts\":\"%s\",\"kind\":\"disk_critical\",\"reaper\":\"test\"}\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> .chump-locks/ambient.jsonl'
