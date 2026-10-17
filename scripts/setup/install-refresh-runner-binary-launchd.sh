#!/usr/bin/env bash
# scripts/setup/install-refresh-runner-binary-launchd.sh — CREDIBLE-076 / INFRA-2007
#
# Install TWO launchd agents (hybrid W-002 fix):
#
#   1. com.chump.refresh-runner-binary          — 5-min cron FALLBACK
#      Runs refresh-runner-binary.sh every 5 minutes (was 30min before INFRA-2007).
#      This is the safety net: catches any event-driven miss (daemon restart gap,
#      fswatch latency spike, ambient.jsonl rotation, etc.).
#
#   2. com.chump.binary-refresh-event-watcher   — event-driven PRIMARY (INFRA-2007)
#      Runs binary-refresh-event-watcher.sh as a KeepAlive daemon. Watches
#      ambient.jsonl for kind=binary_main_updated and triggers rebuild within
#      CHUMP_BINARY_EVENT_RATE_LIMIT_S (default 60s) of merge. Eliminates the
#      W-002 class on the happy path.
#
# Usage:
#   bash scripts/setup/install-refresh-runner-binary-launchd.sh            # install + load both
#   bash scripts/setup/install-refresh-runner-binary-launchd.sh --uninstall # unload + remove both

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

# INFRA-2365: resolve to the MAIN worktree, not whatever worktree this
# installer happens to run from. Installing from a linked/temp worktree
# (e.g. a claimed gap worktree under .claude/worktrees/ or /tmp) bakes that
# worktree's path into ProgramArguments/WorkingDirectory. Once the worktree
# is reaped or the session ends, launchd can't find the script and the job
# fails with exit=78 ("script path gone") forever — the root cause behind
# the refresh-runner-binary daemon going silently stale (see INFRA-451 for
# the same class fixed in install-farmer-launchd.sh).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/resolve-main-worktree.sh
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
REPO_ROOT="$(resolve_main_worktree "${BASH_SOURCE[0]}")" || {
    echo "FAIL: could not resolve main worktree from ${BASH_SOURCE[0]}" >&2
    exit 1
}
REFRESH_SCRIPT="$REPO_ROOT/scripts/setup/refresh-runner-binary.sh"
WATCHER_SCRIPT="$REPO_ROOT/scripts/coord/binary-refresh-event-watcher.sh"
LOG_BASE="$REPO_ROOT/.chump-locks/binary-refresh-logs"

CRON_PLIST_NAME="com.chump.refresh-runner-binary"
WATCHER_PLIST_NAME="com.chump.binary-refresh-event-watcher"
CRON_PLIST_PATH="$HOME/Library/LaunchAgents/${CRON_PLIST_NAME}.plist"
WATCHER_PLIST_PATH="$HOME/Library/LaunchAgents/${WATCHER_PLIST_NAME}.plist"

# Uninstall mode
if [[ "${1:-}" == "--uninstall" ]]; then
    for _plist in "$CRON_PLIST_PATH" "$WATCHER_PLIST_PATH"; do
        if [[ -f "$_plist" ]]; then
            launchctl unload "$_plist" 2>/dev/null || true
            rm -f "$_plist"
            echo "uninstalled $(basename "$_plist" .plist)"
        else
            echo "$(basename "$_plist" .plist) not installed"
        fi
    done
    exit 0
fi

if [[ ! -x "$REFRESH_SCRIPT" ]]; then
    echo "FAIL: $REFRESH_SCRIPT not found or not executable"
    exit 1
fi

if [[ ! -x "$WATCHER_SCRIPT" ]]; then
    echo "FAIL: $WATCHER_SCRIPT not found or not executable"
    exit 1
fi

mkdir -p "$(dirname "$CRON_PLIST_PATH")"
mkdir -p "$LOG_BASE"

# Resolve full PATH for the launchd env (bash + git + cargo discoverable)
LAUNCHD_PATH="$HOME/.cargo/bin:$HOME/.rustup/toolchains/stable-aarch64-apple-darwin/bin:$HOME/.local/bin:${BREW_PREFIX}/bin:/usr/local/bin:/usr/bin:/bin"

# ── 1. Cron fallback: every 5 minutes ────────────────────────────────────────
cat > "$CRON_PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${CRON_PLIST_NAME}</string>

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
    <string>${LOG_BASE}/launchd-cron-stdout.log</string>

    <key>StandardErrorPath</key>
    <string>${LOG_BASE}/launchd-cron-stderr.log</string>

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
echo "wrote $CRON_PLIST_PATH (5-min cron fallback)"

# ── 2. Event-driven watcher: KeepAlive daemon ────────────────────────────────
cat > "$WATCHER_PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${WATCHER_PLIST_NAME}</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${WATCHER_SCRIPT}</string>
    </array>

    <key>KeepAlive</key>
    <true/>

    <key>RunAtLoad</key>
    <true/>

    <key>WorkingDirectory</key>
    <string>${REPO_ROOT}</string>

    <key>StandardOutPath</key>
    <string>${LOG_BASE}/launchd-watcher-stdout.log</string>

    <key>StandardErrorPath</key>
    <string>${LOG_BASE}/launchd-watcher-stderr.log</string>

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

    <key>ThrottleInterval</key>
    <integer>10</integer>
</dict>
</plist>
EOF
echo "wrote $WATCHER_PLIST_PATH (event-driven KeepAlive daemon)"

# ── Load both ─────────────────────────────────────────────────────────────────
for _plist in "$CRON_PLIST_PATH" "$WATCHER_PLIST_PATH"; do
    launchctl unload "$_plist" 2>/dev/null || true
    launchctl load "$_plist"
    echo "loaded $(basename "$_plist" .plist)"
done

echo ""
echo "INFRA-2007 hybrid install complete:"
echo "  Primary  — event-driven (binary_main_updated → rebuild within 60s)"
echo "  Fallback — 5-min cron (safety net for daemon restart gaps)"
echo "  Logs: $LOG_BASE/"
