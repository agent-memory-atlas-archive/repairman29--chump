#!/usr/bin/env bash
# install-github-liaison.sh — INFRA-1317
#
# Idempotent installer for the GitHub Liaison launchd user agent.
# Writes ~/Library/LaunchAgents/dev.chump.github-liaison.plist that runs
# scripts/ops/github-liaison.sh as a KeepAlive daemon.
#
# The Liaison is Phase 1 of docs/design/GITHUB_LIAISON.md — one process
# refreshes .chump/github_cache.db every 60s instead of N workers each
# polling GitHub independently.
#
# Default-OFF: the plist sets CHUMP_LIAISON_ENABLED=1 but the daemon
# binary itself defaults to OFF for safety in non-launchd contexts (manual
# invocations, CI). To opt out at the launchd level after install, run
# `--uninstall` or `launchctl unload` the plist.
#
# Usage:
#   install-github-liaison.sh            — install + load (idempotent)
#   install-github-liaison.sh --uninstall — stop + remove plist
#   install-github-liaison.sh --check    — exit 0 iff installed+loaded, else 1
#   install-github-liaison.sh --status   — print launchctl status
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

LABEL="dev.chump.github-liaison"
PLIST_NAME="${LABEL}.plist"
LAUNCH_AGENTS_DIR="${HOME}/Library/LaunchAgents"
DEST="${LAUNCH_AGENTS_DIR}/${PLIST_NAME}"
LIAISON_SCRIPT="${REPO}/scripts/ops/github-liaison.sh"
LOG_DIR="${HOME}/Library/Logs/Chump"
mkdir -p "$LOG_DIR" "$LAUNCH_AGENTS_DIR"

MODE="install"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --uninstall) MODE="uninstall"; shift ;;
        --check)     MODE="check";     shift ;;
        --status)    MODE="status";    shift ;;
        -h|--help)
            sed -n '1,25p' "$0"; exit 0 ;;
        *)
            echo "install-github-liaison: unknown arg: $1" >&2
            exit 2 ;;
    esac
done

_plist_loaded() {
    launchctl list 2>/dev/null | grep -qF "$LABEL"
}

case "$MODE" in
    check)
        if [[ -f "$DEST" ]] && _plist_loaded; then
            exit 0
        fi
        exit 1
        ;;
    status)
        echo "PLIST_PATH:      $DEST"
        echo "PLIST_EXISTS:    $([[ -f "$DEST" ]] && echo yes || echo no)"
        echo "LAUNCHCTL_LIST:"
        launchctl list 2>/dev/null | grep -F "$LABEL" || echo "  (not loaded)"
        exit 0
        ;;
    uninstall)
        if [[ -f "$DEST" ]]; then
            launchctl unload "$DEST" 2>/dev/null || true
            rm -f "$DEST"
            echo "Uninstalled: $DEST"
        else
            echo "Not installed: $DEST (nothing to do)"
        fi
        # Also release any stale lock from a previously-running liaison so the
        # next fresh install starts cleanly.
        "$LIAISON_SCRIPT" --release >/dev/null 2>&1 || true
        exit 0
        ;;
    install)
        if [[ ! -x "$LIAISON_SCRIPT" ]]; then
            chmod +x "$LIAISON_SCRIPT" 2>/dev/null || true
        fi
        if [[ ! -f "$LIAISON_SCRIPT" ]]; then
            echo "install-github-liaison: missing $LIAISON_SCRIPT" >&2
            exit 1
        fi

        cat >"$DEST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>${LIAISON_SCRIPT}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>30</integer>
  <key>StandardOutPath</key>
  <string>${LOG_DIR}/github-liaison.out.log</string>
  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/github-liaison.err.log</string>
  <key>WorkingDirectory</key>
  <string>${REPO}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>${HOME}</string>
    <key>PATH</key>
    <string>/usr/local/bin:${BREW_PREFIX}/bin:${HOME}/.cargo/bin:/usr/bin:/bin</string>
    <key>CHUMP_LIAISON_ENABLED</key>
    <string>1</string>
  </dict>
</dict>
</plist>
PLIST

        # Reload idempotently.
        launchctl unload "$DEST" 2>/dev/null || true
        launchctl load "$DEST"

        echo "Installed and loaded: $DEST"
        launchctl list 2>/dev/null | grep -F "$LABEL" || true
        echo
        echo "Smoke test (single cycle, no opt-in needed):"
        echo "  $LIAISON_SCRIPT --once"
        echo "Health check:"
        echo "  $LIAISON_SCRIPT --check"
        echo "Tail logs:"
        echo "  tail -f $LOG_DIR/github-liaison.{out,err}.log"
        exit 0
        ;;
esac
