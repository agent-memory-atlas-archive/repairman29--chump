#!/usr/bin/env bash
# scripts/setup/install-main-preflight-watchdog-daemon-launchd.sh — INFRA-2397
#
# Idempotently installs the main-preflight-watchdog launchd agent:
#   com.chump.main-preflight-watchdog
#
# This daemon runs scripts/coord/main-preflight-watchdog-daemon.sh every
# CHUMP_MAIN_PREFLIGHT_INTERVAL_S seconds (default 600 = 10 min) against
# a fresh origin/main worktree. It files P0 gaps when preflight gates fail
# on main before any PR inherits the failure.
#
# Unlike trunk-sentinel (which watches ci.yml conclusion on main via gh), this
# daemon runs chump preflight LOCALLY — no gh calls, no GraphQL quota consumed.
#
# Usage:
#   bash scripts/setup/install-main-preflight-watchdog-daemon-launchd.sh
#
# Does NOT start the daemon if already loaded — unloads first to pick up any
# plist changes, then loads fresh (idempotent pattern from INFRA-1779).

set -euo pipefail
# INFRA-8194 (R5 slice 2): the Homebrew prefix comes from the host resolver
# (chump_brew_prefix in scripts/lib/host-paths.sh, the shell mirror of
# chump_provision::brew_prefix; `chump node host --field brew-prefix`), not a
# baked Apple Silicon path.
# shellcheck source=../lib/host-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/host-paths.sh"
BREW_PREFIX="$(chump_brew_prefix)"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
ROOT="$(resolve_main_worktree "$0")"

LABEL="com.chump.main-preflight-watchdog"
PLIST_DEST="$HOME/Library/LaunchAgents/${LABEL}.plist"
DAEMON_SCRIPT="$ROOT/scripts/coord/main-preflight-watchdog-daemon.sh"
LOG_OUT="$HOME/.chump/logs/main-preflight-watchdog.out"
LOG_ERR="$HOME/.chump/logs/main-preflight-watchdog.err"
INTERVAL_S="${CHUMP_MAIN_PREFLIGHT_INTERVAL_S:-600}"

# ── Sanity: daemon script must exist ─────────────────────────────────────────
if [[ ! -f "$DAEMON_SCRIPT" ]]; then
    echo "ERROR: $DAEMON_SCRIPT not found — daemon must land first." >&2
    exit 2
fi
[[ -x "$DAEMON_SCRIPT" ]] || chmod +x "$DAEMON_SCRIPT"

mkdir -p "$HOME/Library/LaunchAgents"
mkdir -p "$HOME/.chump/logs"
mkdir -p "$ROOT/.chump-locks"
mkdir -p "$ROOT/.chump"

# ── Write plist ───────────────────────────────────────────────────────────────
cat > "$PLIST_DEST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${DAEMON_SCRIPT}</string>
        <string>tick</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${ROOT}</string>
    <key>StartInterval</key>
    <integer>${INTERVAL_S}</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_OUT}</string>
    <key>StandardErrorPath</key>
    <string>${LOG_ERR}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>${HOME}</string>
        <key>PATH</key>
        <string>/Users/${USER}/.local/bin:${BREW_PREFIX}/bin:/usr/local/bin:/usr/bin:/bin</string>
        <!-- META-248: explicit absolute path so the daemon does not compute
             it relative to a /tmp worktree under launchd's execution context. -->
        <key>CHUMP_AMBIENT_PATH</key>
        <string>${ROOT}/.chump-locks/ambient.jsonl</string>
        <key>REPO_ROOT</key>
        <string>${ROOT}</string>
    </dict>
</dict>
</plist>
PLISTEOF

echo "Wrote ${PLIST_DEST}"

# ── Validate plist ────────────────────────────────────────────────────────────
if ! plutil -lint "$PLIST_DEST" >/dev/null 2>&1; then
    echo "ERROR: ${PLIST_DEST} is not valid XML — refusing to load" >&2
    plutil -lint "$PLIST_DEST" >&2 || true
    exit 3
fi
echo "Plist lint: OK"

# ── Unload existing instance (ignore error if not loaded) ────────────────────
launchctl unload "$PLIST_DEST" 2>/dev/null || true

# ── Load ─────────────────────────────────────────────────────────────────────
launchctl load "$PLIST_DEST"
echo "Loaded ${LABEL} (interval=${INTERVAL_S}s)"
echo "Logs: out=${LOG_OUT}  err=${LOG_ERR}"
