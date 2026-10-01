#!/usr/bin/env bash
# node-orchestrator.sh — the OS's resource-aware self-orchestration loop (RESILIENT-318 / DISK_AWARE_FLEET).
#
# Makes a node HARDWARE-AWARE and self-managing so sizing workers + placing storage
# is the OS's job, not a hand-op. One control loop: SENSE -> DECIDE -> ACT.
#   SENSE  — cores, load, RAM-free, disk-free per mounted volume -> resource-inventory.json
#   HEAL   — ensure the housekeeping organs (reapers + disk-monitor) are running; restart if down
#   SCALE  — worker pool tracks capacity: target = clamp(1 .. cores-1) by load + free RAM, with hysteresis
#   ENFORCE— WORKER_MAX is a hard cap, checked EVERY tick regardless of hysteresis or how the drift
#            happened (hand-started extra worker, installer bug, etc) — RESILIENT-328. Also throttles
#            scale-UP (never scale-down/heal/place) when the merge pipeline is CI-saturated: reads the
#            most recent kind=merge_queue_health ambient event and honors backpressure_recommended so
#            workers stop over-producing PRs the merge pipeline cannot drain. Also caps AGGREGATE cargo
#            parallelism (worker_count * CARGO_BUILD_JOBS) to CORES by writing a managed [build] jobs
#            block into ~/.cargo/config.toml — INFRA-3659, durable version of a hand-cap (see
#            cargo_jobs_cap()/enforce_cargo_jobs()).
#   PLACE  — under sustained disk pressure, relocate heavy churn (cargo) to the largest-free volume
#            GRACEFULLY: background rsync (fleet stays up) -> atomic symlink swap -> validate.
#            Foreground mv is BANNED (it wedged the fleet 50min on 2026-08-19, unkillable D-state).
#            Auto-execute is OFF by default (CHUMP_ORCH_AUTOPLACE=1 to arm) — senses+recommends until proven.
#
# Host-agnostic supervisor calls: systemctl (Linux) — runit/launchd variants TODO via svc_* shims.
# Tracked in-repo so `chump-node-install.sh` installs it on EVERY owned node (COTG).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${CHUMP_STATE_DIR:-$HOME/.chump}"
REPO="${CHUMP_REPO_ROOT:-$HOME/Projects/chump}"
INV="$STATE_DIR/resource-inventory.json"
INTERVAL="${CHUMP_ORCH_INTERVAL:-120}"
AUTOPLACE="${CHUMP_ORCH_AUTOPLACE:-0}"          # 0 = sense+recommend only; 1 = graceful auto-relocate
WORKER_UNIT="${CHUMP_ORCH_WORKER_UNIT:-chump-cj-worker}"   # worker@1 is this; worker@N are extras
WORKER_MAX="${CHUMP_ORCH_WORKER_MAX:-0}"        # 0 = auto (cores-1)
SCALE_UP_LOAD="${CHUMP_ORCH_SCALE_UP_LOAD:-70}"   # per-core load% below which we may scale up
SCALE_DN_LOAD="${CHUMP_ORCH_SCALE_DN_LOAD:-300}"  # per-core load% = GENUINE thrash (build fleets peg cores; busy≠oversubscribed)
RAM_SHED_MB="${CHUMP_ORCH_RAM_SHED_MB:-800}"      # RAM-avail floor: real shed signal is memory pressure, not busy CPU
DISK_PLACE_PCT="${CHUMP_ORCH_DISK_PLACE_PCT:-90}" # root%>= this triggers placement consideration
HOUSEKEEPING="${CHUMP_ORCH_HOUSEKEEPING:-chump-rot-reaper.service chump-worktree-reaper.service chump-disk-monitor.service}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO/.chump-locks/ambient.jsonl}"
BACKPRESSURE_MAX_AGE_S="${CHUMP_ORCH_BACKPRESSURE_MAX_AGE_S:-900}"  # stale signal (>15min) is ignored, not trusted
# RESILIENT-291 (PLACE half): the capacity planner + its output. effective_max()
# consumes worker_budget from this plan so the worker CEILING is capacity-derived
# (cores/mem/GPU/load/disk + orchestration+embed overhead) rather than a blind
# cores-1 or an autonomy-only cap. Falls back cleanly when the plan is absent.
CAPACITY_PLANNER="${CHUMP_ORCH_CAPACITY_PLANNER:-$REPO/scripts/ops/node-capacity-plan.sh}"
CAPACITY_PLAN="${CHUMP_ORCH_CAPACITY_PLAN:-$STATE_DIR/node-capacity-plan.json}"
PLAN_REFRESH_EVERY="${CHUMP_ORCH_PLAN_REFRESH_EVERY:-5}"  # re-run the planner every N ticks
mkdir -p "$STATE_DIR"
log(){ printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

# plan_worker_budget — read worker_budget from the capacity plan JSON, or "" if
# unreadable/absent. Grep-based (no jq dependency), tolerant of formatting.
plan_worker_budget() {
  [ -f "$CAPACITY_PLAN" ] || { echo ""; return; }
  grep -o '"worker_budget"[[:space:]]*:[[:space:]]*[0-9]\+' "$CAPACITY_PLAN" 2>/dev/null \
    | head -1 | grep -o '[0-9]\+$'
}

# refresh_plan — re-run the capacity planner so the plan tracks live signals. Best
# effort: a planner failure never breaks the orchestration loop (falls back to env/cores-1).
refresh_plan() {
  [ -x "$CAPACITY_PLANNER" ] || [ -f "$CAPACITY_PLANNER" ] || return 0
  CHUMP_REPO_ROOT="$REPO" CHUMP_STATE_DIR="$STATE_DIR" bash "$CAPACITY_PLANNER" >/dev/null 2>&1 || true
}

# effective_max — the enforced cap, single source of truth for both enforce_cap()
# and scale(). Precedence: capacity-plan worker_budget > CHUMP_ORCH_WORKER_MAX env
# > cores-1. The plan is the PLACE-half brain; this loop is the enforcement around it.
effective_max() {
  local max; max="$(plan_worker_budget)"
  if [ -z "$max" ]; then max=$WORKER_MAX; [ "$max" = 0 ] && max=$((CORES-1)); fi
  [ "$max" -lt 1 ] 2>/dev/null && max=1
  echo "$max"
}

# ci_backpressure — true (rc 0) when the most recent merge_queue_health ambient
# event (within BACKPRESSURE_MAX_AGE_S) recommends backpressure. Stale or
# absent signal = not backpressured (fail open, since the monitor daemon may
# not be installed on every node yet).
ci_backpressure() {
  [ -f "$AMBIENT" ] || return 1
  local line
  line=$(grep '"kind":"merge_queue_health"' "$AMBIENT" 2>/dev/null | tail -1)
  [ -z "$line" ] && return 1
  local bp ts ts_epoch now_epoch
  bp=$(printf '%s' "$line" | grep -o '"backpressure_recommended":[a-z]*' | cut -d: -f2)
  [ "$bp" = "true" ] || return 1
  ts=$(printf '%s' "$line" | grep -o '"ts":"[^"]*"' | head -1 | cut -d'"' -f4)
  ts_epoch=$(date -u -d "$ts" +%s 2>/dev/null || echo 0)
  now_epoch=$(date -u +%s)
  [ "$ts_epoch" -gt 0 ] && [ "$((now_epoch - ts_epoch))" -le "$BACKPRESSURE_MAX_AGE_S" ]
}

# enforce_cap — hard cap on WORKER_MAX, run EVERY tick regardless of hysteresis
# or scale()'s own state — closes RESILIENT-328 (drifted to 3 workers, orchestrator
# blind to the overshoot because scale() only ever nudges by ±1 off its own
# hysteresis mark). Stops the highest-numbered extra worker(s) until at/under cap.
enforce_cap() {
  local max; max=$(effective_max)
  while [ "$WORKERS_UP" -gt "$max" ]; do
    local n=$WORKERS_UP
    if sudo systemctl stop "chump-cj-worker${n}" 2>/dev/null; then
      log "ENFORCE: WORKERS_UP=$WORKERS_UP > WORKER_MAX=$max -> stopped chump-cj-worker${n}"
    else
      log "ENFORCE: WORKERS_UP=$WORKERS_UP > WORKER_MAX=$max but could not stop chump-cj-worker${n} -> giving up this tick"
      break
    fi
    WORKERS_UP=$((WORKERS_UP-1))
  done
}

# cargo_jobs_cap — INFRA-3659: the per-worker CARGO_BUILD_JOBS that keeps
# AGGREGATE rustc parallelism (worker_count * jobs_per_worker) at/under
# CORES. effective_max() already bounds worker COUNT to cores-1, but each
# worker's own `cargo check`/`clippy` defaults to several parallel rustc
# jobs — on CJ (4 cores) that was ~14 workers x CARGO_BUILD_JOBS=4 = ~56
# rustc threads -> swap thrash, 30-45min/gap, unverified_ship (2026-08-22).
cargo_jobs_cap() {
  local max; max=$(effective_max)
  local jobs=$(( CORES / max ))
  [ "$jobs" -lt 1 ] && jobs=1
  echo "$jobs"
}

# enforce_cargo_jobs — writes a CHUMP-managed [build] jobs block into
# ~/.cargo/config.toml so the cap from cargo_jobs_cap() applies to every
# cargo/rustc invocation on this host, regardless of which worker spawns it
# (tonight's hand-fix: jobs=1 hand-edited into this same file). Idempotent —
# only rewrites when the computed value changes, and refuses to touch a
# file that already has an unmanaged [build] section (don't clobber a
# hand-authored sccache/jobs config we don't understand).
CARGO_CONFIG="${CHUMP_ORCH_CARGO_CONFIG:-$HOME/.cargo/config.toml}"
enforce_cargo_jobs() {
  local jobs; jobs=$(cargo_jobs_cap)
  local cache="$STATE_DIR/.orch-cargo-jobs"
  [ "$(cat "$cache" 2>/dev/null || echo '')" = "$jobs" ] && return 0
  local begin='# BEGIN CHUMP-MANAGED cargo-jobs-cap (INFRA-3659, node-orchestrator.sh enforces this — do not hand-edit)'
  local end='# END CHUMP-MANAGED cargo-jobs-cap'
  mkdir -p "$(dirname "$CARGO_CONFIG")"
  if [ -f "$CARGO_CONFIG" ] && grep -q '^\[build\]' "$CARGO_CONFIG" 2>/dev/null && ! grep -qF "$begin" "$CARGO_CONFIG" 2>/dev/null; then
    log "CARGO-JOBS: $CARGO_CONFIG has an unmanaged [build] section -> not overwriting (leaving jobs cap unmanaged)"
    return 0
  fi
  local block
  block=$(printf '%s\n[build]\njobs = %d\n%s\n' "$begin" "$jobs" "$end")
  if [ -f "$CARGO_CONFIG" ] && grep -qF "$begin" "$CARGO_CONFIG" 2>/dev/null; then
    awk -v begin="$begin" -v end="$end" -v block="$block" '
      $0==begin {print block; skip=1; next}
      skip && $0==end {skip=0; next}
      skip {next}
      {print}
    ' "$CARGO_CONFIG" > "$CARGO_CONFIG.tmp.$$" && mv "$CARGO_CONFIG.tmp.$$" "$CARGO_CONFIG"
  else
    printf '\n%s\n' "$block" >> "$CARGO_CONFIG"
  fi
  echo "$jobs" > "$cache"
  log "CARGO-JOBS: capped aggregate rustc concurrency -> CARGO_BUILD_JOBS=$jobs per worker (cores=$CORES, max_workers=$(effective_max)) written to $CARGO_CONFIG"
}

sense() {
  CORES=$(nproc)
  LOAD1=$(awk '{print $1}' /proc/loadavg)
  LOADPCT=$(awk -v l="$LOAD1" -v c="$CORES" 'BEGIN{printf "%d", (l/c)*100}')
  RAM_AVAIL_MB=$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo)
  ROOT_PCT=$(df -P / | awk 'NR==2{gsub("%","",$5); print $5}')
  # per-volume free (largest-free non-root, non-boot volume for placement targets)
  # placement targets: real data volumes only — exclude vfat (printer/boot) which can't hold cargo symlinks/perms
  BEST_VOL=$(df -P -x tmpfs -x devtmpfs -x vfat 2>/dev/null | awk 'NR>1 && $6!~"/boot" && $6!~"/print" && $6!="/" {print $4, $6}' | sort -rn | head -1)
  BEST_VOL_FREE_KB=$(echo "$BEST_VOL" | awk '{print $1}')
  BEST_VOL_MNT=$(echo "$BEST_VOL" | awk '{print $2}')
  WORKERS_UP=$(systemctl list-units "${WORKER_UNIT}*" 'chump-cj-worker2*' --state=active --no-legend 2>/dev/null | grep -c "\.service")
  printf '{"ts":"%s","cores":%d,"load1":%s,"load_pct":%d,"ram_avail_mb":%d,"root_pct":%d,"best_vol":"%s","best_vol_free_gb":%d,"workers_up":%d}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$CORES" "$LOAD1" "$LOADPCT" "$RAM_AVAIL_MB" "$ROOT_PCT" "${BEST_VOL_MNT:-none}" "$((${BEST_VOL_FREE_KB:-0}/1024/1024))" "$WORKERS_UP" > "$INV"
}

# heal() — INFRA-3649 AC3: HOUSEKEEPING organs are declared as chump-*.service
# names for historical reasons, but on a non-systemd-supervised node (CJ:
# housekeeping runs as bare ~/.chump/organs/<name>.sh loops, not systemd
# units) a blind `systemctl is-active`/`restart` silently no-ops — is-active
# returns "unknown"/non-zero for a unit that was never registered, restart
# errors out (swallowed by `|| true`), and the organ is never actually
# revived. svc-abstraction.sh's svc_is_alive/svc_revive pick the right
# supervisor (systemd unit vs bare process) PER ORGAN, so the same heal()
# body works whether this node runs HOUSEKEEPING as real units or as process
# organs — and svc_revive already carries the backoff guard + the
# kind=organ_self_healed emit (AC2/AC4), so heal() doesn't need its own.
# shellcheck source=svc-abstraction.sh
source "${CHUMP_ORCH_SVC_ABSTRACTION:-$SCRIPT_DIR/svc-abstraction.sh}"
heal() {
  local u name
  for u in $HOUSEKEEPING; do
    name="${u%.service}"; name="${name#chump-}"
    svc_is_alive "$name" >/dev/null 2>&1 || { log "HEAL: $name down -> revive"; svc_revive "$name" >/dev/null 2>&1 || true; }
  done
}

scale() {
  local max; max=$(effective_max)
  local target=$WORKERS_UP
  # scale up only with idle CPU AND >=1.5G free RAM per new worker AND no CI-queue backpressure —
  # RESILIENT-328: an idle-looking node is still the wrong node to add PR-producing capacity to
  # when the merge pipeline can't drain what's already queued.
  if [ "$LOADPCT" -lt "$SCALE_UP_LOAD" ] && [ "$RAM_AVAIL_MB" -gt 1500 ] && [ "$WORKERS_UP" -lt "$max" ] && ! ci_backpressure; then
    target=$((WORKERS_UP+1)); log "SCALE: idle (load ${LOADPCT}%/core, RAM ${RAM_AVAIL_MB}MB) -> $WORKERS_UP->$target (max $max)"
  elif [ "$LOADPCT" -lt "$SCALE_UP_LOAD" ] && [ "$RAM_AVAIL_MB" -gt 1500 ] && [ "$WORKERS_UP" -lt "$max" ] && ci_backpressure; then
    log "SCALE: idle capacity available but CI-queue backpressure active -> holding at $WORKERS_UP (not adding PR-producing capacity)"
  elif { [ "$RAM_AVAIL_MB" -lt "$RAM_SHED_MB" ] || [ "$LOADPCT" -gt "$SCALE_DN_LOAD" ]; } && [ "$WORKERS_UP" -gt 1 ]; then
    # shed only on REAL pressure: low RAM (OOM risk) or genuine thrash — NOT normal build-busy CPU
    target=$((WORKERS_UP-1)); log "SCALE: shed on pressure (RAM ${RAM_AVAIL_MB}MB<${RAM_SHED_MB} or load ${LOADPCT}%/core>${SCALE_DN_LOAD}) -> $WORKERS_UP->$target"
  fi
  # hysteresis: require the same decision twice before acting
  local mark="$STATE_DIR/.orch-scale-intent"
  local prev; prev=$(cat "$mark" 2>/dev/null || echo "$WORKERS_UP")
  echo "$target" > "$mark"
  [ "$target" = "$WORKERS_UP" ] && return 0
  [ "$target" != "$prev" ] && { log "SCALE: intent $target not yet confirmed (was $prev) — waiting one cycle"; return 0; }
  # act: worker@N units are chump-cj-worker2, worker3... (N=2 is the existing extra)
  if [ "$target" -gt "$WORKERS_UP" ]; then
    local n=$((target)); sudo systemctl start "chump-cj-worker${n}" 2>/dev/null && log "SCALE: started chump-cj-worker${n}" || log "SCALE: chump-cj-worker${n} not installed (need unit) — cannot scale up past installed workers"
  else
    local n=$((WORKERS_UP)); sudo systemctl stop "chump-cj-worker${n}" 2>/dev/null && log "SCALE: stopped chump-cj-worker${n}"
  fi
}

place() {
  [ "${ROOT_PCT:-0}" -lt "$DISK_PLACE_PCT" ] && return 0
  local cargo="$HOME/.cargo"
  if [ -L "$cargo" ]; then log "PLACE: root ${ROOT_PCT}% but cargo already relocated -> $(readlink "$cargo"); nothing to move"; return 0; fi
  if [ -z "${BEST_VOL_MNT:-}" ] || [ "$BEST_VOL_MNT" = none ] || [ "$((${BEST_VOL_FREE_KB:-0}/1024/1024))" -lt 25 ]; then
    log "PLACE: root ${ROOT_PCT}% but no volume with >=25G free to hold cargo — ALERT operator"; return 0
  fi
  if [ "$AUTOPLACE" != 1 ]; then
    log "PLACE: RECOMMEND relocate ~/.cargo -> $BEST_VOL_MNT/cargo (root ${ROOT_PCT}%, target has $((BEST_VOL_FREE_KB/1024/1024))G). Auto-place OFF (set CHUMP_ORCH_AUTOPLACE=1 to arm)."; return 0
  fi
  # GRACEFUL: rsync while fleet runs, then atomic symlink swap (NEVER foreground mv)
  local lock="$STATE_DIR/.orch-place.lock"; [ -e "$lock" ] && { log "PLACE: relocation already in progress"; return 0; }
  : > "$lock"; local dst="$BEST_VOL_MNT/cargo"
  log "PLACE: graceful relocate ~/.cargo -> $dst (rsync live)"
  rsync -a --delete "$cargo/" "$dst/" 2>/dev/null && rsync -a --delete "$cargo/" "$dst/" 2>/dev/null   # 2 passes: bulk + delta
  if [ -d "$dst/registry" ]; then
    mv "$cargo" "$cargo.pre-orch-$(date -u +%s)" && ln -s "$dst" "$cargo" && log "PLACE: swapped -> $dst; validating"
    ( export PATH="$cargo/bin:$PATH"; cargo --version >/dev/null 2>&1 ) && { rm -rf "$cargo".pre-orch-* & log "PLACE: OK, old copy reaping in background"; } || log "PLACE: validation FAILED — investigate (old copy kept at $cargo.pre-orch-*)"
  else log "PLACE: rsync incomplete (no registry at $dst) — aborted, no swap"; fi
  rm -f "$lock"
}

# Sourceable for tests (RESILIENT-328): only run the daemon loop when executed directly.
if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
  log "node-orchestrator up (interval ${INTERVAL}s, autoplace=$AUTOPLACE)"
  _tick=0
  while true; do
    sense
    # PLACE half (RESILIENT-291): refresh the capacity plan on a cadence so
    # effective_max()'s worker_budget tracks live signals; enforce_cap/scale
    # below then hold the worker count to the capacity-derived ceiling.
    [ "$(( _tick % PLAN_REFRESH_EVERY ))" -eq 0 ] && refresh_plan
    _tick=$(( _tick + 1 ))
    heal
    enforce_cap
    enforce_cargo_jobs
    scale
    place
    sleep "$INTERVAL"
  done
fi
