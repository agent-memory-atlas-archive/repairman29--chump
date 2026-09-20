#!/usr/bin/env bash
# node-role-assign.sh — RESILIENT-1031 / Node Fabric component #2 (placement kernel).
#
# node-describe.sh declares raw hardware CAPABILITY and the roles a node
# FITS (roles_fit); nothing writes an actual POLICY decision. Per
# docs/design/NODE_FABRIC.md ("roles_fit != role_assigned"): closetjunky
# *fits* build-worker (46G free, 4 cores) but must NEVER build — raw fit is
# necessary but not sufficient. This script is the placement kernel that
# reads each node's declared capability + roles_fit and ASSIGNS one of four
# policy roles (brain/muscle/gpu-embed/operator), then persists
# `role_assigned` back into docs/fleet/nodes/<node>.json.
#
# Assignment precedence (first match wins):
#   1. gpu-embed  — roles_fit contains "gpu-embed" (has a real CUDA/embed-
#      capable GPU) -> serves embeddings/small-inference.
#   2. brain      — always_on AND roles_fit contains "atc-heartbeat" or
#      "broker" -> the always-on coordination node (NATS broker, ATC
#      heartbeat, worker dispatch).
#   3. muscle     — always_on AND roles_fit contains "build-worker" ->
#      general always-on workhorse (build/ship/CI) that isn't the brain.
#   4. operator   — everything else (interactive laptops that sleep, or a
#      node with no strong fit) -> human-in-the-loop / ATC-interactive node.
#
# Consumed by: scripts/ops/organ-reconcile.sh (role-scoped reconcile via
# CHUMP_ORGAN_RECONCILE_ROLE) and the future placement engine/governor
# (component #5 in docs/design/NODE_FABRIC.md).
#
# Usage:
#   node-role-assign.sh [--apply|--check] [--dir <nodes-dir>] [--host <node_id>]
#
#   --apply   (default) compute role_assigned for each node file and persist
#             it back into the JSON (atomic write).
#   --check   compute role_assigned for each node file and compare against
#             the persisted value; exit 1 if any node is missing or drifted
#             (does not write). Safe for a pre-reconcile drift check.
#   --dir     node registry directory (default: docs/fleet/nodes under repo root).
#   --host    only process the node file whose "node_id" matches this value.
#
# Exit codes: 0 success/no-drift, 1 drift found (--check) or a node file
# failed to parse, 2 usage error.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

MODE="apply"
# The node registry names machines, tailnet addresses and what runs where, and this repo is
# PUBLIC, so it lives outside the tree. One variable for every reader and writer.
NODES_DIR="${CHUMP_NODE_REGISTRY_DIR:-$HOME/.chump/fleet/nodes}"
HOST_FILTER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) MODE="apply"; shift ;;
    --check) MODE="check"; shift ;;
    --dir) NODES_DIR="$2"; shift 2 ;;
    --host) HOST_FILTER="$2"; shift 2 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "node-role-assign.sh: jq required" >&2; exit 2; }

AMBIENT_LOG="${NODE_AMBIENT:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
LIB_AMBIENT="$REPO_ROOT/scripts/coord/lib/ambient-write.sh"
[[ -f "$LIB_AMBIENT" ]] && source "$LIB_AMBIENT"

emit() {  # kind, extra-json (no leading/trailing comma)
  local kind="$1" extra="${2:-}"
  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local line
  if [[ -n "$extra" ]]; then line="{\"ts\":\"$ts\",\"kind\":\"$kind\",$extra}"
  else line="{\"ts\":\"$ts\",\"kind\":\"$kind\"}"; fi
  if command -v _ambient_write >/dev/null 2>&1; then
    [[ -d "$(dirname "$AMBIENT_LOG")" ]] && _ambient_write "$AMBIENT_LOG" "$line" || true
  else
    [[ -d "$(dirname "$AMBIENT_LOG")" ]] && printf '%s\n' "$line" >> "$AMBIENT_LOG" 2>/dev/null || true
  fi
  return 0
}

[[ -d "$NODES_DIR" ]] || { echo "node-role-assign.sh: no such dir: $NODES_DIR" >&2; exit 2; }

# assign_role <node_json_file> -> prints one of brain|muscle|gpu-embed|operator
#
# POLICY VETO (NODE_FABRIC.md #2 finding, "roles_fit != role_assigned"): an
# optional `role_pin` field in the node JSON is an operator/topology decision
# that OVERRIDES the capability-derived role. This is what lets a one-brain
# topology hold when several always_on boxes all *fit* brain (cuphead + mugman
# both fit atc-heartbeat/broker; only cuphead is the brain, mugman is muscle
# overflow). Capability says what a box CAN do; the pin says what it's FOR.
assign_role() {
  local file="$1"
  local pin
  pin="$(jq -r '.role_pin // empty' "$file")"
  if [[ -n "$pin" ]]; then echo "$pin"; return; fi
  local always_on has_gpu_embed has_brain_fit has_build_worker
  always_on="$(jq -r '.hardware.always_on // false' "$file")"
  has_gpu_embed="$(jq -r '(.roles_fit // []) | index("gpu-embed") != null' "$file")"
  has_brain_fit="$(jq -r '(.roles_fit // []) | (index("atc-heartbeat") != null) or (index("broker") != null)' "$file")"
  has_build_worker="$(jq -r '(.roles_fit // []) | index("build-worker") != null' "$file")"

  if [[ "$has_gpu_embed" == "true" ]]; then
    echo "gpu-embed"
  elif [[ "$always_on" == "true" && "$has_brain_fit" == "true" ]]; then
    echo "brain"
  elif [[ "$always_on" == "true" && "$has_build_worker" == "true" ]]; then
    echo "muscle"
  else
    echo "operator"
  fi
}

status=0
shopt -s nullglob
files=("$NODES_DIR"/*.json)
shopt -u nullglob

if [[ ${#files[@]} -eq 0 ]]; then
  echo "node-role-assign.sh: no node files under $NODES_DIR" >&2
  exit 0
fi

for f in "${files[@]}"; do
  node_id="$(jq -r '.node_id // empty' "$f" 2>/dev/null || true)"
  if [[ -z "$node_id" ]]; then
    echo "node-role-assign.sh: skip unparsable node file: $f" >&2
    status=1
    continue
  fi
  if [[ -n "$HOST_FILTER" && "$node_id" != "$HOST_FILTER" ]]; then
    continue
  fi

  computed_role="$(assign_role "$f")"
  persisted_role="$(jq -r '.role_assigned // empty' "$f")"

  if [[ "$MODE" == "check" ]]; then
    if [[ "$persisted_role" != "$computed_role" ]]; then
      echo "DRIFT $node_id: persisted='${persisted_role:-<none>}' computed='$computed_role' ($f)" >&2
      status=1
    else
      echo "OK $node_id: role_assigned=$computed_role"
    fi
    continue
  fi

  # --apply: write role_assigned back into the node file (atomic tmp+rename).
  tmp="${f}.tmp.$$"
  jq --arg role "$computed_role" '. + {role_assigned: $role}' "$f" > "$tmp" \
    && mv "$tmp" "$f"
  if [[ "$persisted_role" != "$computed_role" ]]; then
    echo "ASSIGNED $node_id: role_assigned=$computed_role (was '${persisted_role:-<none>}')"
    # scanner-anchor: "kind":"node_role_assigned"  (RESILIENT-1031)
    emit "node_role_assigned" "\"node_id\":\"$node_id\",\"role_assigned\":\"$computed_role\",\"previous_role\":\"${persisted_role:-none}\""
  else
    echo "UNCHANGED $node_id: role_assigned=$computed_role"
  fi
done

exit "$status"
