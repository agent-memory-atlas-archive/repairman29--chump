#!/usr/bin/env bash
# disk-check.sh — INFRA-975
#
# Disk-pressure gates for chump claim + worker. The fleet creates ~5-9 GB
# linked worktrees (each one carries its own cargo target/), so a multi-
# hour run with parallel claims can fill /private/tmp easily. We learned
# this the hard way 2026-05-13: 60+ GB of stale target/ dirs broke every
# install attempt for hours.
#
# Sourceable. Two public functions:
#
#   chump_disk_free_gb [path]
#       Echo integer GB free on the filesystem hosting `path` (default: .).
#       Empty output on probe failure.
#
#   chump_disk_check_or_abort
#       Used by gap-claim.sh. If free < CHUMP_DISK_LOW_GB (default 5),
#       emit kind=claim_aborted_disk_full and `exit 1`. Honors
#       CHUMP_DISK_CHECK_DISABLE=1 escape hatch.
#
#   chump_disk_check_pause_worker
#       Used by worker.sh. If free < CHUMP_DISK_CRITICAL_GB (default 1) OR
#       any path in CHUMP_DISK_PRESSURE_PATHS is >= CHUMP_DISK_PRESSURE_PCT
#       (default 90) percent used, emit kind=fleet_paused_disk_critical /
#       kind=disk_pressure_pause (respectively), best-effort page the
#       operator via operator-recall.sh, and return 1 (caller pauses).
#       Returns 0 when fine. Honors CHUMP_DISK_CHECK_DISABLE=1.
#
#   chump_disk_pressure_check
#       RESILIENT-1444: percentage-based guard. Checks df-reported percent-
#       used for every path in CHUMP_DISK_PRESSURE_PATHS (space-separated,
#       default "REPO_ROOT/."). If any path is >= CHUMP_DISK_PRESSURE_PCT
#       (default 90), emits kind=disk_pressure_pause to ambient.jsonl, pages
#       the operator (best-effort, via scripts/dispatch/operator-recall.sh
#       if present), and returns 1. Standalone callers (fleet-doctor) can
#       use this directly instead of failing gaps into abandoned worktrees.
#
# Env:
#   CHUMP_DISK_LOW_GB         claim-abort threshold (default 5)
#   CHUMP_DISK_CRITICAL_GB    worker-pause threshold (default 1)
#   CHUMP_DISK_PRESSURE_PCT   percent-used pause threshold (default 90)
#   CHUMP_DISK_PRESSURE_PATHS space-separated paths to check (default: REPO_ROOT or cwd)
#   CHUMP_DISK_CHECK_DISABLE  =1 short-circuits all checks (escape hatch)
#   CHUMP_DISK_CHECK_PATH     filesystem to probe (default = cwd)
#   CHUMP_AMBIENT_LOG         ambient.jsonl path (default .chump-locks/ambient.jsonl)

# Idempotent guard so multiple sources don't re-define.
[[ "${_CHUMP_DISK_CHECK_LOADED:-0}" == "1" ]] || {
_CHUMP_DISK_CHECK_LOADED=1

_dc_log() { printf '[disk-check] %s\n' "$*" >&2; }

# Echo integer GB free on $1's filesystem.
chump_disk_free_gb() {
  local path="${1:-${CHUMP_DISK_CHECK_PATH:-.}}"
  # df -k → 1KB blocks. Available is column 4 on macOS + Linux.
  local kb
  kb="$(df -k "$path" 2>/dev/null | awk 'NR==2 { print $4 }')"
  [[ -z "$kb" || ! "$kb" =~ ^[0-9]+$ ]] && return 0
  printf '%d' $(( kb / 1024 / 1024 ))
}

_dc_emit() {
  local kind="$1"; shift
  local amb="${CHUMP_AMBIENT_LOG:-${REPO_ROOT:-.}/.chump-locks/ambient.jsonl}"
  mkdir -p "$(dirname "$amb")" 2>/dev/null || true
  printf '{"ts":"%s","kind":"%s",%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$kind" "$*" \
    >> "$amb" 2>/dev/null || true
}

# Echo integer percent-used (0-100) on $1's filesystem. Empty on probe failure.
chump_disk_used_pct() {
  local path="${1:-.}"
  local pct
  # df -k → column 5 is "Use%" (e.g. "87%") on both macOS and Linux.
  pct="$(df -k "$path" 2>/dev/null | awk 'NR==2 { gsub(/%/,"",$5); print $5 }')"
  [[ -z "$pct" || ! "$pct" =~ ^[0-9]+$ ]] && return 0
  printf '%d' "$pct"
}

# Loud, visible page. The disk_pressure_pause ambient event is the durable
# signal other watchers (operator-recall, fleet-doctor) act on; this is the
# immediate stderr surface for whoever is attached to this process right now.
_dc_page_operator() {
  local reason="$1"
  _dc_log "PAGE (disk pressure): $reason"
}

# RESILIENT-1444: percentage-based disk-pressure guard. Returns 1 (pause) if
# any configured path is at/above CHUMP_DISK_PRESSURE_PCT percent used.
chump_disk_pressure_check() {
  [[ "${CHUMP_DISK_CHECK_DISABLE:-0}" == "1" ]] && return 0
  local threshold="${CHUMP_DISK_PRESSURE_PCT:-90}"
  local paths="${CHUMP_DISK_PRESSURE_PATHS:-${REPO_ROOT:-.}}"
  local path pct breached=0
  for path in $paths; do
    pct=$(chump_disk_used_pct "$path")
    [[ -z "$pct" ]] && continue
    if [[ "$pct" -ge "$threshold" ]]; then
      breached=1
      _dc_log "PAUSE: $path is ${pct}% used >= threshold ${threshold}%"
      _dc_emit "disk_pressure_pause" \
        '"path":"'"$path"'","used_pct":'"$pct"',"threshold_pct":'"$threshold"
      _dc_page_operator "disk_pressure_pause: $path at ${pct}% (threshold ${threshold}%)"
    fi
  done
  [[ "$breached" == "1" ]] && return 1
  return 0
}

# gap-claim.sh pre-check. Exits 1 when free < threshold.
chump_disk_check_or_abort() {
  [[ "${CHUMP_DISK_CHECK_DISABLE:-0}" == "1" ]] && return 0
  local threshold="${CHUMP_DISK_LOW_GB:-5}"
  local free; free=$(chump_disk_free_gb)
  [[ -z "$free" ]] && return 0  # probe failed; fail open

  if [[ "$free" -lt "$threshold" ]]; then
    _dc_log "ABORT: disk free ${free}GB < threshold ${threshold}GB"
    _dc_log "       Re-run after pruning worktrees / cargo target dirs."
    _dc_log "       Bypass: CHUMP_DISK_CHECK_DISABLE=1 (e.g. when you know you have"
    _dc_log "       just-freed space about to come through df)."
    _dc_emit "claim_aborted_disk_full" \
      '"free_gb":'"$free"',"threshold_gb":'"$threshold"',"path":"'"${CHUMP_DISK_CHECK_PATH:-$(pwd)}"'"'
    exit 1
  fi
  return 0
}

# worker.sh pre-cycle check. Returns 1 when caller should pause.
chump_disk_check_pause_worker() {
  [[ "${CHUMP_DISK_CHECK_DISABLE:-0}" == "1" ]] && return 0
  local threshold="${CHUMP_DISK_CRITICAL_GB:-1}"
  local free; free=$(chump_disk_free_gb)
  [[ -z "$free" ]] && return 0

  if [[ "$free" -lt "$threshold" ]]; then
    _dc_log "PAUSE: disk free ${free}GB < critical ${threshold}GB"
    _dc_emit "fleet_paused_disk_critical" \
      '"free_gb":'"$free"',"threshold_gb":'"$threshold"',"path":"'"${CHUMP_DISK_CHECK_PATH:-$(pwd)}"'"'
    return 1
  fi

  # RESILIENT-1444: percentage-based guard runs alongside the GB-based one —
  # a large filesystem (e.g. 100+ GB) can be at 95% used while still clearing
  # the absolute-GB threshold above.
  chump_disk_pressure_check || return 1

  return 0
}

}  # end idempotent guard
