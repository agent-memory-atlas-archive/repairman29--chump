#!/usr/bin/env bash
# scripts/setup/install-conflict-resolution-consumer-launchd.sh — RESILIENT-301
#
# Install the com.chump.conflict-resolution-consumer LaunchAgent that runs
# scripts/coord/conflict-resolution-consumer.sh every 900s (~15 min).
#
# conflict-resolution-consumer.sh is the standing consumer for
# armed_pr_needs_conflict_resolution (INFRA-3473 produced it, nothing
# consumed it): it picks up flagged PRs plus green+DIRTY+unarmed PRs,
# attempts a plain rebase then conflict-resolver-agent.sh (INFRA-1488)
# resolution, and escalates to the operator after N failed attempts.
#
# Usage:
#   bash scripts/setup/install-conflict-resolution-consumer-launchd.sh            # install + load
#   bash scripts/setup/install-conflict-resolution-consumer-launchd.sh --check    # exits 0 if loaded
#   bash scripts/setup/install-conflict-resolution-consumer-launchd.sh --uninstall
#
# Override interval for testing (seconds):
#   CHUMP_CONFLICT_RESOLUTION_CONSUMER_INTERVAL=300 bash scripts/setup/install-conflict-resolution-consumer-launchd.sh

set -euo pipefail
# INFRA-8194 (R5 slice 2): the Homebrew prefix comes from the host resolver
# (chump_brew_prefix in scripts/lib/host-paths.sh, the shell mirror of
# chump_provision::brew_prefix; `chump node host --field brew-prefix`), not a
# baked Apple Silicon path.
# shellcheck source=../lib/host-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/host-paths.sh"
BREW_PREFIX="$(chump_brew_prefix)"

case "$(uname -s)" in
  Darwin) ;;
  *) echo "skip: not macOS"; exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# INFRA-2365: resolve to the MAIN worktree, not whatever worktree this
# installer runs from (see scripts/lib/resolve-main-worktree.sh; INFRA-451
# class — a baked-in linked/temp worktree path dies with exit=78 once the
# worktree is reaped).
# shellcheck source=../lib/resolve-main-worktree.sh
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
REPO_ROOT="$(resolve_main_worktree "${BASH_SOURCE[0]}")" || {
    echo "FAIL: could not resolve main worktree from ${BASH_SOURCE[0]}" >&2
    exit 1
}
PLIST_NAME="com.chump.conflict-resolution-consumer"
DEST="$HOME/Library/LaunchAgents/${PLIST_NAME}.plist"
INTERVAL="${CHUMP_CONFLICT_RESOLUTION_CONSUMER_INTERVAL:-900}"

CONSUMER_SCRIPT="$REPO_ROOT/scripts/coord/conflict-resolution-consumer.sh"

# ── --check mode ──────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--check" ]]; then
    if launchctl list 2>/dev/null | grep -q "$PLIST_NAME"; then
        echo "ok: $PLIST_NAME is loaded"
        exit 0
    else
        echo "MISSING: $PLIST_NAME not loaded"
        exit 1
    fi
fi

# ── --uninstall mode ──────────────────────────────────────────────────────────
if [[ "${1:-}" == "--uninstall" ]]; then
    if [[ -f "$DEST" ]]; then
        launchctl unload "$DEST" 2>/dev/null || true
        rm -f "$DEST"
        echo "uninstalled $PLIST_NAME"
    else
        echo "$PLIST_NAME not installed"
    fi
    exit 0
fi

# ── Install ───────────────────────────────────────────────────────────────────
if [[ ! -x "$CONSUMER_SCRIPT" ]]; then
    echo "ERROR: $CONSUMER_SCRIPT not found or not executable" >&2
    exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents"
mkdir -p "$REPO_ROOT/.chump-locks"

# PATH must include cargo + brew binaries so git and gh resolve correctly.
CARGO_BIN="$HOME/.cargo/bin"
PATH_VALUE="/usr/local/bin:${BREW_PREFIX}/bin:${BREW_PREFIX}/sbin:${CARGO_BIN}:/usr/bin:/bin"
LOG="$REPO_ROOT/.chump-locks/conflict-resolution-consumer.log"

cat > "$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${PLIST_NAME}</string>

  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${CONSUMER_SCRIPT}</string>
  </array>

  <key>WorkingDirectory</key>
  <string>${REPO_ROOT}</string>

  <key>StartInterval</key>
  <integer>${INTERVAL}</integer>

  <key>RunAtLoad</key>
  <true/>

  <key>StandardOutPath</key>
  <string>${LOG}</string>

  <key>StandardErrorPath</key>
  <string>${LOG}</string>

  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>${HOME}</string>
    <key>PATH</key>
    <string>${PATH_VALUE}</string>
    <key>CHUMP_REPO_ROOT</key>
    <string>${REPO_ROOT}</string>
  </dict>

  <key>ThrottleInterval</key>
  <integer>300</integer>
</dict>
</plist>
EOF

launchctl unload "$DEST" 2>/dev/null || true
launchctl load "$DEST"
echo "installed + loaded $PLIST_NAME (interval ${INTERVAL}s) → $DEST"
