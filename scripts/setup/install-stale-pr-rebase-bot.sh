#!/usr/bin/env bash
# scripts/setup/install-stale-pr-rebase-bot.sh — INFRA-2295
#
# Idempotently installs the launchd agent that runs stale-pr-rebase-bot.sh
# every 15 minutes (StartInterval: 900).
#
# Usage:
#   bash scripts/setup/install-stale-pr-rebase-bot.sh        # install + load
#   launchctl unload ~/Library/LaunchAgents/com.chump.stale-pr-rebase-bot.plist
#
# Does NOT start the daemon if already loaded — unloads first to pick up
# any plist changes, then loads fresh (idempotent pattern from INFRA-1779).

set -euo pipefail
# INFRA-8194 (R5 slice 2): the Homebrew prefix comes from the host resolver
# (chump_brew_prefix in scripts/lib/host-paths.sh, the shell mirror of
# chump_provision::brew_prefix; `chump node host --field brew-prefix`), not a
# baked Apple Silicon path.
# shellcheck source=../lib/host-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/host-paths.sh"
BREW_PREFIX="$(chump_brew_prefix)"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Resolve main worktree so the plist path survives worktree reaping (INFRA-451).
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
ROOT="$(resolve_main_worktree "$0")"

LABEL="com.chump.stale-pr-rebase-bot"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
BOT_SCRIPT="$ROOT/scripts/coord/stale-pr-rebase-bot.sh"
LOG_OUT="$HOME/.chump/logs/stale-pr-rebase-bot.out"
LOG_ERR="$HOME/.chump/logs/stale-pr-rebase-bot.err"
INTERVAL_S=900   # 15 minutes

if [[ ! -f "$BOT_SCRIPT" ]]; then
    echo "ERROR: $BOT_SCRIPT not found — INFRA-2295 must land first." >&2
    exit 2
fi
[[ -x "$BOT_SCRIPT" ]] || chmod +x "$BOT_SCRIPT"

mkdir -p "$HOME/Library/LaunchAgents"
mkdir -p "$HOME/.chump/logs"

cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${BOT_SCRIPT}</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${ROOT}</string>
    <key>StartInterval</key>
    <integer>${INTERVAL_S}</integer>
    <!-- RunAtLoad=true: exercises the daemon immediately on install so
         "did the plist land correctly?" is answered at install time, not
         15 minutes later (INFRA-351 lesson). -->
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_OUT}</string>
    <key>StandardErrorPath</key>
    <string>${LOG_ERR}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <!-- gh CLI needs HOME for auth token; PATH for git + python3 (INFRA-802). -->
        <key>HOME</key>
        <string>${HOME}</string>
        <key>PATH</key>
        <string>${BREW_PREFIX}/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
</dict>
</plist>
PLISTEOF

echo "Wrote ${PLIST}"

# Unload first (idempotent — fails silently if not loaded).
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo ""
echo "Loaded launchd job ${LABEL}"
echo "  Cadence: every $((INTERVAL_S / 60)) min (RunAtLoad=true)"
echo "  Stdout:  ${LOG_OUT}"
echo "  Stderr:  ${LOG_ERR}"
echo "  Verify:  launchctl list | grep ${LABEL}"
echo "  Disable: launchctl unload ${PLIST}"
