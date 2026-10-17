#!/usr/bin/env bash
# install-fleet-pool-keeper.sh — RESILIENT-177: register com.chump.fleet-pool-keeper.
#
#   install-fleet-pool-keeper.sh              install + load (StartInterval 300s)
#   install-fleet-pool-keeper.sh --uninstall  bootout + remove plist
#
# Verify: launchctl print "gui/$(id -u)/com.chump.fleet-pool-keeper"
# Logs  : /tmp/chump-fleet-pool-keeper.log
set -euo pipefail
# INFRA-8194 (R5 slice 2): the Homebrew prefix comes from the host resolver
# (chump_brew_prefix in scripts/lib/host-paths.sh, the shell mirror of
# chump_provision::brew_prefix; `chump node host --field brew-prefix`), not a
# baked Apple Silicon path.
# shellcheck source=../lib/host-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/host-paths.sh"
BREW_PREFIX="$(chump_brew_prefix)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# RESILIENT-168: never bake a temp-clone path into a persistent plist.
case "$REPO_ROOT" in
    /tmp/*|/private/tmp/*|/var/folders/*)
        if [[ "${CHUMP_INSTALL_ALLOW_TMP:-0}" != "1" ]]; then
            echo "ERROR: refusing to install a persistent daemon from temp path $REPO_ROOT" >&2
            echo "  (run from the canonical checkout, or CHUMP_INSTALL_ALLOW_TMP=1 to override)" >&2
            exit 1
        fi
        ;;
esac

LABEL="com.chump.fleet-pool-keeper"
PLIST_PATH="$HOME/Library/LaunchAgents/${LABEL}.plist"
KEEPER="$REPO_ROOT/scripts/ops/fleet-pool-keeper.sh"
UID_N="$(id -u)"

if [[ "${1:-}" == "--uninstall" ]]; then
    launchctl bootout "gui/${UID_N}/${LABEL}" 2>/dev/null || true
    rm -f "$PLIST_PATH"
    echo "[install-fleet-pool-keeper] uninstalled."
    exit 0
fi

[[ -x "$KEEPER" ]] || { echo "ERROR: keeper script not executable: $KEEPER" >&2; exit 1; }

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${KEEPER}</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>CHUMP_REPO</key><string>${REPO_ROOT}</string>
        <key>PATH</key><string>${BREW_PREFIX}/bin:${HOME}/.local/bin:${HOME}/.cargo/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
    <key>StartInterval</key><integer>300</integer>
    <key>RunAtLoad</key><true/>
    <key>StandardOutPath</key><string>/tmp/chump-fleet-pool-keeper.log</string>
    <key>StandardErrorPath</key><string>/tmp/chump-fleet-pool-keeper.log</string>
</dict>
</plist>
PLIST

# RESILIENT-168 lessons: bootout stale copy, clear disabled-override, load.
launchctl bootout "gui/${UID_N}/${LABEL}" 2>/dev/null || true
launchctl enable "gui/${UID_N}/${LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/${UID_N}" "$PLIST_PATH"

echo "[install-fleet-pool-keeper] loaded (StartInterval 300s)."
echo "  verify: launchctl print gui/${UID_N}/${LABEL} | grep state"
