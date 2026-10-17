#!/usr/bin/env bash
# install-runner-autoscale.sh — INFRA-1535
#
# Installs the chump-runner-autoscale loop as a launchd service. Polls
# GitHub Actions queue depth + runner count + scales the M4 runner pool.
#
# Usage:
#   scripts/setup/install-runner-autoscale.sh         # install + start
#   scripts/setup/install-runner-autoscale.sh --check # is it running?
#   scripts/setup/install-runner-autoscale.sh --uninstall

set -euo pipefail
# INFRA-8194 (R5 slice 2): the Homebrew prefix comes from the host resolver
# (chump_brew_prefix in scripts/lib/host-paths.sh, the shell mirror of
# chump_provision::brew_prefix; `chump node host --field brew-prefix`), not a
# baked Apple Silicon path.
# shellcheck source=../lib/host-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/host-paths.sh"
BREW_PREFIX="$(chump_brew_prefix)"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AUTOSCALE_SCRIPT="$REPO_ROOT/scripts/coord/chump-runner-autoscale.sh"
PLIST="$HOME/Library/LaunchAgents/com.chump.runner-autoscale.plist"
LOGDIR="$HOME/Library/Logs/Chump"

cmd_check() {
  if launchctl print "gui/$UID/com.chump.runner-autoscale" >/dev/null 2>&1; then
    echo "OK: runner-autoscale service is registered"
    launchctl print "gui/$UID/com.chump.runner-autoscale" | grep -E "^\s*(state|pid|last exit code)" | head -3
    exit 0
  else
    echo "FAIL: runner-autoscale service is NOT registered"
    exit 1
  fi
}

cmd_uninstall() {
  if [ -f "$PLIST" ]; then
    launchctl bootout "gui/$UID" "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    echo "Removed autoscale service + plist."
  fi
}

cmd_install() {
  [ -x "$AUTOSCALE_SCRIPT" ] || { echo "ERROR: $AUTOSCALE_SCRIPT not executable"; exit 1; }

  mkdir -p "$LOGDIR" "$(dirname "$PLIST")"

  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.chump.runner-autoscale</string>
    <key>ProgramArguments</key>
    <array>
        <string>$AUTOSCALE_SCRIPT</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$REPO_ROOT</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>30</integer>
    <key>StandardOutPath</key>
    <string>$LOGDIR/runner-autoscale.log</string>
    <key>StandardErrorPath</key>
    <string>$LOGDIR/runner-autoscale.err</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>${BREW_PREFIX}/bin:/usr/local/bin:/usr/bin:/bin</string>
        <key>CHUMP_REPO_OWNER</key>
        <string>${CHUMP_REPO_OWNER:-repairman29}</string>
        <key>CHUMP_REPO_NAME</key>
        <string>${CHUMP_REPO_NAME:-chump}</string>
        <key>CHUMP_RUNNER_MIN</key>
        <string>${CHUMP_RUNNER_MIN:-1}</string>
        <key>CHUMP_RUNNER_M4_MAX</key>
        <string>${CHUMP_RUNNER_M4_MAX:-4}</string>
    </dict>
</dict>
</plist>
EOF

  # Reload if already loaded
  launchctl bootout "gui/$UID" "$PLIST" 2>/dev/null || true
  launchctl bootstrap "gui/$UID" "$PLIST"
  sleep 2

  echo "Installed and started com.chump.runner-autoscale"
  echo "Logs: $LOGDIR/runner-autoscale.{log,err}"
  echo "Status: $0 --check"
}

case "${1:-}" in
  --check)     cmd_check ;;
  --uninstall) cmd_uninstall ;;
  -h|--help)   sed -n '2,/^$/p' "$0" | sed 's/^# \?//'; exit 0 ;;
  "")          cmd_install ;;
  *)           echo "Unknown arg: $1"; exit 1 ;;
esac
