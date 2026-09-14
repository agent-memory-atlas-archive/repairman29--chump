#!/usr/bin/env bash
# INFRA-6130: unit tests for scripts/lib/lock.sh — mutual exclusion + timeout.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../lib/lock.sh
source "$REPO_ROOT/scripts/lib/lock.sh"

TMP_LOCK_DIR="$(mktemp -d)"
CHUMP_LOCK_DIR="$TMP_LOCK_DIR"
trap 'rm -rf "$TMP_LOCK_DIR"' EXIT

PASS=0
FAIL=0

_ok() { echo "PASS: $1"; PASS=$(( PASS + 1 )); }
_bad() { echo "FAIL: $1"; FAIL=$(( FAIL + 1 )); }

# 1. Basic acquire + release works.
if acquire_lock "basic" 5; then
  _ok "acquire_lock succeeds when lock is free"
else
  _bad "acquire_lock failed on a free lock"
fi
release_lock "basic"
if [[ ! -d "$(_lock_path basic)" ]]; then
  _ok "release_lock removes the lock dir"
else
  _bad "release_lock left the lock dir behind"
fi

# 2. Mutual exclusion: a second acquire on a held lock must fail fast (short timeout).
acquire_lock "excl" 5 || _bad "setup: could not take initial lock for exclusion test"
start=$(date +%s)
if acquire_lock "excl" 1; then
  _bad "second acquire_lock succeeded while lock was already held (mutual exclusion violated)"
  release_lock "excl"
else
  elapsed=$(( $(date +%s) - start ))
  if [[ "$elapsed" -ge 1 ]]; then
    _ok "second acquire_lock correctly blocked/timed out while held (waited ${elapsed}s)"
  else
    _bad "second acquire_lock returned failure too fast (${elapsed}s) — not actually polling"
  fi
fi
release_lock "excl"

# 3. Timeout behavior: acquire_lock returns nonzero after the configured timeout, not before.
acquire_lock "timeout-test" 5 || _bad "setup: could not take initial lock for timeout test"
start=$(date +%s)
if acquire_lock "timeout-test" 2; then
  _bad "acquire_lock succeeded despite lock being held for the full timeout window"
  release_lock "timeout-test"
else
  elapsed=$(( $(date +%s) - start ))
  if [[ "$elapsed" -ge 2 && "$elapsed" -le 6 ]]; then
    _ok "acquire_lock timed out at approximately the configured window (${elapsed}s)"
  else
    _bad "acquire_lock timeout window off: waited ${elapsed}s, expected ~2s"
  fi
fi
release_lock "timeout-test"

# 4. After release, a waiting acquire can succeed again.
acquire_lock "reacquire" 5 || _bad "setup: could not take initial lock for reacquire test"
release_lock "reacquire"
if acquire_lock "reacquire" 2; then
  _ok "acquire_lock succeeds again after release"
  release_lock "reacquire"
else
  _bad "acquire_lock failed to reacquire a released lock"
fi

echo "=== $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
