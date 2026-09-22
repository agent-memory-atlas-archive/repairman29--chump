#!/usr/bin/env bash
# install-stale-worktree-reaper-systemd.sh — RESILIENT-1444
#
# Linux counterpart to install-stale-worktree-reaper-launchd.sh. The launchd
# installer only produces a ~/Library/LaunchAgents plist, so on a Linux
# coordinator node (e.g. CJ) the reaper never runs on a timer — abandoned
# worker worktrees (rc=1 leftovers, see worker.sh "leaving worktree ... on
# disk rc=1") pile up unbounded and correlate with the disk-starvation spiral
# this gap fixes. Installs a systemd --user timer that runs
# stale-worktree-reaper.sh --execute hourly, same cadence as the macOS plist.
#
# Requires: `loginctl enable-linger $USER` (so the user timer runs without a
# login session). Verify: systemctl --user list-timers | grep chump-worktree-reaper
#
# Uninstall:
#   systemctl --user disable --now chump-worktree-reaper.timer
#   rm ~/.config/systemd/user/chump-worktree-reaper.{service,timer}
#   systemctl --user daemon-reload
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
INTERVAL="${CHUMP_WORKTREE_REAPER_INTERVAL:-3600}"
REAPER_SH="$REPO_ROOT/scripts/ops/stale-worktree-reaper.sh"
UNIT_DIR="$HOME/.config/systemd/user"

[[ -f "$REAPER_SH" ]] || { echo "ERROR: reaper not found at $REAPER_SH" >&2; exit 1; }
mkdir -p "$UNIT_DIR"

_PATH="$HOME/.local/bin:$HOME/.cargo/bin:$REPO_ROOT/target/release:/usr/local/bin:/usr/bin:/bin"

cat >"$UNIT_DIR/chump-worktree-reaper.service" <<EOF
[Unit]
Description=chump stale-worktree reaper (Linux) — reap abandoned/merged worktrees (RESILIENT-1444)
After=network-online.target

[Service]
Type=oneshot
Environment=HOME=%h
Environment=PATH=$_PATH
WorkingDirectory=$REPO_ROOT
ExecStart=/usr/bin/env bash $REAPER_SH --execute
EOF

cat >"$UNIT_DIR/chump-worktree-reaper.timer" <<EOF
[Unit]
Description=chump stale-worktree reaper timer (every ${INTERVAL}s) — RESILIENT-1444

[Timer]
OnBootSec=5min
OnUnitActiveSec=${INTERVAL}s
AccuracySec=30s
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now chump-worktree-reaper.timer

echo "Installed chump-worktree-reaper.{service,timer} (interval=${INTERVAL}s)"
echo "  reaper: $REAPER_SH --execute"
systemctl --user is-active chump-worktree-reaper.timer && echo "timer: active"
systemctl --user is-enabled chump-worktree-reaper.timer && echo "timer: enabled"
