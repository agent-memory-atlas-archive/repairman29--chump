#!/usr/bin/env bash
# lock.sh — reusable file-based lock primitive for bash scripts (INFRA-6130,
# INFRA-1966 slice).
#
# Provides acquire_lock/release_lock built on `mkdir`, which is atomic on
# every POSIX filesystem (no flock binary dependency, so it works
# unconditionally in CI runners and macOS/Linux alike — see
# scripts/lib/discover-flock.sh for the flock-availability problems this
# sidesteps).
#
# Usage:
#   source scripts/lib/lock.sh
#   if acquire_lock "my-lock-name" 30; then
#     ...critical section...
#     release_lock "my-lock-name"
#   else
#     echo "timed out waiting for lock" >&2
#   fi
#
# Env:
#   CHUMP_LOCK_DIR   directory holding lock directories (default: .chump-locks)
#   CHUMP_LOCK_POLL_INTERVAL_S  poll interval while waiting (default: 0.2)

set -uo pipefail

CHUMP_LOCK_DIR="${CHUMP_LOCK_DIR:-.chump-locks}"
CHUMP_LOCK_POLL_INTERVAL_S="${CHUMP_LOCK_POLL_INTERVAL_S:-0.2}"

_lock_path() {
  local name="$1"
  local sanitized
  sanitized="$(printf '%s' "$name" | tr '/' '_' | tr -c '[:alnum:]._-' '_')"
  printf '%s/lock-%s.d' "$CHUMP_LOCK_DIR" "$sanitized"
}

# acquire_lock <name> [timeout_seconds]
#
# Atomically acquires a lock identified by <name>. Blocks (polling) until
# the lock is free or <timeout_seconds> elapses (default: 10). Writes this
# process's PID into the lock dir so a stale lock (owner process dead) can
# be diagnosed/reaped by callers.
#
# Returns 0 on success, 1 on timeout.
acquire_lock() {
  local name="$1"
  local timeout="${2:-10}"
  local lockdir
  lockdir="$(_lock_path "$name")"
  mkdir -p "$CHUMP_LOCK_DIR" 2>/dev/null || true

  local waited=0
  local start_ts
  start_ts=$(date +%s)
  while true; do
    if mkdir "$lockdir" 2>/dev/null; then
      printf '%s\n' "$$" > "$lockdir/pid" 2>/dev/null || true
      return 0
    fi
    waited=$(( $(date +%s) - start_ts ))
    if [[ "$waited" -ge "$timeout" ]]; then
      return 1
    fi
    sleep "$CHUMP_LOCK_POLL_INTERVAL_S"
  done
}

# release_lock <name>
#
# Releases a lock previously acquired via acquire_lock. Safe to call even
# if the lock is not currently held (no-op).
release_lock() {
  local name="$1"
  local lockdir
  lockdir="$(_lock_path "$name")"
  rm -rf "$lockdir" 2>/dev/null || true
}
