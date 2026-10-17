#!/usr/bin/env bash
# install-bootstrap-auto-launchd.sh — INFRA-1808
#
# Installs an hourly LaunchAgent that runs
# `chump-fleet-bootstrap.sh --install` unattended, so the bootstrapper
# itself no longer depends on an operator remembering to run it by hand.
# The installers it calls are already idempotent, so re-running hourly is
# safe.
#
# Root cause this closes: code shipping to the repo (installer scripts,
# plists) is not the same as code running on the host — nothing ran the
# bootstrap installer automatically, so newly-shipped daemons (pr-auto-rebase,
# claude-reaper, bot-merge-watchdog, ...) sat un-installed for days until an
# operator happened to run chump-fleet-bootstrap.sh manually.
#
# After install:
#   launchctl list | grep com.chump.bootstrap-auto-install
#
# Manual smoke (force one cycle):
#   launchctl start com.chump.bootstrap-auto-install
#   tail -20 /tmp/chump-bootstrap-auto-install.out.log
#
# Uninstall:
#   launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.chump.bootstrap-auto-install.plist
#   rm ~/Library/LaunchAgents/com.chump.bootstrap-auto-install.plist
#
# Dry-run (writes the plist to a temp dir instead of ~/Library/LaunchAgents,
# never calls launchctl — used by scripts/ci/test-bootstrap-auto-install.sh):
#   install-bootstrap-auto-launchd.sh --dry-run

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

DRY_RUN=0
for arg in "$@"; do
    [[ "$arg" == "--dry-run" ]] && DRY_RUN=1
done

LABEL="com.chump.bootstrap-auto-install"
PLIST_NAME="${LABEL}.plist"
LAUNCH_AGENTS_DIR="${CHUMP_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
DEST="$LAUNCH_AGENTS_DIR/$PLIST_NAME"
RUNNER="$REPO/scripts/setup/bootstrap-auto-install-runner.sh"

mkdir -p "$LAUNCH_AGENTS_DIR"

cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${RUNNER}</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${REPO}</string>
  <!-- Hourly. Installers are idempotent, so re-running is safe. -->
  <key>StartInterval</key>
  <integer>3600</integer>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-bootstrap-auto-install.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-bootstrap-auto-install.err.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>${HOME}</string>
    <key>PATH</key>
    <string>/usr/local/bin:${BREW_PREFIX}/bin:${HOME}/.cargo/bin:/usr/bin:/bin</string>
  </dict>
  <key>ThrottleInterval</key>
  <integer>60</integer>
</dict>
</plist>
EOF

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[dry-run] wrote plist to $DEST (launchctl not invoked)"
    exit 0
fi

if command -v launchctl >/dev/null 2>&1; then
    launchctl bootout "gui/$(id -u)" "$DEST" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$DEST"
    echo "Installed and loaded: $DEST"
else
    echo "launchctl not found (non-macOS host) — wrote plist to $DEST but did not load it" >&2
fi

echo "  runs: bash $RUNNER  (chump-fleet-bootstrap.sh --install + ambient emit)"
echo "  interval: 3600s"
echo "  verify: launchctl list | grep $LABEL"
echo "  manual smoke: launchctl start $LABEL && tail -20 /tmp/chump-bootstrap-auto-install.out.log"
