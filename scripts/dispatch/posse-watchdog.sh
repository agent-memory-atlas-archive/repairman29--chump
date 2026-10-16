#!/bin/bash
# MISSION-110 — Posse self-healing watchdog
# Monitors the posse-portfolio-scan.service and restarts it on crash
# Logs watchdog events to system journal and file

set -euo pipefail

WATCHDOG_LOG="${HOME}/.chump/posse-watchdog.log"
SERVICE_NAME="posse-portfolio-scan.service"
RESTART_TIMEOUT=30

mkdir -p "$(dirname "$WATCHDOG_LOG")"

log_event() {
  local msg="$1"
  local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "[$timestamp] $msg" | tee -a "$WATCHDOG_LOG"
  logger -t posse-watchdog "$msg"
}

is_service_active() {
  systemctl is-active "$SERVICE_NAME" &>/dev/null
}

restart_service() {
  log_event "Posse service not running, attempting restart..."

  if systemctl start "$SERVICE_NAME" 2>/dev/null; then
    log_event "Successfully restarted Posse service"
    return 0
  else
    log_event "ERROR: Failed to restart Posse service"
    return 1
  fi
}

main() {
  log_event "Posse watchdog started"

  while true; do
    if ! is_service_active; then
      restart_service
      sleep "$RESTART_TIMEOUT"
    fi

    sleep 10
  done
}

main
