#!/usr/bin/env bash
# scripts/setup/install-oracle-refresh-launchd.sh — META-088
#
# Installs the oracle-refresh launchd job — fires every 4 hours, spawns
# Opus to re-contemplate docs/process/THE_PATH.md. Auto-commits + auto-PRs
# on change; no-op when content hash matches.

set -euo pipefail
# INFRA-8194 (R5 slice 2): the Homebrew prefix comes from the host resolver
# (chump_brew_prefix in scripts/lib/host-paths.sh, the shell mirror of
# chump_provision::brew_prefix; `chump node host --field brew-prefix`), not a
# baked Apple Silicon path.
# shellcheck source=../lib/host-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/host-paths.sh"
BREW_PREFIX="$(chump_brew_prefix)"

# INFRA-2365: resolve to the MAIN worktree, not whatever worktree this
# installer runs from (see scripts/lib/resolve-main-worktree.sh; INFRA-451
# class — a baked-in linked/temp worktree path dies with exit=78 once the
# worktree is reaped).
# shellcheck source=../lib/resolve-main-worktree.sh
source "$(cd "$(dirname "$0")" && pwd)/../lib/resolve-main-worktree.sh"
REPO_ROOT="$(resolve_main_worktree "$0")" || {
    echo "FAIL: could not resolve main worktree from $0" >&2
    exit 1
}
SCRIPT="$REPO_ROOT/scripts/coord/oracle-refresh.sh"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST="$PLIST_DIR/com.chump.oracle-refresh.plist"

[[ -x "$SCRIPT" ]] || { echo "missing/non-executable: $SCRIPT"; exit 1; }

mkdir -p "$PLIST_DIR"

cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.chump.oracle-refresh</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${SCRIPT}</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${REPO_ROOT}</string>
    <key>StartInterval</key>
    <integer>14400</integer>
    <key>RunAtLoad</key>
    <false/>
    <key>StandardOutPath</key>
    <string>${REPO_ROOT}/.chump-locks/oracle-refresh.log</string>
    <key>StandardErrorPath</key>
    <string>${REPO_ROOT}/.chump-locks/oracle-refresh.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:${BREW_PREFIX}/bin:/usr/bin:/bin:${HOME}/.cargo/bin</string>
    </dict>
</dict>
</plist>
PLIST_EOF

# Idempotent reinstall
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo "[install-oracle-refresh-launchd] installed at $PLIST"
echo "[install-oracle-refresh-launchd] cadence: every 4h (14400s)"
echo "[install-oracle-refresh-launchd] logs: $REPO_ROOT/.chump-locks/oracle-refresh.log"
echo ""
echo "Manual run (immediate, bounded by CHUMP_ORACLE_WALL_BUDGET_S=30):"
echo "  bash $SCRIPT --force"
echo ""
echo "Bypass: CHUMP_ORACLE_DISABLED=1 in env"
echo ""
echo "Uninstall:"
echo "  launchctl unload $PLIST && rm $PLIST"
