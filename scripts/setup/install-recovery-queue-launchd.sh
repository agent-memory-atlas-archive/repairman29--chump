#!/usr/bin/env bash
# scripts/setup/install-recovery-queue-launchd.sh — thin shim for chump-cron
#
# Forward to `chump cron install recovery-queue-service`

set -euo pipefail

# Resolve main worktree as the original did
source "$(cd "$(dirname "$0")" && pwd)/../lib/resolve-main-worktree.sh"
REPO_ROOT="$(resolve_main_worktree "$0")" || {
    echo "FAIL: could not resolve main worktree from $0" >&2
    exit 1
}

# Run the chump command to install
chump cron install recovery-queue-service

# Then print the same messages as the original
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST="$PLIST_DIR/com.chump.recovery-queue-service.plist"
echo "[install-recovery-queue] installed launchd at $PLIST (60s cadence)"
echo "[install-recovery-queue] DISABLED BY DEFAULT — operator must export CHUMP_RECOVERY_QUEUE_PAUSE=0 + restart fleet to enable"
echo "[install-recovery-queue] safety: set CHUMP_RECOVERY_QUEUE_PAUSE=1 to disable; CHUMP_RECOVERY_QUEUE_DRY_RUN=1 to plan-only"
echo "[install-recovery-queue] inspect: launchctl print gui/\$(id -u)/com.chump.recovery-queue-service"
echo "[install-recovery-queue] logs:    tail -f ${REPO_ROOT}/.chump-locks/recovery-queue-service.log"
