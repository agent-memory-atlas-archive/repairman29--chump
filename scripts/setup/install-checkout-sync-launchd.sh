#!/usr/bin/env bash
# scripts/setup/install-checkout-sync-launchd.sh — MISSION-027 / RESILIENT-629
#
# Installs the com.chump.checkout-sync LaunchAgent (macOS) or a per-minute
# cron job (Linux) that runs scripts/ops/checkout-sync.sh on a cadence
# (default 300s on macOS / every 60s — cron's minimum granularity — on
# Linux; see RESILIENT-629 AC1).
#
# checkout-sync.sh keeps the RUNNING checkout — the one the fleet's
# scripts/dispatch/_pick_gap.py and daemons actually execute out of — fast
# on origin/main, independent of MISSION-012's binary-only auto-deploy.
#
# Usage:
#   bash scripts/setup/install-checkout-sync-launchd.sh            # install + load
#   bash scripts/setup/install-checkout-sync-launchd.sh --check    # exits 0 if loaded
#   bash scripts/setup/install-checkout-sync-launchd.sh --uninstall
#
# Override interval for testing (seconds, macOS only — Linux cron is fixed
# at once-per-minute):
#   CHUMP_CHECKOUT_SYNC_INTERVAL=60 bash scripts/setup/install-checkout-sync-launchd.sh
#
# Point at a dedicated fleet checkout instead of this repo root:
#   CHUMP_SYNC_TARGET_DIR=/path/to/fleet/checkout bash scripts/setup/install-checkout-sync-launchd.sh

set -euo pipefail
# INFRA-8194 (R5 slice 2): the Homebrew prefix comes from the host resolver
# (chump_brew_prefix in scripts/lib/host-paths.sh, the shell mirror of
# chump_provision::brew_prefix; `chump node host --field brew-prefix`), not a
# baked Apple Silicon path.
# shellcheck source=../lib/host-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/host-paths.sh"
BREW_PREFIX="$(chump_brew_prefix)"

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
PLIST_NAME="com.chump.checkout-sync"
DEST="$HOME/Library/LaunchAgents/${PLIST_NAME}.plist"
INTERVAL="${CHUMP_CHECKOUT_SYNC_INTERVAL:-300}"
TARGET_DIR="${CHUMP_SYNC_TARGET_DIR:-$REPO_ROOT}"
CRON_TAG="chump-checkout-sync"

SYNC_SCRIPT="$REPO_ROOT/scripts/ops/checkout-sync.sh"

# ── --check mode ──────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--check" ]]; then
    if [[ "$(uname -s)" == "Darwin" ]]; then
        if launchctl list 2>/dev/null | grep -q "$PLIST_NAME"; then
            echo "ok: $PLIST_NAME is loaded"
            exit 0
        else
            echo "MISSING: $PLIST_NAME not loaded"
            exit 1
        fi
    else
        if crontab -l 2>/dev/null | grep -q "$CRON_TAG"; then
            echo "ok: $CRON_TAG cron job installed"
            exit 0
        else
            echo "MISSING: $CRON_TAG cron job not installed"
            exit 1
        fi
    fi
fi

# ── --uninstall mode ──────────────────────────────────────────────────────────
if [[ "${1:-}" == "--uninstall" ]]; then
    if [[ "$(uname -s)" == "Darwin" ]]; then
        if [[ -f "$DEST" ]]; then
            launchctl unload "$DEST" 2>/dev/null || true
            rm -f "$DEST"
            echo "uninstalled $PLIST_NAME"
        else
            echo "$PLIST_NAME not installed"
        fi
    else
        ( crontab -l 2>/dev/null | grep -v "$CRON_TAG" ) | crontab - 2>/dev/null || true
        echo "uninstalled $CRON_TAG cron job"
    fi
    exit 0
fi

# ── Install ───────────────────────────────────────────────────────────────────
if [[ ! -x "$SYNC_SCRIPT" ]]; then
    echo "ERROR: $SYNC_SCRIPT not found or not executable" >&2
    exit 1
fi

# ── Linux: cron, once per minute (cron's minimum granularity; satisfies the
# "every 60 seconds" cadence in RESILIENT-629 AC1). ────────────────────────────
if [[ "$(uname -s)" != "Darwin" ]]; then
    mkdir -p "$TARGET_DIR/.chump-locks/checkout-sync-logs"
    CRON_LOG="$TARGET_DIR/.chump-locks/checkout-sync-cron.log"
    CRON_LINE="* * * * * CHUMP_SYNC_TARGET_DIR=$TARGET_DIR /bin/bash $SYNC_SCRIPT >> $CRON_LOG 2>&1 # $CRON_TAG"
    ( crontab -l 2>/dev/null | grep -v "$CRON_TAG"; echo "$CRON_LINE" ) | crontab -
    echo "Installed cron job: $CRON_TAG (every 60s)"
    echo "  sync script : ${SYNC_SCRIPT}"
    echo "  target dir  : ${TARGET_DIR}"
    echo "  verify      : crontab -l | grep $CRON_TAG"
    echo "  cron log    : ${CRON_LOG}"
    echo "  logs        : ${TARGET_DIR}/.chump-locks/checkout-sync-logs/"
    exit 0
fi

mkdir -p "$HOME/Library/LaunchAgents"
mkdir -p "$TARGET_DIR/.chump-locks/checkout-sync-logs"

CARGO_BIN="$HOME/.cargo/bin"
PATH_VALUE="/usr/local/bin:${BREW_PREFIX}/bin:${BREW_PREFIX}/sbin:${CARGO_BIN}:/usr/bin:/bin"

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
    <string>${SYNC_SCRIPT}</string>
  </array>

  <key>WorkingDirectory</key>
  <string>${TARGET_DIR}</string>

  <key>StartInterval</key>
  <integer>${INTERVAL}</integer>

  <key>RunAtLoad</key>
  <true/>

  <key>StandardOutPath</key>
  <string>/tmp/chump-checkout-sync.out.log</string>

  <key>StandardErrorPath</key>
  <string>/tmp/chump-checkout-sync.err.log</string>

  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>${HOME}</string>
    <key>PATH</key>
    <string>${PATH_VALUE}</string>
    <key>CHUMP_SYNC_TARGET_DIR</key>
    <string>${TARGET_DIR}</string>
  </dict>

  <key>ThrottleInterval</key>
  <integer>60</integer>
</dict>
</plist>
EOF

# Reload idempotently: bootout (ignore error if not loaded) + bootstrap.
launchctl bootout "gui/$(id -u)" "$DEST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$DEST"

echo "Installed: $DEST"
echo "  sync script : ${SYNC_SCRIPT}"
echo "  target dir  : ${TARGET_DIR}"
echo "  interval    : ${INTERVAL}s (~$(( INTERVAL / 60 )) min)"
echo "  verify      : launchctl list | grep checkout-sync"
echo "  on-demand   : launchctl start ${PLIST_NAME}"
echo "  logs        : ${TARGET_DIR}/.chump-locks/checkout-sync-logs/"
