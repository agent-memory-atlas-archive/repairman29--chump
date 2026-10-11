#!/usr/bin/env bash
# RESILIENT-1579: reopen a gap unless it carries an OPERATOR block.
# A blocked gap is auto-blocked only if its notes carry an auto-block stamp
# (INFRA-3832 auto-block); any other blocked gap is treated as operator-set.
# Usage: source this; safe_reopen_gap <GAP-ID>   (rc 0 reopened/already open, 3 refused, 1 failed)

# gap_is_operator_blocked <status> <notes>  -> rc 0 if operator-blocked
gap_is_operator_blocked() {
    [[ "$1" == "blocked" ]] || return 1
    # RESILIENT-1587: explicit operator marker wins even over an auto-block stamp.
    if grep -qE 'operator-block:' <<<"$2"; then return 0; fi
    if grep -qE 'auto-block|auto-blocked' <<<"$2"; then return 1; fi
    return 0
}

# gap_reopen_allowed <GAP-ID> -> rc 0 allowed, 3 refused (operator-blocked).
# Use before any `chump gap set --status open --add-note ...` that cannot go through safe_reopen_gap.
gap_reopen_allowed() {
    local gid="$1" bin="${CHUMP_BIN:-chump}" status notes
    status="$("$bin" gap show "$gid" --field status 2>/dev/null | tr -d '[:space:]' || true)"
    [[ "$status" == "blocked" ]] || return 0
    notes="$("$bin" gap show "$gid" --field notes 2>/dev/null || true)"
    if gap_is_operator_blocked "$status" "$notes"; then
        echo "gap_reopen_allowed: $gid is operator-blocked — refusing to reopen" >&2
        return 3
    fi
    return 0
}

safe_reopen_gap() {
    local gid="$1" bin="${CHUMP_BIN:-chump}" status notes
    status="$("$bin" gap show "$gid" --field status 2>/dev/null | tr -d '[:space:]' || true)"
    [[ "$status" == "open" ]] && return 0
    notes="$("$bin" gap show "$gid" --field notes 2>/dev/null || true)"
    if gap_is_operator_blocked "$status" "$notes"; then
        echo "safe_reopen_gap: $gid is operator-blocked — refusing to reopen" >&2
        return 3
    fi
    "$bin" gap set "$gid" --status open >/dev/null 2>&1
}
