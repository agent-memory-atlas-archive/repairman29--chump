#!/usr/bin/env bash
# Source me: exports the floor model/ladder/API key from the single-source
# scripts/setup/floor-config.json (RESILIENT-600, RESILIENT-596 slice).
# Wins over ~/.chump/providers.env and launcher-set ladder values, which are
# deprecated for ladder shape. providers.env supplies secret VALUES only.
_fc_root="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
CHUMP_FLOOR_CONFIG="${CHUMP_FLOOR_CONFIG:-$_fc_root/scripts/setup/floor-config.json}"
if [[ -f "$CHUMP_FLOOR_CONFIG" ]] && command -v jq >/dev/null 2>&1; then
    _fc_model="$(jq -r '.floor_model // empty' "$CHUMP_FLOOR_CONFIG")"
    _fc_ladder="$(jq -r '(.escalation_ladder // []) | join(",")' "$CHUMP_FLOOR_CONFIG")"
    _fc_free="$(jq -r '.free_tier_providers // empty' "$CHUMP_FLOOR_CONFIG")"
    _fc_base="$(jq -r '.api_base // empty' "$CHUMP_FLOOR_CONFIG")"
    _fc_keyenv="$(jq -r '.api_key_env // empty' "$CHUMP_FLOOR_CONFIG")"
    if [[ -n "$_fc_model" ]]; then
        export CHUMP_FLOOR_MODEL="$_fc_model" OPENAI_MODEL="$_fc_model"
    fi
    [[ -n "$_fc_ladder" ]] && export CHUMP_MODEL_ESCALATION_LADDER="$_fc_ladder"
    [[ -n "$_fc_free" ]] && export CHUMP_FREE_TIER_PROVIDERS="$_fc_free"
    [[ -n "$_fc_base" ]] && export OPENAI_API_BASE="$_fc_base"
    if [[ -n "$_fc_keyenv" ]]; then
        if [[ -z "${!_fc_keyenv:-}" && -f "$HOME/.chump/providers.env" ]]; then
            # shellcheck disable=SC1091
            { set -a; source "$HOME/.chump/providers.env" 2>/dev/null; set +a; }
            _fc_ladder_now="$CHUMP_MODEL_ESCALATION_LADDER"
            export CHUMP_MODEL_ESCALATION_LADDER="$_fc_ladder_now"
            [[ -n "$_fc_ladder" ]] && export CHUMP_MODEL_ESCALATION_LADDER="$_fc_ladder"
            [[ -n "$_fc_model" ]] && export OPENAI_MODEL="$_fc_model"
        fi
        [[ -n "${!_fc_keyenv:-}" ]] && export OPENAI_API_KEY="${!_fc_keyenv}"
    fi
    unset _fc_model _fc_ladder _fc_free _fc_base _fc_keyenv _fc_ladder_now
fi
unset _fc_root
