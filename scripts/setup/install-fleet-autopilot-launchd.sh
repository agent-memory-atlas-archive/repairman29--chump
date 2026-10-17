#!/usr/bin/env bash
# scripts/setup/install-fleet-autopilot-launchd.sh — META-090
#
# Install com.chump.fleet-autopilot launchd agent that fires the autopilot
# master heartbeat every 5 minutes. The heartbeat is a thin liveness check
# that reports daemon-set health and emits autopilot_partial if anything
# slipped (e.g. another launchd agent was unloaded externally).
#
# This installer is invoked by `bash scripts/coord/fleet-autopilot.sh start`
# as the master heartbeat layer. Operator can also run it standalone.
#
# Usage:
#   bash scripts/setup/install-fleet-autopilot-launchd.sh             # install + load
#   bash scripts/setup/install-fleet-autopilot-launchd.sh --uninstall

set -euo pipefail
# INFRA-8194 (R5 slice 2): the Homebrew prefix comes from the host resolver
# (chump_brew_prefix in scripts/lib/host-paths.sh, the shell mirror of
# chump_provision::brew_prefix; `chump node host --field brew-prefix`), not a
# baked Apple Silicon path.
# shellcheck source=../lib/host-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/host-paths.sh"
BREW_PREFIX="$(chump_brew_prefix)"

case "$(uname -s)" in
  Darwin) ;;
  *) echo "skip: not macOS"; exit 0 ;;
esac

# INFRA-2365: resolve to the MAIN worktree, not the worktree this installer
# happens to run from — see install-refresh-runner-binary-launchd.sh for the
# full rationale (baking a linked/temp worktree path in causes exit=78 once
# that worktree is reaped).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/resolve-main-worktree.sh
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
REPO_ROOT="$(resolve_main_worktree "${BASH_SOURCE[0]}")" || {
    echo "FAIL: could not resolve main worktree from ${BASH_SOURCE[0]}" >&2
    exit 1
}
PLIST_NAME="com.chump.fleet-autopilot"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_NAME}.plist"
AUTOPILOT_SCRIPT="$REPO_ROOT/scripts/coord/fleet-autopilot.sh"
LOG_BASE="$REPO_ROOT/.chump-locks/autopilot-logs"

if [[ "${1:-}" == "--uninstall" ]]; then
    if [[ -f "$PLIST_PATH" ]]; then
        launchctl unload "$PLIST_PATH" 2>/dev/null || true
        rm -f "$PLIST_PATH"
        echo "uninstalled $PLIST_NAME"
    else
        echo "$PLIST_NAME not installed"
    fi
    exit 0
fi

if [[ ! -x "$AUTOPILOT_SCRIPT" ]]; then
    echo "FAIL: $AUTOPILOT_SCRIPT not found or not executable"
    exit 1
fi

mkdir -p "$(dirname "$PLIST_PATH")"
mkdir -p "$LOG_BASE"

LAUNCHD_PATH="$HOME/.cargo/bin:$HOME/.rustup/toolchains/stable-aarch64-apple-darwin/bin:$HOME/.local/bin:${BREW_PREFIX}/bin:/usr/local/bin:/usr/bin:/bin"

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_NAME}</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${AUTOPILOT_SCRIPT}</string>
        <string>heartbeat</string>
    </array>

    <key>StartInterval</key>
    <integer>300</integer>

    <key>RunAtLoad</key>
    <true/>

    <key>WorkingDirectory</key>
    <string>${REPO_ROOT}</string>

    <key>StandardOutPath</key>
    <string>${LOG_BASE}/heartbeat-stdout.log</string>

    <key>StandardErrorPath</key>
    <string>${LOG_BASE}/heartbeat-stderr.log</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>${LAUNCHD_PATH}</string>
        <key>HOME</key>
        <string>${HOME}</string>
        <key>CHUMP_REPO_ROOT</key>
        <string>${REPO_ROOT}</string>
    </dict>

    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
EOF

echo "wrote $PLIST_PATH"

# Reload (unload first in case of upgrade)
launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"
echo "loaded $PLIST_NAME"
echo "heartbeat fires every 5 minutes (StartInterval=300) + at load"
echo "logs: $LOG_BASE/heartbeat-{stdout,stderr}.log"
