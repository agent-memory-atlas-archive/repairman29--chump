#!/usr/bin/env bash
# subagent-pre-exit-check.sh — INFRA-1953
#
# Mandatory pre-exit gate for any subagent dispatched via the META-069
# pattern. Asserts the subagent's claimed work actually shipped to a PR
# before allowing return.
#
# Pattern observed 2026-05-24 (INFRA-1893 #2489, INFRA-1935 #2536):
# Sonnet subagents commit + push successfully then idle-wait for a Monitor
# notification instead of creating the PR. Dispatcher manually recovers
# (gh pr create + GraphQL auto-merge) every time, ~30s wasted per dispatch.
# This gate catches that pattern in the subagent itself.
#
# Usage:
#   bash scripts/dispatch/subagent-pre-exit-check.sh <branch-name>
#
# Exit codes:
#   0 — all good: branch on origin, PR exists, auto-merge armed
#   1 — no PR for branch (the half-ship failure mode)
#   2 — PR exists but auto-merge not armed (re-arm via GraphQL)
#   3 — branch not on origin (push never happened or was rejected)
#   4 — bad invocation (no branch arg)

set -uo pipefail

BRANCH="${1:-}"
if [[ -z "$BRANCH" ]]; then
    printf 'usage: %s <branch-name>\n' "$0" >&2
    exit 4
fi

REPO="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
AMBIENT="$REPO/.chump-locks/ambient.jsonl"

emit_idle() {
    local reason="$1"
    local sess="${CHUMP_SESSION_ID:-unknown}"
    # Debounce per session-id within a 5-minute window so a tight loop
    # of subagent re-checks doesn't spam ambient. Marker file in tmp.
    local marker="${TMPDIR:-/tmp}/chump-subagent-idle-${sess}.marker"
    if [[ -f "$marker" ]]; then
        local mtime now age
        mtime=$(stat -c %Y "$marker" 2>/dev/null || stat -f %m "$marker" 2>/dev/null)
        now=$(date -u +%s)
        if [[ -n "$mtime" ]]; then
            age=$((now - mtime))
            [[ "$age" -lt 300 ]] && return 0
        fi
    fi
    : > "$marker" 2>/dev/null
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","kind":"subagent_idle_without_pr","session":"%s","branch":"%s","reason":"%s"}\n' \
        "$ts" "$sess" "$BRANCH" "$reason" >> "$AMBIENT" 2>/dev/null || true
}

# ── (a) branch exists on origin ──────────────────────────────────────────────
if ! git ls-remote --exit-code origin "refs/heads/$BRANCH" >/dev/null 2>&1; then
    printf '[pre-exit-check] FAIL: branch %s not on origin — push never happened\n' "$BRANCH" >&2
    emit_idle "branch_not_on_origin"
    exit 3
fi

# ── (b) PR exists for branch ────────────────────────────────────────────────
PR_COUNT=$(gh pr list --head "$BRANCH" --state open --json number --jq 'length' 2>/dev/null || echo 0)
if [[ "$PR_COUNT" -eq 0 ]]; then
    printf '[pre-exit-check] FAIL: no PR for branch %s — half-ship failure mode (INFRA-1953); run gh pr create now\n' "$BRANCH" >&2
    emit_idle "no_pr_for_branch"
    exit 1
fi

# ── (c) auto-merge armed ────────────────────────────────────────────────────
PR_N=$(gh pr list --head "$BRANCH" --state open --json number --jq '.[0].number' 2>/dev/null)
# CREDIBLE-1518: armed means autoMergeRequest is non-null. gh's GraphQL JSON
# names the field mergeMethod; the REST-backed gh-shim (pr-view-translate.py)
# carries both. Reading only .merge_method made every armed PR a false red.
AM=$(gh pr view "$PR_N" --json autoMergeRequest \
    --jq 'if .autoMergeRequest == null then "DISARMED" else (.autoMergeRequest.mergeMethod // .autoMergeRequest.merge_method // "ARMED") end' 2>/dev/null)
if [[ "$AM" == "DISARMED" ]]; then
    printf '[pre-exit-check] FAIL: PR #%s exists but auto-merge not armed (INFRA-1906); re-arm via GraphQL\n' "$PR_N" >&2
    emit_idle "auto_merge_not_armed"
    exit 2
fi

printf '[pre-exit-check] OK: branch=%s PR=#%s auto-merge=%s\n' "$BRANCH" "$PR_N" "$AM"
exit 0
