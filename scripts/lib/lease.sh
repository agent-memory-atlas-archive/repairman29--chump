#!/usr/bin/env bash
# scripts/lib/lease.sh — INFRA-1212
#
# Shared reader for `.chump-locks/*.json` lease files. Replaces 8 ad-hoc
# parsers across the reaper / scanner / driver scripts. Keeps the parsers
# in ONE place so when the lease JSON schema gains a field, every consumer
# picks it up consistently.
#
# Usage: source scripts/lib/lease.sh
#
# Public API
#   lease_dir [--repo <path>]            echo the canonical lease dir
#   lease_iter [--repo <path>]           emit one lease file path per line
#   lease_field <path> <field>           echo a string field value (empty if absent)
#   lease_int_field <path> <field>       echo an integer field value (empty if absent)
#   lease_heartbeat_age_s <path>         seconds since heartbeat_at (or 0 if missing)
#   lease_is_fresh <path> [grace_s=900]  return 0 iff heartbeat is within grace
#   lease_is_expired <path> [grace_s=30] return 0 iff expires_at is past now+grace
#   lease_session_id <path>              shortcut for `lease_field … session_id`
#   lease_gap_id <path>                  shortcut for `lease_field … gap_id`
#   lease_worktree <path>                shortcut for `lease_field … worktree`
#
# Implementation notes
# - Parsers grep-based on purpose: jq is not always present on minimal CI
#   images / fresh CCR sandboxes. We do however fall back to jq when it
#   IS available because it handles deeply-quoted strings correctly.
# - All functions are read-only. No writer is exposed — leases are written
#   by atomic_claim::write_basic_lease + write_or_merge_lease (Rust). This
#   library is for consumers only.

# INFRA-8190: the ONE gap-store path resolver (chump_state_db).
# shellcheck source=../coord/lib/state-store.sh
. "$(dirname "${BASH_SOURCE[0]}")/../coord/lib/state-store.sh" 2>/dev/null || true

# Idempotent guard.
if [[ -n "${__CHUMP_LIB_LEASE_LOADED:-}" ]]; then return 0; fi
__CHUMP_LIB_LEASE_LOADED=1

# ── Helpers ──────────────────────────────────────────────────────────────────

# Echo the canonical .chump-locks dir for the given repo (default: cwd's repo).
lease_dir() {
    local repo=""
    if [[ "${1:-}" == "--repo" && -n "${2:-}" ]]; then repo="$2"; shift 2; fi
    if [[ -z "$repo" ]]; then
        repo="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    fi
    printf '%s\n' "${CHUMP_LOCK_DIR:-$repo/.chump-locks}"
}

# Iterate all lease files in the canonical lease dir. Skips ambient.jsonl
# and the cooldown/ subdir which are not lease files.
lease_iter() {
    local dir; dir="$(lease_dir "$@")"
    [[ -d "$dir" ]] || return 0
    # Use nullglob-safe iteration via find — handles the empty-dir case.
    find "$dir" -maxdepth 1 -type f -name '*.json' \
        ! -name 'ambient.jsonl' 2>/dev/null
}

# Generic field extractor. Prefers jq when available; falls back to a
# grep + sed pattern that matches the canonical pretty-printed shape
# written by atomic_claim::write_basic_lease + write_or_merge_lease.
lease_field() {
    local path="$1" field="$2"
    [[ -f "$path" ]] || return 0
    if command -v jq >/dev/null 2>&1; then
        jq -r --arg f "$field" '.[$f] // empty' "$path" 2>/dev/null
        return
    fi
    grep -oE "\"${field}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$path" 2>/dev/null \
        | head -1 \
        | sed -E "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/"
}

# Integer field extractor — matches { "field": 1234 } (no quotes).
lease_int_field() {
    local path="$1" field="$2"
    [[ -f "$path" ]] || return 0
    if command -v jq >/dev/null 2>&1; then
        jq -r --arg f "$field" '.[$f] // empty' "$path" 2>/dev/null
        return
    fi
    grep -oE "\"${field}\"[[:space:]]*:[[:space:]]*-?[0-9]+" "$path" 2>/dev/null \
        | head -1 \
        | sed -E "s/.*\"${field}\"[[:space:]]*:[[:space:]]*(-?[0-9]+).*/\1/"
}

# Convenience shortcuts.
lease_session_id() { lease_field "$1" session_id; }
lease_gap_id()     { lease_field "$1" gap_id; }
lease_worktree()   { lease_field "$1" worktree; }

# Heartbeat age in seconds since `heartbeat_at`. Returns 0 if absent
# or unparseable (consumers should treat 0 as "no heartbeat" not "fresh").
lease_heartbeat_age_s() {
    local path="$1"
    local hb; hb="$(lease_field "$path" heartbeat_at)"
    [[ -z "$hb" ]] && { printf '0\n'; return; }
    # ISO8601 like "2026-05-14T07:21:50Z" — strip trailing Z, parse as UTC.
    local hb_epoch
    if hb_epoch="$(date -u -j -f '%Y-%m-%dT%H:%M:%S' "${hb%Z}" +%s 2>/dev/null)"; then
        :
    elif hb_epoch="$(date -u -d "$hb" +%s 2>/dev/null)"; then
        :
    else
        printf '0\n'; return
    fi
    local now; now="$(date -u +%s)"
    printf '%d\n' "$(( now - hb_epoch ))"
}

# Return 0 iff heartbeat_at is within `grace_s` seconds (default 900 = 15 min).
# Mirrors the INFRA-1074 reaper safety threshold.
lease_is_fresh() {
    local path="$1" grace="${2:-900}"
    local age; age="$(lease_heartbeat_age_s "$path")"
    [[ "$age" -gt 0 ]] || return 1   # no heartbeat == not fresh
    [[ "$age" -le "$grace" ]]
}

# Return 0 iff expires_at is in the past (with `grace_s` slack, default 30s).
lease_is_expired() {
    local path="$1" grace="${2:-30}"
    local exp; exp="$(lease_field "$path" expires_at)"
    [[ -z "$exp" ]] && return 1   # no expiry == not expired
    local exp_epoch
    if exp_epoch="$(date -u -j -f '%Y-%m-%dT%H:%M:%S' "${exp%Z}" +%s 2>/dev/null)"; then
        :
    elif exp_epoch="$(date -u -d "$exp" +%s 2>/dev/null)"; then
        :
    else
        return 1
    fi
    local now; now="$(date -u +%s)"
    [[ "$now" -gt "$(( exp_epoch + grace ))" ]]
}

# ── state.db lease reader (INFRA-2744) ───────────────────────────────────────
# The helpers above read `.chump-locks/*.json` lease files. But the CANONICAL
# lease store is the `leases` table in `.chump/state.db` — interactive
# `chump claim` (atomic_claim::try_claim_gap) writes the lease there ONLY, with
# no JSON sidecar. Any tool that resolves "who holds gap X's claim" purely from
# JSON (bot-merge re-claim, --release) therefore misses an interactive claim and
# wrongly reports "owned by a DIFFERENT session". This reader closes that gap.
#
# lease_session_from_statedb <gap_id> [<state_db_path>]
#   Echoes the session_id holding <gap_id>'s lease (empty if none / no sqlite3).
#   Default db resolves the MAIN repo's state.db via --git-common-dir, so it is
#   correct when called from inside a linked worktree (whose own state.db does
#   NOT hold the canonical lease). Read-only.
lease_session_from_statedb() {
    local gap_id="$1" db="${2:-}"
    # gap ids are [A-Za-z0-9_-]; reject anything else rather than risk SQL.
    [[ "$gap_id" =~ ^[A-Za-z0-9_-]+$ ]] || return 0
    command -v sqlite3 >/dev/null 2>&1 || return 0
    if [[ -z "$db" ]]; then
        local repo gitdir
        gitdir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
        if [[ -n "$gitdir" ]]; then repo="$(dirname "$gitdir")"; else repo="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; fi
        # INFRA-8190: the ONE shell resolver (falls back to the same precedence).
        if declare -F chump_state_db >/dev/null 2>&1; then db="$(chump_state_db "$repo" 2>/dev/null)"; else db="${CHUMP_STATE_DB:-$repo/.chump/state.db}"; fi
    fi
    [[ -f "$db" ]] || return 0
    sqlite3 "$db" "SELECT session_id FROM leases WHERE gap_id='$gap_id' LIMIT 1;" 2>/dev/null || true
}

# ── dispatch-worktree lease lookup (INFRA-8204) ──────────────────────────────
# `chump dispatch --backend headless` writes its lease under
# `<worktree>/.chump-locks/<session_id>.json` (see src/dispatch.rs
# resolve_dispatch_session_id / claim()). bot-merge.sh's session-ID
# auto-detection only ever scanned `$LOCK_DIR/*.json` (the MAIN checkout) and
# state.db — never `$PWD/.chump-locks` when `$PWD` IS the dispatch worktree —
# so it could never find this lease. This helper closes that gap.
#
# lease_file_for_gap_in_dir <dir> <gap-id>
#   Echoes the path of the first <dir>/*.json lease whose gap_id (or
#   pending_new_gap.id) equals <gap-id>. Prints nothing and returns 1 when no
#   match is found (or <dir> doesn't exist). Read-only.
lease_file_for_gap_in_dir() {
    local dir="$1" gap_id="$2"
    [[ -d "$dir" ]] || return 1
    local f gid
    for f in "$dir"/*.json; do
        [[ -f "$f" ]] || continue
        gid="$(lease_field "$f" gap_id)"
        if [[ -z "$gid" ]]; then
            if command -v jq >/dev/null 2>&1; then
                gid="$(jq -r '.pending_new_gap.id // empty' "$f" 2>/dev/null)"
            else
                # Lease JSON is written compact (single-line, see
                # chump-agent-lease::claim_gap) so a window-free regex over
                # the whole file is safe here.
                gid="$(grep -oE '"pending_new_gap"[[:space:]]*:[[:space:]]*\{[^}]*"id"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null \
                    | sed -E 's/.*"id"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')"
            fi
        fi
        if [[ "$gid" == "$gap_id" ]]; then
            printf '%s\n' "$f"
            return 0
        fi
    done
    return 1
}

# ── bot-merge session-auto-detect selection (INFRA-8201) ─────────────────────
# bm_pick_session_from_lockdir <lockdir> <gap_id>
#   Scans every lease file in <lockdir> for one whose gap_id (or
#   pending_new_gap.id) equals <gap_id>, SKIPPING any lease whose
#   expires_at has passed (lease_is_expired). Echoes the first live match's
#   session_id and returns 0; prints nothing and returns 1 on no live match.
#   Extracted from bot-merge.sh's "Session-ID auto-detection" block so an
#   expired marker (TTL passed, writer dead) can never be adopted as bot-
#   merge's own identity ahead of a live session's lease for the same gap.
bm_pick_session_from_lockdir() {
    local dir="$1" gap_id="$2"
    local f gid sess
    [[ -d "$dir" ]] || return 1
    for f in "$dir"/*.json; do
        [[ -f "$f" ]] || continue
        [[ "$(basename "$f")" == "ambient.jsonl" ]] && continue
        if lease_is_expired "$f"; then
            continue
        fi
        gid="$(lease_field "$f" gap_id)"
        if [[ -z "$gid" ]]; then
            if command -v jq >/dev/null 2>&1; then
                gid="$(jq -r '.pending_new_gap.id // empty' "$f" 2>/dev/null)"
            else
                gid="$(grep -oE '"pending_new_gap"[[:space:]]*:[[:space:]]*\{[^}]*"id"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null \
                    | sed -E 's/.*"id"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')"
            fi
        fi
        if [[ "$gid" == "$gap_id" ]]; then
            sess="$(lease_session_id "$f")"
            if [[ -n "$sess" ]]; then
                printf '%s\n' "$sess"
                return 0
            fi
        fi
    done
    return 1
}

# lease_worktree_from_statedb <gap_id> [<state_db_path>]
#   Echoes the worktree path holding <gap_id>'s lease (empty if none / no
#   sqlite3). INFRA-1901: lets a caller detect "am I already sitting inside
#   the claimed worktree?" BEFORE invoking `chump claim`, instead of only
#   recovering after a claim failure. Same db-resolution rules as
#   lease_session_from_statedb. Read-only.
lease_worktree_from_statedb() {
    local gap_id="$1" db="${2:-}"
    [[ "$gap_id" =~ ^[A-Za-z0-9_-]+$ ]] || return 0
    command -v sqlite3 >/dev/null 2>&1 || return 0
    if [[ -z "$db" ]]; then
        local repo gitdir
        gitdir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
        if [[ -n "$gitdir" ]]; then repo="$(dirname "$gitdir")"; else repo="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; fi
        # INFRA-8190: the ONE shell resolver (falls back to the same precedence).
        if declare -F chump_state_db >/dev/null 2>&1; then db="$(chump_state_db "$repo" 2>/dev/null)"; else db="${CHUMP_STATE_DB:-$repo/.chump/state.db}"; fi
    fi
    [[ -f "$db" ]] || return 0
    sqlite3 "$db" "SELECT worktree FROM leases WHERE gap_id='$gap_id' LIMIT 1;" 2>/dev/null || true
}
