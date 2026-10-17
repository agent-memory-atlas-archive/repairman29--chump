#!/usr/bin/env bash
# scripts/lib/worktree-iter.sh — INFRA-1211
#
# Shared worktree-scanning primitives for the reaper family.
# Eliminates the 7 independent hand-rolled scan loops that each reaper
# maintained independently (divergence documented in INFRA-1211).
#
# Builds on top of scripts/lib/lease.sh (INFRA-1212), which owns all
# .chump-locks/*.json reading. This library owns the *worktree* layer:
# path scanning, git state inspection, and ambient event emission.
#
# Public API:
#   scan_worktrees [--include-tmp] [--include-dot-claude] [--repo <path>]
#       Emit one worktree path per stdout line.
#       --include-tmp       include /tmp/chump-* directories (default: on)
#       --include-dot-claude include <repo>/.claude/worktrees/* (default: on)
#       --repo <path>       use this as the main repo root
#
#   wt_has_active_lease <wt_path> [<grace_s>]
#       Return 0 iff any .chump-locks/*.json claims <wt_path> and its
#       heartbeat is within <grace_s> seconds (default 900 = 15 min).
#
#   wt_is_dirty <wt_path>
#       Return 0 iff the worktree has uncommitted or untracked changes.
#
#   wt_has_live_bot_merge <wt_path> [<lock_dir>] [<grace_min>]   (RESILIENT-1609)
#       Return 0 iff a bot-merge ship is live in <wt_path>: a fresh
#       .chump-locks/bot-merge-*.steps file names it, or a live process has
#       it as its cwd. Sets WT_LIVE_BOT_MERGE_DETAIL.
#
#   emit_reaper_event <kind> <wt_path> <reason> [<extra_json_fields>]
#       Append one JSON line to .chump-locks/ambient.jsonl.
#       <extra_json_fields>: optional extra JSON fields like "\"foo\":1"
#
# Usage:
#   # shellcheck source=scripts/lib/worktree-iter.sh
#   source "$(dirname "$0")/../lib/worktree-iter.sh"
#   source "$(dirname "$0")/../lib/lease.sh"   # required for wt_has_active_lease

# Idempotent guard.
if [[ -n "${__CHUMP_LIB_WORKTREE_ITER_LOADED:-}" ]]; then return 0; fi
__CHUMP_LIB_WORKTREE_ITER_LOADED=1
# INFRA-8190: the ONE gap-store path resolver (chump_state_db).
# shellcheck source=../coord/lib/state-store.sh
. "$(dirname "${BASH_SOURCE[0]}")/../coord/lib/state-store.sh" 2>/dev/null || true

# ── Internal helpers ──────────────────────────────────────────────────────────

# Resolve the main repo root from any worktree. Uses --git-common-dir so linked
# worktrees still point at the shared repo root.
_wt_main_repo() {
    if [[ -n "${REAPER_REPO_ROOT:-}" ]]; then
        printf '%s\n' "$REAPER_REPO_ROOT"
        return
    fi
    local common
    common="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
    if [[ "$common" == ".git" ]]; then
        git rev-parse --show-toplevel 2>/dev/null || pwd
    else
        (cd "$common/.." && pwd)
    fi
}

# ── Public: scan_worktrees ────────────────────────────────────────────────────

# scan_worktrees [--include-tmp] [--include-dot-claude] [--repo <path>]
#
# Both --include-tmp and --include-dot-claude are ON by default; pass the
# flag to override via CHUMP_WT_SCAN_TMP=0 / CHUMP_WT_SCAN_DOT_CLAUDE=0.
# Directories that don't exist are silently skipped.
scan_worktrees() {
    local include_tmp="${CHUMP_WT_SCAN_TMP:-1}"
    local include_dot_claude="${CHUMP_WT_SCAN_DOT_CLAUDE:-1}"
    local repo=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --include-tmp)         include_tmp=1 ;;
            --no-tmp)              include_tmp=0 ;;
            --include-dot-claude)  include_dot_claude=1 ;;
            --no-dot-claude)       include_dot_claude=0 ;;
            --repo)                repo="$2"; shift ;;
            *) ;;  # ignore unknown flags for forward-compat
        esac
        shift
    done

    [[ -z "$repo" ]] && repo="$(_wt_main_repo)"

    if [[ "$include_dot_claude" == "1" ]]; then
        local wt_base="${CHUMP_WORKTREE_BASE:-$repo/.claude/worktrees}"
        if [[ -d "$wt_base" ]]; then
            for d in "$wt_base"/*/; do
                [[ -d "$d" ]] && printf '%s\n' "${d%/}"
            done
        fi
    fi

    if [[ "$include_tmp" == "1" ]]; then
        for d in /tmp/chump-*/; do
            [[ -d "$d" ]] && printf '%s\n' "${d%/}"
        done
    fi
}

# ── Public: wt_has_active_lease ──────────────────────────────────────────────

# wt_has_active_lease <wt_path> [<grace_s>]
#
# Scans all .chump-locks/*.json and returns 0 iff at least one lease:
#   (a) names <wt_path> (or /private<wt_path> on macOS) in its "worktree" field, AND
#   (b) has heartbeat_at within <grace_s> seconds (default 900 = 15 min).
#
# Requires lease.sh to be sourced. Degrades gracefully if lease.sh helpers
# are unavailable — falls back to a raw grep scan (sufficient for safety).
wt_has_active_lease() {
    local wt_path="$1"
    local grace="${2:-900}"

    # Normalise macOS /private/tmp symlink — leases may store either form.
    local wt_alt=""
    if [[ "$wt_path" == /tmp/* ]]; then
        wt_alt="/private${wt_path}"
    elif [[ "$wt_path" == /private/tmp/* ]]; then
        wt_alt="${wt_path#/private}"
    fi

    local repo; repo="$(_wt_main_repo)"

    # RESILIENT-099: interactive `chump claim` writes the lease to the state.db
    # `leases` table ONLY (no .chump-locks/*.json sidecar with a heartbeat). Check
    # it FIRST so an active interactive claim HARD-BLOCKS reap — the reaper ate an
    # actively-leased worktree this way. Same canonical-store split as INFRA-2744
    # (bot-merge re-claim) / RESILIENT-103 (lease unification).
    if command -v sqlite3 >/dev/null 2>&1; then
        # INFRA-8190: the ONE shell resolver when loaded (same precedence otherwise).
        local _sdb
        if declare -F chump_state_db >/dev/null 2>&1; then _sdb="$(chump_state_db "$repo" 2>/dev/null)"; else _sdb="${CHUMP_STATE_DB:-$repo/.chump/state.db}"; fi
        if [[ -f "$_sdb" ]]; then
            local _now _hit
            _now="$(date -u +%s)"
            _hit="$(sqlite3 "$_sdb" "SELECT 1 FROM leases WHERE (worktree='$wt_path' OR worktree='$wt_alt') AND expires_at > $_now LIMIT 1;" 2>/dev/null || true)"
            [[ -n "$_hit" ]] && return 0
        fi
    fi

    local lock_dir="${CHUMP_LOCK_DIR:-$repo/.chump-locks}"
    [[ -d "$lock_dir" ]] || return 1

    local lease
    for lease in "$lock_dir"/*.json; do
        [[ -f "$lease" ]] || continue

        # Read worktree field — use lease.sh if available, else grep.
        local claimed_wt=""
        if command -v lease_worktree >/dev/null 2>&1; then
            claimed_wt="$(lease_worktree "$lease" 2>/dev/null || true)"
        else
            claimed_wt="$(grep -oE '"worktree"[[:space:]]*:[[:space:]]*"[^"]*"' "$lease" 2>/dev/null \
                | head -1 \
                | sed -E 's/.*"worktree"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')"
        fi
        [[ -z "$claimed_wt" ]] && continue

        # Match either canonical form.
        if [[ "$claimed_wt" != "$wt_path" && "$claimed_wt" != "$wt_alt" ]]; then
            continue
        fi

        # Check heartbeat freshness — use lease.sh if available.
        if command -v lease_is_fresh >/dev/null 2>&1; then
            if lease_is_fresh "$lease" "$grace"; then
                return 0
            fi
        else
            # Fallback: raw grep for heartbeat_at and manual age calculation.
            local hb
            hb="$(grep -oE '"heartbeat_at"[[:space:]]*:[[:space:]]*"[^"]*"' "$lease" 2>/dev/null \
                | head -1 \
                | sed -E 's/.*"heartbeat_at"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')"
            [[ -z "$hb" ]] && hb="$(grep -oE '"taken_at"[[:space:]]*:[[:space:]]*"[^"]*"' "$lease" 2>/dev/null \
                | head -1 \
                | sed -E 's/.*"taken_at"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')"
            if [[ -n "$hb" ]]; then
                local hb_epoch now age
                hb_epoch="$(date -u -j -f '%Y-%m-%dT%H:%M:%S' "${hb%Z}" +%s 2>/dev/null \
                    || date -u -d "$hb" +%s 2>/dev/null \
                    || echo 0)"
                now="$(date -u +%s)"
                age=$(( now - hb_epoch ))
                [[ "$age" -le "$grace" ]] && return 0
            fi
        fi
    done

    return 1
}

# ── Public: wt_is_dirty ───────────────────────────────────────────────────────

# wt_is_dirty <wt_path>
#
# Return 0 iff the worktree at <wt_path> has uncommitted or untracked changes.
# Uses `git -C <path> status --porcelain`. Returns 1 on error (e.g. not a git
# repo — treat as clean to avoid spurious safety blocks).
wt_is_dirty() {
    local wt_path="$1"
    [[ -d "$wt_path" ]] || return 1
    local out
    out="$(git -C "$wt_path" status --porcelain 2>/dev/null || true)"
    [[ -n "$out" ]]
}

# _wt_live_cwds_refresh — "<pid>\t<cwd>" for every live process, cached for
# CHUMP_WT_CWD_CACHE_S (default 15) seconds into $_WT_CWD_CACHE so a reaper sweeping hundreds of
# worktrees runs lsof once, not once per worktree. lsof -d cwd, else /proc.
_WT_CWD_CACHE=""
_WT_CWD_CACHE_T=0
_wt_live_cwds_refresh() {
    local now; now="$(date +%s)"
    if [[ -z "$_WT_CWD_CACHE_T" || $(( now - _WT_CWD_CACHE_T )) -ge "${CHUMP_WT_CWD_CACHE_S:-15}" || -z "$_WT_CWD_CACHE" ]]; then
        if command -v lsof >/dev/null 2>&1; then
            _WT_CWD_CACHE="$(lsof -a -d cwd -Fpn 2>/dev/null | awk '
                /^p/ { p = substr($0, 2); next }
                /^n/ { printf "%s\t%s\n", p, substr($0, 2) }')"
        elif [[ -d /proc/self ]]; then
            local c p
            _WT_CWD_CACHE=""
            for c in /proc/[0-9]*/cwd; do
                p="${c#/proc/}"; p="${p%/cwd}"
                _WT_CWD_CACHE+="${p}"$'\t'"$(readlink "$c" 2>/dev/null || true)"$'\n'
            done
        fi
        _WT_CWD_CACHE_T="$now"
    fi
}

# ── Public: wt_has_live_bot_merge (RESILIENT-1609) ───────────────────────────

# wt_has_live_bot_merge <wt_path> [<lock_dir>] [<grace_min>]
#
# Return 0 iff a bot-merge ship is LIVE in <wt_path>, i.e. either:
#   (a) a <lock_dir>/bot-merge-*.steps file modified within <grace_min>
#       minutes (default CHUMP_REAPER_BOT_MERGE_GRACE_MIN, else
#       CHUMP_REAPER_ACTIVE_LEASE_MIN, else 15) names this worktree in its
#       session-start line ("worktree":"<path>"), or names the gap the
#       worktree basename implies ("gap_ids" contains it); or
#   (b) <wt_path> is the cwd of a live process other than this one (lsof or
#       /proc, whichever exists).
#
# WHY: a CHUMP_BOT_MERGE_RECOVERY_MODE=1 ship takes no lease and leaves the git
# index idle while clippy/tests run, so lease + index + unpushed checks all
# said "reapable" and the reaper removed ~/chump/.claude/worktrees/infra-8180
# mid-push (2026-10-16 18:46Z, kind=bot_merge_crashed). bot-merge now touches
# its steps file on every step and on every heartbeat tick, so a fresh mtime
# means a live ship.
#
# Sets WT_LIVE_BOT_MERGE_DETAIL ("steps_file=<name>" or "cwd_pid=<pid>").
# Never deletes or writes anything. CHUMP_REAPER_SAFETY_CHECK=0 bypasses.
wt_has_live_bot_merge() {
    local wt="$1" lock_dir="${2:-}" grace_min="${3:-}"
    WT_LIVE_BOT_MERGE_DETAIL=""
    [[ -d "$wt" ]] || return 1
    [[ "${CHUMP_REAPER_SAFETY_CHECK:-1}" == "0" ]] && return 1
    [[ -z "$grace_min" ]] && grace_min="${CHUMP_REAPER_BOT_MERGE_GRACE_MIN:-${CHUMP_REAPER_ACTIVE_LEASE_MIN:-15}}"
    [[ "$grace_min" =~ ^[0-9]+$ ]] || grace_min=15
    [[ -z "$lock_dir" ]] && lock_dir="$(_wt_main_repo)/.chump-locks"

    local wt_real base expected_gap=""
    wt_real="$(cd -P "$wt" 2>/dev/null && pwd -P || printf '%s' "$wt")"
    base="$(basename "$wt_real")"
    expected_gap="$(printf '%s' "${base#chump-}" | tr '[:lower:]' '[:upper:]')"

    # (a) fresh bot-merge steps file naming this worktree / its gap.
    local sf first f_wt f_wt_real
    if [[ -d "$lock_dir" ]]; then
        while IFS= read -r sf; do
            [[ -f "$sf" ]] || continue
            first="$(head -1 "$sf" 2>/dev/null || true)"
            f_wt="$(printf '%s' "$first" | sed -n 's/.*"worktree":"\([^"]*\)".*/\1/p')"
            if [[ -n "$f_wt" ]]; then
                f_wt_real="$(cd -P "$f_wt" 2>/dev/null && pwd -P || printf '%s' "$f_wt")"
                if [[ "$f_wt" == "$wt" || "$f_wt_real" == "$wt_real" ]]; then
                    WT_LIVE_BOT_MERGE_DETAIL="steps_file=$(basename "$sf")"
                    return 0
                fi
            fi
            if [[ -n "$expected_gap" ]] && \
               printf '%s' "$first" | grep -q "\"gap_ids\":\"\([^\"]* \)\{0,\}${expected_gap}\( [^\"]*\)\{0,\}\""; then
                WT_LIVE_BOT_MERGE_DETAIL="steps_file=$(basename "$sf")"
                return 0
            fi
        done < <(find "$lock_dir" -maxdepth 1 -name 'bot-merge-*.steps' -type f -mmin "-${grace_min}" 2>/dev/null)
    fi

    # (b) a live process (not us) has this worktree as its cwd.
    local pid cwd_line cwd_line_pid
    pid=""
    _wt_live_cwds_refresh   # not in a subshell: the cache must persist
    while IFS=$'\t' read -r cwd_line_pid cwd_line; do
        [[ -n "$cwd_line" ]] || continue
        [[ "$cwd_line_pid" == "$$" ]] && continue
        if [[ "$cwd_line" == "$wt_real" || "$cwd_line" == "$wt_real/"* ]]; then
            pid="$cwd_line_pid"; break
        fi
    done <<< "$_WT_CWD_CACHE"
    if [[ -n "$pid" ]]; then
        WT_LIVE_BOT_MERGE_DETAIL="cwd_pid=$pid"
        return 0
    fi
    return 1
}

# ── Public: emit_reaper_event ─────────────────────────────────────────────────

# emit_reaper_event <kind> <wt_path> <reason> [<extra_json_fields>]
#
# Appends a JSON event to .chump-locks/ambient.jsonl.
# <extra_json_fields> is optional raw JSON text inserted into the object,
# e.g. '"age_days":3,"branch":"chump/foo"'. Must not include a leading comma.
emit_reaper_event() {
    local kind="$1"
    local wt_path="$2"
    local reason="$3"
    local extra="${4:-}"

    local repo; repo="$(_wt_main_repo)"
    local ambient="${CHUMP_AMBIENT_LOG:-$repo/.chump-locks/ambient.jsonl}"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local reaper="${REAPER_NAME:-unknown}"

    local json
    if [[ -n "$extra" ]]; then
        json="{\"ts\":\"$ts\",\"kind\":\"$kind\",\"reaper\":\"$reaper\",\"worktree\":\"$wt_path\",\"reason\":\"$reason\",$extra}"
    else
        json="{\"ts\":\"$ts\",\"kind\":\"$kind\",\"reaper\":\"$reaper\",\"worktree\":\"$wt_path\",\"reason\":\"$reason\"}"
    fi
    mkdir -p "$(dirname "$ambient")" 2>/dev/null || true
    printf '%s\n' "$json" >> "$ambient" 2>/dev/null || true
}
