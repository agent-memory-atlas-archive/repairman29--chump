#!/usr/bin/env bash
# install_chump_gap_timer.sh — RESILIENT-1370
#
# Install chump-gap-close-decomposed systemd timer and service to ~/.config/systemd/user/
# This timer runs periodically to auto-close decomposed umbrella gaps when all child slices
# are done (see RESILIENT-1366 for context).
#
# Usage:
#   scripts/install_chump_gap_timer.sh              # install + enable + activate
#   scripts/install_chump_gap_timer.sh --check      # verify only, exit non-zero if incomplete
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SERVICE_SRC="$REPO_ROOT/contrib/systemd/chump-gap-close-decomposed.service"
TIMER_SRC="$REPO_ROOT/scripts/dispatch/chump-gap-close-decomposed.timer"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"

SERVICE_NAME="chump-gap-close-decomposed.service"
TIMER_NAME="chump-gap-close-decomposed.timer"

MODE="install"
for a in "$@"; do
  case "$a" in
    --check) MODE="check" ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done

ok(){ printf '  \033[32m✓\033[0m %s\n' "$*"; }
no(){ printf '  \033[31m✗\033[0m %s\n' "$*"; }
info(){ printf '\033[36m[CHUMP-GAP-TIMER]\033[0m %s\n' "$*"; }

do_install() {
  local fail=0

  # Verify source files exist
  if [ ! -f "$SERVICE_SRC" ]; then
    no "service file not found: $SERVICE_SRC"
    return 1
  fi
  if [ ! -f "$TIMER_SRC" ]; then
    no "timer file not found: $TIMER_SRC"
    return 1
  fi

  # Create systemd user directory if it doesn't exist
  mkdir -p "$SYSTEMD_USER_DIR" || { no "failed to create $SYSTEMD_USER_DIR"; return 1; }

  # Copy service and timer files
  cp "$SERVICE_SRC" "$SYSTEMD_USER_DIR/$SERVICE_NAME" || { no "failed to copy service file"; return 1; }
  ok "copied $SERVICE_NAME to $SYSTEMD_USER_DIR"

  cp "$TIMER_SRC" "$SYSTEMD_USER_DIR/$TIMER_NAME" || { no "failed to copy timer file"; return 1; }
  ok "copied $TIMER_NAME to $SYSTEMD_USER_DIR"

  # Reload systemd configuration
  systemctl --user daemon-reload || { no "systemctl --user daemon-reload failed"; return 1; }
  ok "systemctl --user daemon-reload"

  # Enable and start the timer
  systemctl --user enable --now "$TIMER_NAME" || { no "systemctl --user enable --now failed"; return 1; }
  ok "systemctl --user enable --now $TIMER_NAME"

  # Verify the timer is active
  if systemctl --user is-active "$TIMER_NAME" >/dev/null 2>&1; then
    ok "timer is active: $TIMER_NAME"
  else
    no "timer is not active after installation"
    return 1
  fi

  info "installation complete"
  return 0
}

do_check() {
  local fail=0

  # Check if service file is in place
  if [ -f "$SYSTEMD_USER_DIR/$SERVICE_NAME" ]; then
    ok "service file exists: $SYSTEMD_USER_DIR/$SERVICE_NAME"
  else
    no "service file missing: $SYSTEMD_USER_DIR/$SERVICE_NAME"
    fail=1
  fi

  # Check if timer file is in place
  if [ -f "$SYSTEMD_USER_DIR/$TIMER_NAME" ]; then
    ok "timer file exists: $SYSTEMD_USER_DIR/$TIMER_NAME"
  else
    no "timer file missing: $SYSTEMD_USER_DIR/$TIMER_NAME"
    fail=1
  fi

  # Check if timer is enabled
  if systemctl --user is-enabled "$TIMER_NAME" >/dev/null 2>&1; then
    ok "timer is enabled: $TIMER_NAME"
  else
    no "timer is not enabled: $TIMER_NAME"
    fail=1
  fi

  # Check if timer is active
  if systemctl --user is-active "$TIMER_NAME" >/dev/null 2>&1; then
    ok "timer is active: $TIMER_NAME"
  else
    no "timer is not active: $TIMER_NAME"
    fail=1
  fi

  return "$fail"
}

if [ "$MODE" = "check" ]; then
  info "checking installation"
  do_check
  exit $?
else
  info "installing chump-gap-close-decomposed timer"
  do_install
  exit $?
fi
