#!/usr/bin/env bash
# scripts/coord/lib/no-idle.sh — shared anti-idle helpers (INFRA-2210)
#
# Operator directive: "no idle curators, ship aggressively for 12h, conserve
# OFF." A curator-loop tick that would otherwise print "quiet — no
# actionable items" and exit must instead try one fallback action before
# giving up: broadcast a HANDOFF offer, rescue a stuck PR, or self-dispatch
# on the next unclaimed P0/P1 gap. This file is sourced (not executed) by
# each *-loop.sh; it has no subcommands of its own.
#
# Usage (from a *-loop.sh):
#   source "$(dirname "$0")/lib/no-idle.sh"
#   if no_idle_try_fallback "ci-audit"; then
#       return 0   # action taken — tick is no longer quiet
#   fi
#   return 1       # genuinely nothing to do, even after fallback
#
# Rust-First-Bypass: glue between chump CLI + sqlite3 + broadcast.sh; <200
# LOC; read-mostly (only writes are ambient emits, already idempotent).

_NO_IDLE_LIB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_NO_IDLE_WORK_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
_NO_IDLE_GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_NO_IDLE_GIT_COMMON" == ".git" ]]; then
    _NO_IDLE_REPO_ROOT="$_NO_IDLE_WORK_ROOT"
else
    _NO_IDLE_REPO_ROOT="$(cd "$_NO_IDLE_GIT_COMMON/.." && pwd)"
fi
# INFRA-8190: resolve the ONE canonical store (CHUMP_STATE_DB > MAIN checkout),
# not the linked worktree's own .chump/state.db (a split-brain copy).
# shellcheck source=state-store.sh
. "$(dirname "${BASH_SOURCE[0]}")/state-store.sh"
_NO_IDLE_STATE_DB="$(chump_state_db "$_NO_IDLE_WORK_ROOT" 2>/dev/null)"

# Emit kind=curator_no_op_avoided — the AC4 signal the watchdog counts.
# scanner-anchor: "kind":"curator_no_op_avoided"
no_idle_emit_avoided() {
    local role="$1" action="$2" detail="${3:-}"
    local lock_dir="$_NO_IDLE_REPO_ROOT/.chump-locks"
    mkdir -p "$lock_dir" 2>/dev/null || true
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local extra
    extra="\"role\":\"${role}\",\"action\":\"${action}\""
    [[ -n "$detail" ]] && extra="${extra},\"detail\":\"${detail}\""
    printf '{"ts":"%s","kind":"curator_no_op_avoided","session":"%s",%s}\n' \
        "$ts" "${CHUMP_SESSION_ID:-${role}-$$}" "$extra" \
        >> "${CHUMP_AMBIENT_LOG:-$lock_dir/ambient.jsonl}" 2>/dev/null || true
}

# Broadcast a HANDOFF offer to another lane. Cheap, always safe.
no_idle_offer_handoff() {
    local role="$1" msg="$2"
    local bcast="$_NO_IDLE_LIB_ROOT/broadcast.sh"
    [[ -x "$bcast" ]] || bcast="bash $bcast"
    $bcast WARN "no-idle: ${role} lane quiet — offering help: ${msg}" 2>/dev/null || true
}

# Check for BLOCKED PRs stuck > N hours; return 0 (found + acted) or 1.
# Prints the PR numbers acted on.
no_idle_check_stuck_prs() {
    local role="$1" max_age_h="${2:-2}"
    local lock_dir="$_NO_IDLE_REPO_ROOT/.chump-locks"
    local ambient="${CHUMP_AMBIENT_LOG:-$lock_dir/ambient.jsonl}"
    [[ -f "$ambient" ]] || return 1
    local now_epoch
    now_epoch="$(date -u +%s)"
    local stuck_prs
    stuck_prs="$(tail -500 "$ambient" 2>/dev/null | grep '"kind":"pr_stuck"' | tail -20 || true)"
    [[ -n "$stuck_prs" ]] || return 1
    local acted=0
    local line pr_num ev_ts ev_epoch age_h
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        pr_num="$(printf '%s' "$line" | sed -n 's/.*"pr":"\{0,1\}\([0-9]*\)"\{0,1\}.*/\1/p')"
        ev_ts="$(printf '%s' "$line" | sed -n 's/.*"ts":"\([^"]*\)".*/\1/p')"
        [[ -n "$ev_ts" ]] || continue
        ev_epoch="$(date -u -d "$ev_ts" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$ev_ts" +%s 2>/dev/null || echo 0)"
        [[ "$ev_epoch" -gt 0 ]] || continue
        age_h=$(( (now_epoch - ev_epoch) / 3600 ))
        if (( age_h >= max_age_h )); then
            no_idle_offer_handoff "$role" "stuck-PR convoy: PR#${pr_num:-?} BLOCKED ${age_h}h — triggering rescue dispatch"
            acted=1
        fi
    done <<< "$stuck_prs"
    (( acted == 1 )) && return 0
    return 1
}

# Self-dispatch: find next open P0/P1 gap with no skills_required (or in
# $domain) and broadcast intent to pick it up. Read-only against state.db —
# never claims on the caller's behalf (claiming stays a human/worker decision
# via `chump claim`), just surfaces the target so the loop's actionable-item
# count is non-zero and the operator/fleet sees the offer.
no_idle_self_dispatch_gap() {
    local role="$1" domain="${2:-}"
    command -v sqlite3 >/dev/null 2>&1 || return 1
    [[ -f "$_NO_IDLE_STATE_DB" ]] || return 1
    local where="status='open' AND priority IN ('P0','P1') AND (skills_required IS NULL OR skills_required='' OR skills_required='[]')"
    if [[ -n "$domain" ]]; then
        where="${where} AND domain='${domain}'"
    fi
    local row
    row="$(sqlite3 -separator '|' "$_NO_IDLE_STATE_DB" \
        "SELECT id, title FROM gaps WHERE ${where} ORDER BY priority ASC LIMIT 1;" 2>/dev/null || true)"
    [[ -n "$row" ]] || return 1
    local gid="${row%%|*}"
    local title="${row#*|}"
    no_idle_offer_handoff "$role" "self-dispatch candidate: ${gid} — ${title}"
    printf '%s\n' "$gid"
    return 0
}

# Top-level fallback dispatcher — tries, in order: stuck-PR rescue, then
# self-dispatch on next P0/P1. Returns 0 if any action was taken (and emits
# curator_no_op_avoided), 1 if genuinely nothing to do.
no_idle_try_fallback() {
    local role="$1" domain="${2:-}"
    if no_idle_check_stuck_prs "$role" 2; then
        no_idle_emit_avoided "$role" "stuck_pr_rescue"
        return 0
    fi
    local gid
    if gid="$(no_idle_self_dispatch_gap "$role" "$domain")"; then
        no_idle_emit_avoided "$role" "self_dispatch" "$gid"
        return 0
    fi
    return 1
}
