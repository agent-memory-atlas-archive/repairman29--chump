#!/usr/bin/env bash
# scripts/setup/install-refresh-almanac-binary-launchd.sh — INFRA-3639
#
# Installs a launchd agent that runs scripts/setup/refresh-almanac-binary.sh
# every 5 minutes so a vanished almanac binary or an empty/stale index
# self-heals without a human noticing first. Almanac twin of
# scripts/setup/install-refresh-runner-binary-launchd.sh (CREDIBLE-076).
#
# Usage:
#   bash scripts/setup/install-refresh-almanac-binary-launchd.sh             # install + load
#   bash scripts/setup/install-refresh-almanac-binary-launchd.sh --uninstall # unload + remove

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/resolve-main-worktree.sh
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
REPO_ROOT="$(resolve_main_worktree "${BASH_SOURCE[0]}")" || {
    echo "FAIL: could not resolve main worktree from ${BASH_SOURCE[0]}" >&2
    exit 1
}
REFRESH_SCRIPT="$REPO_ROOT/scripts/setup/refresh-almanac-binary.sh"
LOG_BASE="$REPO_ROOT/.chump-locks/almanac-refresh-logs"

PLIST_NAME="com.chump.refresh-almanac-binary"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_NAME}.plist"

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

if [[ ! -x "$REFRESH_SCRIPT" ]]; then
    echo "FAIL: $REFRESH_SCRIPT not found or not executable"
    exit 1
fi

mkdir -p "$(dirname "$PLIST_PATH")" "$LOG_BASE"

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
        <string>${REFRESH_SCRIPT}</string>
    </array>

    <key>StartInterval</key>
    <integer>300</integer>

    <key>RunAtLoad</key>
    <true/>

    <key>WorkingDirectory</key>
    <string>${REPO_ROOT}</string>

    <key>StandardOutPath</key>
    <string>${LOG_BASE}/launchd-stdout.log</string>

    <key>StandardErrorPath</key>
    <string>${LOG_BASE}/launchd-stderr.log</string>

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
echo "wrote $PLIST_PATH (5-min almanac self-heal cron)"

launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"
echo "loaded $PLIST_NAME"
echo "logs: $LOG_BASE/"
