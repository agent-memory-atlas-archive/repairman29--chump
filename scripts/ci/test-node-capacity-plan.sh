#!/usr/bin/env bash
# test-node-capacity-plan.sh — unit/logic coverage for the PLACE-half budget formula
# in scripts/ops/node-capacity-plan.sh (RESILIENT-291 Node Fabric #5).
#
# DEPTH: unit/logic (happy-path + edge). Covers compute_worker_budget() across the
# real fleet shapes (CJ orchestration+embed host, cuphead 2-core, big idle build box)
# plus the clamp/disk-brake edges. GAPS (not covered here): live nvidia-smi GPU
# disposition branches, systemctl orchestration-organ detection, and the
# orchestrator's consumption of the plan file — those need a live node (dogfooded on
# CJ + cuphead in the shipping session, not in CI).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHUMP_PLAN_LIB_ONLY=1 source "$HERE/ops/node-capacity-plan.sh"

fail=0
check() {
  local desc="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    printf 'ok   — %s (=%s)\n' "$desc" "$got"
  else
    printf 'FAIL — %s: got %s want %s\n' "$desc" "$got" "$want"; fail=1
  fi
}

# args: cores orch_reserve embed_reserve disk_pct [headroom]
# RESILIENT-1204: budget is round-half-up (was floor). CJ (4c orch+embed) has
# usable=2, 2*0.75=1.5 -> rounds to 2 (floor truncated it to 1 and starved the box
# to a single worker; the build-thrash that once justified sub-cores-1 is now handled
# by the INFRA-3659 aggregate cargo-jobs cap + runtime RAM/load shed, so the budget
# no longer double-discounts fixed overhead). The clamp still guarantees >=1 free core.
check "CJ (4c orch+embed, disk89) -> 2"      "$(compute_worker_budget 4 1 1 89)"  2
check "cuphead (2c clean, disk96) -> 1"      "$(compute_worker_budget 2 0 0 96)"  1
check "big idle build box (16c, disk40) ->12" "$(compute_worker_budget 16 0 0 40)" 12
check "8c orchestration host -> 5"           "$(compute_worker_budget 8 1 0 50)"  5
check "4c clean node -> 3"                    "$(compute_worker_budget 4 0 0 50)"  3
check "1c tiny node -> 1 (never 0)"          "$(compute_worker_budget 1 0 0 10)"  1
check "2c orch+embed reserves both -> 1"     "$(compute_worker_budget 2 1 1 50)"  1
check "disk-brake pins a big box to 1"       "$(compute_worker_budget 16 0 0 95)" 1
check "reserves never underflow below 1"     "$(compute_worker_budget 3 2 2 50)"  1
check "budget never exceeds cores-1"         "$(compute_worker_budget 4 0 0 50 100)" 3
check "headroom override (8c, 50%) -> 4"     "$(compute_worker_budget 8 0 0 50 50)"  4
# round-half-up boundary coverage (RESILIENT-1204): the .5 case rounds UP (CJ's
# usable=2 shape), while a .49-and-below case still rounds DOWN — so the change is a
# principled round, not a blanket +1. 3c orch host: usable=2, 2*0.75=1.5 -> 2.
check "round-half-up: usable=2 @75% -> 2"    "$(compute_worker_budget 3 1 0 50)"  2
# 6c one reserve @75%: usable=5, 5*0.75=3.75 -> rounds to 4.
check "round-half-up: usable=5 @75% -> 4"    "$(compute_worker_budget 6 1 0 50)"  4
# below-half still floors: usable=5 @70% = 3.5 -> 4 is >=.5; use @69% = 3.45 -> 3.
check "round-half-down: usable=5 @69% -> 3"  "$(compute_worker_budget 6 1 0 50 69)" 3

if [ "$fail" -ne 0 ]; then echo "node-capacity-plan formula: FAILURES"; exit 1; fi
echo "node-capacity-plan formula: all cases pass"
