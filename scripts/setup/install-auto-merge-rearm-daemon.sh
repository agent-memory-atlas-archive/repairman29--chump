#!/usr/bin/env bash
# install-auto-merge-rearm-daemon.sh — INFRA-2309
#
# Install a launchd plist that runs scripts/coord/auto-merge-rearm-daemon.sh
# tick every CHUMP_AUTO_MERGE_REARM_INTERVAL_S (default 60s).
#
# The daemon re-arms auto-merge on any CLEAN PR where auto-merge was
# disarmed by a force-push or rebase. Without it, "passed QA but didn't ship"
# happens because GitHub clears autoMergeRequest on branch updates.
#
# Usage:
#   bash scripts/setup/install-auto-merge-rearm-daemon.sh   # install + load
#   launchctl unload ~/Library/LaunchAgents/dev.chump.auto-merge-rearm.plist
#
# Env knobs (read at install time):
#   CHUMP_AUTO_MERGE_REARM_INTERVAL_S  — default 60 (min 30)
#   CHUMP_AUTO_MERGE_REARM_DRY_RUN     — set to 1 to install in dry-run mode
#   CHUMP_AUTO_MERGE_REARM_OPEN        — set to 1 to bypass fix-class allowlist

set -euo pipefail
# INFRA-8194 (R5 slice 2): the Homebrew prefix comes from the host resolver
# (chump_brew_prefix in scripts/lib/host-paths.sh, the shell mirror of
# chump_provision::brew_prefix; `chump node host --field brew-prefix`), not a
# baked Apple Silicon path.
# shellcheck source=../lib/host-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/host-paths.sh"
BREW_PREFIX="$(chump_brew_prefix)"

# Use resolve-main-worktree so the plist path survives worktree reaping (INFRA-451).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "$SCRIPT_DIR/../lib/resolve-main-worktree.sh" ]]; then
    # shellcheck source=scripts/lib/resolve-main-worktree.sh
    source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
    ROOT="$(resolve_main_worktree "$0")"
else
    # Fallback: resolve two levels up (works from main worktree installs).
    ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi

INTERVAL_S="${CHUMP_AUTO_MERGE_REARM_INTERVAL_S:-60}"
if [[ "$INTERVAL_S" -lt 30 ]]; then
    echo "WARN: CHUMP_AUTO_MERGE_REARM_INTERVAL_S=$INTERVAL_S is below 30; clamping to 30"
    INTERVAL_S=30
fi

LABEL="dev.chump.auto-merge-rearm"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
SCRIPT="$ROOT/scripts/coord/auto-merge-rearm-daemon.sh"
LOG_OUT="/tmp/chump-auto-merge-rearm.out.log"
LOG_ERR="/tmp/chump-auto-merge-rearm.err.log"

if [[ ! -f "$SCRIPT" ]]; then
    echo "ERROR: $SCRIPT not found — INFRA-2309 must land first" >&2
    exit 2
fi
if [[ ! -x "$SCRIPT" ]]; then
    chmod +x "$SCRIPT"
fi

mkdir -p "$HOME/Library/LaunchAgents"

# Build optional env var block
DRY_RUN_KEY=""
if [[ -n "${CHUMP_AUTO_MERGE_REARM_DRY_RUN:-}" ]]; then
    DRY_RUN_KEY="        <key>CHUMP_AUTO_MERGE_REARM_DRY_RUN</key>
        <string>1</string>"
fi
OPEN_KEY=""
if [[ -n "${CHUMP_AUTO_MERGE_REARM_OPEN:-}" ]]; then
    OPEN_KEY="        <key>CHUMP_AUTO_MERGE_REARM_OPEN</key>
        <string>1</string>"
fi

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
        <string>tick</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${ROOT}</string>
    <key>StartInterval</key>
    <integer>${INTERVAL_S}</integer>
    <!-- RunAtLoad=true so reload immediately exercises the daemon —
         INFRA-351 lesson: macOS launchd jobs gated by StartInterval
         drop ticks during sleep; RunAtLoad=true catches "did install work?" -->
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
        <key>CHUMP_AUTO_MERGE_REARM_INTERVAL_S</key>
        <string>${INTERVAL_S}</string>
${DRY_RUN_KEY}
${OPEN_KEY}
    </dict>
</dict>
</plist>
PLISTEOF

echo "Wrote ${PLIST}"

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo ""
echo "Loaded launchd job ${LABEL}"
echo "  Cadence:  every ${INTERVAL_S}s (RunAtLoad=true)"
echo "  Stdout:   ${LOG_OUT}"
echo "  Stderr:   ${LOG_ERR}"
echo "  Verify:   launchctl list | grep ${LABEL}"
echo "  Disable:  launchctl unload ${PLIST}"
echo "  Dry-run:  CHUMP_AUTO_MERGE_REARM_DRY_RUN=1 bash $0"
echo "  Open:     CHUMP_AUTO_MERGE_REARM_OPEN=1 bash $0  (skip fix-class filter)"
