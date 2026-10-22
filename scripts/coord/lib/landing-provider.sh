#!/usr/bin/env bash
# scripts/coord/lib/landing-provider.sh — RESILIENT-1643 (PHASE-R R3 slice b)
#
# ONE decision: "is GitHub's native merge queue the landing provider for this
# ship?" When it is, the ship path must only ENQUEUE and wait for the R1
# receipt — the queue owns rebasing and ordering, so bot-merge must stop
# rebasing / force-pushing the branch (a local rebase races the queue's own
# rebase+retest and can eject the entry; on a 4-core runner that is a double
# rebase for nothing).
#
# THE GATE
#   Queue mode is ON when BOTH hold:
#     * CHUMP_LANDING_PROVIDER == github   (operator opt-in; case-insensitive)
#     * a merge-queue ruleset is active on the base branch (main), detected the
#       same way auto-merge-armer.sh does (INFRA-1377):
#         - CHUMP_MERGE_QUEUE_ENABLED=1  → force on  (no API call)
#         - CHUMP_MERGE_QUEUE_ENABLED=0  → force off (no API call)
#         - unset → live GraphQL probe for repository.mergeQueue(branch:"main")
#   With no queue (the default — CHUMP_LANDING_PROVIDER unset), this returns
#   "false" and the caller's current rebase/arm behaviour is unchanged.
#
# FAIL-SAFE
#   Any probe error, missing gh, or unknown owner/repo → "false". For a gate
#   file the safe default is the long-standing behaviour (rebase as before);
#   we only SKIP rebasing when a queue is positively confirmed.
#
# USAGE
#   source scripts/coord/lib/landing-provider.sh
#   if [[ "$(landing_queue_mode "owner/repo")" == "true" ]]; then ... ; fi
#   # owner/repo optional; derived from the chump/origin remote when omitted.

# Guard against double-sourcing.
# shellcheck disable=SC2317  # `|| true` only runs if executed rather than sourced
if [[ -n "${_CHUMP_LANDING_PROVIDER_SOURCED:-}" ]]; then
    return 0 2>/dev/null || true
fi
_CHUMP_LANDING_PROVIDER_SOURCED=1

_landing_provider_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve owner/repo for the GraphQL probe. Prefer an explicit arg, then the
# `chump` remote, then `origin`. Echoes "owner/repo" or empty on failure.
_landing_provider_owner_repo() {
    local arg="${1:-}"
    if [[ -n "$arg" ]]; then
        printf '%s' "$arg"
        return 0
    fi
    local url
    url="$(git remote get-url chump 2>/dev/null \
        || git remote get-url origin 2>/dev/null || true)"
    [[ -z "$url" ]] && return 0
    printf '%s' "$url" | sed 's|.*github.com[:/]||; s|\.git$||'
}

# Live-detect a merge queue on main. Echoes "true"/"false". Mirrors
# auto-merge-armer.sh::_detect_merge_queue (INFRA-1377).
_landing_provider_detect_queue() {
    local owner_repo owner name result
    owner_repo="$(_landing_provider_owner_repo "${1:-}")"
    owner="${owner_repo%%/*}"
    name="${owner_repo##*/}"
    if [[ -z "$owner" || -z "$name" || "$owner" == "$name" ]]; then
        printf 'false'; return 0
    fi
    if ! command -v gh >/dev/null 2>&1; then
        printf 'false'; return 0
    fi
    result="$(gh api graphql \
        -f owner="$owner" -f name="$name" \
        -f query='query($owner:String!,$name:String!){
          repository(owner:$owner,name:$name){
            mergeQueue(branch:"main"){id}}}' \
        --jq '.data.repository.mergeQueue != null' 2>/dev/null || printf 'false')"
    [[ "$result" == "true" ]] && printf 'true' || printf 'false'
}

# landing_queue_mode [owner/repo] → echoes "true" when GitHub's merge queue is
# the landing provider (see THE GATE above), else "false".
landing_queue_mode() {
    # Opt-in gate: provider must be GitHub, case-insensitive.
    local provider="${CHUMP_LANDING_PROVIDER:-}"
    provider="$(printf '%s' "$provider" | tr '[:upper:]' '[:lower:]')"
    if [[ "$provider" != "github" ]]; then
        printf 'false'; return 0
    fi
    case "${CHUMP_MERGE_QUEUE_ENABLED:-}" in
        1) printf 'true'; return 0 ;;
        0) printf 'false'; return 0 ;;
    esac
    _landing_provider_detect_queue "${1:-}"
}
