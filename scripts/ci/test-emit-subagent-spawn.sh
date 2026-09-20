#!/usr/bin/env bash
# CI test: META-978 — emit-subagent-spawn.sh
#
# Verifies the orchestrator's Agent-tool-dispatch spawn emitter:
#   1. Script exists and is executable.
#   2. kind=subagent_spawned is registered in EVENT_REGISTRY.yaml.
#   3. A real emit lands in ambient.jsonl (not ambient-rejected.jsonl) with
#      sub_session_id, worktree_path, and parent_session_id populated —
#      i.e. it passes the kind-schema gate in scripts/dev/ambient-emit.sh.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
EMIT="$REPO_ROOT/scripts/coord/emit-subagent-spawn.sh"
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
PASS=0; FAIL=0

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== META-978 emit-subagent-spawn.sh test ==="
echo

[[ -x "$EMIT" ]] && ok "emit-subagent-spawn.sh exists and is executable" || fail "emit-subagent-spawn.sh missing or not executable"
grep -q 'kind: subagent_spawned' "$REGISTRY" && ok "subagent_spawned registered in EVENT_REGISTRY.yaml" || fail "subagent_spawned not in EVENT_REGISTRY.yaml"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
LOG="$SANDBOX/ambient.jsonl"
REJECTED="$SANDBOX/ambient-rejected.jsonl"

SUB_ID="$(CHUMP_AMBIENT_LOG="$LOG" CHUMP_AMBIENT_REJECTED_LOG="$REJECTED" \
    CHUMP_SESSION_ID="test-parent-session" CHUMP_AGENT_HARNESS="manual" \
    "$EMIT" --worktree /tmp/chump-test-gap --description "test dispatch" --model sonnet --agent-id "abc123")"

[[ -n "$SUB_ID" ]] && ok "emit prints a sub_session_id ($SUB_ID)" || fail "emit produced no sub_session_id"

if [[ -s "$REJECTED" ]]; then
    fail "subagent_spawned event was quarantined to ambient-rejected.jsonl"
else
    ok "subagent_spawned event was NOT quarantined"
fi

if grep -q '"kind":"subagent_spawned"' "$LOG" 2>/dev/null; then
    ok "ambient.jsonl contains kind=subagent_spawned"
else
    fail "ambient.jsonl missing kind=subagent_spawned"
fi

if grep -q '"parent_session_id":"test-parent-session"' "$LOG" 2>/dev/null \
    && grep -q '"worktree_path":"/tmp/chump-test-gap"' "$LOG" 2>/dev/null \
    && grep -q "\"sub_session_id\":\"${SUB_ID}\"" "$LOG" 2>/dev/null; then
    ok "payload carries sub_session_id, worktree_path, parent_session_id"
else
    fail "payload missing one of sub_session_id/worktree_path/parent_session_id"
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
