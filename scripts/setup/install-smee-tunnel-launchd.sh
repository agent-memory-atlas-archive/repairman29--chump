#!/usr/bin/env bash
# install-smee-tunnel-launchd.sh — INFRA-1081
# Installs the smee.io → localhost webhook tunnel as a KeepAlive LaunchAgent.
# Requires Node.js (uses npx --yes smee-client).

set -euo pipefail
# INFRA-8194 (R5 slice 2): the Homebrew prefix comes from the host resolver
# (chump_brew_prefix in scripts/lib/host-paths.sh, the shell mirror of
# chump_provision::brew_prefix; `chump node host --field brew-prefix`), not a
# baked Apple Silicon path.
# shellcheck source=../lib/host-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/host-paths.sh"
BREW_PREFIX="$(chump_brew_prefix)"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/resolve-main-worktree.sh
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
REPO="$(resolve_main_worktree "$0")"

PLIST_NAME="com.chump.smee-tunnel.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"
PORT="${CHUMP_WEBHOOK_PORT:-9097}"
SECRETS_ENV="${CHUMP_SECRETS_ENV:-$HOME/.chump/secrets.env}"

[[ -f "$SECRETS_ENV" ]] || { echo "missing $SECRETS_ENV — must define CHUMP_SMEE_URL"; exit 1; }
# shellcheck source=/dev/null
source "$SECRETS_ENV"
[[ -n "${CHUMP_SMEE_URL:-}" ]] || { echo "CHUMP_SMEE_URL not set in $SECRETS_ENV"; exit 1; }

command -v node >/dev/null 2>&1 || { echo "node not installed — install Node.js first"; exit 1; }

PATH_VALUE="/usr/local/bin:${BREW_PREFIX}/bin:${BREW_PREFIX}/sbin:${HOME}/.cargo/bin:/usr/bin:/bin"

mkdir -p "$HOME/Library/LaunchAgents"

cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.chump.smee-tunnel</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>npx --yes smee-client@latest --url ${CHUMP_SMEE_URL} --target http://localhost:${PORT}/webhook</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${REPO}</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-smee-tunnel.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-smee-tunnel.err.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>${HOME}</string>
    <key>PATH</key>
    <string>${PATH_VALUE}</string>
  </dict>
  <key>ThrottleInterval</key>
  <integer>10</integer>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)" "$DEST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$DEST"

echo "Installed: $DEST"
echo "  smee URL: ${CHUMP_SMEE_URL}"
echo "  target:   http://localhost:${PORT}/webhook"
echo "  verify:   launchctl list | grep chump.smee-tunnel"
