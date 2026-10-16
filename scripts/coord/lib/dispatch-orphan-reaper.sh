#!/usr/bin/env bash
# scripts/coord/lib/dispatch-orphan-reaper.sh — INFRA-8198
#
# `reap_dispatch_orphans` — sweeps for `claude -p` processes whose
# `chump dispatch` parent is gone (PPID 1, or a parent that is neither
# `chump dispatch` nor the worker loop) and whose cwd sits under a
# `.claude/worktrees/` dispatch worktree. This is the farmer-side backstop
# for the INFRA-8198 bug class: a dispatch process that exits (cleanly or
# abnormally) while its headless work child keeps running unsupervised past
# the subagent budget, with no lease, no ship phase, nothing watching it.
#
# AC1/AC2 (src/dispatch.rs) close the mechanism going forward (process
# group + PDEATHSIG + loud exit). This reaper is the sweep for anything
# that slipped through before that fix landed, or on a platform/path where
# PDEATHSIG doesn't apply.
#
# Sourced by scripts/coord/farmer.sh; split into its own file (not inlined)
# so scripts/ci/test-farmer-dispatch-orphan-reaper.sh can exercise the
# function directly against a fake process, without running a full farmer
# tick.
#
# Env:
#   CHUMP_DISPATCH_ORPHAN_REAP=0       — disable entirely (default: enabled)
#   CHUMP_DISPATCH_ORPHAN_DRY_RUN=1    — log what would be killed, don't kill
#   CHUMP_DISPATCH_ORPHAN_MIN_AGE_S=N  — min process age before reaping
#                                        (default 2100 = 1800s budget + 5min)
#   CHUMP_DISPATCH_ORPHAN_GRACE_S=N    — SIGTERM→SIGKILL grace window
#                                        (default 30; test-only override)

# scanner-anchor: "kind":"dispatch_orphan_reaped"

# Fallback `emit`/`log` so this file is independently sourceable by the test
# runner without pulling in all of farmer.sh's state.
if ! declare -f emit >/dev/null 2>&1; then
    emit() {
        local kind="$1"
        shift
        local extra="${1:-}"
        local ts
        ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        local line
        if [[ -n "$extra" ]]; then
            line="{\"ts\":\"$ts\",\"kind\":\"${kind}\",${extra}}"
        else
            line="{\"ts\":\"$ts\",\"kind\":\"${kind}\"}"
        fi
        printf '%s\n' "$line" >> "${AMBIENT:-${LOCK_DIR:-.chump-locks}/ambient.jsonl}" 2>/dev/null || true
    }
fi
if ! declare -f log >/dev/null 2>&1; then
    log() { printf '[dispatch-orphan-reaper %s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
fi

# Returns the gap slug this pid's cwd suggests, e.g.
# `.claude/worktrees/infra-9996` → `infra-9996`. Empty string if the cwd
# doesn't match the dispatch worktree convention.
_dispatch_orphan_gap_slug_for_pid() {
    local pid="$1"
    local cwd=""
    if [[ -r "/proc/$pid/cwd" ]]; then
        cwd="$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)"
    fi
    [[ -n "$cwd" ]] || return 1
    case "$cwd" in
        */.claude/worktrees/*)
            printf '%s\n' "${cwd##*/.claude/worktrees/}"
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

reap_dispatch_orphans() {
    [[ "${CHUMP_DISPATCH_ORPHAN_REAP:-1}" != "0" ]] || return 0

    local min_age="${CHUMP_DISPATCH_ORPHAN_MIN_AGE_S:-2100}"
    local dry_run="${CHUMP_DISPATCH_ORPHAN_DRY_RUN:-0}"

    local pid gap_slug parent_pid parent_cmd age_s
    while IFS= read -r pid; do
        [[ -n "$pid" ]] || continue

        gap_slug="$(_dispatch_orphan_gap_slug_for_pid "$pid")" || continue

        parent_pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
        [[ -n "$parent_pid" ]] || continue
        parent_cmd=""
        if [[ "$parent_pid" != "1" ]]; then
            parent_cmd="$(ps -o args= -p "$parent_pid" 2>/dev/null || true)"
            case "$parent_cmd" in
                *"chump dispatch"*|*worker.sh*)
                    continue # supervised — a live dispatch/worker still owns it
                    ;;
            esac
        fi

        age_s="$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')"
        [[ -n "$age_s" ]] || continue
        (( age_s >= min_age )) || continue

        log "orphan claude -p pid=$pid gap=$gap_slug age_s=$age_s parent_pid=$parent_pid — chump dispatch parent is gone"

        if [[ "$dry_run" == "1" ]]; then
            log "DRY-RUN: would reap pid=$pid"
            continue
        fi

        kill -TERM "$pid" 2>/dev/null || true
        sleep "${CHUMP_DISPATCH_ORPHAN_GRACE_S:-30}"
        if kill -0 "$pid" 2>/dev/null; then
            kill -KILL "$pid" 2>/dev/null || true
        fi

        emit "dispatch_orphan_reaped" "\"gap_id\":\"$gap_slug\",\"pid\":$pid,\"age_s\":$age_s,\"note\":\"INFRA-8198: claude -p whose chump dispatch parent is gone\""
    done < <(pgrep -f '^claude -p' 2>/dev/null || true)
}
