#!/usr/bin/env bash
# node-capacity-plan.sh — the PLACE half of declare-and-place (RESILIENT-291 / Node Fabric #5).
#
# node-describe.sh (component #1) + capability.rs KV DECLARE what a node IS (cores,
# ram, disk, GPU, roles_fit, services_running). This script does the missing half:
# it PLACES work against that declared capacity. Per node it computes a PLACEMENT
# BUDGET — how many workers this box should run, whether it is an orchestration
# host, and what to do with its GPU — from the DECLARED manifest + LIVE signals,
# and writes it where node-orchestrator.sh enforces it.
#
# It is the brain; node-orchestrator.sh is the loop around it (SENSE/HEAL/SCALE/
# ENFORCE already exist there — effective_max() now reads THIS plan's worker_budget
# instead of the autonomy-only cap or a blind cores-1). This closes the gap that
# left worker counts set by AUTONOMY_LEVEL (run-fleet.sh ~L245) + hand-written
# per-node scripts, with nothing right-sizing a box to its real cores/mem/GPU/load.
#
# WHY a node needs less than cores-1 workers: a box that is ALSO the orchestration
# host (fleet-server, discord-gateway, pr-lander, node-orchestrator, ...16 organs on
# CJ) and a CPU-embed host (ollama/llama-server) carries fixed overhead that a naive
# cores-1 worker budget ignores — that is exactly why CJ (4 cores) thrashed at load
# ~5 with the orchestrator oscillating 1<->2 workers. The budget subtracts that
# overhead so sustained load trends toward <= cores.
#
# Placement model (capacity -> worker budget):
#   reserved      = orchestration_reserve (1 if heavy-organ host) + embed_reserve (1 if CPU-bound ollama)
#   usable        = cores - reserved
#   worker_budget = round(usable * HEADROOM_PCT/100)              # headroom so we don't peg every core
#   worker_budget = clamp(1 .. cores-1)                           # always leave 1 core for OS/organs
#   worker_budget = 1  if root_disk_pct >= DISK_BRAKE_PCT         # don't pile build churn on a full disk
#
# GPU disposition: assigned (in use) | reserved-idle (+reason) | none. Never silently idle.
#
# Host-agnostic: Linux (nproc/free/df/nvidia-smi/systemctl) with macOS/Apple-Silicon
# fallbacks. Tracked in-repo so chump-node-install.sh ships it to EVERY owned node (COTG).
#
# Usage:
#   node-capacity-plan.sh            # compute + write plan + emit ambient; print plan JSON
#   node-capacity-plan.sh --print    # compute + print only (no write, no emit)
#   (sourced)                        # exposes compute_worker_budget() for tests, no side effects
set -uo pipefail

STATE_DIR="${CHUMP_STATE_DIR:-$HOME/.chump}"
REPO="${CHUMP_REPO_ROOT:-$HOME/Projects/chump}"
PLAN="$STATE_DIR/node-capacity-plan.json"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO/.chump-locks/ambient.jsonl}"
HEADROOM_PCT="${CHUMP_PLAN_HEADROOM_PCT:-75}"     # keep ~25% core headroom under sustained load
DISK_BRAKE_PCT="${CHUMP_PLAN_DISK_BRAKE_PCT:-90}" # root% at/above which worker budget is pinned to 1
# Heavy orchestration organs — presence of >= ORCH_HOST_MIN of these => this box is an
# orchestration host and reserves a core for them (they are not free).
ORCH_ORGANS="${CHUMP_PLAN_ORCH_ORGANS:-chump-fleet-server chump-discord-gateway chump-pr-lander chump-node-orchestrator chump-postgrest}"
ORCH_HOST_MIN="${CHUMP_PLAN_ORCH_HOST_MIN:-3}"

log(){ printf '[%s] node-capacity-plan: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

# compute_worker_budget CORES ORCH_RESERVE EMBED_RESERVE DISK_PCT [HEADROOM_PCT]
# Pure function (no I/O) — unit-tested by scripts/ci/test-node-capacity-plan.sh.
compute_worker_budget() {
  local cores="$1" orch_reserve="$2" embed_reserve="$3" disk_pct="$4" headroom="${5:-$HEADROOM_PCT}"
  [ "$cores" -lt 1 ] 2>/dev/null && cores=1
  local reserved=$(( orch_reserve + embed_reserve ))
  local usable=$(( cores - reserved ))
  [ "$usable" -lt 1 ] && usable=1
  # RESILIENT-1204: round-half-up, NOT floor. Integer floor truncated CJ's real
  # capacity — a 4-core orchestration+embed host has usable=2, and floor(2*0.75)=
  # floor(1.5)=1 STARVED it to a single worker despite a large backlog (the operator
  # even set CHUMP_ORCH_WORKER_MAX=2 via drop-in, silently overridden by budget=1).
  # The 1<->2 build-thrash at load ~5 that justified the original sub-cores-1 budget
  # is now independently prevented by the AGGREGATE cargo-jobs cap (INFRA-3659:
  # enforce_cargo_jobs pins worker_count*CARGO_BUILD_JOBS<=cores, so 2 workers on CJ
  # run 2 rustc jobs each = 4 = cores, never the ~56-thread swap-thrash of the
  # uncapped era) plus the orchestrator's runtime RAM/load shed guards. So the budget
  # no longer needs to double-discount fixed overhead (once as a reserved core, again
  # by flooring the headroom). Round-half-up gives CJ its true 2; the clamp below
  # still guarantees >=1 free core, so this can never over-scale past cores-1.
  local budget=$(( (usable * headroom + 50) / 100 ))
  [ "$budget" -lt 1 ] && budget=1
  local cap=$(( cores - 1 )); [ "$cap" -lt 1 ] && cap=1
  [ "$budget" -gt "$cap" ] && budget=$cap
  if [ "$disk_pct" -ge "$DISK_BRAKE_PCT" ] 2>/dev/null && [ "$budget" -gt 1 ]; then budget=1; fi
  echo "$budget"
}

# gpu_disposition — assigned | reserved-idle(+reason) | none. Computed live so the
# reason is a reading, not a guess (axiom: no claims on guesses).
gpu_disposition() {
  local os; os="$(uname -s)"
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    if [ "$os" = Darwin ] && sysctl -n machdep.cpu.brand_string 2>/dev/null | grep -qi apple; then
      GPU_STATE="none"; GPU_REASON="Apple Silicon (Metal, no CUDA) — not a fleet CUDA target"; return
    fi
    GPU_STATE="none"; GPU_REASON="no discrete NVIDIA GPU"; return
  fi
  local row util mem_used mem_total cc
  row="$(nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,compute_cap --format=csv,noheader,nounits 2>/dev/null | head -1)"
  util="$(echo "$row"   | awk -F',' '{gsub(/ /,"",$1);print $1+0}')"
  mem_used="$(echo "$row"| awk -F',' '{gsub(/ /,"",$2);print $2+0}')"
  mem_total="$(echo "$row"|awk -F',' '{gsub(/ /,"",$3);print $3+0}')"
  cc="$(echo "$row"     | awk -F',' '{gsub(/ /,"",$4);print $4}')"
  local ollama_up=false
  pgrep -x ollama >/dev/null 2>&1 || pgrep -f 'llama-server' >/dev/null 2>&1 && ollama_up=true
  if [ "${mem_used:-0}" -gt 50 ]; then
    GPU_STATE="assigned"; GPU_REASON="in use: ${mem_used}MiB/${mem_total}MiB resident, util ${util}%"; return
  fi
  # idle. Explain WHY from a live reading, not a guess.
  local cc_major="${cc%%.*}"
  if [ -n "$cc" ] && [ "${cc_major:-0}" -lt 6 ] 2>/dev/null && [ "$ollama_up" = true ]; then
    GPU_STATE="reserved-idle"
    GPU_REASON="present (CC ${cc}) but ollama fell back to CPU — bundled CUDA (cuda_v12/v13) dropped this GPU's compute capability; embeds are CPU-bound (counts toward embed_reserve). Reclaim needs a legacy-CUDA ollama/llama build."
  elif [ "$ollama_up" = true ]; then
    GPU_STATE="reserved-idle"
    GPU_REASON="present, ollama running but 0MiB resident — not offloading; investigate driver/CUDA on this host."
  else
    GPU_STATE="reserved-idle"
    GPU_REASON="present (${mem_total}MiB, CC ${cc:-unknown}) and free — available for fleet embed/inference work; no workload assigned yet."
  fi
}

# Read a numeric field from the declared node manifest (docs/fleet/nodes/<host>.json)
# if present. This CONSUMES the declared capacity (node-describe.sh output) rather
# than re-deriving it — falling back to the live reading when the manifest is absent.
declared_field() {
  local file="$1" key="$2"
  [ -f "$file" ] || { echo ""; return; }
  grep -o "\"$key\"[[:space:]]*:[[:space:]]*[0-9]\+" "$file" 2>/dev/null | head -1 | grep -o '[0-9]\+$'
}

# scanner-anchor: "kind":"node_capacity_plan"
emit_ambient() {
  local budget="$1" cores="$2" orch="$3" embed="$4"
  mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || return 0
  printf '{"ts":"%s","kind":"node_capacity_plan","node":"%s","cores":%d,"worker_budget":%d,"workers_up":%d,"capacity_sink":%s,"oversubscribed":%s,"gpu":"%s","root_pct":%d}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$NODE" "$cores" "$budget" "${WORKERS_UP:-0}" "${CAPACITY_SINK:-false}" "$OVERSUBSCRIBED" "$GPU_STATE" "$ROOT_PCT" \
    >> "$AMBIENT" 2>/dev/null || true
}

plan() {
  NODE="$(hostname -s 2>/dev/null || hostname)"
  local manifest="${CHUMP_NODE_REGISTRY_DIR:-$HOME/.chump/fleet/nodes}/${NODE}.json"

  # cores: prefer the declared manifest, fall back to live nproc.
  CORES="$(declared_field "$manifest" cpu_cores)"
  [ -z "$CORES" ] && CORES="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)"
  local declared_src="manifest"; [ -f "$manifest" ] || declared_src="live-introspect"

  # live signals
  LOAD1="$(awk '{print $1}' /proc/loadavg 2>/dev/null || uptime | awk -F'load average:' '{print $2}' | awk -F, '{print $1}' | tr -d ' ')"
  LOADPCT="$(awk -v l="${LOAD1:-0}" -v c="$CORES" 'BEGIN{printf "%d",(l/c)*100}')"
  RAM_AVAIL_MB="$(awk '/MemAvailable/{printf "%d",$2/1024}' /proc/meminfo 2>/dev/null || echo 0)"
  ROOT_PCT="$(df -P / 2>/dev/null | awk 'NR==2{gsub("%","",$5);print $5}')"; ROOT_PCT="${ROOT_PCT:-0}"

  # role classification: orchestration host?
  local orch_count=0 u
  for u in $ORCH_ORGANS; do
    systemctl is-active "$u" >/dev/null 2>&1 && orch_count=$(( orch_count + 1 ))
  done
  ORCHESTRATION_HOST=false; local orch_reserve=0
  if [ "$orch_count" -ge "$ORCH_HOST_MIN" ]; then ORCHESTRATION_HOST=true; orch_reserve=1; fi

  # embed host? (CPU-bound ollama/llama-server competes with build cores)
  EMBED_HOST=false; local embed_reserve=0
  if pgrep -x ollama >/dev/null 2>&1 || pgrep -f 'llama-server' >/dev/null 2>&1; then EMBED_HOST=true; fi

  gpu_disposition
  # If the GPU is genuinely doing the embed work, it's NOT stealing build cores -> no reserve.
  # If embeds are present but CPU-bound (reserved-idle GPU + ollama), reserve a core.
  if [ "$EMBED_HOST" = true ] && [ "$GPU_STATE" != "assigned" ]; then embed_reserve=1; fi

  WORKER_BUDGET="$(compute_worker_budget "$CORES" "$orch_reserve" "$embed_reserve" "$ROOT_PCT")"

  # workers currently up (same accounting node-orchestrator uses)
  WORKERS_UP="$(systemctl list-units 'chump-*worker*' --state=active --no-legend 2>/dev/null | grep -c '\.service')"
  WORKERS_UP="${WORKERS_UP:-0}"

  # posture — makes REBALANCE visible in both directions, not just "cap the busy box":
  #   worker_posture: is the worker COUNT above/at/below the capacity-derived budget?
  #   load_posture:   is the box saturated / busy / has headroom right now?
  #   capacity_sink:  headroom load AND not over its worker budget AND disk ok
  #                   => this node can ABSORB more routed work (a place-onto target).
  local worker_posture load_posture
  if   [ "$WORKERS_UP" -gt "$WORKER_BUDGET" ]; then worker_posture="over-budget"
  elif [ "$WORKERS_UP" -lt "$WORKER_BUDGET" ]; then worker_posture="under-budget"
  else worker_posture="at-budget"; fi
  if   [ "${LOADPCT:-0}" -ge 100 ]; then load_posture="saturated"
  elif [ "${LOADPCT:-0}" -ge 60 ]; then load_posture="busy"
  else load_posture="headroom"; fi
  CAPACITY_SINK=false
  if [ "$load_posture" = "headroom" ] && [ "$WORKERS_UP" -le "$WORKER_BUDGET" ] && [ "$ROOT_PCT" -lt "$DISK_BRAKE_PCT" ]; then
    CAPACITY_SINK=true
  fi
  # over-subscribed = saturated even at/under budget (the CJ case: config ceiling
  # WORKER_MAX exceeded the derived budget, and fixed organ/embed overhead pegs load).
  OVERSUBSCRIBED=false
  [ "$load_posture" = "saturated" ] && OVERSUBSCRIBED=true

  # disk pressure flag
  local disk_flag="ok"
  [ "$ROOT_PCT" -ge "$DISK_BRAKE_PCT" ] && disk_flag="pressure (root ${ROOT_PCT}% >= ${DISK_BRAKE_PCT}%) — worker budget pinned to 1; relocate/reap needed"

  cat > "${1:-/dev/stdout}" <<EOF
{
  "schema": "node-capacity-plan-v1",
  "node": "$NODE",
  "computed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "declared_source": "$declared_src",
  "sensed": {
    "cores": $CORES,
    "load1": ${LOAD1:-0},
    "load_pct_per_core": ${LOADPCT:-0},
    "ram_avail_mb": ${RAM_AVAIL_MB:-0},
    "root_pct": $ROOT_PCT
  },
  "roles": {
    "orchestration_host": $ORCHESTRATION_HOST,
    "orchestration_organs_active": $orch_count,
    "embed_host": $EMBED_HOST
  },
  "budget": {
    "worker_budget": $WORKER_BUDGET,
    "workers_up": $WORKERS_UP,
    "formula": "round((cores - orch_reserve - embed_reserve) * ${HEADROOM_PCT}/100), clamp(1..cores-1), disk-brake@${DISK_BRAKE_PCT}%",
    "orch_reserve": $orch_reserve,
    "embed_reserve": $embed_reserve
  },
  "posture": {
    "worker_posture": "$worker_posture",
    "load_posture": "$load_posture",
    "oversubscribed": $OVERSUBSCRIBED,
    "capacity_sink": $CAPACITY_SINK
  },
  "gpu": {
    "disposition": "$GPU_STATE",
    "reason": "$GPU_REASON"
  },
  "disk": "$disk_flag"
}
EOF
}

# ── entrypoints ──────────────────────────────────────────────────────────────
# CHUMP_PLAN_LIB_ONLY=1 forces library mode (no side effects) — used by the CI
# test to source compute_worker_budget() without triggering a live plan run.
if [[ -z "${CHUMP_PLAN_LIB_ONLY:-}" && "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
  case "${1:-}" in
    --print) plan /dev/stdout ;;
    *)
      mkdir -p "$STATE_DIR"
      plan "$PLAN"
      cat "$PLAN"
      emit_ambient "$WORKER_BUDGET" "$CORES" "$ORCHESTRATION_HOST" "$EMBED_HOST"
      log "wrote $PLAN — worker_budget=$WORKER_BUDGET, gpu=$GPU_STATE, orchestration_host=$orchestration_host"
      ;;
  esac
fi
