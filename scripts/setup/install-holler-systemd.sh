#!/bin/bash
# MISSION-111 — Install holler.service and holler.timer systemd units.
# Usage: bash scripts/setup/install-holler-systemd.sh [--check]

set -euo pipefail

HOLLER_SERVICE="scripts/dispatch/holler.service"
HOLLER_TIMER="scripts/dispatch/holler.timer"
HOLLER_INIT="scripts/ops/holler-init.sh"

SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
SYSTEMD_SYSTEM_DIR="/etc/systemd/system"

# Detect if we're running with sudo/root
if [[ "${EUID:-$(id -u)}" == "0" ]]; then
  TARGET_DIR="$SYSTEMD_SYSTEM_DIR"
  SCOPE="system"
else
  TARGET_DIR="$SYSTEMD_USER_DIR"
  SCOPE="user"
fi

check_mode() {
  local exit_code=0

  if [[ ! -f "$HOLLER_SERVICE" ]]; then
    echo "ERROR: $HOLLER_SERVICE not found" >&2
    exit_code=1
  fi

  if [[ ! -f "$HOLLER_TIMER" ]]; then
    echo "ERROR: $HOLLER_TIMER not found" >&2
    exit_code=1
  fi

  if [[ ! -f "$HOLLER_INIT" ]]; then
    echo "ERROR: $HOLLER_INIT not found" >&2
    exit_code=1
  fi

  if [[ ! -x "$HOLLER_INIT" ]]; then
    echo "ERROR: $HOLLER_INIT is not executable" >&2
    exit_code=1
  fi

  if [[ ! -d "$TARGET_DIR" ]]; then
    echo "ERROR: systemd $SCOPE directory $TARGET_DIR not found" >&2
    exit_code=1
  fi

  if [[ $exit_code -eq 0 ]]; then
    echo "✓ All holler prerequisites met"
  fi

  return $exit_code
}

install_units() {
  mkdir -p "$TARGET_DIR"

  cp "$HOLLER_SERVICE" "$TARGET_DIR/holler.service"
  cp "$HOLLER_TIMER" "$TARGET_DIR/holler.timer"

  echo "✓ Installed holler.service to $TARGET_DIR/holler.service"
  echo "✓ Installed holler.timer to $TARGET_DIR/holler.timer"

  # Reload systemd to pick up new units
  if [[ "$SCOPE" == "system" ]]; then
    systemctl daemon-reload
  else
    systemctl --user daemon-reload
  fi

  echo "✓ Reloaded systemd $SCOPE daemon"

  echo ""
  echo "Installation complete. To enable and start the holler timer:"
  echo "  systemctl --${SCOPE} enable --now holler.timer"
  echo ""
  echo "To verify installation:"
  echo "  systemctl --${SCOPE} list-timers holler.timer"
  echo "  journalctl --${SCOPE}-unit holler.service"
}

main() {
  if [[ "${1:-}" == "--check" ]]; then
    check_mode
    return $?
  fi

  check_mode || {
    echo ""
    echo "Cannot proceed with installation. Fix errors above." >&2
    return 1
  }

  install_units
}

main "$@"
