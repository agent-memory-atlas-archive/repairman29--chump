#!/usr/bin/env bash
# cargo-target-reaper.sh — INFRA-1250 + INFRA-1170 + INFRA-2125 + INFRA-2181
# Reclaim stale cargo build artifacts (60GB+ unbounded growth).
#
# Usage:
#   bash scripts/ops/cargo-target-reaper.sh [--execute] [--fingerprint-age-d N] [--fleet-age-d N]
#   bash scripts/ops/cargo-target-reaper.sh --event-listen [--execute]
#
# By default: dry-run only, EXCEPT under disk pressure (>= CHUMP_REAPER_AUTO_EXECUTE_PCT
# used, default 80) where it auto-escalates to --execute (RESILIENT-1590); --dry-run forces dry.
#
# --event-listen (INFRA-2181): tail-poll ambient.jsonl for kind=integration_cycle_shipped
#   at 30s cadence; fire a full reap (--execute if passed) within 60s of each event.
#   Keeps running indefinitely as a daemon. Exits 0 on SIGTERM/SIGINT.
#   Falls through to a one-shot run if the ambient log is unavailable (fail-open).
#
# Reaps:
#   (a) target/debug/.fingerprint/*        mtime > FINGERPRINT_AGE_D days
#   (b) target/debug/deps/lib*.rlib        mtime > FINGERPRINT_AGE_D days
#   (c) ~/.cache/chump-fleet-target/<dir>/ mtime > FLEET_AGE_D days AND
#       no live process has CARGO_TARGET_DIR pointing at <dir>
#   (d) INFRA-1170: /tmp/chump-*/target/   where originating git worktree no
#       longer exists in `git worktree list --porcelain` (orphaned target dirs)
#   (e) INFRA-2125/A: /tmp/chump-coord-linux-build* + /tmp/chump-cross-build-*
#       (Linux cross-build artifacts from scripts/dev/cross-build-linux.sh)
#   (f) INFRA-2125/B: /tmp/chump-*/.cargo-test-target/
#       (hidden cargo target dirs from Sonnet workers using custom CARGO_TARGET_DIR)
#   (g) INFRA-2125/C: /tmp/chump-*/target/ in worktrees with ACTIVE lease but
#       whose PR is open + auto-merge armed + local HEAD matches remote tip
#       (work is safely on origin; rebuild cost is bounded)
#   (h) INFRA-2188: ~/.cache/chump-runner/cargo-target/{debug,release}/
#       .fingerprint/* AND deps/lib*.rlib by FLEET_AGE_D mtime. Filed because
#       the self-hosted runner accumulates 40-60GB here unbounded — it never
#       runs as a worktree so (c)/(d) miss it. Safety guard: skip the
#       sub-target dir if any chump-* binary mtime <24h ago (worker is hot).
#   (j) RESILIENT-1620 + RESILIENT-1635: Class D — dispatch worktrees under the
#       repo's .claude/worktrees. Reaps target/ + .cargo-test-target/ (build
#       output only, source + branch untouched) when the worktree is lease-less,
#       has no process cwd inside, and no live bot-merge AND either (a) its PR is
#       merged/closed (RESILIENT-1620), or (b) RESILIENT-1635: its PR is still
#       OPEN but the worktree is IDLE — no running chump dispatch for its gap, a
#       clean source tree, and no bot-merge/dispatch activity within the 2h
#       window. Also removes stale bot-merge-active-dispatch-*.path markers
#       older than the RESILIENT-1609 grace whose bot-merge PID is dead.
#       Fail-closed guards (RESILIENT-1635 review): the whole tick is skipped
#       unless it holds the node build lane lock (flock -n) and passes
#       `chump admit cargo`; a symlinked worktree entry or build dir, or one
#       resolving outside the scanned base, is kept; a process with
#       CARGO_TARGET_DIR inside the worktree (as spelled or resolved) or an
#       open file under its build dirs keeps it; on Linux a pid whose /proc
#       environ/cwd/fd is unreadable is judged by its cmdline (names the
#       worktree, or is a same-uid cargo/rustc/nextest/rustdoc/clippy/sccache/
#       bot-merge.sh: busy); an unknown/no-PR state, an unparseable cache row or failing gh
#       is NOT open; an open-PR worktree with no derivable gap id is kept. The
#       lane lock path is fixed at $HOME/.chump/architect-lane.lock (no env
#       override; tests use a sandbox HOME).
#       SAME-UID ONLY: the reaper sees the cwd, environment and open files of
#       processes running as its own uid (on Linux, only the dumpable ones; a
#       non-dumpable or other-uid pid is judged by its cmdline alone). Run it
#       as the uid that owns the worktrees and their builds; a build run by
#       another uid that never names the worktree in its argv is not seen.
#
# Disk-pressure escalation (INFRA-2188):
#   CHUMP_DISK_CRITICAL_GB (default 20) — when df reports free < N GB on
#   $HOME, FINGERPRINT_AGE_D is forced to 1 and FLEET_AGE_D to 2 for this
#   run. Emits kind=cargo_reaper_aggressive_mode_engaged on entry.
#
# NOT covered here (PRODUCT-256): ~/.cargo/chump-shared-target — the
# CARGO_TARGET_DIR every worker/worktree/CI run actually builds into
# (scripts/dispatch/worker.sh, scripts/dispatch/run-fleet.sh). It grows
# unbounded (156G observed 2026-08-09) and none of classes (a)-(h) above
# reach it. Coverage lives in a separate, purpose-built script:
# scripts/coord/shared-target-cache-reaper.sh (RESILIENT-1045, cap-based,
# invoked unconditionally at the top of scripts/coord/disk-pressure-reaper.sh
# on every tick regardless of tier). Don't assume this script's silence on
# chump-shared-target means it's uncovered fleet-wide — check that script
# first.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-${REAPER_REPO_ROOT:-$REPO_ROOT}/.chump-locks/ambient.jsonl}"
_reaped_count=0
_target_paths_scanned=0
_reaper_error_msg=""

# RESILIENT-130: emit kind=cargo_target_reaper_run on every run (including early
# non-zero exit) so launchd / systemd failures are never silent in ambient.jsonl.
# scanner-anchor: "kind":"cargo_target_reaper_run"
_emit_cargo_target_reaper_run() {
    local rc=$?
    local amb="${AMBIENT_LOG:-${REAPER_REPO_ROOT:-$REPO_ROOT}/.chump-locks/ambient.jsonl}"
    mkdir -p "$(dirname "$amb")" 2>/dev/null || true
    local err="${_reaper_error_msg:-}"
    if [[ $rc -ne 0 && -z "$err" ]]; then
        err="exited with rc=$rc"
    fi
    err="${err//\\/\\\\}"
    err="${err//\"/\\\"}"
    printf '{"ts":"%s","kind":"cargo_target_reaper_run","rc":%d,"target_paths_scanned":%d,"paths_reaped":%d,"error_msg":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc" "${_target_paths_scanned:-0}" "${_reaped_count:-0}" "$err" \
        >> "$amb" 2>/dev/null || true
}
trap _emit_cargo_target_reaper_run EXIT

EXECUTE=0
EVENT_LISTEN=0
# RESILIENT-1620: Class D — lease-less dispatch worktrees under the repo's
# .claude/worktrees whose PR merged/closed. --class-d-only runs ONLY Class D,
# bypassing the global cargo-process / low-disk guards (Class D is build-safe
# per-worktree: it checks live lease, process cwd inside, live bot-merge, and
# cargo lock before touching any worktree). Used by disk-health-monitor's
# alert→action trigger and the Class-D CI test.
CLASS_D_ONLY=0
# RESILIENT-1635: a dispatch worktree whose PR is still OPEN is "idle" (its build
# output is reapable) only when no bot-merge/dispatch activity has touched it
# within this window. Fixed at 120 min per the gap ("no bot-merge or dispatch
# activity in the last 2h"); not an env knob (no bypass var).
CLASSD_IDLE_WINDOW_MIN=120
FINGERPRINT_AGE_D="${CHUMP_CARGO_REAPER_FINGERPRINT_AGE_D:-14}"
FLEET_AGE_D="${CHUMP_CARGO_REAPER_FLEET_AGE_D:-7}"
MIN_FREE_GB=1
# INFRA-2188: when free disk drops below DISK_CRITICAL_GB on $HOME, the reaper
# escalates: FINGERPRINT_AGE_D→1 and FLEET_AGE_D→2 for this run.
DISK_CRITICAL_GB="${CHUMP_DISK_CRITICAL_GB:-20}"
# INFRA-2188: ~/.cache/chump-runner/cargo-target/{debug,release}. Override for
# tests via CHUMP_CARGO_REAPER_RUNNER_CACHE.
RUNNER_CACHE_BASE="${CHUMP_CARGO_REAPER_RUNNER_CACHE:-${HOME}/.cache/chump-runner/cargo-target}"
RUNNER_HOT_BIN_AGE_H="${CHUMP_CARGO_REAPER_RUNNER_HOT_AGE_H:-24}"

# INFRA-1211: shared worktree scanning + github cache libs
# shellcheck source=scripts/lib/worktree-iter.sh
if [[ -f "$(dirname "$0")/../lib/worktree-iter.sh" ]]; then
    source "$(dirname "$0")/../lib/worktree-iter.sh"
fi
# shellcheck source=scripts/coord/lib/github_cache.sh
if [[ -f "$(dirname "$0")/../coord/lib/github_cache.sh" ]]; then
    source "$(dirname "$0")/../coord/lib/github_cache.sh"
fi
# RESILIENT-1620: chump_gh (throttled + criticality-aware gh wrapper, INFRA-1080)
# for the Class D cache-miss fallback. Degrade to plain gh if the lib is absent.
# shellcheck source=scripts/coord/lib/github.sh
if [[ -f "$(dirname "$0")/../coord/lib/github.sh" ]]; then
    source "$(dirname "$0")/../coord/lib/github.sh" 2>/dev/null || true
fi
command -v chump_gh >/dev/null 2>&1 || chump_gh() { gh "$@"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --execute)            EXECUTE=1 ;;
        --dry-run)            FORCE_DRY=1 ;;
        --event-listen)       EVENT_LISTEN=1 ;;
        --class-d-only)       CLASS_D_ONLY=1 ;;
        --fingerprint-age-d)  FINGERPRINT_AGE_D="$2"; shift ;;
        --fleet-age-d)        FLEET_AGE_D="$2"; shift ;;
        --help|-h)
            sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# //'
            exit 0
            ;;
        *) echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
    shift
done

# RESILIENT-1590: a dry-run reaper under disk pressure is a no-op that looks alive.
# Escalate to --execute when $HOME's filesystem is >= CHUMP_REAPER_AUTO_EXECUTE_PCT
# used (default 80) unless --dry-run was passed explicitly.
if [[ $EXECUTE -eq 0 && "${FORCE_DRY:-0}" -eq 0 ]]; then
    _used_pct="$(df -P "$HOME" 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')"
    if [[ "${_used_pct:-0}" =~ ^[0-9]+$ ]] && (( _used_pct >= ${CHUMP_REAPER_AUTO_EXECUTE_PCT:-80} )); then
        EXECUTE=1
        echo "[cargo-target-reaper] disk ${_used_pct}% >= ${CHUMP_REAPER_AUTO_EXECUTE_PCT:-80}% — auto-escalating to --execute"
    fi
fi

# ── (j) RESILIENT-1620: Class D — merged/closed dispatch worktree build dirs ─
# A worktree under the repo's .claude/worktrees with:
#   - NO live lease (wt_has_active_lease, state.db + .chump-locks)
#   - NO process cwd inside it
#   - NO live bot-merge ship (wt_has_live_bot_merge)
#   - and whose branch's PR is MERGED or CLOSED (cache-first, gh fallback)
# gets ONLY target/ and .cargo-test-target/ removed — never the source tree.
# This is the state chump dispatch leaves after a ship: active-target-reaper
# keeps the worktree and only reaps target/ once it has gone quiet (mtime >1d),
# so a just-merged worktree's fresh target/ lives for a full day and filled the
# disk to 99% (receipt 2026-10-17 22:47Z). Class D reaps it on PR-merge,
# regardless of mtime, because the work is already on origin.

# _classd_under <path> <base>... — 0 iff <path> equals one of the <base>s or
# lies under it (lexical; a trailing slash on <path> is ignored).
_classd_under() {
    local p="${1%/}" b
    shift
    for b in "$@"; do
        [[ -n "$b" ]] || continue
        b="${b%/}"
        if [[ "$p" == "$b" || "$p" == "$b"/* ]]; then
            return 0
        fi
    done
    return 1
}

# _classd_glob_escape <s> — escape fnmatch metacharacters so a path can be used
# literally inside a find -lname pattern.
_classd_glob_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\*/\\*}"
    s="${s//\?/\\?}"
    s="${s//\[/\\[}"
    printf '%s' "$s"
}

# _classd_cwd_inside <wt_real> [<wt_alt>] — return 0 iff a live process other
# than this one has its cwd at or under <wt_real> (or <wt_alt>, the unresolved
# spelling). Callers pass the pwd -P path (RESILIENT-1635: the unresolved path
# missed a cwd reported in resolved form). /proc on Linux; on macOS one
# `lsof -d cwd` listing of every process. Fails closed: with neither available
# it reports busy.
_classd_cwd_inside() {
    local wt="$1" alt="${2:-}" c link pid line out
    if [[ -d /proc/self ]]; then
        for c in /proc/[0-9]*/cwd; do
            pid="${c#/proc/}"; pid="${pid%/cwd}"
            [[ "$pid" == "$$" ]] && continue
            link="$(readlink "$c" 2>/dev/null || true)"
            [[ -z "$link" ]] && continue
            _classd_under "$link" "$wt" "$alt" && return 0
        done
        return 1
    fi
    command -v lsof >/dev/null 2>&1 || return 0
    out="$(lsof -a -d cwd -n -P -Fpn 2>/dev/null || true)"
    pid=""
    while IFS= read -r line; do
        case "$line" in
            p*) pid="${line#p}" ;;
            n*)
                [[ "$pid" == "$$" ]] && continue
                _classd_under "${line#n}" "$wt" "$alt" && return 0
                ;;
        esac
    done <<< "$out"
    return 1
}

# _classd_resolve_path <abs_path> — RESILIENT-1635: echo <abs_path> with its
# longest EXISTING prefix resolved through symlinks (cd -P) and the missing
# tail appended unchanged. A CARGO_TARGET_DIR that does not exist yet (the
# build is about to create it) still resolves through a symlinked parent, so an
# alias spelling cannot hide a build aimed inside the worktree. Returns 1 when
# no prefix resolves.
_classd_resolve_path() {
    local p="${1%/}" head rest="" r
    [[ -n "$p" ]] || return 1
    head="$p"
    while [[ -n "$head" && "$head" != "/" && ! -d "$head" ]]; do
        rest="/$(basename "$head")${rest}"
        head="$(dirname "$head")"
    done
    [[ -n "$head" ]] || head="/"
    r="$(cd -P "$head" 2>/dev/null && pwd -P || true)"
    [[ -n "$r" ]] || return 1
    printf '%s%s' "${r%/}" "$rest"
}

# _classd_normalize_path <abs_path> — RESILIENT-1635: echo <abs_path> with
# empty and "." components dropped and each ".." popping the component before
# it (lexical, no filesystem access; ".." at the root stays at the root). cargo
# creates a CARGO_TARGET_DIR such as <x>/not-yet/../<wt>/target with
# create_dir_all, so the build lands in <x>/<wt>/target even though no prefix
# past <x> exists for cd -P to resolve.
_classd_normalize_path() {
    local p="$1" c out=""
    local -a parts=() stack=()
    IFS='/' read -r -a parts <<< "$p"
    for c in "${parts[@]+"${parts[@]}"}"; do
        case "$c" in
            ''|.) ;;
            ..) [[ ${#stack[@]} -gt 0 ]] && stack=("${stack[@]:0:${#stack[@]}-1}") ;;
            *) stack+=("$c") ;;
        esac
    done
    for c in "${stack[@]+"${stack[@]}"}"; do out+="/${c}"; done
    printf '%s' "${out:-/}"
}

# _classd_ctd_value_busy <value> <cwd> <wt_real> [<wt_alt>] — 0 iff one
# CARGO_TARGET_DIR value lands at or under the worktree, compared as spelled,
# as resolved, and with ".." normalized (then resolved again); a relative value
# is taken against <cwd>, when known. Any one match is busy.
_classd_ctd_value_busy() {
    local v="$1" cwd="$2" wt="$3" alt="${4:-}" r n
    [[ -n "$v" ]] || return 1
    if [[ "$v" != /* ]]; then
        [[ -n "$cwd" ]] || return 1
        v="${cwd%/}/${v}"
    fi
    _classd_under "$v" "$wt" "$alt" && return 0
    r="$(_classd_resolve_path "$v" || true)"
    [[ -n "$r" ]] && _classd_under "$r" "$wt" "$alt" && return 0
    n="$(_classd_normalize_path "$v")"
    _classd_under "$n" "$wt" "$alt" && return 0
    r="$(_classd_resolve_path "$n" || true)"
    [[ -n "$r" ]] && _classd_under "$r" "$wt" "$alt" && return 0
    return 1
}

# _classd_target_dir_env_busy <wt_real> [<wt_alt>] — RESILIENT-1635: 0 iff a
# live process has CARGO_TARGET_DIR at or under the worktree. The pre-push test
# gate runs nextest with CARGO_TARGET_DIR=<wt>/.cargo-test-target and its cwd
# ELSEWHERE, so the cwd check alone reaped a live test build. Linux reads
# /proc/<pid>/environ (a relative value resolves against that process's cwd);
# macOS reads `ps -wwE` (the environment of the user's own non-platform
# processes, which is what cargo/rustc/nextest are). Both compare the value as
# spelled AND resolved (longest existing prefix, cd -P). A pid whose environ
# cannot be read is judged by _classd_blind_pid_busy. Fails closed with neither.
_classd_target_dir_env_busy() {
    local wt="$1" alt="${2:-}" e pid kv v line out rest cwd
    if [[ -d /proc/self ]]; then
        for e in /proc/[0-9]*/environ; do
            pid="${e#/proc/}"; pid="${pid%/environ}"
            [[ "$pid" == "$$" ]] && continue
            [[ -r "$e" ]] || continue
            # The < redirection sits inside the guarded group, so an environ
            # that turns unreadable between the -r test and the open (or a pid
            # that exits) prints nothing on stderr.
            {
                while IFS= read -r -d '' kv; do
                    [[ "$kv" == CARGO_TARGET_DIR=* ]] || continue
                    v="${kv#CARGO_TARGET_DIR=}"
                    cwd=""
                    [[ "$v" == /* ]] || cwd="$(readlink "/proc/${pid}/cwd" 2>/dev/null || true)"
                    _classd_ctd_value_busy "$v" "$cwd" "$wt" "$alt" && return 0
                done < "$e"
            } 2>/dev/null || true
        done
        return 1
    fi
    command -v ps >/dev/null 2>&1 || return 0
    out="$(ps -A -wwE -o pid=,command= 2>/dev/null || true)"
    [[ -n "$out" ]] || return 0
    while IFS= read -r line; do
        [[ "$line" == *CARGO_TARGET_DIR=* ]] || continue
        line="${line#"${line%%[![:space:]]*}"}"
        pid="${line%% *}"
        [[ "$pid" == "$$" ]] && continue
        rest="${line#* }"
        # Lexical compare first (the value as spelled, no fork).
        for v in "$wt" "$alt"; do
            [[ -n "$v" ]] || continue
            v="${v%/}"
            if [[ "$rest" == *"CARGO_TARGET_DIR=${v} "* || "$rest" == *"CARGO_TARGET_DIR=${v}/"* \
                  || "$rest" == *"CARGO_TARGET_DIR=${v}" ]]; then
                return 0
            fi
        done
        # Then every CARGO_TARGET_DIR value on the line, resolved through
        # symlinks (an alias spelling of the worktree is the same build dir).
        while [[ "$rest" == *CARGO_TARGET_DIR=* ]]; do
            rest="${rest#*CARGO_TARGET_DIR=}"
            v="${rest%% *}"
            cwd=""
            if [[ -n "$v" && "$v" != /* ]] && command -v lsof >/dev/null 2>&1; then
                cwd="$(lsof -a -p "$pid" -d cwd -n -P -Fn 2>/dev/null | sed -n 's/^n//p' | head -1 || true)"
            fi
            _classd_ctd_value_busy "$v" "$cwd" "$wt" "$alt" && return 0
        done
    done <<< "$out"
    return 1
}

# _classd_names_path <string> <path> — RESILIENT-1635: 0 iff <string>
# contains <path> at an occurrence whose next character is the end of the
# string or NOT one of [A-Za-z0-9._-] (a path-name character). So
# "--manifest-path=<wt>/Cargo.toml", "<wt>;", "<wt>:", "'<wt>'", "<wt>=" all
# name <wt>, while "<wt>-old" and "<wt>2" do not. Every occurrence is tried.
_classd_names_path() {
    local s="$1" w="$2" rest nxt
    [[ -n "$w" ]] || return 1
    rest="$s"
    while [[ "$rest" == *"$w"* ]]; do
        rest="${rest#*"$w"}"
        [[ -n "$rest" ]] || return 0
        nxt="${rest:0:1}"
        case "$nxt" in
            [ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-]) ;;
            *) return 0 ;;
        esac
    done
    return 1
}

# _classd_blind_pid_busy <wt_real> [<wt_alt>] — RESILIENT-1635 (Linux only):
# the cwd, CARGO_TARGET_DIR and open-file checks read /proc/<pid>/cwd, environ
# and fd, which are unreadable for another uid's process AND for a same-uid
# non-dumpable one (prctl PR_SET_DUMPABLE 0, setuid helpers). Such a "blind"
# pid used to count as not busy. For every blind pid, fall back to the
# world-readable /proc/<pid>/cmdline: 0 (busy) iff an argument names the
# worktree (_classd_names_path: the worktree path not followed by a path-name
# character), or the process is a same-uid cargo / rustc / nextest /
# cargo-nextest / rustdoc / cargo-clippy / clippy-driver / sccache /
# bot-merge.sh (argv0 basename; bot-merge.sh anywhere in the first four
# arguments; uid from /proc/<pid>/status). A blind pid matching neither does NOT
# make the worktree busy (on cuphead 260 of 295 pids are blind; treating all of
# them as busy would mean Class D never runs). Each blind pid is recorded in
# CLASSD_BLIND_PIDS for the one per-tick summary line; the match is in
# CLASSD_BLIND_DETAIL. Returns 1 off Linux (no /proc).
CLASSD_BLIND_PIDS=" "
CLASSD_BLIND_DETAIL=""
_classd_blind_pid_busy() {
    local wt="$1" alt="${2:-}" p pid myuid a w k val _rest uid nm
    local -a args
    [[ -d /proc/self ]] || return 1
    myuid="$(id -u 2>/dev/null || echo -1)"
    for p in /proc/[0-9]*; do
        pid="${p#/proc/}"
        [[ "$pid" == "$$" ]] && continue
        # Readable on all three: the precise checks already judged this pid.
        if { : < "$p/environ"; } 2>/dev/null \
            && readlink "$p/cwd" >/dev/null 2>&1 \
            && [[ -r "$p/fd" && -x "$p/fd" ]]; then
            continue
        fi
        args=()
        {
            while IFS= read -r -d '' a || [[ -n "$a" ]]; do args+=("$a"); done < "$p/cmdline"
        } 2>/dev/null || true
        [[ ${#args[@]} -gt 0 ]] || continue   # exited, or a kernel thread
        [[ "$CLASSD_BLIND_PIDS" == *" $pid "* ]] || CLASSD_BLIND_PIDS+="$pid "
        for a in "${args[@]}"; do
            for w in "$wt" "$alt"; do
                [[ -n "$w" ]] || continue
                w="${w%/}"
                if _classd_names_path "$a" "$w"; then
                    CLASSD_BLIND_DETAIL="pid=${pid} cmdline names ${w}"
                    return 0
                fi
            done
        done
        nm="${args[0]%% *}"
        nm="${nm##*/}"
        case "$nm" in
            cargo|rustc|nextest|cargo-nextest|rustdoc|cargo-clippy|clippy-driver|sccache) ;;
            *) nm="" ;;
        esac
        if [[ -z "$nm" ]]; then
            for a in "${args[@]:0:4}"; do
                [[ " $a " =~ [[:space:]/]bot-merge\.sh[[:space:]] ]] && { nm="bot-merge.sh"; break; }
            done
        fi
        [[ -n "$nm" ]] || continue
        uid=""
        {
            while read -r k val _rest; do
                [[ "$k" == Uid: ]] && { uid="$val"; break; }
            done < "$p/status"
        } 2>/dev/null || true
        if [[ -n "$uid" && "$uid" == "$myuid" ]]; then
            CLASSD_BLIND_DETAIL="pid=${pid} same-uid ${nm}"
            return 0
        fi
    done
    return 1
}

# _classd_cargo_rustc_busy <wt_real> [<wt_alt>] — RESILIENT-1641: 0 iff a live
# cargo/rustc/nextest/clippy/rustdoc process runs against <wt_real> (or
# <wt_alt>) via its command-line arguments (e.g. --manifest-path or
# --target-dir), even when its cwd is elsewhere and CARGO_TARGET_DIR is unset.
CLASSD_CARGO_BUSY_DETAIL=""
_classd_cargo_rustc_busy() {
    local wt="$1" alt="${2:-}" out line pid rest cmd0 w
    command -v ps >/dev/null 2>&1 || return 0
    out="$(ps -A -ww -o pid=,command= 2>/dev/null || true)"
    [[ -n "$out" ]] || return 0
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -n "$line" ]] || continue
        pid="${line%% *}"
        [[ "$pid" == "$$" ]] && continue
        rest="${line#* }"
        cmd0="${rest%% *}"
        cmd0="${cmd0##*/}"
        case "$cmd0" in
            cargo|rustc|nextest|cargo-nextest|rustdoc|cargo-clippy|clippy-driver|sccache) ;;
            *) continue ;;
        esac
        for w in "$wt" "$alt"; do
            [[ -n "$w" ]] || continue
            w="${w%/}"
            if _classd_names_path "$rest" "$w"; then
                CLASSD_CARGO_BUSY_DETAIL="pid=${pid} cmd=${cmd0}"
                return 0
            fi
        done
    done <<< "$out"
    return 1
}

# _classd_build_files_open <dir>... — RESILIENT-1635: 0 iff a live process
# holds an open file at or under any existing <dir> (the build dirs). Linux
# scans /proc/<pid>/fd links with one find; macOS uses `lsof +D <dir>`. Fails
# closed when neither is available.
_classd_build_files_open() {
    local d hit esc
    local -a pats=()
    if [[ -d /proc/self ]]; then
        for d in "$@"; do
            [[ -e "$d" ]] || continue
            esc="$(_classd_glob_escape "${d%/}")"
            if [[ ${#pats[@]} -gt 0 ]]; then pats+=(-o); fi
            pats+=(-lname "$esc" -o -lname "${esc}/*")
        done
        [[ ${#pats[@]} -gt 0 ]] || return 1
        hit="$(find /proc/[0-9]*/fd -mindepth 1 -maxdepth 1 -type l \( "${pats[@]}" \) \
            -print -quit 2>/dev/null || true)"
        [[ -n "$hit" ]]
        return
    fi
    command -v lsof >/dev/null 2>&1 || return 0
    for d in "$@"; do
        [[ -d "$d" ]] || continue
        hit="$(lsof -n -P +D "$d" 2>/dev/null || true)"
        [[ -n "$hit" ]] && return 0
    done
    return 1
}

# _classd_pr_merged_or_closed <branch> — echo "yes" if the branch's PR is
# merged or closed, "no" if open, "" if unknown/no PR. Cache-first via
# cache_lookup_pr_state_by_branch (INFRA-8578), with REST fallback on miss.
_classd_pr_merged_or_closed() {
    local branch="$1"
    local out state
    if command -v cache_lookup_pr_state_by_branch >/dev/null 2>&1; then
        out="$(cache_lookup_pr_state_by_branch "$branch" 2>/dev/null || true)"
        if [[ -n "$out" && "$out" == *$'\t'* ]]; then
            state="${out#*$'\t'}"
            case "$state" in
                merged|closed) printf 'yes'; return 0 ;;
                open)          printf 'no';  return 0 ;;
                *)             printf '';    return 0 ;;
            esac
        fi
    fi
    printf ''
}

# ── RESILIENT-1635: open-PR idle-worktree guards ────────────────────────────
# A dispatch worktree whose PR is still OPEN is reapable (build output only)
# ONLY when it is IDLE. On top of the lease / cwd / live-bot-merge checks that
# run_class_d already applies to every candidate, "idle" requires all three:
#   1. no running `chump dispatch` / `--execute-gap` for the worktree's gap
#   2. a clean source tree (no tracked changes)   [Chief rule 2026-10-19 11:55Z]
#   3. no bot-merge/dispatch activity within CLASSD_IDLE_WINDOW_MIN (2h)

# _classd_gap_ids <wt> <branch> — RESILIENT-1635: echo the gap ids this
# worktree can belong to, one per line, uppercased: the leading [a-z]+-[0-9]+
# of the worktree basename and of the branch's last segment. So
# resilient-1828-fleet-1-<ts> maps to RESILIENT-1828 (the old whole-name
# compare matched nothing there and reaped a worktree under a live dispatch).
# Echoes nothing when neither yields a gap id; the caller then keeps the
# worktree (fail closed).
_classd_gap_ids() {
    local wt="$1" branch="$2" tok g seen=" "
    for tok in "$(basename "$wt")" "${branch##*/}"; do
        tok="$(printf '%s' "$tok" | tr '[:upper:]' '[:lower:]')"
        if [[ "$tok" =~ ^([a-z]+-[0-9]+) ]]; then
            g="$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:lower:]' '[:upper:]')"
            if [[ "$seen" != *" $g "* ]]; then
                seen+="$g "
                printf '%s\n' "$g"
            fi
        fi
    done
}

# _classd_dispatch_running <gap_id>... — 0 iff a live `chump dispatch` /
# `--execute-gap` process names one of the gap ids. The match is whole-token
# (gap id bounded by non-[A-Z0-9]) rather than a loose substring, so
# RESILIENT-18 never matches a RESILIENT-1828 dispatch. Called only with at
# least one gap id (run_class_d keeps a worktree with none).
_classd_dispatch_running() {
    local pid args g pids
    [[ $# -gt 0 ]] || return 0
    pids="$(pgrep -f 'chump dispatch|--execute-gap|execute-gap' 2>/dev/null || true)"
    [[ -n "$pids" ]] || return 1
    for pid in $pids; do
        [[ "$pid" == "$$" ]] && continue
        args="$(ps -o args= -p "$pid" 2>/dev/null | tr '[:lower:]' '[:upper:]' || true)"
        [[ -n "$args" ]] || continue
        for g in "$@"; do
            [[ -n "$g" ]] || continue
            if [[ "$args" =~ (^|[^A-Z0-9])${g}($|[^A-Z0-9]) ]]; then
                CLASSD_DISPATCH_DETAIL="pid=${pid} gap=${g}"
                return 0
            fi
        done
    done
    return 1
}

# _classd_source_clean <wt> — 0 iff the worktree's TRACKED files are clean
# (ignores untracked build dirs). Fails closed: if git can't report, treat as
# dirty so the worktree is skipped rather than reaped.
_classd_source_clean() {
    local wt="$1" dirty
    dirty="$(git -C "$wt" status --porcelain --untracked-files=no 2>/dev/null || printf 'GIT_ERR')"
    [[ -z "$dirty" ]]
}

# _classd_marker_pid_alive <marker> — 0 iff the bot-merge that wrote this
# bot-merge-active-*.path marker is still running. The marker's content is the
# ship's log path, .chump-locks/bot-merge-<PID>.log; the PID must be alive AND
# still be a bot-merge (a recycled PID is not the ship). bot-merge writes the
# marker once per ship, so a ship that outlives the mtime grace still owns it.
_classd_marker_pid_alive() {
    local f="$1" content pid args
    content="$(head -1 "$f" 2>/dev/null || true)"
    [[ "$content" =~ bot-merge-([0-9]+)\.log ]] || return 1
    pid="${BASH_REMATCH[1]}"
    kill -0 "$pid" 2>/dev/null || return 1
    args="$(ps -o args= -p "$pid" 2>/dev/null || true)"
    [[ "$args" == *bot-merge* ]]
}

# _classd_recent_activity <wt> <window_min> <gap_id>... — 0 iff bot-merge or
# dispatch activity touched THIS worktree within <window_min> minutes. Signals:
#   - the NEWEST mtime anywhere under the build dirs (find -mmin): an
#     incremental build rewrites files deep in target/ without moving the
#     top-level dir's mtime, so the top-level mtime alone read a live build as
#     idle;
#   - a bot-merge-*.steps file within the window whose CONTENT names this
#     worktree path or one of its gap ids;
#   - a bot-merge-active-dispatch-*.path marker whose FILENAME names one of the
#     gap ids and that is within the window OR whose bot-merge PID is alive.
# A marker that names a different/no gap is NOT this worktree's activity, else
# one fresh ship elsewhere pins every idle worktree.
_classd_recent_activity() {
    local wt="$1" window_min="$2"
    shift 2
    local now cutoff p mt hit g
    now="$(date +%s)"
    cutoff=$(( now - window_min * 60 ))
    for p in "$wt/target" "$wt/.cargo-test-target" "$wt/.cargo-build-target"; do
        [[ -e "$p" ]] || continue
        hit="$(find "$p" -mmin "-${window_min}" -print -quit 2>/dev/null || true)"
        [[ -n "$hit" ]] && return 0
    done
    local lock_dir f first fbase
    lock_dir="${REAPER_REPO_ROOT:-$REPO_ROOT}/.chump-locks"
    if [[ -d "$lock_dir" ]]; then
        while IFS= read -r f; do
            [[ -f "$f" ]] || continue
            mt="$(stat -f%m "$f" 2>/dev/null || stat -c%Y "$f" 2>/dev/null || echo 0)"
            case "$f" in
                *bot-merge-active-dispatch-*.path)
                    # A marker ties to a worktree only via its gap-named filename.
                    fbase="$(basename "$f" | tr '[:lower:]' '[:upper:]')"
                    for g in "$@"; do
                        [[ "$fbase" =~ (^|[^A-Z0-9])${g}($|[^A-Z0-9]) ]] || continue
                        if [[ "$mt" -gt "$cutoff" ]] || _classd_marker_pid_alive "$f"; then
                            return 0
                        fi
                    done
                    ;;
                *)
                    [[ "$mt" -gt "$cutoff" ]] || continue
                    first="$(head -1 "$f" 2>/dev/null || true)"
                    [[ "$first" == *"$wt"* ]] && return 0
                    first="$(printf '%s' "$first" | tr '[:lower:]' '[:upper:]')"
                    for g in "$@"; do
                        [[ "$first" =~ (^|[^A-Z0-9])${g}($|[^A-Z0-9]) ]] && return 0
                    done
                    ;;
            esac
        done < <(find "$lock_dir" -maxdepth 1 \
            \( -name 'bot-merge-*.steps' -o -name 'bot-merge-active-dispatch-*.path' \) \
            -type f 2>/dev/null)
    fi
    return 1
}

# _classd_reap_stale_markers — remove bot-merge-active-dispatch-*.path markers
# older than the RESILIENT-1609 grace whose bot-merge is no longer running.
# bot-merge.sh writes one per ship to advertise its log path and nothing cleans
# them up, so idle dispatch worktrees strand 5-9h-old markers (receipt
# 2026-10-18). A marker within the grace, or one whose bot-merge PID is still
# alive (a ship longer than the grace), names a live ship — keep it. Logs each
# removal (stdout + ambient class=D). Uses globals EXECUTE, _dry_label,
# AMBIENT_LOG, _total_bytes, _reaped_count, _classd_count.
_classd_reap_stale_markers() {
    local lock_dir grace_min now cutoff f mt size age
    lock_dir="${REAPER_REPO_ROOT:-$REPO_ROOT}/.chump-locks"
    [[ -d "$lock_dir" ]] || return 0
    grace_min="${CHUMP_REAPER_BOT_MERGE_GRACE_MIN:-${CHUMP_REAPER_ACTIVE_LEASE_MIN:-15}}"
    [[ "$grace_min" =~ ^[0-9]+$ ]] || grace_min=15
    now="$(date +%s)"
    cutoff=$(( now - grace_min * 60 ))
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        mt="$(stat -f%m "$f" 2>/dev/null || stat -c%Y "$f" 2>/dev/null || echo 0)"
        if [[ "$mt" -ge "$cutoff" ]]; then
            echo "  keep (marker within ${grace_min}m grace): ${f}"
            continue
        fi
        if _classd_marker_pid_alive "$f"; then
            echo "  keep (marker's bot-merge still running): ${f}"
            continue
        fi
        size="$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f" 2>/dev/null || echo 0)"
        age=$(( ( now - mt ) / 86400 ))
        echo "${_dry_label}  class-D stale marker reap: ${f} (older than ${grace_min}m grace, bot-merge not running)"
        if [[ $EXECUTE -eq 1 ]]; then
            rm -f "$f" 2>/dev/null || true
        fi
        _total_bytes=$(( _total_bytes + size ))
        _reaped_count=$(( _reaped_count + 1 ))
        _classd_count=$(( _classd_count + 1 ))
        printf '{"ts":"%s","kind":"cargo_target_reaped","path":"%s","bytes_freed":%d,"age_days":%d,"dry_run":%s,"class":"D"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$f" "$size" "$age" \
            "$([[ $EXECUTE -eq 1 ]] && echo 'false' || echo 'true')" \
            >> "$AMBIENT_LOG" 2>/dev/null || true
    done < <(find "$lock_dir" -maxdepth 1 -name 'bot-merge-active-dispatch-*.path' -type f 2>/dev/null)
}

# _classd_lane_acquire — RESILIENT-1635: before it deletes anything, Class D
# takes the node build lane lock the architect's guarded sweep and lane builds
# take (a non-blocking flock -n on $HOME/.chump/architect-lane.lock) and passes
# the `chump admit cargo` admission check. The lock path is FIXED: no env var
# can point it elsewhere (a test override was a production bypass: pointed at
# /dev/null it reaped while the real lock was held). Tests run the real code
# under a sandbox HOME instead. What this buys: no Class D tick runs while a
# lane holder (architect sweep or lane build) holds the lock, and none runs past
# the admit capacity ceiling; it does NOT serialise against a cargo build that
# never takes the lane lock (those are covered per worktree by the cwd,
# CARGO_TARGET_DIR, open-file and blind-pid checks). A lock file missing from
# an existing $HOME/.chump is created (>>) and the tick proceeds; a missing
# $HOME/.chump directory skips the tick. Returns 0 holding the lock on fd 8,
# else 1 after logging why; the caller then skips the whole Class D tick. Fails
# closed when HOME, flock, the lock file or chump is unavailable.
_classd_lane_acquire() {
    local lock rc=0
    if [[ -z "${HOME:-}" ]]; then
        echo "[cargo-target-reaper] Class D skipped: HOME unset, cannot locate the node build lane lock"
        return 1
    fi
    lock="${HOME}/.chump/architect-lane.lock"
    if ! command -v flock >/dev/null 2>&1; then
        echo "[cargo-target-reaper] Class D skipped: flock unavailable, cannot take the node build lane lock (${lock})"
        return 1
    fi
    if ! { exec 8>>"$lock"; } 2>/dev/null; then
        echo "[cargo-target-reaper] Class D skipped: cannot open the node build lane lock ${lock}"
        return 1
    fi
    if ! flock -n 8 2>/dev/null; then
        exec 8>&-
        echo "[cargo-target-reaper] Class D skipped: node build lane lock held by another process (${lock})"
        return 1
    fi
    if ! command -v chump >/dev/null 2>&1; then
        flock -u 8 2>/dev/null || true
        exec 8>&-
        echo "[cargo-target-reaper] Class D skipped: chump not on PATH, cannot run the chump admit cargo admission check"
        return 1
    fi
    chump admit cargo >/dev/null 2>&1 8>&- || rc=$?
    if [[ $rc -ne 0 ]]; then
        flock -u 8 2>/dev/null || true
        exec 8>&-
        echo "[cargo-target-reaper] Class D skipped: chump admit cargo refused (exit ${rc})"
        return 1
    fi
    return 0
}

# _classd_lane_release — drop the lane lock taken by _classd_lane_acquire.
_classd_lane_release() {
    flock -u 8 2>/dev/null || true
    exec 8>&-
}

# run_class_d — scan .claude/worktrees for reapable dispatch worktrees (PR
# merged/closed, or OPEN-but-idle per RESILIENT-1635) and reap their target/ +
# .cargo-test-target/. Uses globals EXECUTE, _dry_label, AMBIENT_LOG,
# _total_bytes, _reaped_count.
_classd_count=0
run_class_d() {
    local wt_base
    wt_base="${CHUMP_WORKTREE_BASE:-${REAPER_REPO_ROOT:-$REPO_ROOT}/.claude/worktrees}"
    # Fail closed: without the lease checker Class D cannot prove a worktree is
    # lease-less, so it reaps nothing rather than everything.
    if ! command -v wt_has_active_lease >/dev/null 2>&1; then
        echo "[cargo-target-reaper] Class D skipped: wt_has_active_lease unavailable (scripts/lib/worktree-iter.sh not loaded)"
        return 0
    fi
    [[ -d "$wt_base" ]] || return 0
    # RESILIENT-1635: the scanned base, resolved. Every worktree must resolve to
    # a path under it (a .claude/worktrees/X symlink to another checkout got that
    # checkout's real target/ deleted).
    local base_real
    base_real="$(cd -P "$wt_base" 2>/dev/null && pwd -P || true)"
    if [[ -z "$base_real" ]]; then
        echo "[cargo-target-reaper] Class D skipped: cannot resolve ${wt_base}"
        return 0
    fi
    # RESILIENT-1635: hold the node build lane and pass `chump admit cargo`
    # before deleting anything; otherwise skip the whole tick (logged).
    if ! _classd_lane_acquire; then
        return 0
    fi
    # The scan runs with fd 8 closed (8>&-): bash parks the lock fd on a
    # close-on-exec descriptor for the call, so the lock stays held by this
    # shell while no child (git, find, lsof, rm, ...) inherits it. A child that
    # outlived the tick could otherwise keep the lane locked.
    CLASSD_BLIND_PIDS=" "
    _classd_scan "$wt_base" "$base_real" 8>&-
    local blind="${CLASSD_BLIND_PIDS# }"
    blind="${blind% }"
    if [[ -n "$blind" ]]; then
        local nblind
        nblind="$(wc -w <<< "$blind" | tr -d ' ')"
        echo "[cargo-target-reaper] Class D: ${nblind} pid(s) with unreadable /proc environ/cwd/fd, judged by cmdline: ${blind}"
    fi
    _classd_lane_release
}

# _classd_scan <wt_base> <base_real> — the Class D worktree loop + the stale
# marker sweep. Called by run_class_d holding the lane lock, with fd 8 closed.
_classd_scan() {
    local wt_base="$1" base_real="$2"
    echo "[cargo-target-reaper] Scanning ${wt_base}/* (Class D: merged/closed or idle open-PR lease-less dispatch worktrees)…"
    local wt wt_entry
    local -a _wts=()
    if command -v scan_worktrees >/dev/null 2>&1; then
        while IFS= read -r wt; do _wts+=("$wt"); done < <(
            CHUMP_WORKTREE_BASE="$wt_base" CHUMP_WT_SCAN_TMP=0 CHUMP_WT_SCAN_DOT_CLAUDE=1 \
                scan_worktrees --no-tmp --include-dot-claude 2>/dev/null || true)
    else
        local d
        for d in "$wt_base"/*/; do [[ -d "$d" ]] && _wts+=("${d%/}"); done
    fi

    for wt_entry in "${_wts[@]+"${_wts[@]}"}"; do
        wt_entry="${wt_entry%/}"
        # RESILIENT-1635: never follow a symlinked worktree entry.
        if [[ -L "$wt_entry" ]]; then
            echo "  skip (worktree entry is a symlink): ${wt_entry}"
            continue
        fi
        [[ -d "$wt_entry" ]] || continue
        # Resolve with pwd -P and require the result to stay under the scanned
        # base; everything below uses the resolved path.
        wt="$(cd -P "$wt_entry" 2>/dev/null && pwd -P || true)"
        if [[ -z "$wt" || "$wt" != "$base_real"/* ]]; then
            echo "  skip (resolved path ${wt:-?} is not under ${base_real}): ${wt_entry}"
            continue
        fi
        local target="$wt/target"
        local ctt="$wt/.cargo-test-target"
        local cbt="$wt/.cargo-build-target"
        # Nothing to reap if no build dir exists.
        [[ -e "$target" || -e "$ctt" || -e "$cbt" || -L "$target" || -L "$ctt" || -L "$cbt" ]] || continue
        # RESILIENT-1635: a symlinked build dir points at someone else's build.
        if [[ -L "$target" || -L "$ctt" || -L "$cbt" ]]; then
            echo "  skip (build dir is a symlink): ${wt}"
            continue
        fi
        [[ -d "$target" || -d "$ctt" || -d "$cbt" ]] || continue

        # Opt-out sentinel (same marker the other reapers honor).
        if [[ -e "$wt/.chump-no-reap" ]]; then
            echo "  skip (.chump-no-reap present): ${wt}"
            continue
        fi

        # Safety: never reap a worktree with a live lease (either spelling).
        # RESILIENT-1623: wt_has_active_lease checks the union of env and repo stores.
        local _lease_ttl="${CHUMP_LEASE_HEARTBEAT_TTL_S:-600}"
        if wt_has_active_lease "$wt" "$_lease_ttl" || { [[ "$wt_entry" != "$wt" ]] && wt_has_active_lease "$wt_entry" "$_lease_ttl"; }; then
            echo "  skip (active lease): ${wt}"
            continue
        fi

        # Safety: never reap a worktree that is a live process's cwd.
        if _classd_cwd_inside "$wt" "$wt_entry"; then
            echo "  skip (process cwd inside): ${wt}"
            continue
        fi

        # Safety: never race a live bot-merge ship.
        if command -v wt_has_live_bot_merge >/dev/null 2>&1 && wt_has_live_bot_merge "$wt"; then
            echo "  skip (live bot-merge: ${WT_LIVE_BOT_MERGE_DETAIL:-?}): ${wt}"
            continue
        fi

        # Resolve the branch, then the PR state (cache-first, gh fallback).
        local branch
        branch="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
        if [[ -z "$branch" || "$branch" == "HEAD" ]]; then
            echo "  skip (no branch): ${wt}"
            continue
        fi
        local merged pr_disp="merged/closed"
        merged="$(_classd_pr_merged_or_closed "$branch")"
        if [[ "$merged" != "yes" ]]; then
            # RESILIENT-1635: an OPEN PR is still reapable (build output only) if
            # the dispatch worktree is IDLE. An unknown/no-PR state (gh failing,
            # no PR, unparseable) is NOT open: keep. lease + cwd + live-bot-merge
            # already excluded above.
            if [[ "$merged" != "no" ]]; then
                echo "  skip (PR state unknown or no PR for ${branch}): ${wt}"
                continue
            fi
            local -a gap_ids=()
            local g
            while IFS= read -r g; do [[ -n "$g" ]] && gap_ids+=("$g"); done < <(_classd_gap_ids "$wt" "$branch")
            if [[ ${#gap_ids[@]} -eq 0 ]]; then
                echo "  skip (no gap id derivable from $(basename "$wt") or ${branch}; cannot rule out a running dispatch): ${wt}"
                continue
            fi
            CLASSD_DISPATCH_DETAIL=""
            if _classd_dispatch_running "${gap_ids[@]}"; then
                echo "  skip (running dispatch for gap: ${CLASSD_DISPATCH_DETAIL:-?}): ${wt}"
                continue
            fi
            if ! _classd_source_clean "$wt"; then
                echo "  skip (dirty source tree): ${wt}"
                continue
            fi
            if _classd_recent_activity "$wt" "$CLASSD_IDLE_WINDOW_MIN" "${gap_ids[@]}"; then
                echo "  skip (bot-merge/dispatch activity within ${CLASSD_IDLE_WINDOW_MIN}m): ${wt}"
                continue
            fi
            pr_disp="idle open-PR"
        fi

        # RESILIENT-1635: last check before deleting — a process building into
        # this worktree from elsewhere (CARGO_TARGET_DIR inside it, or an open
        # file under its build dirs) makes it busy.
        if _classd_target_dir_env_busy "$wt" "$wt_entry"; then
            echo "  skip (a process has CARGO_TARGET_DIR inside the worktree): ${wt}"
            continue
        fi
        CLASSD_CARGO_BUSY_DETAIL=""
        if _classd_cargo_rustc_busy "$wt" "$wt_entry"; then
            echo "  skip (active cargo/rustc process against worktree: ${CLASSD_CARGO_BUSY_DETAIL:-?}): ${wt}"
            continue
        fi
        if _classd_build_files_open "$target" "$ctt" "$cbt"; then
            echo "  skip (a process holds an open file under the build dirs): ${wt}"
            continue
        fi
        # RESILIENT-1635: a pid whose environ/cwd/fd the checks above could not
        # read is judged by its cmdline (Linux; see _classd_blind_pid_busy).
        CLASSD_BLIND_DETAIL=""
        if _classd_blind_pid_busy "$wt" "$wt_entry"; then
            echo "  skip (unreadable pid judged busy by cmdline: ${CLASSD_BLIND_DETAIL:-?}): ${wt}"
            continue
        fi

        # Reap ONLY the build dirs — never the source tree.
        local reap_dir size_bytes age_days
        for reap_dir in "$target" "$ctt" "$cbt"; do
            [[ -d "$reap_dir" ]] || continue
            [[ -L "$reap_dir" ]] && continue
            # Belt-and-suspenders: skip if a cargo lock says a build is in flight.
            if [[ -f "${reap_dir}/.cargo-lock" ]]; then
                echo "  skip (cargo lock active): ${reap_dir}"
                continue
            fi
            size_bytes=$(du -sk "$reap_dir" 2>/dev/null | awk '{print $1 * 1024}' || echo 0)
            age_days=$(( ( $(date +%s) - $(stat -f%m "$reap_dir" 2>/dev/null \
                || stat -c%Y "$reap_dir" 2>/dev/null || echo 0) ) / 86400 ))
            echo "${_dry_label}  class-D reap: ${reap_dir} (branch ${branch} ${pr_disp}, ${age_days}d old, ~$(( size_bytes / 1024 / 1024 ))MB)"
            if [[ $EXECUTE -eq 1 ]]; then
                rm -rf "$reap_dir" 2>/dev/null || true
            fi
            _total_bytes=$(( _total_bytes + size_bytes ))
            _reaped_count=$(( _reaped_count + 1 ))
            _classd_count=$(( _classd_count + 1 ))
            printf '{"ts":"%s","kind":"cargo_target_reaped","path":"%s","bytes_freed":%d,"age_days":%d,"dry_run":%s,"class":"D","worktree":"%s","branch":"%s"}\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$reap_dir" "$size_bytes" "$age_days" \
                "$([[ $EXECUTE -eq 1 ]] && echo 'false' || echo 'true')" "$wt" "$branch" \
                >> "$AMBIENT_LOG" 2>/dev/null || true
        done
    done

    # RESILIENT-1635: sweep stale bot-merge-active-dispatch-*.path markers.
    _classd_reap_stale_markers
}

# ── --class-d-only early path (RESILIENT-1620) ──────────────────────────────
# Runs ONLY Class D, bypassing the global cargo-process / low-disk guards that
# the full run uses: Class D is build-safe per-worktree (lease + cwd + bot-merge
# + cargo-lock checks), so disk-health-monitor's alert→action trigger can fire
# it unconditionally even while the fleet is building.
if [[ $CLASS_D_ONLY -eq 1 ]]; then
    AMBIENT_LOG="${REAPER_REPO_ROOT:-$REPO_ROOT}/.chump-locks/ambient.jsonl"
    _dry_label="[DRY-RUN]"
    [[ $EXECUTE -eq 1 ]] && _dry_label=""
    _total_bytes=0
    _reaped_count=0
    run_class_d
    _total_mb=$(( _total_bytes / 1024 / 1024 ))
    echo ""
    echo "[cargo-target-reaper] ${_dry_label} Class-D-only done: ${_classd_count} artifacts, ~${_total_mb}MB"
    printf '{"ts":"%s","kind":"cargo_target_reaper_summary","reaped_count":%d,"bytes_freed":%d,"execute":%s,"worktree_orphan_count":0,"cross_build_count":0,"cargo_test_target_count":0,"lease_auto_merge_count":0,"runner_scope_count":0,"root_orphan_target_count":0,"class_d_count":%d,"aggressive_mode":false,"class_d_only":true}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_reaped_count" "$_total_bytes" \
        "$([[ $EXECUTE -eq 1 ]] && echo 'true' || echo 'false')" "$_classd_count" \
        >> "$AMBIENT_LOG" 2>/dev/null || true
    exit 0
fi

# ── Event-listener mode (INFRA-2181) ────────────────────────────────────────
# When --event-listen is passed, tail-poll ambient.jsonl for
# kind=integration_cycle_shipped and trigger a full reap within 60s.
# Runs indefinitely as a daemon; exits cleanly on SIGTERM/SIGINT.
if [[ $EVENT_LISTEN -eq 1 ]]; then
    _ambient_log="${CHUMP_CARGO_REAPER_AMBIENT_LOG:-${REPO_ROOT}/.chump-locks/ambient.jsonl}"
    _poll_interval="${CHUMP_CARGO_REAPER_EVENT_POLL_S:-30}"
    _reaper_self="${BASH_SOURCE[0]}"
    _execute_flag=""
    [[ $EXECUTE -eq 1 ]] && _execute_flag="--execute"

    echo "[cargo-target-reaper] event-listen mode: polling ${_ambient_log} every ${_poll_interval}s for kind=integration_cycle_shipped"
    printf '{"ts":"%s","kind":"cargo_target_reaper_event_listener_started","poll_interval_s":%d,"execute":%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_poll_interval" \
        "$([[ $EXECUTE -eq 1 ]] && echo 'true' || echo 'false')" \
        >> "${_ambient_log}" 2>/dev/null || true

    _last_seen_ts=""
    _stop=0
    trap '_stop=1' SIGTERM SIGINT

    # Fall back to one-shot if ambient log is not readable
    if [[ ! -f "$_ambient_log" ]]; then
        echo "[cargo-target-reaper] WARN: ambient log not found at ${_ambient_log} — running one-shot reap (fail-open)" >&2
        exec bash "$_reaper_self" ${_execute_flag}
    fi

    while [[ $_stop -eq 0 ]]; do
        # Find any integration_cycle_shipped events newer than _last_seen_ts
        _new_event=""
        while IFS= read -r _line; do
            _kind=$(printf '%s' "$_line" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('kind',''))" 2>/dev/null || true)
            if [[ "$_kind" == "integration_cycle_shipped" ]]; then
                _event_ts=$(printf '%s' "$_line" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('ts',''))" 2>/dev/null || true)
                if [[ -z "$_last_seen_ts" || "$_event_ts" > "$_last_seen_ts" ]]; then
                    _new_event="$_line"
                    _last_seen_ts="$_event_ts"
                fi
            fi
        done < <(tail -200 "$_ambient_log" 2>/dev/null || true)

        if [[ -n "$_new_event" ]]; then
            _gap_id=$(printf '%s' "$_new_event" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('gap_id','unknown'))" 2>/dev/null || echo unknown)
            echo "[cargo-target-reaper] integration_cycle_shipped detected (gap=${_gap_id}, ts=${_last_seen_ts}) — triggering reap…"
            printf '{"ts":"%s","kind":"cargo_target_reaper_event_triggered","trigger_event_ts":"%s","gap_id":"%s","execute":%s}\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_last_seen_ts" "$_gap_id" \
                "$([[ $EXECUTE -eq 1 ]] && echo 'true' || echo 'false')" \
                >> "${_ambient_log}" 2>/dev/null || true
            # Run reap inline (not subprocess) so EXECUTE flag propagates cleanly
            # Re-exec as a child to get a fresh process with safety guards reset
            bash "$_reaper_self" ${_execute_flag} &
            _reap_pid=$!
            wait "$_reap_pid" || true
        fi

        # Sleep in small chunks so SIGTERM is caught promptly
        _slept=0
        while [[ $_stop -eq 0 && $_slept -lt $_poll_interval ]]; do
            sleep 5
            _slept=$(( _slept + 5 ))
        done
    done

    echo "[cargo-target-reaper] event-listen mode: received stop signal, exiting cleanly."
    printf '{"ts":"%s","kind":"cargo_target_reaper_event_listener_stopped"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        >> "${_ambient_log}" 2>/dev/null || true
    exit 0
fi

# ── Safety guards ────────────────────────────────────────────────────────────

# INFRA-2188 + ZERO-WASTE-012: compute the disk-critical AGGRESSIVE_MODE FIRST, so
# the guards below can relax when disk is critical. Previously this ran AFTER the
# guards — so on a continuously-building fleet at low disk, the blanket cargo-active
# guard ALWAYS aborted and the aggressive mode never engaged → the reaper never ran
# while the shared target grew unbounded → recurring disk_critical.
AGGRESSIVE_MODE=0
if [[ "$DISK_CRITICAL_GB" -gt 0 ]]; then
    _home_free_kb=$(df -k "$HOME" 2>/dev/null | awk 'NR==2{print $4}' || echo "9999999")
    _home_free_gb=$(( _home_free_kb / 1024 / 1024 ))
    if [[ $_home_free_gb -lt $DISK_CRITICAL_GB ]]; then
        AGGRESSIVE_MODE=1
        FINGERPRINT_AGE_D=1
        FLEET_AGE_D=2
        echo "[cargo-target-reaper] disk-critical: ${_home_free_gb}GB free on \$HOME (< ${DISK_CRITICAL_GB}GB threshold) — escalating: FINGERPRINT_AGE_D=${FINGERPRINT_AGE_D} FLEET_AGE_D=${FLEET_AGE_D}"
        # INFRA-2188: emit ambient event so fleet observers can react.
        _agg_log="${REPO_ROOT}/.chump-locks/ambient.jsonl"
        printf '{"ts":"%s","kind":"cargo_reaper_aggressive_mode_engaged","free_gb":%d,"disk_critical_gb":%d,"fingerprint_age_d":%d,"fleet_age_d":%d}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_home_free_gb" "$DISK_CRITICAL_GB" \
            "$FINGERPRINT_AGE_D" "$FLEET_AGE_D" \
            >> "$_agg_log" 2>/dev/null || true
    fi
fi

# 1. Refuse if any cargo process is active — NORMAL MODE ONLY (ZERO-WASTE-012).
# In disk-critical aggressive mode the fleet is always building, so a blanket abort
# means the reaper NEVER runs while disk fills. The per-target cargo-lock check
# (later, per candidate) + age-based reaping (only stale artifacts an active build
# does not reference) keep aggressive-mode reaping build-safe.
if [[ $AGGRESSIVE_MODE -eq 0 ]] \
   && { pgrep -x "cargo" > /dev/null 2>&1 || pgrep -f "rustc " > /dev/null 2>&1; }; then
    # Skip cleanly this cycle: an active build is a NORMAL condition on a worker
    # node (it is nearly always building), not a failure. Exiting non-zero here
    # marked the systemd oneshot unit `failed` every tick on a build host — the
    # exact spurious-failure this reaper's own guard should not cause. The timer
    # re-runs it once the build settles; nothing to reap now.
    echo "[cargo-target-reaper] SKIP: active cargo/rustc processes detected — nothing to reap this cycle; will retry next tick." >&2
    exit 0
fi

# 2. Refuse if free disk < MIN_FREE_GB — NORMAL MODE ONLY (ZERO-WASTE-012).
# When disk IS critical (aggressive mode), reaping is exactly what is needed;
# aborting here is backwards for a disk reaper.
if [[ $AGGRESSIVE_MODE -eq 0 ]]; then
    _free_kb=$(df -k "$REPO_ROOT" 2>/dev/null | awk 'NR==2{print $4}' || echo "9999999")
    _free_gb=$(( _free_kb / 1024 / 1024 ))
    if [[ $_free_gb -lt $MIN_FREE_GB ]]; then
        # Skip cleanly (exit 0, not a failure): in normal mode below the safety
        # floor there is nothing this reaper will safely touch; disk-critical
        # reaping is handled by AGGRESSIVE_MODE above. A non-zero exit here only
        # marked the systemd oneshot unit `failed` without doing any work.
        echo "[cargo-target-reaper] SKIP: only ${_free_gb}GB free — below the ${MIN_FREE_GB}GB normal-mode floor; nothing to reap this cycle." >&2
        exit 0
    fi
fi

AMBIENT_LOG="${REPO_ROOT}/.chump-locks/ambient.jsonl"
_dry_label="[DRY-RUN]"
[[ $EXECUTE -eq 1 ]] && _dry_label=""

_total_bytes=0
_reaped_count=0

# ── Helper: maybe_delete ─────────────────────────────────────────────────────
# Usage: maybe_delete <path>
maybe_delete() {
    local path="$1"
    local size_bytes=0
    if [[ -d "$path" ]]; then
        size_bytes=$(du -sk "$path" 2>/dev/null | awk '{print $1 * 1024}' || echo 0)
    elif [[ -f "$path" ]]; then
        size_bytes=$(stat -f%z "$path" 2>/dev/null || stat -c%s "$path" 2>/dev/null || echo 0)
    fi
    local age_days=0
    age_days=$(( ( $(date +%s) - $(stat -f%m "$path" 2>/dev/null || stat -c%Y "$path" 2>/dev/null || echo 0) ) / 86400 ))
    echo "${_dry_label}  reap: ${path} (${age_days}d old, ~$(( size_bytes / 1024 / 1024 ))MB)"
    if [[ $EXECUTE -eq 1 ]]; then
        rm -rf "$path"
    fi
    _total_bytes=$(( _total_bytes + size_bytes ))
    _reaped_count=$(( _reaped_count + 1 ))
    # Emit per-artifact ambient event
    printf '{"ts":"%s","kind":"cargo_target_reaped","path":"%s","bytes_freed":%d,"age_days":%d,"dry_run":%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$path" "$size_bytes" "$age_days" \
        "$([[ $EXECUTE -eq 1 ]] && echo 'false' || echo 'true')" \
        >> "$AMBIENT_LOG" 2>/dev/null || true
}

# ── (a+b) main repo target/debug ─────────────────────────────────────────────
TARGET_DEBUG="${REPO_ROOT}/target/debug"
if [[ -d "$TARGET_DEBUG" ]]; then
    echo "[cargo-target-reaper] Scanning ${TARGET_DEBUG}/.fingerprint/* (>${FINGERPRINT_AGE_D}d)…"
    while IFS= read -r -d '' entry; do
        maybe_delete "$entry"
    done < <(find "${TARGET_DEBUG}/.fingerprint" -mindepth 1 -maxdepth 1 -mtime "+${FINGERPRINT_AGE_D}" -print0 2>/dev/null)

    echo "[cargo-target-reaper] Scanning ${TARGET_DEBUG}/deps/lib*.rlib (>${FINGERPRINT_AGE_D}d)…"
    while IFS= read -r -d '' entry; do
        maybe_delete "$entry"
    done < <(find "${TARGET_DEBUG}/deps" -maxdepth 1 -name 'lib*.rlib' -mtime "+${FINGERPRINT_AGE_D}" -print0 2>/dev/null)
fi

# ── (c) fleet shared target dirs ─────────────────────────────────────────────
FLEET_CACHE="${HOME}/.cache/chump-fleet-target"
if [[ -d "$FLEET_CACHE" ]]; then
    echo "[cargo-target-reaper] Scanning ${FLEET_CACHE}/ (>${FLEET_AGE_D}d, no live owner)…"
    # Collect all CARGO_TARGET_DIR values from live processes
    _live_targets=""
    while IFS= read -r pid; do
        _env=$(ps eww -p "$pid" 2>/dev/null | grep -o 'CARGO_TARGET_DIR=[^ ]*' | head -1 || true)
        if [[ -n "$_env" ]]; then
            _live_targets="${_live_targets}${_env##*=}"$'\n'
        fi
    done < <(pgrep -f "cargo|rustc" 2>/dev/null || true)

    while IFS= read -r -d '' dir; do
        _basename=$(basename "$dir")
        # Skip if any live process references this dir
        if echo "$_live_targets" | grep -qF "$_basename" 2>/dev/null; then
            echo "  skip (live owner): ${dir}"
            continue
        fi
        maybe_delete "$dir"
    done < <(find "$FLEET_CACHE" -mindepth 1 -maxdepth 1 -type d -mtime "+${FLEET_AGE_D}" -print0 2>/dev/null)
fi

# ── (d) INFRA-1170: /tmp/chump-*/target/ orphaned by gone worktrees ──────────
# Reap target/ dirs in /tmp/chump-* paths where the originating git worktree
# is no longer registered in `git worktree list --porcelain`. Safe because:
#   - If the worktree was removed (git worktree remove), the target dir is dead weight.
#   - If the worktree is still active, git worktree list will still show it.
#
# Failure taxonomy (emitted as ambient events):
#   transient: cargo lock file present (.cargo-lock) — build may be in flight.
#   permanent: rm -rf failed (path gone mid-reap, permission error, etc.).
_tmp_orphan_count=0

# Build set of registered worktree paths (INFRA-1211: use shared scanner).
_registered_wts=$'\n'
if command -v scan_worktrees >/dev/null 2>&1; then
    for _wt in $(scan_worktrees --include-tmp --include-dot-claude); do
        _registered_wts="${_registered_wts}${_wt}"$'\n'
    done
else
    # Fallback to legacy scan if lib missing
    _wt_list_raw="$(git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null || true)"
    while IFS= read -r _wt_line; do
        if [[ "$_wt_line" == worktree\ * ]]; then
            _registered_wts="${_registered_wts}${_wt_line#worktree }"$'\n'
        fi
    done <<< "$_wt_list_raw"
fi

# Support override for testing: CHUMP_CARGO_REAPER_TMP_GLOB controls the scan path.
_TMP_GLOB="${CHUMP_CARGO_REAPER_TMP_GLOB:-/tmp/chump-*}"
echo "[cargo-target-reaper] Scanning ${_TMP_GLOB}/target/ (orphaned worktrees)…"

# META-117/B: materialize _registered_wts to a tempfile once before loop
_META117_REG_WTS_BUF="$(mktemp)"
trap 'rm -f "$_META117_REG_WTS_BUF"' EXIT
printf '%s' "$_registered_wts" > "$_META117_REG_WTS_BUF"

for _wt_candidate in ${_TMP_GLOB}/; do
    [[ -d "$_wt_candidate" ]] || continue
    _wt_candidate="${_wt_candidate%/}"
    _target_candidate="${_wt_candidate}/target"
    [[ -d "$_target_candidate" ]] || continue

    # Skip if this worktree is still registered with git.
    if grep -qxF "$_wt_candidate" "$_META117_REG_WTS_BUF" 2>/dev/null; then
        echo "  skip (registered worktree): ${_wt_candidate}"
        continue
    fi

    # RESILIENT-116: honor the .chump-no-reap escape hatch (same sentinel
    # active-target-reaper.sh and stale-worktree-reaper.sh respect — see
    # RESILIENT-107 precedent). Checked before any deletion decision.
    if [[ -e "${_wt_candidate}/.chump-no-reap" ]]; then
        printf '{"ts":"%s","kind":"target_reap_skipped","worktree":"%s","reason":"no_reap_marker"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_target_candidate" \
            >> "$AMBIENT_LOG" 2>/dev/null || true
        echo "  skip (.chump-no-reap present): ${_target_candidate}"
        continue
    fi

    # Transient failure: cargo lock present means a build may be in flight.
    if [[ -f "${_target_candidate}/.cargo-lock" ]]; then
        printf '{"ts":"%s","kind":"cargo_target_reaped","path":"%s","error":"cargo_lock_active","failure_class":"transient","worktree_gone":true,"dry_run":true}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_target_candidate" \
            >> "$AMBIENT_LOG" 2>/dev/null || true
        printf '{"ts":"%s","kind":"target_reap_skipped","worktree":"%s","reason":"active_build"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_target_candidate" \
            >> "$AMBIENT_LOG" 2>/dev/null || true
        echo "  skip (cargo lock active — transient): ${_target_candidate}"
        continue
    fi

    # RESILIENT-116: lsof guard — a live process with files open under
    # target/ means a build is actively writing to it even when no
    # .cargo-lock is present (e.g. between compiler invocations).
    if command -v lsof >/dev/null 2>&1 && lsof -F n +D "$_target_candidate" 2>/dev/null | grep -q .; then
        printf '{"ts":"%s","kind":"target_reap_skipped","worktree":"%s","reason":"active_build"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_target_candidate" \
            >> "$AMBIENT_LOG" 2>/dev/null || true
        echo "  skip (process has files open — active build): ${_target_candidate}"
        continue
    fi

    _t_size_bytes=$(du -sk "$_target_candidate" 2>/dev/null | awk '{print $1 * 1024}' || echo 0)
    _t_age_days=$(( ( $(date +%s) - $(stat -f%m "$_target_candidate" 2>/dev/null \
        || stat -c%Y "$_target_candidate" 2>/dev/null || echo 0) ) / 86400 ))
    echo "${_dry_label}  orphan worktree target: ${_target_candidate} (${_t_age_days}d old, ~$(( _t_size_bytes / 1024 / 1024 ))MB)"

    _reap_ok=1
    if [[ $EXECUTE -eq 1 ]]; then
        if ! rm -rf "$_target_candidate" 2>/dev/null; then
            # Permanent failure: path vanished mid-reap or permission denied.
            printf '{"ts":"%s","kind":"cargo_target_reaped","path":"%s","error":"rm_failed","failure_class":"permanent","worktree_gone":true}\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_target_candidate" \
                >> "$AMBIENT_LOG" 2>/dev/null || true
            _reap_ok=0
        fi
    fi

    if [[ $_reap_ok -eq 1 ]]; then
        _total_bytes=$(( _total_bytes + _t_size_bytes ))
        _reaped_count=$(( _reaped_count + 1 ))
        _tmp_orphan_count=$(( _tmp_orphan_count + 1 ))
        printf '{"ts":"%s","kind":"cargo_target_reaped","path":"%s","bytes_freed":%d,"age_days":%d,"dry_run":%s,"worktree_gone":true}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_target_candidate" \
            "$_t_size_bytes" "$_t_age_days" \
            "$([[ $EXECUTE -eq 1 ]] && echo 'false' || echo 'true')" \
            >> "$AMBIENT_LOG" 2>/dev/null || true
    fi
done

# ── (e) INFRA-2125/A: Linux cross-build artifacts ───────────────────────────
# /tmp/chump-coord-linux-build* and /tmp/chump-cross-build-* from cross-build-linux.sh
_cross_build_count=0
echo "[cargo-target-reaper] Scanning /tmp/chump-coord-linux-build* and /tmp/chump-cross-build-* (Class A cross-build artifacts)…"
for _cross_dir in /tmp/chump-coord-linux-build* /tmp/chump-cross-build-*; do
    [[ -d "$_cross_dir" ]] || continue
    _cb_size=$(du -sk "$_cross_dir" 2>/dev/null | awk '{print $1 * 1024}' || echo 0)
    _cb_age=$(( ( $(date +%s) - $(stat -f%m "$_cross_dir" 2>/dev/null || stat -c%Y "$_cross_dir" 2>/dev/null || echo 0) ) / 86400 ))
    echo "${_dry_label}  cross-build artifact: ${_cross_dir} (${_cb_age}d old, ~$(( _cb_size / 1024 / 1024 ))MB)"
    if [[ $EXECUTE -eq 1 ]]; then
        rm -rf "$_cross_dir" 2>/dev/null || true
    fi
    _total_bytes=$(( _total_bytes + _cb_size ))
    _reaped_count=$(( _reaped_count + 1 ))
    _cross_build_count=$(( _cross_build_count + 1 ))
    printf '{"ts":"%s","kind":"cargo_target_reaped","path":"%s","bytes_freed":%d,"age_days":%d,"dry_run":%s,"class":"cross_build"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_cross_dir" "$_cb_size" "$_cb_age" \
        "$([[ $EXECUTE -eq 1 ]] && echo 'false' || echo 'true')" \
        >> "$AMBIENT_LOG" 2>/dev/null || true
done

# ── (f) INFRA-2125/B: hidden .cargo-test-target/ dirs ───────────────────────
# /tmp/chump-*/.cargo-test-target/ — Sonnet workers setting custom CARGO_TARGET_DIR
_cargo_test_target_count=0
echo "[cargo-target-reaper] Scanning /tmp/chump-*/.cargo-test-target/ (Class B worker cargo-test-target dirs)…"
for _wt_dir in ${_TMP_GLOB:-/tmp/chump-*}/; do
    [[ -d "$_wt_dir" ]] || continue
    _ctt="${_wt_dir%/}/.cargo-test-target"
    [[ -d "$_ctt" ]] || continue
    _ctt_size=$(du -sk "$_ctt" 2>/dev/null | awk '{print $1 * 1024}' || echo 0)
    _ctt_age=$(( ( $(date +%s) - $(stat -f%m "$_ctt" 2>/dev/null || stat -c%Y "$_ctt" 2>/dev/null || echo 0) ) / 86400 ))
    echo "${_dry_label}  cargo-test-target: ${_ctt} (${_ctt_age}d old, ~$(( _ctt_size / 1024 / 1024 ))MB)"
    if [[ $EXECUTE -eq 1 ]]; then
        rm -rf "$_ctt" 2>/dev/null || true
    fi
    _total_bytes=$(( _total_bytes + _ctt_size ))
    _reaped_count=$(( _reaped_count + 1 ))
    _cargo_test_target_count=$(( _cargo_test_target_count + 1 ))
    printf '{"ts":"%s","kind":"cargo_target_reaped","path":"%s","bytes_freed":%d,"age_days":%d,"dry_run":%s,"class":"cargo_test_target"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_ctt" "$_ctt_size" "$_ctt_age" \
        "$([[ $EXECUTE -eq 1 ]] && echo 'false' || echo 'true')" \
        >> "$AMBIENT_LOG" 2>/dev/null || true
done

# ── (g) INFRA-2125/C: lease-active worktrees with pushed+auto-merge PR ──────
# Reap target/ in a worktree that has an active lease IF:
#   1. A PR exists for the branch
#   2. That PR has autoMergeRequest != null (auto-merge armed)
#   3. Local HEAD matches origin/<branch> (work is safely on origin)
# Reasoning: work is on origin; rebuild cost is bounded if CI bounces.
_lease_armed_count=0
echo "[cargo-target-reaper] Scanning lease-active worktrees for pushed+auto-merge PRs (Class C)…"
for _lease_file in "${REPO_ROOT}/.chump-locks"/*.json; do
    [[ -f "$_lease_file" ]] || continue
    _lease_wt=$(python3 -c "import json,sys; d=json.load(open('$_lease_file')); print(d.get('worktree',''))" 2>/dev/null || true)
    [[ -n "$_lease_wt" ]] || continue
    _lease_target="${_lease_wt}/target"
    [[ -d "$_lease_target" ]] || continue

    # RESILIENT-116: honor the .chump-no-reap escape hatch — a pushed +
    # auto-merge-armed PR can still have a build actively running (e.g. a
    # local re-test after push) racing this class-C reap.
    if [[ -e "${_lease_wt}/.chump-no-reap" ]]; then
        printf '{"ts":"%s","kind":"target_reap_skipped","worktree":"%s","reason":"no_reap_marker"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_lease_target" \
            >> "$AMBIENT_LOG" 2>/dev/null || true
        echo "  skip (.chump-no-reap present): ${_lease_target}"
        continue
    fi

    # RESILIENT-116: active cargo lock or fresh mtime means a build may be
    # mid-flight in this worktree; do not race it even if the PR is pushed.
    if [[ -f "${_lease_target}/.cargo-lock" ]]; then
        printf '{"ts":"%s","kind":"target_reap_skipped","worktree":"%s","reason":"active_build"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_lease_target" \
            >> "$AMBIENT_LOG" 2>/dev/null || true
        echo "  skip (cargo lock active — transient): ${_lease_target}"
        continue
    fi
    if command -v lsof >/dev/null 2>&1 && lsof -F n +D "$_lease_target" 2>/dev/null | grep -q .; then
        printf '{"ts":"%s","kind":"target_reap_skipped","worktree":"%s","reason":"active_build"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_lease_target" \
            >> "$AMBIENT_LOG" 2>/dev/null || true
        echo "  skip (process has files open — active build): ${_lease_target}"
        continue
    fi

    # Get branch name from worktree
    _branch=$(git -C "$_lease_wt" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    [[ -n "$_branch" ]] || continue

    # Check: does a PR exist for this branch? (INFRA-1081: cache-first)
    _pr_json=""
    if command -v cache_lookup_pr_by_branch >/dev/null 2>&1; then
        _pr_json=$(cache_lookup_pr_by_branch "$_branch" 2>/dev/null || true)
        if [[ -n "$_pr_json" ]]; then
            _pr_json="[$_pr_json]" # wrap in array to match gh pr list --json output shape
        fi
    fi

    if [[ -z "$_pr_json" ]]; then
        _pr_json=$(gh pr list --head "$_branch" --json number,autoMergeRequest,headRefOid --limit 1 2>/dev/null || true)
    fi
    [[ -n "$_pr_json" ]] || continue
    _pr_count=$(echo "$_pr_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d))" 2>/dev/null || echo 0)
    [[ "$_pr_count" -gt 0 ]] || continue

    # Check: auto-merge armed?
    _auto_merge=$(echo "$_pr_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print('yes' if d[0].get('autoMergeRequest') else 'no')" 2>/dev/null || echo no)
    [[ "$_auto_merge" == "yes" ]] || continue

    # Check: local HEAD matches remote tip?
    _local_head=$(git -C "$_lease_wt" rev-parse HEAD 2>/dev/null || true)
    _remote_head=$(git -C "$_lease_wt" rev-parse "origin/${_branch}" 2>/dev/null || true)
    [[ -n "$_local_head" && -n "$_remote_head" ]] || continue
    [[ "$_local_head" == "$_remote_head" ]] || continue

    _lt_size=$(du -sk "$_lease_target" 2>/dev/null | awk '{print $1 * 1024}' || echo 0)
    _lt_age=$(( ( $(date +%s) - $(stat -f%m "$_lease_target" 2>/dev/null || stat -c%Y "$_lease_target" 2>/dev/null || echo 0) ) / 86400 ))
    _pr_num=$(echo "$_pr_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['number'])" 2>/dev/null || echo unknown)
    echo "${_dry_label}  lease+auto-merge target: ${_lease_target} (PR #${_pr_num} auto-merge armed, HEAD pushed, ${_lt_age}d old, ~$(( _lt_size / 1024 / 1024 ))MB)"
    if [[ $EXECUTE -eq 1 ]]; then
        rm -rf "$_lease_target" 2>/dev/null || true
    fi
    _total_bytes=$(( _total_bytes + _lt_size ))
    _reaped_count=$(( _reaped_count + 1 ))
    _lease_armed_count=$(( _lease_armed_count + 1 ))
    printf '{"ts":"%s","kind":"cargo_target_reaped","path":"%s","bytes_freed":%d,"age_days":%d,"dry_run":%s,"class":"lease_auto_merge","pr_number":%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_lease_target" "$_lt_size" "$_lt_age" \
        "$([[ $EXECUTE -eq 1 ]] && echo 'false' || echo 'true')" "$_pr_num" \
        >> "$AMBIENT_LOG" 2>/dev/null || true
done

# ── (h) INFRA-2188: chump-runner cargo-target cache ─────────────────────────
# The self-hosted runner sets CARGO_TARGET_DIR=~/.cache/chump-runner/cargo-target
# and accumulates 40-60GB there unbounded. It's never a worktree path so (c)/(d)
# miss it. We mirror the (a+b) pattern but key the safety guard on per-profile
# hot-binary mtime: if any chump-* binary in the profile dir was touched within
# the last RUNNER_HOT_BIN_AGE_H hours, skip that profile (runner job in flight).
_runner_scope_count=0
if [[ -d "$RUNNER_CACHE_BASE" ]]; then
    echo "[cargo-target-reaper] Scanning ${RUNNER_CACHE_BASE}/{debug,release} (runner-scope; hot-touch guard ${RUNNER_HOT_BIN_AGE_H}h)…"
    for _profile in debug release; do
        _prof_dir="${RUNNER_CACHE_BASE}/${_profile}"
        [[ -d "$_prof_dir" ]] || continue

        # Hot-touch guard: scan top-level chump-* binaries (no extension) for
        # any mtime newer than RUNNER_HOT_BIN_AGE_H hours. If hot, skip.
        _hot=0
        _hot_age_s=$(( RUNNER_HOT_BIN_AGE_H * 3600 ))
        _now_epoch=$(date +%s)
        while IFS= read -r -d '' _bin; do
            [[ -f "$_bin" ]] || continue
            # Skip .d / .rlib / .rmeta / dirs
            case "$_bin" in *.d|*.rlib|*.rmeta) continue ;; esac
            _bmtime=$(stat -f%m "$_bin" 2>/dev/null || stat -c%Y "$_bin" 2>/dev/null || echo 0)
            if [[ $(( _now_epoch - _bmtime )) -lt $_hot_age_s ]]; then
                _hot=1
                echo "  skip (${_profile}: hot binary $(basename "$_bin") <${RUNNER_HOT_BIN_AGE_H}h)"
                break
            fi
        done < <(find "$_prof_dir" -mindepth 1 -maxdepth 1 -name 'chump*' -type f -print0 2>/dev/null)
        [[ $_hot -eq 1 ]] && continue

        # Reap .fingerprint/* > FLEET_AGE_D
        if [[ -d "${_prof_dir}/.fingerprint" ]]; then
            while IFS= read -r -d '' _entry; do
                _rs_size=$(du -sk "$_entry" 2>/dev/null | awk '{print $1 * 1024}' || echo 0)
                _rs_age=$(( ( _now_epoch - $(stat -f%m "$_entry" 2>/dev/null || stat -c%Y "$_entry" 2>/dev/null || echo 0) ) / 86400 ))
                echo "${_dry_label}  runner-scope reap: ${_entry} (${_rs_age}d old, ~$(( _rs_size / 1024 / 1024 ))MB)"
                if [[ $EXECUTE -eq 1 ]]; then
                    rm -rf "$_entry" 2>/dev/null || true
                fi
                _total_bytes=$(( _total_bytes + _rs_size ))
                _reaped_count=$(( _reaped_count + 1 ))
                _runner_scope_count=$(( _runner_scope_count + 1 ))
                printf '{"ts":"%s","kind":"cargo_target_reaped","path":"%s","bytes_freed":%d,"age_days":%d,"dry_run":%s,"class":"runner_cache","profile":"%s"}\n' \
                    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_entry" "$_rs_size" "$_rs_age" \
                    "$([[ $EXECUTE -eq 1 ]] && echo 'false' || echo 'true')" "$_profile" \
                    >> "$AMBIENT_LOG" 2>/dev/null || true
            done < <(find "${_prof_dir}/.fingerprint" -mindepth 1 -maxdepth 1 -mtime "+${FLEET_AGE_D}" -print0 2>/dev/null)
        fi

        # Reap deps/lib*.rlib > FLEET_AGE_D
        if [[ -d "${_prof_dir}/deps" ]]; then
            while IFS= read -r -d '' _entry; do
                _rs_size=$(stat -f%z "$_entry" 2>/dev/null || stat -c%s "$_entry" 2>/dev/null || echo 0)
                _rs_age=$(( ( _now_epoch - $(stat -f%m "$_entry" 2>/dev/null || stat -c%Y "$_entry" 2>/dev/null || echo 0) ) / 86400 ))
                echo "${_dry_label}  runner-scope reap: ${_entry} (${_rs_age}d old, ~$(( _rs_size / 1024 / 1024 ))MB)"
                if [[ $EXECUTE -eq 1 ]]; then
                    rm -f "$_entry" 2>/dev/null || true
                fi
                _total_bytes=$(( _total_bytes + _rs_size ))
                _reaped_count=$(( _reaped_count + 1 ))
                _runner_scope_count=$(( _runner_scope_count + 1 ))
                printf '{"ts":"%s","kind":"cargo_target_reaped","path":"%s","bytes_freed":%d,"age_days":%d,"dry_run":%s,"class":"runner_cache","profile":"%s"}\n' \
                    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_entry" "$_rs_size" "$_rs_age" \
                    "$([[ $EXECUTE -eq 1 ]] && echo 'false' || echo 'true')" "$_profile" \
                    >> "$AMBIENT_LOG" 2>/dev/null || true
            done < <(find "${_prof_dir}/deps" -maxdepth 1 -name 'lib*.rlib' -mtime "+${FLEET_AGE_D}" -print0 2>/dev/null)
        fi
    done
fi

# ── (i) INFRA-7890: orphaned root-level .cargo-test-target / .cargo-build-target ──
# Per-worktree build dirs (INFRA-1138 / INFRA-1374) are meant to live inside a
# linked worktree under /tmp/chump-* (reaped by class f above). The main
# checkout at $REPO_ROOT is never itself claimed as a worktree, so a
# .cargo-test-target or .cargo-build-target directly under $REPO_ROOT is a
# leftover from a direct (non-worktree) test/build run — now superseded by the
# shared sccache rustc-wrapper cache, so it's pure orphaned waste rather than a
# live per-worktree cache. Gated the same way as class (g): skip if a cargo
# lock or open fd suggests a build is mid-flight.
_root_orphan_target_count=0
for _root_ctt in "${REPO_ROOT}/.cargo-test-target" "${REPO_ROOT}/.cargo-build-target"; do
    [[ -d "$_root_ctt" ]] || continue
    _rctt_age=$(( ( $(date +%s) - $(stat -f%m "$_root_ctt" 2>/dev/null || stat -c%Y "$_root_ctt" 2>/dev/null || echo 0) ) / 86400 ))
    if [[ $_rctt_age -le $FLEET_AGE_D ]]; then
        echo "  skip (root cargo target <${FLEET_AGE_D}d old): ${_root_ctt}"
        continue
    fi
    if [[ -f "${_root_ctt}/.cargo-lock" ]]; then
        echo "  skip (cargo lock active — transient): ${_root_ctt}"
        continue
    fi
    if command -v lsof >/dev/null 2>&1 && lsof -F n +D "$_root_ctt" 2>/dev/null | grep -q .; then
        echo "  skip (process has files open — active build): ${_root_ctt}"
        continue
    fi
    _rctt_size=$(du -sk "$_root_ctt" 2>/dev/null | awk '{print $1 * 1024}' || echo 0)
    echo "${_dry_label}  root orphaned cargo target: ${_root_ctt} (${_rctt_age}d old, ~$(( _rctt_size / 1024 / 1024 ))MB)"
    if [[ $EXECUTE -eq 1 ]]; then
        rm -rf "$_root_ctt" 2>/dev/null || true
    fi
    _total_bytes=$(( _total_bytes + _rctt_size ))
    _reaped_count=$(( _reaped_count + 1 ))
    _root_orphan_target_count=$(( _root_orphan_target_count + 1 ))
    printf '{"ts":"%s","kind":"cargo_target_reaped","path":"%s","bytes_freed":%d,"age_days":%d,"dry_run":%s,"class":"root_orphan_cargo_target"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_root_ctt" "$_rctt_size" "$_rctt_age" \
        "$([[ $EXECUTE -eq 1 ]] && echo 'false' || echo 'true')" \
        >> "$AMBIENT_LOG" 2>/dev/null || true
done

# ── (j) RESILIENT-1620: Class D — merged/closed lease-less dispatch worktrees ─
run_class_d

# ── Summary ──────────────────────────────────────────────────────────────────
_total_mb=$(( _total_bytes / 1024 / 1024 ))
echo ""
echo "[cargo-target-reaper] ${_dry_label} Done: ${_reaped_count} artifacts, ~${_total_mb}MB (orphaned /tmp worktrees: ${_tmp_orphan_count}, runner-scope: ${_runner_scope_count}, class-D: ${_classd_count})"
if [[ $EXECUTE -eq 0 && $_reaped_count -gt 0 ]]; then
    echo "[cargo-target-reaper] Re-run with --execute to actually delete."
fi

# Summary ambient event — includes worktree_orphan_count (INFRA-1170) + INFRA-2125 class counts + INFRA-2188 runner_scope_count + INFRA-7890 root_orphan_target_count + aggressive_mode flag.
_target_paths_scanned=$(( ${_reaped_count:-0} + ${_tmp_orphan_count:-0} + ${_runner_scope_count:-0} + ${_root_orphan_target_count:-0} + ${_classd_count:-0} + 1 ))
printf '{"ts":"%s","kind":"cargo_target_reaper_summary","reaped_count":%d,"bytes_freed":%d,"execute":%s,"worktree_orphan_count":%d,"cross_build_count":%d,"cargo_test_target_count":%d,"lease_auto_merge_count":%d,"runner_scope_count":%d,"root_orphan_target_count":%d,"class_d_count":%d,"aggressive_mode":%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_reaped_count" "$_total_bytes" \
    "$([[ $EXECUTE -eq 1 ]] && echo 'true' || echo 'false')" \
    "$_tmp_orphan_count" "$_cross_build_count" "$_cargo_test_target_count" "$_lease_armed_count" \
    "$_runner_scope_count" "$_root_orphan_target_count" "$_classd_count" \
    "$([[ $AGGRESSIVE_MODE -eq 1 ]] && echo 'true' || echo 'false')" \
    >> "$AMBIENT_LOG" 2>/dev/null || true
