#!/usr/bin/env bash
# install-auto-arm-sweeper-launchd.sh — INFRA-382
#
# Install a launchd plist that runs scripts/ops/auto-arm-sweeper.sh
# (INFRA-374, shipped in PR #985) every 30 minutes. Without a
# scheduled run, the sweeper never executes — and the lost-auto-merge
# class of stuck PRs sits forever.
#
# Usage:
#   bash scripts/setup/install-auto-arm-sweeper-launchd.sh   # install + load
#   launchctl unload ~/Library/LaunchAgents/dev.chump.auto-arm-sweeper.plist
#                                                            # to stop
#
# Env knobs (read at install time):
#   AUTO_ARM_INTERVAL_MIN — default 30 (min 5 — macOS coalesces under that)

set -euo pipefail
# INFRA-8194 (R5 slice 2): the Homebrew prefix comes from the host resolver
# (chump_brew_prefix in scripts/lib/host-paths.sh, the shell mirror of
# chump_provision::brew_prefix; `chump node host --field brew-prefix`), not a
# baked Apple Silicon path.
# shellcheck source=../lib/host-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/host-paths.sh"
BREW_PREFIX="$(chump_brew_prefix)"
# INFRA-451: resolve to the *main* worktree (not a linked worktree this
# install script may be running from), so the plist absolute path survives
# worktree reaping.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
ROOT="$(resolve_main_worktree "$0")"

INTERVAL_MIN="${AUTO_ARM_INTERVAL_MIN:-30}"
if [[ "$INTERVAL_MIN" -lt 5 ]]; then
    echo "WARN: AUTO_ARM_INTERVAL_MIN=$INTERVAL_MIN is below 5; clamping to 5"
    INTERVAL_MIN=5
fi
INTERVAL_S=$((INTERVAL_MIN * 60))

LABEL="dev.chump.auto-arm-sweeper"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
SCRIPT="$ROOT/scripts/ops/auto-arm-sweeper.sh"
LOG_OUT="/tmp/chump-auto-arm-sweeper.out.log"
LOG_ERR="/tmp/chump-auto-arm-sweeper.err.log"

if [[ ! -f "$SCRIPT" ]]; then
    echo "ERROR: $SCRIPT not found — INFRA-374 must land first" >&2
    exit 2
fi
if [[ ! -x "$SCRIPT" ]]; then
    chmod +x "$SCRIPT"
fi

mkdir -p "$HOME/Library/LaunchAgents"

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
        <string>${SCRIPT}</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${ROOT}</string>
    <key>StartInterval</key>
    <integer>${INTERVAL_S}</integer>
    <!-- RunAtLoad=true so reload immediately exercises the sweeper —
         INFRA-351 lesson: macOS launchd jobs gated by StartInterval
         drop ticks during sleep; RunAtLoad=true at least catches the
         "did the install work?" check at install time. -->
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_OUT}</string>
    <key>StandardErrorPath</key>
    <string>${LOG_ERR}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <!-- gh CLI needs HOME for auth token, PATH for git/python3 (INFRA-802). -->
        <key>HOME</key>
        <string>${HOME}</string>
        <key>PATH</key>
        <string>${BREW_PREFIX}/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
</dict>
</plist>
PLISTEOF

echo "Wrote ${PLIST}"

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo ""
echo "✓ Loaded launchd job ${LABEL}"
echo "  Cadence: every ${INTERVAL_MIN} min (RunAtLoad=true)"
echo "  Stdout:  ${LOG_OUT}"
echo "  Stderr:  ${LOG_ERR}"
echo "  Verify:  launchctl list | grep ${LABEL}"
echo "  Disable: launchctl unload ${PLIST}"
