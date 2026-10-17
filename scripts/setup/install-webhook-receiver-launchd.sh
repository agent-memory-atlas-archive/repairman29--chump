#!/usr/bin/env bash
# install-webhook-receiver-launchd.sh — INFRA-1081
# Installs the GitHub webhook receiver as a KeepAlive LaunchAgent.
#
# Prerequisites:
#   - Create a webhook in github.com/repairman29/chump/settings/hooks
#     pointing at a smee.io URL
#   - Set CHUMP_GITHUB_WEBHOOK_SECRET + CHUMP_SMEE_URL in ~/.chump/secrets.env
#   - Run scripts/setup/install-smee-tunnel-launchd.sh to bridge smee→localhost
#
# After install:
#   launchctl list | grep chump.github-webhook-receiver
#   tail /tmp/chump-webhook-receiver.out.log

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

PLIST_NAME="com.chump.github-webhook-receiver.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"
PORT="${CHUMP_WEBHOOK_PORT:-9097}"
SECRETS_ENV="${CHUMP_SECRETS_ENV:-$HOME/.chump/secrets.env}"

[[ -f "$SECRETS_ENV" ]] || { echo "missing $SECRETS_ENV — must define CHUMP_GITHUB_WEBHOOK_SECRET"; exit 1; }

mkdir -p "$HOME/Library/LaunchAgents"

# Read the secret + smee URL from the operator's env file.
# shellcheck source=/dev/null
source "$SECRETS_ENV"

PATH_VALUE="/usr/local/bin:${BREW_PREFIX}/bin:${BREW_PREFIX}/sbin:${HOME}/.cargo/bin:/usr/bin:/bin"

cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.chump.github-webhook-receiver</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/env</string>
    <string>python3</string>
    <string>${REPO}/scripts/ops/github-webhook-receiver.py</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${REPO}</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-webhook-receiver.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-webhook-receiver.err.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>${HOME}</string>
    <key>PATH</key>
    <string>${PATH_VALUE}</string>
    <key>CHUMP_WEBHOOK_PORT</key>
    <string>${PORT}</string>
    <key>CHUMP_GITHUB_WEBHOOK_SECRET</key>
    <string>${CHUMP_GITHUB_WEBHOOK_SECRET}</string>
  </dict>
  <key>ThrottleInterval</key>
  <integer>5</integer>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)" "$DEST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$DEST"

echo "Installed: $DEST"
echo "  port:   $PORT"
echo "  log:    /tmp/chump-webhook-receiver.out.log"
echo "  verify: launchctl list | grep chump.github-webhook-receiver"
echo
echo "Next: install the smee.io tunnel that forwards github→localhost:$PORT"
echo "      scripts/setup/install-smee-tunnel-launchd.sh"
