#!/usr/bin/env bash
# install-fleet-server.sh — INFRA-2175
#
# Install the chump-fleet-server launchd user agent.
# The server listens on 127.0.0.1:7070 and serves the fleet visualization
# REST + WebSocket API (INFRA-2164 sub-slice b).
#
# Usage:
#   scripts/setup/install-fleet-server.sh            # build + install + load
#   scripts/setup/install-fleet-server.sh --uninstall

set -euo pipefail
# INFRA-8194 (R5 slice 2): __BREW_PREFIX__ in the plist template resolves
# through the host resolver (chump_brew_prefix, the shell mirror of
# chump_provision::brew_prefix) instead of a baked Apple Silicon path.
# shellcheck source=../lib/host-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/host-paths.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLIST_SRC="$REPO_ROOT/scripts/setup/launchd/com.chump.fleet-server.plist"
PLIST_DST="$HOME/Library/LaunchAgents/com.chump.fleet-server.plist"
LABEL="com.chump.fleet-server"
LOG_DIR="$HOME/Library/Logs/Chump"
CARGO_BIN="$HOME/.cargo/bin/chump-fleet-server"

if [[ "${1:-}" == "--uninstall" ]]; then
    echo "[install-fleet-server] unloading $LABEL …"
    launchctl unload "$PLIST_DST" 2>/dev/null || true
    rm -f "$PLIST_DST"
    echo "[install-fleet-server] uninstalled."
    exit 0
fi

[[ -f "$PLIST_SRC" ]] || { echo "FAIL: missing $PLIST_SRC" >&2; exit 1; }

# Build the binary if not present or stale.
echo "[install-fleet-server] building chump-fleet-server …"
(cd "$REPO_ROOT" && PATH="$HOME/.cargo/bin:$PATH" cargo build --release -p chump-fleet-server)
cp "$REPO_ROOT/target/release/chump-fleet-server" "$CARGO_BIN"
echo "[install-fleet-server] binary installed at $CARGO_BIN"

mkdir -p "$LOG_DIR" "$HOME/Library/LaunchAgents"

# Substitute placeholders in the plist.
sed \
  -e "s|__BREW_PREFIX__|$(chump_brew_prefix)|g" \
  -e "s|CHUMP_FLEET_SERVER_BIN_PLACEHOLDER|$CARGO_BIN|g" \
  -e "s|CHUMP_REPO_ROOT_PLACEHOLDER|$REPO_ROOT|g" \
  -e "s|CHUMP_LOG_DIR_PLACEHOLDER|$LOG_DIR|g" \
  "$PLIST_SRC" > "$PLIST_DST"

echo "[install-fleet-server] wrote $PLIST_DST"

# Reload.
launchctl unload "$PLIST_DST" 2>/dev/null || true
launchctl load "$PLIST_DST"
echo "[install-fleet-server] loaded $LABEL"

sleep 2
if launchctl list | grep -q "$LABEL"; then
    echo "[install-fleet-server] $LABEL is running on 127.0.0.1:7070"
    echo "[install-fleet-server] logs: tail -F $LOG_DIR/fleet-server.out.log"
else
    echo "[install-fleet-server] WARNING: $LABEL not visible in launchctl list" >&2
    echo "[install-fleet-server] check $LOG_DIR/fleet-server.err.log" >&2
    exit 1
fi
