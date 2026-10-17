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

# ── RESILIENT-1610: crate-/src-aware stray classification + overflow preserve ──
#
# The INFRA-8202 guard above treated the dispatch `--paths` list as a hard
# commit fence and aborted (exit 4) on ANY staged path outside it — which lost
# finished work in three Rust dispatches (receipt: a lease on
# crates/chump-gap-store whose diff also touched src/main.rs got refused). The
# functions below replace the all-or-nothing refusal with a classification:
#   - a path outside the lease is ALLOWED (committed with the in-scope work)
#     when it sits in the same crate (crates/<name>/) or the src/ tree as a
#     leased path, OR when no OTHER live lease claims it;
#   - only a REAL collision (a docs/gaps/*.yaml deletion, or a path some other
#     live lease owns) is pulled out, preserved on refs/stash/<gap-id>, and
#     reported via kind=dispatch_paths_overflow.

# _bm_path_crate <path>
#   Echoes `crates/<name>` when <path> is under a crate, else nothing.
_bm_path_crate() {
    local p="$1"
    [[ "$p" == crates/* ]] || return 0
    local rest="${p#crates/}"
    local name="${rest%%/*}"
    [[ -n "$name" ]] && printf 'crates/%s\n' "$name"
    return 0
}

# _bm_path_covered_by <path> <newline-separated coverage list>
#   0 iff <path> is covered by any entry (exact match, trailing-slash prefix,
#   `**` glob prefix, or a bare directory prefix like "scripts/ci").
_bm_path_covered_by() {
    local f="$1" list="$2" lp
    local -a arr=()
    while IFS= read -r lp; do [[ -n "$lp" ]] && arr+=("$lp"); done <<< "$list"
    [[ ${#arr[@]} -eq 0 ]] && return 1
    for lp in "${arr[@]}"; do
        [[ "$f" == "$lp" ]] && return 0
        case "$lp" in
            */) [[ "$f" == "$lp"* ]] && return 0 ;;
            *'**') local prefix="${lp%\*\*}"; [[ "$f" == "$prefix"* ]] && return 0 ;;
            *) [[ "$f" == "$lp"/* ]] && return 0 ;;
        esac
    done
    return 1
}

# _bm_iso_to_epoch <iso8601>
#   Echoes a unix epoch for an ISO-8601 timestamp (GNU `date -d` then BSD
#   `date -j`). Non-zero + no output when unparseable/empty.
_bm_iso_to_epoch() {
    local iso="$1" e
    [[ -z "$iso" ]] && return 1
    if e="$(date -u -d "$iso" +%s 2>/dev/null)"; then printf '%s\n' "$e"; return 0; fi
    if e="$(date -u -j -f '%Y-%m-%dT%H:%M:%S' "${iso%Z}" +%s 2>/dev/null)"; then printf '%s\n' "$e"; return 0; fi
    return 1
}

# _bm_lease_is_live <lease-file>
#   0 iff the lease's expires_at is in the future. A missing/unparseable
#   expiry is treated as live (conservative: better to flag a collision and
#   preserve the work than silently commit over another agent's claim).
_bm_lease_is_live() {
    local lf="$1"
    [[ -f "$lf" ]] || return 1
    local exp
    if declare -F lease_field >/dev/null 2>&1; then
        exp="$(lease_field "$lf" expires_at 2>/dev/null)"
    else
        exp="$(grep -oE '"expires_at"[[:space:]]*:[[:space:]]*"[^"]*"' "$lf" 2>/dev/null \
            | head -1 | sed -E 's/.*"expires_at"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')"
    fi
    [[ -z "$exp" ]] && return 0
    local exp_e now
    exp_e="$(_bm_iso_to_epoch "$exp")" || return 0
    now="$(date -u +%s)"
    [[ "$exp_e" -gt "$now" ]]
}

# _bm_other_lease_claims <path> <our-lease-file> [lock-dir]
#   0 iff some OTHER live lease file in <lock-dir> declares a path that covers
#   <path>. Our own lease file (matched by basename) is skipped.
_bm_other_lease_claims() {
    local f="$1" our_lease="$2"
    local dir="${3:-${LOCK_DIR:-${REPO_ROOT:-.}/.chump-locks}}"
    [[ -d "$dir" ]] || return 1
    local our_base=""
    [[ -n "$our_lease" ]] && our_base="$(basename "$our_lease")"
    local lf
    for lf in "$dir"/*.json; do
        [[ -f "$lf" ]] || continue
        [[ -n "$our_base" && "$(basename "$lf")" == "$our_base" ]] && continue
        _bm_lease_is_live "$lf" || continue
        if _bm_path_covered_by "$f" "$(_bm_lease_paths "$lf")"; then
            return 0
        fi
    done
    return 1
}

# _bm_collision_staged_paths <lease-file> <gap-id> <staged-path-list>
#   Echoes the subset of staged paths (one per line) that are REAL collisions:
#   outside OUR lease AND either a docs/gaps/*.yaml deletion or claimed by
#   another live lease, and NOT rescued by the same-crate / same-src-tree
#   allowances. Everything else (in-lease, or allowed-outside) is committed.
_bm_collision_staged_paths() {
    local lease_file="$1"; shift
    local _gap_id="$1"; shift   # reserved for future per-gap policy; unused today
    local staged="$*"
    local our_paths; our_paths="$(_bm_lease_paths "$lease_file")"

    local our_crates="" has_src_lease=0 lp c
    while IFS= read -r lp; do
        [[ -z "$lp" ]] && continue
        c="$(_bm_path_crate "$lp")"
        [[ -n "$c" ]] && our_crates+="${c}"$'\n'
        [[ "$lp" == src/* || "$lp" == src ]] && has_src_lease=1
    done <<< "$our_paths"

    local -a collisions=()
    local f fc
    for f in $staged; do
        # In our lease → always fine.
        _bm_path_covered_by "$f" "$our_paths" && continue
        # docs/gaps/*.yaml deletion is always a collision (MISSION-111 class).
        if [[ "$f" == docs/gaps/*.yaml ]] \
            && git diff --cached --name-status -- "$f" 2>/dev/null | grep -q '^D'; then
            collisions+=("$f"); continue
        fi
        # Same-crate allowance. (Herestring, not printf|grep -q, to dodge the
        # INFRA-1658 pipefail race.)
        fc="$(_bm_path_crate "$f")"
        if [[ -n "$fc" ]] && grep -qxF "$fc" <<< "$our_crates"; then
            continue
        fi
        # Same src/ tree allowance.
        if [[ "$has_src_lease" -eq 1 && ( "$f" == src/* || "$f" == src ) ]]; then
            continue
        fi
        # Outside lease + not same crate/src: collision iff another live lease owns it.
        if _bm_other_lease_claims "$f" "$lease_file"; then
            collisions+=("$f")
        fi
    done
    [[ ${#collisions[@]} -gt 0 ]] && printf '%s\n' "${collisions[@]}"
    return 0
}

# _bm_emit_dispatch_paths_overflow <gap-id> <collision-paths-newline> [stash-sha]
#   Appends a kind=dispatch_paths_overflow ambient event naming the preserved
#   paths + the recovery ref. The literal "kind":"dispatch_paths_overflow"
#   lives here so the event-registry emit-site scanner can anchor on it.
_bm_emit_dispatch_paths_overflow() {
    local gap_id="$1" collisions="$2" stash_sha="${3:-}"
    local list; list="$(printf '%s' "$collisions" | tr '\n' ' ' | sed 's/ *$//')"
    local ambient="${CHUMP_AMBIENT_LOG:-${REPO_ROOT:-.}/.chump-locks/ambient.jsonl}"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","kind":"dispatch_paths_overflow","gap_id":"%s","preserved_ref":"refs/stash/%s","stash_sha":"%s","paths":"%s"}\n' \
        "$ts" "$gap_id" "$gap_id" "$stash_sha" "${list//\"/}" \
        >> "$ambient" 2>/dev/null || true
}

# _bm_preserve_and_drop_collisions <gap-id> <collision-paths-newline>
#   Preserves the current dirty state (incl. the collision paths) on
#   refs/stash/<gap-id> via a temp commit object (`git stash create` +
#   `git update-ref` — no HEAD move, no hooks), then drops the collision
#   paths from the index + worktree so the in-scope auto-commit excludes
#   them, and emits kind=dispatch_paths_overflow.
_bm_preserve_and_drop_collisions() {
    local gap_id="$1"; shift
    local collisions="$*"
    local stash_sha
    stash_sha="$(git stash create "bot-merge path-overflow preserve ${gap_id}" 2>/dev/null || true)"
    if [[ -n "$stash_sha" ]]; then
        git update-ref "refs/stash/${gap_id}" "$stash_sha" 2>/dev/null \
            || git update-ref "refs/bot-merge-overflow/${gap_id}" "$stash_sha" 2>/dev/null || true
    fi
    local p
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        git reset -q HEAD -- "$p" 2>/dev/null || true
        git checkout -q HEAD -- "$p" 2>/dev/null || true
    done <<< "$collisions"
    if declare -F yellow >/dev/null 2>&1; then
        yellow "RESILIENT-1610: staged paths collided with another live lease — preserved on refs/stash/${gap_id}, kept out of this commit: $(printf '%s' "$collisions" | tr '\n' ' ')"
    fi
    _bm_emit_dispatch_paths_overflow "$gap_id" "$collisions" "$stash_sha"
}
