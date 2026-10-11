#!/usr/bin/env bash
# disk-reclaim-actuator.sh — RESILIENT-1565
#
# Consumes the infra-watcher disk_headroom finding and ACTS: reclaims disk
# idle-gated and high/low-water bounded. Never interrupts a live build.
#
#   high-water: act when free GB < CHUMP_DISK_RECLAIM_HIGH_GB (default 35)
#   low-water : stop reclaiming once free GB >= CHUMP_DISK_RECLAIM_LOW_GB (default 50)
#   idle gate : skip entirely while a rustc/cargo build is running
#
# Usage: disk-reclaim-actuator.sh [--execute]   (default: dry-run)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CHUMP_REPO:-$(cd "$HERE/../.." && pwd)}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
HIGH_GB="${CHUMP_DISK_RECLAIM_HIGH_GB:-35}"
LOW_GB="${CHUMP_DISK_RECLAIM_LOW_GB:-50}"
EXECUTE=0
[[ "${1:-}" == "--execute" ]] && EXECUTE=1

emit() {
  mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true
  printf '{"ts":"%s","kind":"disk_reclaim","detail":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$AMBIENT" 2>/dev/null || true
}

free_gb() {
  if [[ -n "${CHUMP_DISK_RECLAIM_FREE_GB_FILE:-}" ]]; then cat "$CHUMP_DISK_RECLAIM_FREE_GB_FILE"; return; fi
  local kb; kb="$(df -k "$HOME" 2>/dev/null | awk 'NR==2{print $4}')"
  [[ "$kb" =~ ^[0-9]+$ ]] && echo $(( kb / 1024 / 1024 )) || echo 9999
}

build_live() {
  [[ -n "${CHUMP_DISK_RECLAIM_BUILD_LIVE:-}" ]] && return "$((1 - CHUMP_DISK_RECLAIM_BUILD_LIVE))"
  pgrep -f 'rustc|cargo (build|test|fix|check|clippy)' >/dev/null 2>&1
}

run_step() {
  local name="$1"; shift
  if [[ "$EXECUTE" -eq 0 ]]; then echo "[disk-reclaim] DRY-RUN step=$name"; return 0; fi
  echo "[disk-reclaim] step=$name"
  "$@" >/dev/null 2>&1 || true
}

start="$(free_gb)"
if (( start >= HIGH_GB )); then
  echo "[disk-reclaim] free=${start}GB >= high-water ${HIGH_GB}GB — nothing to do"; exit 0
fi
if build_live; then
  echo "[disk-reclaim] free=${start}GB below high-water but a build is live — deferring"
  emit "deferred_live_build free=${start}GB"; exit 0
fi

reached() { (( $(free_gb) >= LOW_GB )); }

steps=(
  "stale-worktrees|bash $REPO_ROOT/scripts/ops/stale-worktree-reaper.sh --execute"
  "pressure-reaper|bash $HERE/disk-pressure-reaper.sh --execute"
  "binary-refresh-tmp|find /tmp -maxdepth 1 -name 'chump-binary-refresh-*' -mmin +120 -exec rm -rf {} +"
  "cargo-registry-cache|bash -c 'rm -rf \"\${CARGO_HOME:-\$HOME/.cargo}\"/registry/cache \"\${CARGO_HOME:-\$HOME/.cargo}\"/registry/src'"
)
for s in "${steps[@]}"; do
  reached && break
  build_live && { emit "aborted_live_build"; break; }
  name="${s%%|*}"; cmd="${s#*|}"
  # shellcheck disable=SC2086
  run_step "$name" bash -c "$cmd"
done
end="$(free_gb)"
emit "reclaimed start=${start}GB end=${end}GB execute=${EXECUTE} low_water=${LOW_GB}GB"
echo "[disk-reclaim] free ${start}GB -> ${end}GB"
exit 0
