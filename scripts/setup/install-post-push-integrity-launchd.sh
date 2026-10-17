#!/usr/bin/env bash
# scripts/setup/install-post-push-integrity-launchd.sh — INFRA-2026
#
# Installs the post-push PR integrity watch daemon (60s cadence).
# Pairs with scripts/coord/post-push-integrity-watch.sh.
#
# Motivation: 2026-05-25T19:00Z — wizard pushed stale main HEAD to a branch
# via force-with-lease from a stale worktree; GitHub auto-closed PR #2582.
# Manual recovery via git reflog + gh pr reopen worked but cost time.
# This daemon catches that class of incident within 60s and auto-recovers.
#
# Usage:
#   bash scripts/setup/install-post-push-integrity-launchd.sh   # install + load
#   launchctl unload ~/Library/LaunchAgents/com.chump.post-push-integrity.plist  # stop
#
# Idempotent: unload + reload on reinstall.

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

LABEL="com.chump.post-push-integrity"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
SCRIPT="$ROOT/scripts/coord/post-push-integrity-watch.sh"
LOG="$ROOT/.chump-locks/post-push-integrity.log"

if [[ ! -f "$SCRIPT" ]]; then
    echo "ERROR: $SCRIPT not found — INFRA-2026 daemon script missing" >&2
    exit 2
fi
if [[ ! -x "$SCRIPT" ]]; then
    chmod +x "$SCRIPT"
fi

mkdir -p "$HOME/Library/LaunchAgents"
mkdir -p "$(dirname "$LOG")"

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
    <integer>60</integer>
    <!-- RunAtLoad=true exercises the daemon immediately at install time
         so operator can confirm it wired up (INFRA-351 lesson). -->
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG}</string>
    <key>StandardErrorPath</key>
    <string>${LOG}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <!-- gh CLI needs HOME for auth token; PATH for git+gh (INFRA-802). -->
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
launchctl load -w "$PLIST"

echo ""
echo "[install-post-push-integrity] loaded launchd job ${LABEL}"
echo "  Cadence: every 60s (RunAtLoad=true)"
echo "  Log:     tail -f ${LOG}"
echo "  Verify:  launchctl list | grep ${LABEL}"
echo "  Disable: launchctl unload ${PLIST}"
echo "  Pairs with: scripts/coord/post-push-integrity-watch.sh"
