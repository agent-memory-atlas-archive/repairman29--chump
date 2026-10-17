#!/usr/bin/env bash
# install-gh-token-rotate-launchd.sh — INFRA-1361
# Installs the GitHub App installation-token rotator LaunchAgent.
# Runs `chump gh-token rotate` every 50 minutes (StartInterval=3000s).
#
# Safe to install before GitHub App configuration exists — the rotate
# subcommand exits 0 silently when ~/.chump/github_apps.toml is absent.
#
# After install:
#   launchctl list | grep chump.gh-token-rotate
#
# Manual run:
#   launchctl start com.chump.gh-token-rotate
#   tail ~/Library/Logs/chump-gh-token-rotate.log
#
# Uninstall:
#   launchctl unload ~/Library/LaunchAgents/com.chump.gh-token-rotate.plist
#   rm ~/Library/LaunchAgents/com.chump.gh-token-rotate.plist
#
# Linux operators: use cron instead —
#   */50 * * * * /path/to/chump gh-token rotate >> ~/Library/Logs/chump-gh-token-rotate.log 2>&1

set -euo pipefail
# INFRA-8194 (R5 slice 2): the Homebrew prefix comes from the host resolver
# (chump_brew_prefix in scripts/lib/host-paths.sh, the shell mirror of
# chump_provision::brew_prefix; `chump node host --field brew-prefix`), not a
# baked Apple Silicon path.
# shellcheck source=../lib/host-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/host-paths.sh"
BREW_PREFIX="$(chump_brew_prefix)"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/resolve-main-worktree.sh
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
REPO="$(resolve_main_worktree "$0")"

PLIST_NAME="com.chump.gh-token-rotate.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"
LOG_FILE="$HOME/Library/Logs/chump-gh-token-rotate.log"
PATH_VALUE="/usr/local/bin:${BREW_PREFIX}/bin:${BREW_PREFIX}/sbin:${HOME}/.cargo/bin:/usr/bin:/bin"

# Locate the chump binary (prefer release build in the repo, fall back to PATH).
CHUMP_BIN="${CHUMP_BIN:-}"
if [[ -z "$CHUMP_BIN" ]]; then
    if [[ -x "$REPO/target/release/chump" ]]; then
        CHUMP_BIN="$REPO/target/release/chump"
    else
        CHUMP_BIN="$(command -v chump 2>/dev/null || true)"
        if [[ -z "$CHUMP_BIN" ]]; then
            echo "ERROR: chump binary not found. Build with 'cargo build --release' first," >&2
            echo "       or set CHUMP_BIN=/path/to/chump before running this script." >&2
            exit 1
        fi
    fi
fi

mkdir -p "$HOME/Library/LaunchAgents"
mkdir -p "$(dirname "$LOG_FILE")"

cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.chump.gh-token-rotate</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>${CHUMP_BIN} gh-token rotate</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${REPO}</string>
  <key>StartInterval</key>
  <integer>3000</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${LOG_FILE}</string>
  <key>StandardErrorPath</key>
  <string>${LOG_FILE}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>${HOME}</string>
    <key>PATH</key>
    <string>${PATH_VALUE}</string>
  </dict>
  <key>ThrottleInterval</key>
  <integer>60</integer>
</dict>
</plist>
EOF

chmod 644 "$DEST"

# Reload: unload existing (ignore errors) then bootstrap fresh.
launchctl bootout "gui/$(id -u)" "$DEST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$DEST"

echo "Installed: $DEST"
echo "  binary:  $CHUMP_BIN"
echo "  log:     $LOG_FILE"
echo "  cadence: every 50 minutes (StartInterval=3000s)"
echo "  verify:  launchctl list | grep chump.gh-token-rotate"
echo "  on-demand: launchctl start com.chump.gh-token-rotate"
