#!/usr/bin/env bash
# scripts/coord/shared-target-cache-reaper.sh — RESILIENT-1045 / RESILIENT-1680
#
# A routine, scoped prune of the shared cargo build cache
# (~/.cargo/chump-shared-target). It reaps ONLY the rebuildable incremental
# caches (every `incremental/` dir under the target — `debug/incremental`,
# `release/incremental`, and the per-toolchain `<triple>/<profile>/incremental`
# dirs) — never the whole target. CI builds the fleet with CARGO_INCREMENTAL=0,
# so these dirs are pure regrowing waste: on cuphead debug/incremental alone
# reached 21G within a day (RESILIENT-1635 evidence), and the previous version
# of this script did a blunt `rm -rf` of the ENTIRE target only once it crossed
# a 50G env-overridable cap — so between caps it grew unbounded and, when it did
# fire, it threw away the whole reusable compile cache, not just the garbage.
#
# RESILIENT-1680 changes vs. RESILIENT-1045:
#   - Reap scope is now `incremental/` dirs only, never the whole target.
#   - It fires when free disk on the target's filesystem is under a FLOOR or
#     the target is over a size BUDGET (either trigger), not only over a cap.
#   - The floor, the budget and the target path are constants (defaults below)
#     or CLI args the systemd unit/timer passes — NEVER environment variables.
#     The CHUMP_SHARED_TARGET_CAP_GB / CHUMP_SHARED_TARGET / *_OVERRIDE env
#     reads are removed (a CHUMP_* env default on a safety input — a path, a
#     disk floor, a size budget — is a bypass by construction; standing rule,
#     Chief 2026-10-20). Tests exercise the real code under a sandbox HOME.
#   - Before it deletes anything it takes BOTH architect lane locks
#     (~/.chump/architect-lane.lock and ~/.chump/architect-lane2.lock, the two
#     fixed HOME-relative locks the architect's own guarded reclaim takes — see
#     ~/drop-incr.sh), passes `chump admit cargo`, and verifies no cargo, rustc,
#     cargo-nextest or rustdoc process is alive — otherwise it skips the tick
#     with a logged reason. This is the same guard the architect ran by hand;
#     the Chief ruled that hand-reclaim was the last time a human does it.
#
# This is a routine prune, not an emergency response: no daemon killing, no
# AUTONOMY_LEVEL halt, no operator page. It is safe to run on every
# disk-pressure-reaper tick (wired in there) or standalone via systemd/cron.
#
# Usage:
#   shared-target-cache-reaper.sh                       # dry-run (default)
#   shared-target-cache-reaper.sh --execute             # actually delete
#   shared-target-cache-reaper.sh --execute \
#       --target DIR --floor-gb N --budget-gb N         # explicit (unit-passed)
#
# Exit status is 0 on every normal path (reap, skip, nothing-to-do); 2 on a bad
# CLI argument.

set -uo pipefail

# ── Safety inputs: constants (defaults) or CLI args the unit passes, NEVER env.
# A CHUMP_* env default on any of these would re-open the exact bypass the
# standing rule bans, so none of them is read from the environment.
FLOOR_GB_DEFAULT=25                                  # reap if free disk < this (GB)
BUDGET_GB_DEFAULT=15                                 # reap if target size > this (GB)
TARGET_DEFAULT="$HOME/.cargo/chump-shared-target"    # HOME-relative; sandbox HOME in tests

TARGET="$TARGET_DEFAULT"
FLOOR_GB="$FLOOR_GB_DEFAULT"
BUDGET_GB="$BUDGET_GB_DEFAULT"
EXECUTE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --execute)      EXECUTE=1 ;;
    --target)       TARGET="${2:?--target needs a value}"; shift ;;
    --target=*)     TARGET="${1#*=}" ;;
    --floor-gb)     FLOOR_GB="${2:?--floor-gb needs a value}"; shift ;;
    --floor-gb=*)   FLOOR_GB="${1#*=}" ;;
    --budget-gb)    BUDGET_GB="${2:?--budget-gb needs a value}"; shift ;;
    --budget-gb=*)  BUDGET_GB="${1#*=}" ;;
    *) echo "[shared-target-cache-reaper] unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

# The two architect lane locks are FIXED under HOME — no env override (the same
# discipline Class D's node build lane lock uses). Tests set HOME to a sandbox.
LANE_LOCK_1="$HOME/.chump/architect-lane.lock"
LANE_LOCK_2="$HOME/.chump/architect-lane2.lock"

# Ambient sink is an observability path, not a safety input (it changes nothing
# about what is deleted); keep the fleet-standard CHUMP_AMBIENT_LOG override so
# consumers and tests can point it, defaulting under the repo root.
REPO_ROOT="${CHUMP_REPO_ROOT:-${CHUMP_REPO:-${CHUMP_HOME:-$(pwd)}}}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
emit() {
  local dir; dir="$(dirname "$AMBIENT")"
  [[ -d "$dir" ]] || return 0
  printf '{"ts":"%s",%s}\n' "$(ts)" "$1" >> "$AMBIENT" 2>/dev/null || true
}

skip() {  # <human-reason> <ambient-reason-token>
  echo "[shared-target-cache-reaper] skipped: $1"
  # scanner-anchor: "kind":"shared_target_incremental_reap_skipped"
  emit "\"kind\":\"shared_target_incremental_reap_skipped\",\"target\":\"$TARGET\",\"reason\":\"$2\""
  exit 0
}

# Apparent target size in GB (du rounds up, so a non-empty dir is >= 1G).
target_gb() {
  [[ -d "$TARGET" ]] || { echo 0; return 0; }
  du -s -BG "$TARGET" 2>/dev/null | awk '{gsub(/G/,"",$1); print $1+0; exit}' || echo 0
}

# Free disk in GB on the filesystem that holds the target (or its parent, if the
# target itself does not exist yet).
free_gb() {
  local probe="$TARGET"
  [[ -d "$probe" ]] || probe="$(dirname "$TARGET")"
  df -BG "$probe" 2>/dev/null | awk 'NR==2 {gsub(/G/,"",$4); print $4+0; exit}' || echo 999
}

# Hard guard: a live build must never have its incremental cache pulled out
# from under it. Checks the four build-process names the architect's hand
# reclaim checked. `pgrep` is resolved from PATH exactly like every other
# command here — production never reads an env var to choose the binary; tests
# shadow pgrep on PATH under the sandbox.
build_in_progress() {
  pgrep -x cargo         >/dev/null 2>&1 && return 0
  pgrep -x rustc         >/dev/null 2>&1 && return 0
  pgrep -x cargo-nextest >/dev/null 2>&1 && return 0
  pgrep -x rustdoc       >/dev/null 2>&1 && return 0
  return 1
}

cur_gb="$(target_gb)"; cur_gb="${cur_gb:-0}"
avail_gb="$(free_gb)"; avail_gb="${avail_gb:-999}"

if [[ ! -d "$TARGET" ]]; then
  echo "[shared-target-cache-reaper] ${TARGET} does not exist — nothing to do"
  exit 0
fi

over_budget=0; (( cur_gb > BUDGET_GB )) && over_budget=1
under_floor=0; (( avail_gb < FLOOR_GB )) && under_floor=1

if (( over_budget == 0 && under_floor == 0 )); then
  echo "[shared-target-cache-reaper] ${TARGET} is ${cur_gb}G (budget ${BUDGET_GB}G) and free disk ${avail_gb}G (floor ${FLOOR_GB}G) — nothing to do"
  exit 0
fi

reason="over budget (${cur_gb}G > ${BUDGET_GB}G)"
(( under_floor == 1 )) && reason="free disk under floor (${avail_gb}G < ${FLOOR_GB}G)"
echo "[shared-target-cache-reaper] ${TARGET}: ${reason} — considering an incremental-cache reap"

# ── Guards (each one skips the whole tick with a logged reason) ──────────────

# 1. No live build.
if build_in_progress; then
  skip "a cargo/rustc/cargo-nextest/rustdoc build is in progress" "build_in_progress"
fi

# 2. chump admit cargo must admit.
if ! command -v chump >/dev/null 2>&1; then
  skip "chump not on PATH, cannot run the chump admit cargo admission check" "chump_absent"
fi
if ! chump admit cargo >/dev/null 2>&1; then
  skip "chump admit cargo refused" "admit_refused"
fi

# 3+4. BOTH architect lane locks must be free. flock(1) is required; without it
# the tick cannot prove the lanes are idle, so it fails closed and skips.
if ! command -v flock >/dev/null 2>&1; then
  skip "flock unavailable, cannot take the architect lane locks" "flock_absent"
fi
mkdir -p "$HOME/.chump" 2>/dev/null || true
if ! { exec 8>>"$LANE_LOCK_1"; } 2>/dev/null; then
  skip "cannot open architect lane-1 lock ${LANE_LOCK_1}" "lane1_open_failed"
fi
if ! flock -n 8 2>/dev/null; then
  exec 8>&-
  skip "architect lane-1 lock held (${LANE_LOCK_1})" "lane1_held"
fi
if ! { exec 9>>"$LANE_LOCK_2"; } 2>/dev/null; then
  flock -u 8 2>/dev/null || true; exec 8>&-
  skip "cannot open architect lane-2 lock ${LANE_LOCK_2}" "lane2_open_failed"
fi
if ! flock -n 9 2>/dev/null; then
  exec 9>&-
  flock -u 8 2>/dev/null || true; exec 8>&-
  skip "architect lane-2 lock held (${LANE_LOCK_2})" "lane2_held"
fi

release_locks() {
  flock -u 9 2>/dev/null || true; exec 9>&-
  flock -u 8 2>/dev/null || true; exec 8>&-
}

# ── Reap scope: every `incremental/` dir under the target, never the target. ─
mapfile -t INCR < <(find "$TARGET" -type d -name incremental -prune 2>/dev/null)
if (( ${#INCR[@]} == 0 )); then
  release_locks
  echo "[shared-target-cache-reaper] ${TARGET}: no incremental caches to reap — leaving target intact"
  # scanner-anchor: "kind":"shared_target_incremental_reap_skipped"
  emit "\"kind\":\"shared_target_incremental_reap_skipped\",\"target\":\"$TARGET\",\"reason\":\"no_incremental_dirs\""
  exit 0
fi

if (( EXECUTE == 0 )); then
  release_locks
  echo "[shared-target-cache-reaper] DRY-RUN: would reap ${#INCR[@]} incremental dir(s) under ${TARGET} (${reason}); re-run with --execute:"
  printf '    %s\n' "${INCR[@]}"
  # scanner-anchor: "kind":"shared_target_incremental_reap_dryrun"
  emit "\"kind\":\"shared_target_incremental_reap_dryrun\",\"target\":\"$TARGET\",\"incremental_dirs\":${#INCR[@]},\"target_gb\":$cur_gb,\"free_gb\":$avail_gb"
  exit 0
fi

reaped=0
for d in "${INCR[@]}"; do
  # Defensive: only ever delete a dir literally named "incremental" under the
  # target, never the target root itself.
  [[ "$(basename "$d")" == incremental && "$d" != "$TARGET" ]] || continue
  rm -rf -- "$d" 2>/dev/null && reaped=$((reaped + 1))
done
after_gb="$(target_gb)"; after_gb="${after_gb:-$cur_gb}"
freed=$(( cur_gb - after_gb )); (( freed < 0 )) && freed=0
release_locks

echo "[shared-target-cache-reaper] reaped ${reaped} incremental dir(s) under ${TARGET} (~${freed}G freed, target preserved)"
# scanner-anchor: "kind":"shared_target_incremental_reaped"
emit "\"kind\":\"shared_target_incremental_reaped\",\"target\":\"$TARGET\",\"incremental_dirs\":$reaped,\"freed_gb_approx\":$freed,\"target_gb_before\":$cur_gb"
