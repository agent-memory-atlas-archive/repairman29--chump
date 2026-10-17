#!/usr/bin/env bash
# install-curator-launchd.sh — install opus-curator and emergency-fast-path LaunchAgents.
# Idempotent: safe to re-run. Installs both INFRA-842 scheduled tasks.
#
# After install:
#   launchctl list | grep -E 'chump.opus-curator|chump.emergency-fast-path'
#
# To run on demand:
#   launchctl start com.chump.opus-curator
#   launchctl start com.chump.emergency-fast-path
#
# To uninstall:
#   launchctl unload ~/Library/LaunchAgents/com.chump.opus-curator.plist
#   launchctl unload ~/Library/LaunchAgents/com.chump.emergency-fast-path.plist
#   rm ~/Library/LaunchAgents/com.chump.{opus-curator,emergency-fast-path}.plist
set -euo pipefail
# INFRA-8194 (R5 slice 2): the Homebrew prefix comes from the host resolver
# (chump_brew_prefix in scripts/lib/host-paths.sh, the shell mirror of
# chump_provision::brew_prefix; `chump node host --field brew-prefix`), not a
# baked Apple Silicon path.
# shellcheck source=../lib/host-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/host-paths.sh"
BREW_PREFIX="$(chump_brew_prefix)"

# INFRA-451: resolve to the *main* worktree so the plist path survives worktree reaping.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
REPO="$(resolve_main_worktree "$0")"

# Interval overrides for testing:
#   CHUMP_CURATOR_INTERVAL=60 CHUMP_FASTPATH_INTERVAL=30 ./install-curator-launchd.sh
CURATOR_INTERVAL="${CHUMP_CURATOR_INTERVAL:-600}"
FASTPATH_INTERVAL="${CHUMP_FASTPATH_INTERVAL:-300}"

mkdir -p "$HOME/Library/LaunchAgents"

install_plist() {
    local label="$1"
    local script="$2"
    local interval="$3"
    local logname="$4"
    local dest="$HOME/Library/LaunchAgents/${label}.plist"

    cat >"$dest" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>${script}</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${REPO}</string>
  <key>StartInterval</key>
  <integer>${interval}</integer>
  <!-- META-065: RunAtLoad=true so the first run fires on install,
       creating the .chump-locks/curator-armed.sentinel + emitting
       kind=curator_auto_exec_armed for audit. -->
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/${logname}.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/${logname}.err.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>${HOME}</string>
    <key>PATH</key>
    <string>/usr/local/bin:${BREW_PREFIX}/bin:${BREW_PREFIX}/sbin:${HOME}/.cargo/bin:/usr/bin:/bin</string>
  </dict>
  <key>ThrottleInterval</key>
  <integer>60</integer>
</dict>
</plist>
EOF

    launchctl unload "$dest" 2>/dev/null || true
    launchctl load "$dest"
    echo "Installed: $dest (interval=${interval}s)"
}

install_plist \
    "com.chump.opus-curator" \
    "scripts/coord/opus-curator.sh" \
    "$CURATOR_INTERVAL" \
    "chump-opus-curator"

install_plist \
    "com.chump.emergency-fast-path" \
    "scripts/coord/emergency-fast-path.sh" \
    "$FASTPATH_INTERVAL" \
    "chump-emergency-fast-path"

echo
echo "Loaded agents:"
launchctl list | grep -E 'chump.opus-curator|chump.emergency-fast-path' || true
