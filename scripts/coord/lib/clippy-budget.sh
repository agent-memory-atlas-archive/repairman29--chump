#!/usr/bin/env bash
# clippy-budget.sh — RESILIENT-1608
#
# Derives bot-merge's clippy budget from measured clippy time instead of two
# fixed numbers (the INFRA-1422 300s stage budget and the INFRA-587 900s
# phase timeout). Receipts 2026-10-16 on cuphead: a clean clippy took 541s
# under load and was declared wedged at 300s; a later one was killed at 900s.
#
# Source: the ambient stream's kind=bot_merge_phase_duration events, which
# stage_done writes only when a stage completes (i.e. clippy came back
# green). Rule: budget = 1.5 x the slowest of the last 5 green
# `cargo clippy --workspace ...` stages, floor 300s, ceiling 3600s. No
# samples: 900s (the previous fixed value).
#
# Usage: chump_clippy_budget <ambient.jsonl>
#   prints "<budget_s> <source> <slowest_green_s> <samples>"
#   source is "last_green" or "default".

chump_clippy_budget() {
    local amb="${1:-}" floor=300 ceil=3600 default=900 n=5
    local samples=""
    if [[ -n "$amb" && -r "$amb" ]]; then
        samples="$(tail -n 50000 "$amb" 2>/dev/null \
            | grep '"kind":"bot_merge_phase_duration"' \
            | grep '"phase":"cargo clippy --workspace' \
            | sed -n 's/.*"elapsed_s":\([0-9][0-9]*\).*/\1/p' \
            | tail -n "$n" || true)"
    fi
    if [[ -z "$samples" ]]; then
        echo "$default default 0 0"
        return 0
    fi
    local slowest=0 count=0 s
    while read -r s; do
        [[ "$s" =~ ^[0-9]+$ ]] || continue
        count=$((count + 1))
        (( s > slowest )) && slowest=$s
    done <<<"$samples"
    if (( count == 0 )); then
        echo "$default default 0 0"
        return 0
    fi
    local b=$(( (slowest * 3 + 1) / 2 ))
    (( b < floor )) && b=$floor
    (( b > ceil )) && b=$ceil
    echo "$b last_green $slowest $count"
}
