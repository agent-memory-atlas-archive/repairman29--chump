#!/usr/bin/env bash
# RESILIENT-1569: worker timeout must SIGKILL a TERM-ignoring process.
set -u
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO_ROOT/scripts/dispatch/lib/worker-timeout.sh"
CHUMP_TIMEOUT_KILL_AFTER_S=1
pfx="$(build_timeout_prefix 1)"
case "$pfx" in *"-k 1s 1s") ;; *) echo "FAIL: prefix '$pfx'"; exit 1;; esac
start=$(date +%s)
$pfx bash -c 'trap "" TERM; while :; do sleep 0.2; done'
rc=$?
el=$(( $(date +%s) - start ))
[ "$el" -le 6 ] || { echo "FAIL: took ${el}s"; exit 1; }
[ "$rc" -eq 137 ] || { echo "FAIL: rc=$rc (want 137)"; exit 1; }
echo "PASS"
