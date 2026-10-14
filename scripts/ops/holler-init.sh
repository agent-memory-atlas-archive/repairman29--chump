#!/bin/bash
# MISSION-111 — holler service initialization. Loads HOLLER_SERVICE_KEY from
# secret manager or env file, validates it, and initializes alert emission.
# Called by holler.service at boot time.

set -euo pipefail

HOLLER_KEY_FILE="${HOLLER_KEY_FILE:-/root/.chump/holler-key}"
HOLLER_LOG="${HOLLER_LOG:-/var/log/holler.log}"

init_holler_key() {
  # Load HOLLER_SERVICE_KEY from environment or file
  if [[ -z "${HOLLER_SERVICE_KEY:-}" ]]; then
    if [[ -f "$HOLLER_KEY_FILE" ]]; then
      export HOLLER_SERVICE_KEY="$(cat "$HOLLER_KEY_FILE")"
    else
      echo "ERROR: HOLLER_SERVICE_KEY not set in environment and $HOLLER_KEY_FILE not found" >&2
      return 1
    fi
  fi

  # Validate the key is non-empty
  if [[ -z "$HOLLER_SERVICE_KEY" ]]; then
    echo "ERROR: HOLLER_SERVICE_KEY is empty" >&2
    return 1
  fi

  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] HOLLER_SERVICE_KEY loaded successfully" >> "$HOLLER_LOG" 2>/dev/null || true
  return 0
}

enable_holler_timer() {
  # Mark holler service as initialized so timer can proceed
  touch /var/run/holler-initialized
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Holler service initialized, timer enabled" >> "$HOLLER_LOG" 2>/dev/null || true
}

main() {
  init_holler_key || exit 1
  enable_holler_timer
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Holler initialization complete" >> "$HOLLER_LOG" 2>/dev/null || true
}

main "$@"
