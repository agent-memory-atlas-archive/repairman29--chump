#!/usr/bin/env bash
# install-ceo-shadow-launchd.sh — INFRA-3584: hourly CEO shadow tick (dry-run).
# Idempotent. The shadow log feeds the AC-3 shadow-vs-ATC diff report; the
# driver never executes routed commands in v0, so this daemon is read-and-log.
set -euo pipefail
# INFRA-8194 (R5 slice 2): the Homebrew prefix comes from the host resolver
# (chump_brew_prefix in scripts/lib/host-paths.sh, the shell mirror of
# chump_provision::brew_prefix; `chump node host --field brew-prefix`), not a
# baked Apple Silicon path.
# shellcheck source=../lib/host-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/host-paths.sh"
BREW_PREFIX="$(chump_brew_prefix)"

# INFRA-2365: prefer the explicit env override, else resolve the MAIN
# worktree (not whatever worktree this installer runs from — see
# scripts/lib/resolve-main-worktree.sh / INFRA-451 class), falling back to
# the historical hardcoded default only if resolution fails.
# shellcheck source=../lib/resolve-main-worktree.sh
source "$(cd "$(dirname "$0")" && pwd)/../lib/resolve-main-worktree.sh"
REPO="${CHUMP_REPO_ROOT:-$(resolve_main_worktree "$0" 2>/dev/null || echo "$HOME/Projects/Chump")}"
LABEL=com.chump.ceo-shadow
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOGDIR="$HOME/.chump/ceo-shadow"
mkdir -p "$LOGDIR" "$HOME/Library/LaunchAgents"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/python3</string>
    <string>$REPO/scripts/coord/ceo-loop.py</string>
  </array>
  <key>WorkingDirectory</key><string>$REPO</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$HOME/.local/bin:${BREW_PREFIX}/bin:/usr/bin:/bin</string>
    <key>CHUMP_CEO_MODE</key><string>${CHUMP_CEO_MODE:-shadow}</string>
  </dict>
  <key>StartInterval</key><integer>3600</integer>
  <key>StandardOutPath</key><string>$LOGDIR/tick.log</string>
  <key>StandardErrorPath</key><string>$LOGDIR/tick.err</string>
</dict>
</plist>
EOF

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
launchctl list | grep -q "$LABEL" && echo "OK: $LABEL loaded (hourly shadow tick -> $LOGDIR/decisions.jsonl)" || {
  echo "ERROR: $LABEL failed to load" >&2; exit 1; }
