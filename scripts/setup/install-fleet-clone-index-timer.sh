#!/usr/bin/env bash
# install-fleet-clone-index-timer.sh — RESILIENT-1351
#
# Wires scripts/ops/fleet-clone-index.sh (the org-wide clone→index→untether
# sweep that gives almanac the WHOLE repairman29 org, not just the factory
# node's 2 local checkouts) into supervision on the factory node: a periodic
# timer that re-runs the sweep to pick up new org repos and refresh existing
# ones. The sweep itself is niced/ioniced and disk-floor-guarded, so it never
# fights the coordinator/workers and never fills the coordinator's disk.
#
# This is the org-clone companion to install-index-almanac-timer.sh
# (RESILIENT-404): that one reindexes the LOCAL dev checkouts (chump, almanac)
# hourly; this one clones + indexes the other ~107 org repos into the same
# canonical CJ index and drops their worktrees.
#
# Linux-factory-only by design (AC3 of RESILIENT-404 applies here too): the
# whole point of the 2026-09-17 decision is to move the canonical index OFF the
# Mac and onto the factory node, so this installer refuses on macOS.
#
# Usage:
#   scripts/setup/install-fleet-clone-index-timer.sh              # install + run once now
#   scripts/setup/install-fleet-clone-index-timer.sh --check       # verify only, non-zero if incomplete
#   scripts/setup/install-fleet-clone-index-timer.sh --dry-run
#
# Env:
#   CHUMP_STATE_DIR   chump state dir, for logs (default: $HOME/.chump)
#   CHUMP_FLEET_ORG   org to sweep (default: repairman29) — passed through to the sweep
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SWEEP_SCRIPT="$REPO_ROOT/scripts/ops/fleet-clone-index.sh"
STATE_DIR="${CHUMP_STATE_DIR:-$HOME/.chump}"
LOG_DIR="$STATE_DIR/logs"
FLEET_ORG="${CHUMP_FLEET_ORG:-repairman29}"

MODE="install"; DRY=0
for a in "$@"; do
  case "$a" in
    --check) MODE="check" ;;
    --dry-run) DRY=1 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done

ok(){ printf '  \033[32m✓\033[0m %s\n' "$*"; }
no(){ printf '  \033[31m✗\033[0m %s\n' "$*"; }
info(){ printf '\033[36m[FLEET-CLONE-INDEX]\033[0m %s\n' "$*"; }
run(){ [ "$DRY" = 1 ] && { echo "  DRY: $*"; return 0; }; eval "$*"; }

SERVICE_NAME="chump-fleet-clone-index.service"
TIMER_NAME="chump-fleet-clone-index.timer"

if [ "$(uname -s)" = "Darwin" ]; then
  no "this organ is Linux-factory-only by design (canonical index lives on the factory node) — refusing on macOS"
  exit 1
fi

if [ ! -x "$SWEEP_SCRIPT" ]; then
  no "sweep script missing or not executable: $SWEEP_SCRIPT"
  exit 1
fi

detect_supervisor() {
  if command -v systemctl >/dev/null 2>&1 && systemctl --user status >/dev/null 2>&1; then
    echo "systemd-user"
  elif command -v crontab >/dev/null 2>&1; then
    echo "cron"
  else
    echo "none"
  fi
}

install_systemd_user() {
  local unit_dir="$HOME/.config/systemd/user"
  run "mkdir -p '$unit_dir' '$LOG_DIR'"
  run "cat > '$unit_dir/$SERVICE_NAME' <<EOF
[Unit]
Description=Chump almanac fleet ORG clone+index+untether sweep (RESILIENT-1351)

[Service]
Type=oneshot
Nice=19
IOSchedulingClass=idle
Environment=CHUMP_REPO_ROOT=$REPO_ROOT
Environment=CHUMP_FLEET_ORG=$FLEET_ORG
ExecStart=$SWEEP_SCRIPT
EOF"
  run "cat > '$unit_dir/$TIMER_NAME' <<EOF
[Unit]
Description=Chump almanac fleet ORG sweep beat — every 3h (RESILIENT-1351)

[Timer]
OnBootSec=15min
OnUnitActiveSec=3h
Persistent=true
RandomizedDelaySec=10min

[Install]
WantedBy=timers.target
EOF"
  run "systemctl --user daemon-reload"
  run "systemctl --user enable --now '$TIMER_NAME'"
  ok "systemd --user timer installed: $TIMER_NAME (every 3h, niced/idle-io) → $SERVICE_NAME"
}

install_cron() {
  run "mkdir -p '$LOG_DIR'"
  local marker="# chump-fleet-clone-index (RESILIENT-1351)"
  local line="17 */3 * * * CHUMP_REPO_ROOT=$REPO_ROOT CHUMP_FLEET_ORG=$FLEET_ORG $SWEEP_SCRIPT >> $LOG_DIR/fleet-clone-index.log 2>&1 $marker"
  if [ "$DRY" = 1 ]; then
    echo "  DRY: crontab -l | grep -v '$marker' ; append: $line"
  else
    ( crontab -l 2>/dev/null | grep -vF "$marker"; echo "$line" ) | crontab -
  fi
  ok "cron fallback installed: every 3h ($marker)"
}

do_install() {
  local sup; sup="$(detect_supervisor)"
  info "supervisor=$sup  org=$FLEET_ORG"
  case "$sup" in
    systemd-user) install_systemd_user ;;
    cron) install_cron ;;
    *) no "no supervisor available (systemd --user, cron) — organ not supervised; run $SWEEP_SCRIPT by hand"; return 1 ;;
  esac
  info "running org sweep once now (this clones the org; may take several minutes)"
  if [ "$DRY" = 1 ]; then
    echo "  DRY: $SWEEP_SCRIPT"
  else
    CHUMP_REPO_ROOT="$REPO_ROOT" CHUMP_FLEET_ORG="$FLEET_ORG" "$SWEEP_SCRIPT" || true
  fi
}

do_check() {
  local fail=0
  local sup; sup="$(detect_supervisor)"
  case "$sup" in
    systemd-user)
      if systemctl --user is-enabled "$TIMER_NAME" >/dev/null 2>&1; then
        ok "systemd --user timer enabled: $TIMER_NAME"
      else no "systemd --user timer NOT enabled: $TIMER_NAME"; fail=1; fi
      ;;
    cron)
      if crontab -l 2>/dev/null | grep -q "chump-fleet-clone-index"; then ok "cron entry present"
      else no "cron entry missing"; fail=1; fi
      ;;
    *) no "no supervisor available"; fail=1 ;;
  esac
  return "$fail"
}

if [ "$MODE" = "check" ]; then
  do_check
  exit $?
else
  do_install
  exit $?
fi
