#!/usr/bin/env bash
# scripts/coord/lib/bot-merge-autocommit.sh — INFRA-8202
#
# Extracted from bot-merge.sh so the HEAD-race retry, the stray-staged-path
# refusal, and the init-phase sub-step labelling can be exercised directly by
# scripts/ci/test-bot-merge-auto-commit-head-race.sh without sourcing the
# whole 5000-line bot-merge.sh.
#
# Depends on functions/globals already provided by bot-merge.sh at call time:
#   yellow/red/info (scripts/coord/bot-merge.sh logging helpers)
#   lease_iter / lease_gap_id (scripts/lib/lease.sh — sourced by bot-merge.sh)
#   _BM_STEP_FILE / _BM_NAMED_STEP (bot-merge.sh step-tracking globals)
# The functions below degrade gracefully (fall back to `echo`/plain checks)
# when sourced standalone, e.g. from the CI test.

# Idempotent guard.
if [[ -n "${__CHUMP_LIB_BOT_MERGE_AUTOCOMMIT_LOADED:-}" ]]; then return 0; fi
__CHUMP_LIB_BOT_MERGE_AUTOCOMMIT_LOADED=1

# _bm_substep <name>
#   Updates the heartbeat step label to "init/<name>" and refreshes the
#   stall-detection timestamp so a long but legitimately-busy init phase
#   doesn't look identical to a wedged one. Call _bm_step_start to clear it
#   (it overwrites the step file with the plain step name).
_bm_substep() {
    local name="$1"
    _BM_NAMED_STEP="init/${name}"
    if [[ -n "${_BM_STEP_FILE:-}" ]]; then
        printf 'init/%s' "$name" > "$_BM_STEP_FILE" 2>/dev/null || true
        date +%s > "${_BM_STEP_FILE}.changed_at" 2>/dev/null || true
    fi
    if declare -F info >/dev/null 2>&1; then
        info "[init] ${name} starting"
    else
        printf '[init] %s starting\n' "$name"
    fi
}

# _bm_auto_commit_with_retry <commit-msg> <restage-path-list>
#   Commits currently-staged changes. If `git commit` fails because another
#   organ (pr-auto-rebase / merge-serializer) moved HEAD out from under us
#   mid-commit ("cannot lock ref HEAD"), re-reads HEAD, re-stages the same
#   path list, and retries exactly once. Any other failure (e.g. a
#   pre-commit hook rejection) is NOT retried — it falls straight back to
#   the caller's existing exit-4 path.
_bm_auto_commit_with_retry() {
    local msg="$1" restage_paths="${2:-}"
    local _head_before _head_after _err_file _rc=0
    _head_before="$(git rev-parse HEAD 2>/dev/null)"
    _err_file="$(mktemp "${TMPDIR:-/tmp}/bm-commit-err.XXXXXX" 2>/dev/null)" \
        || _err_file="/tmp/bm-commit-err.$$"

    git commit -m "$msg" 2>"$_err_file"
    _rc=$?
    cat "$_err_file" >&2 2>/dev/null || true

    if [[ "$_rc" -eq 0 ]]; then
        rm -f "$_err_file" 2>/dev/null || true
        return 0
    fi

    if grep -qE "cannot lock ref ['\"]?HEAD" "$_err_file" 2>/dev/null; then
        _head_after="$(git rev-parse HEAD 2>/dev/null)"
        if declare -F yellow >/dev/null 2>&1; then
            yellow "INFRA-8202: HEAD moved during the auto-commit (${_head_before} -> ${_head_after}); re-staging and retrying once"
        else
            printf 'INFRA-8202: HEAD moved during the auto-commit (%s -> %s); re-staging and retrying once\n' \
                "$_head_before" "$_head_after"
        fi
        rm -f "$_err_file" 2>/dev/null || true
        if [[ -n "$restage_paths" ]]; then
            # shellcheck disable=SC2086 — intentional word-splitting, mirrors
            # the existing `git add $modified` call sites in this script.
            git add $restage_paths
        fi
        git commit -m "$msg"
        return $?
    fi

    rm -f "$_err_file" 2>/dev/null || true
    return "$_rc"
}

# _bm_resolve_lease_file [lock-dir]
#   Echoes the path to the current session's lease file: prefer
#   <lock-dir>/<CHUMP_SESSION_ID>.json, else the first lease in <lock-dir>
#   whose gap_id matches GAP_IDS[0]/GAP_ID. Empty output means "no lease
#   found" (e.g. an interactive run with no dispatch lease).
_bm_resolve_lease_file() {
    local dir="${1:-${LOCK_DIR:-${REPO_ROOT:-.}/.chump-locks}}"
    if [[ -n "${CHUMP_SESSION_ID:-}" && -f "${dir}/${CHUMP_SESSION_ID}.json" ]]; then
        printf '%s\n' "${dir}/${CHUMP_SESSION_ID}.json"
        return 0
    fi
    local want_gap="${GAP_IDS[0]:-${GAP_ID:-}}"
    [[ -z "$want_gap" ]] && return 0
    declare -F lease_iter >/dev/null 2>&1 || return 0
    local f
    for f in $(lease_iter --repo "${REPO_ROOT:-.}" 2>/dev/null); do
        [[ "$(lease_gap_id "$f" 2>/dev/null)" == "$want_gap" ]] && { printf '%s\n' "$f"; return 0; }
    done
    return 0
}

# _bm_lease_paths <lease-file>
#   Echoes the lease's declared `paths` array, one entry per line.
_bm_lease_paths() {
    local lease_file="$1"
    [[ -n "$lease_file" && -f "$lease_file" ]] || return 0
    python3 -c "
import json, sys
try:
    d = json.load(open('''$lease_file'''))
except Exception:
    sys.exit(0)
for p in (d.get('paths') or []):
    print(p)
" 2>/dev/null || true
}

# _bm_stray_staged_paths <lease-file> <staged-path-list>
#   Echoes any staged path (one per line) that is NOT covered by the
#   lease's declared paths (exact match, prefix with trailing slash, or a
#   `**` glob prefix). When the lease declares no paths, nothing is flagged
#   EXCEPT a staged deletion of docs/gaps/*.yaml, which is always stray
#   (the INFRA-8202 MISSION-111.yaml collateral-deletion class).
_bm_stray_staged_paths() {
    local lease_file="$1"; shift
    local staged="$*"
    local -a lease_paths=()
    local p
    while IFS= read -r p; do
        [[ -n "$p" ]] && lease_paths+=("$p")
    done < <(_bm_lease_paths "$lease_file")

    local -a stray=()
    local f
    for f in $staged; do
        if [[ "$f" == docs/gaps/*.yaml ]] \
            && git diff --cached --name-status -- "$f" 2>/dev/null | grep -q '^D'; then
            stray+=("$f")
            continue
        fi
        [[ ${#lease_paths[@]} -eq 0 ]] && continue
        local matched=0 lp
        for lp in "${lease_paths[@]}"; do
            if [[ "$f" == "$lp" ]]; then matched=1; break; fi
            case "$lp" in
                */) [[ "$f" == "$lp"* ]] && { matched=1; break; } ;;
                *'**') local prefix="${lp%\*\*}"; [[ "$f" == "$prefix"* ]] && { matched=1; break; } ;;
            esac
        done
        [[ "$matched" -eq 0 ]] && stray+=("$f")
    done

    [[ ${#stray[@]} -gt 0 ]] && printf '%s\n' "${stray[@]}"
    return 0
}
