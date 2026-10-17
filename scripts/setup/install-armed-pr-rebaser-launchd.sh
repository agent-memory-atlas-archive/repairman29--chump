#!/usr/bin/env bash
# scripts/setup/install-armed-pr-rebaser-launchd.sh — INFRA-3473
#
# Install the com.chump.armed-pr-rebaser LaunchAgent that runs
# scripts/coord/armed-pr-rebaser.sh every 1200s (~20 min).
#
# armed-pr-rebaser.sh is fleet self-healing: for each open ARMED PR whose
# mergeStateStatus is DIRTY or BEHIND, it rebases the branch on origin/main in a
# throwaway worktree and (only on a CLEAN rebase) force-pushes; a real conflict
# is flagged to ambient, never force-pushed. The queue-driver / conflict-resolver
# only rebase INSIDE a bot-merge run, so once a PR is armed and bot-merge exits,
# nothing re-rebases when main later advances — this closes that gap. The main
# checkout is NEVER touched (all work happens in /tmp/armed-rebaser-<N> worktrees).
#
# Usage:
#   bash scripts/setup/install-armed-pr-rebaser-launchd.sh            # install + load
#   bash scripts/setup/install-armed-pr-rebaser-launchd.sh --check    # exits 0 if loaded
#   bash scripts/setup/install-armed-pr-rebaser-launchd.sh --uninstall
#
# Override interval for testing (seconds):
#   CHUMP_ARMED_PR_REBASER_INTERVAL=300 bash scripts/setup/install-armed-pr-rebaser-launchd.sh

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
PLIST_NAME="com.chump.armed-pr-rebaser"
DEST="$HOME/Library/LaunchAgents/${PLIST_NAME}.plist"
INTERVAL="${CHUMP_ARMED_PR_REBASER_INTERVAL:-1200}"

REBASER_SCRIPT="$REPO_ROOT/scripts/coord/armed-pr-rebaser.sh"

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
if [[ ! -x "$REBASER_SCRIPT" ]]; then
    echo "ERROR: $REBASER_SCRIPT not found or not executable" >&2
    exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents"
mkdir -p "$REPO_ROOT/.chump-locks"

# PATH must include cargo + brew binaries so git and gh resolve correctly.
CARGO_BIN="$HOME/.cargo/bin"
PATH_VALUE="/usr/local/bin:${BREW_PREFIX}/bin:${BREW_PREFIX}/sbin:${CARGO_BIN}:/usr/bin:/bin"
LOG="$REPO_ROOT/.chump-locks/armed-pr-rebaser.log"

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
    <string>${REBASER_SCRIPT}</string>
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
  <integer>600</integer>
</dict>
</plist>
EOF

launchctl unload "$DEST" 2>/dev/null || true
launchctl load "$DEST"
echo "installed + loaded $PLIST_NAME (interval ${INTERVAL}s) → $DEST"
