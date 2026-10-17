#!/usr/bin/env bash
# install-transient-retrigger-launchd.sh — INFRA-1899
#
# Idempotent installer for the transient-retrigger launchd agent. The
# daemon scans open PRs every 5 minutes for known-transient CI failure
# patterns (audit-cancel, checkout auth race, flake-rerun exhaustion,
# network blips) and pushes an empty commit to force a fresh CI run,
# capped at 2 retries per PR per 6 hours. Retires the operator
# hand-empty-commit workaround.
#
# Usage : scripts/setup/install-transient-retrigger-launchd.sh
# Verify: launchctl print "gui/$(id -u)/com.chump.transient-retrigger"
# Logs  : /tmp/chump-transient-retrigger.{out,err}.log
# Unload: launchctl bootout "gui/$(id -u)/com.chump.transient-retrigger"
# Bypass: set CHUMP_TRANSIENT_RETRIGGER_DISABLED=1 in the operator env
set -euo pipefail
# INFRA-8194 (R5 slice 2): the Homebrew prefix comes from the host resolver
# (chump_brew_prefix in scripts/lib/host-paths.sh, the shell mirror of
# chump_provision::brew_prefix; `chump node host --field brew-prefix`), not a
# baked Apple Silicon path.
# shellcheck source=../lib/host-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/host-paths.sh"
BREW_PREFIX="$(chump_brew_prefix)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# INFRA-2365: resolve to the MAIN worktree, not whatever worktree this
# installer runs from (see scripts/lib/resolve-main-worktree.sh; INFRA-451
# class — a baked-in linked/temp worktree path dies with exit=78 once the
# worktree is reaped).
# shellcheck source=../lib/resolve-main-worktree.sh
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
REPO_ROOT="$(resolve_main_worktree "${BASH_SOURCE[0]}")" || {
    echo "FAIL: could not resolve main worktree from ${BASH_SOURCE[0]}" >&2
    exit 1
}
DAEMON_SCRIPT="$REPO_ROOT/scripts/coord/transient-retrigger.sh"
PLIST_LABEL="com.chump.transient-retrigger"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"

if [[ ! -x "$DAEMON_SCRIPT" ]]; then
    echo "ERROR: daemon script not found or not executable: $DAEMON_SCRIPT" >&2
    exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents"

cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_LABEL}</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>-lc</string>
        <string>${DAEMON_SCRIPT}</string>
    </array>

    <key>WorkingDirectory</key>
    <string>${REPO_ROOT}</string>

    <!-- Fire every 5 minutes; daemon runs one cycle per invocation. -->
    <key>StartInterval</key>
    <integer>300</integer>

    <key>RunAtLoad</key>
    <true/>

    <key>StandardOutPath</key>
    <string>/tmp/chump-transient-retrigger.out.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/chump-transient-retrigger.err.log</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:${BREW_PREFIX}/bin:${BREW_PREFIX}/sbin</string>
    </dict>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)/${PLIST_LABEL}" 2>/dev/null || \
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || \
    launchctl load "$PLIST_PATH"

echo "[install-transient-retrigger] installed: $PLIST_PATH"
echo "[install-transient-retrigger] verify : launchctl print \"gui/\$(id -u)/${PLIST_LABEL}\""
echo "[install-transient-retrigger] logs   : /tmp/chump-transient-retrigger.{out,err}.log"
echo "[install-transient-retrigger] unload : launchctl bootout \"gui/\$(id -u)/${PLIST_LABEL}\""
echo "[install-transient-retrigger] bypass : export CHUMP_TRANSIENT_RETRIGGER_DISABLED=1"
echo "[install-transient-retrigger] per-pr : add the 'no-auto-retrigger' label to opt out a specific PR"
