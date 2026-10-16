#!/bin/bash
# MISSION-109 — Install posse-portfolio-scan.service and posse-portfolio-scan.timer systemd units.
# Usage: bash scripts/setup/install-posse-systemd.sh [--check]

set -euo pipefail

POSSE_SERVICE="scripts/dispatch/posse-portfolio-scan.service"
POSSE_TIMER="scripts/dispatch/posse-portfolio-scan.timer"

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

  if [[ ! -f "$POSSE_SERVICE" ]]; then
    echo "ERROR: $POSSE_SERVICE not found" >&2
    exit_code=1
  fi

  if [[ ! -f "$POSSE_TIMER" ]]; then
    echo "ERROR: $POSSE_TIMER not found" >&2
    exit_code=1
  fi

  if [[ ! -d "$TARGET_DIR" ]]; then
    echo "ERROR: systemd $SCOPE directory $TARGET_DIR not found" >&2
    exit_code=1
  fi

  if [[ $exit_code -eq 0 ]]; then
    echo "✓ All posse prerequisites met"
  fi

  return $exit_code
}

install_units() {
  mkdir -p "$TARGET_DIR"

  cp "$POSSE_SERVICE" "$TARGET_DIR/posse-portfolio-scan.service"
  cp "$POSSE_TIMER" "$TARGET_DIR/posse-portfolio-scan.timer"

  echo "✓ Installed posse-portfolio-scan.service to $TARGET_DIR/posse-portfolio-scan.service"
  echo "✓ Installed posse-portfolio-scan.timer to $TARGET_DIR/posse-portfolio-scan.timer"

  # Reload systemd to pick up new units
  if [[ "$SCOPE" == "system" ]]; then
    systemctl daemon-reload
  else
    systemctl --user daemon-reload
  fi

  echo "✓ Reloaded systemd $SCOPE daemon"

  echo ""
  echo "Installation complete. To enable and start the posse timer:"
  echo "  systemctl --${SCOPE} enable --now posse-portfolio-scan.timer"
  echo ""
  echo "To verify installation:"
  echo "  systemctl --${SCOPE} list-timers posse-portfolio-scan.timer"
  echo "  journalctl --${SCOPE}-unit posse-portfolio-scan.service"
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
