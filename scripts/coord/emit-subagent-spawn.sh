#!/usr/bin/env bash
# emit-subagent-spawn.sh — META-978 (Part A slice of META-130 /
# docs/design/SUBAGENT_ATTRIBUTION.md).
#
# Emits kind=subagent_spawned to ambient.jsonl when an orchestrator launches
# a sub-agent via the Agent tool. This is the "emit_spawn helper" named as
# open design question 1(b) in SUBAGENT_ATTRIBUTION.md: a shell wrapper the
# orchestrator (or the sub-agent itself, on SessionStart) invokes so the
# fleet-recorder can later build the parent -> sub-session hierarchy
# (Part B, not yet implemented).
#
# Usage:
#   scripts/coord/emit-subagent-spawn.sh --worktree <path> \
#       --description "<agent description>" [--model sonnet] [--agent-id <id>]
#
# Fields emitted (see docs/observability/EVENT_REGISTRY.yaml kind=subagent_spawned):
#   sub_session_id     synthetic id: chump-sub-<parent_session_id>-<agent_id>
#   parent_session_id  CHUMP_SESSION_ID / CLAUDE_SESSION_ID of the caller
#   worktree_path      worktree the sub-agent will operate in
#   agent_description  short human description of the dispatched task
#   model              sub-agent model (default: sonnet)
#
# Prints the minted sub_session_id to stdout so the caller can pass it
# through to the sub-agent's own environment if desired.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

PARENT_SESSION_ID="${CHUMP_SESSION_ID:-${CLAUDE_SESSION_ID:-unknown}}"
WORKTREE_PATH=""
AGENT_DESCRIPTION=""
MODEL="sonnet"
AGENT_ID=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --worktree) WORKTREE_PATH="${2:-}"; shift 2 ;;
        --description) AGENT_DESCRIPTION="${2:-}"; shift 2 ;;
        --model) MODEL="${2:-}"; shift 2 ;;
        --agent-id) AGENT_ID="${2:-}"; shift 2 ;;
        *) echo "Usage: $0 --worktree <path> --description <desc> [--model sonnet] [--agent-id <id>]" >&2; exit 2 ;;
    esac
done

if [[ -z "$WORKTREE_PATH" ]]; then
    echo "emit-subagent-spawn.sh: --worktree is required" >&2
    exit 2
fi

if [[ -z "$AGENT_ID" ]]; then
    AGENT_ID="$(date +%s%N 2>/dev/null || date +%s)-$$"
fi

SUB_SESSION_ID="chump-sub-${PARENT_SESSION_ID}-${AGENT_ID}"

"$REPO_ROOT/scripts/dev/ambient-emit.sh" subagent_spawned \
    "sub_session_id=${SUB_SESSION_ID}" \
    "parent_session_id=${PARENT_SESSION_ID}" \
    "worktree_path=${WORKTREE_PATH}" \
    "agent_description=${AGENT_DESCRIPTION}" \
    "model=${MODEL}"
# scanner-anchor: "kind":"subagent_spawned"

printf '%s\n' "$SUB_SESSION_ID"
