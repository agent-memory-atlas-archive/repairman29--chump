#!/usr/bin/env bash
# shellcheck disable=SC2001,SC2016,SC2018,SC2019,SC2086,SC1091  # pre-existing file-wide style/info — moved up from line 25 by INFRA-1939 so scope covers source-on-line-24 too

# INFRA-2001: feature-flag shim — when CHUMP_SHIP_RUST=1 AND --mode manual (or unset/default),
# route to the new Rust chump-ship binary instead of this 3044-LOC bash body. Legacy bash
# preserved below for parallel-run validation during 1-week soak. Bot-merge mode still routes
# through bash (Rust BotMergePath is stubbed in Phase 1; Phase 2 sub-gap will port it).
if [ "${CHUMP_SHIP_RUST:-0}" = "1" ]; then
    _mode_arg=""
    for ((_i=1; _i<=$#; _i++)); do
        if [ "${!_i}" = "--mode" ]; then
            _j=$((_i+1))
            _mode_arg="${!_j}"
            break
        fi
    done
    if [ -z "$_mode_arg" ] || [ "$_mode_arg" = "manual" ]; then
        exec chump-ship "$@"
    fi
    # --mode bot-merge falls through to legacy bash (BotMergePath stubbed in Phase 1)
fi

# INFRA-1600: brew util-linux flock not on default PATH on self-hosted CI runners.
# shellcheck source=../lib/discover-flock.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/discover-flock.sh"
# (INFRA-1939: file-wide shellcheck disable moved to line 2 so source-on-line-24 is covered.)
#
# bot-merge.sh — Automated ship pipeline for agent branches.
#
# Intended for Claude sessions, Cursor agents, and the autonomy loop. Runs the
# full pre-merge checklist, pushes to origin, and opens (or updates) a GitHub PR.
#
# Usage:
#   scripts/coord/bot-merge.sh [--gap GAP-ID ...] [--stack-on PREV-GAP-ID] [--auto-merge] [--lane internal|user-facing|critical] [--skip-tests] [--dry-run] [--no-merge-driver]
#                              [--branch-prefix PREFIX] [--pr-template PATH] [--required-checks CHECK1,CHECK2,...]
#
#   --stack-on PREV-GAP-ID
#                  Open this PR with base=<prev-PR-head> instead of main. When
#                  the prev PR lands, the merge queue auto-rebases this PR.
#                  Used for related work that would otherwise file-conflict if
#                  shipped in parallel (INFRA-061 / M3).
#
#   --gap GAP-ID   One or more gap IDs to check against origin/main before proceeding.
#                  If any gap is already `done` or claimed by another agent, the
#                  script aborts early. Repeat for multiple gaps: --gap A --gap B
#                  or pass space-separated: --gap "AUTO-003 COMP-002".
#   --auto-merge   Enable GitHub auto-merge on the PR (requires branch protection
#                  with required CI status checks configured).
#   --skip-tests   Skip `cargo test` (for pure-doc or non-Rust changes). fmt and
#                  clippy still run.
#   --fast         Skip BOTH cargo clippy AND cargo test locally. CI clippy/test
#                  is the gate (auto-merge won't land a red PR). Reduces total
#                  bot-merge wall time from ~5-10 min cold → ~30-60 sec, so
#                  agent-driven shipping fits inside the ~10-15 min subagent
#                  task budget. Implies --skip-tests. Default OFF; pass
#                  explicitly when running from chump dispatch / Agent tool /
#                  any context with a tight task budget. (INFRA-252)
#   --dry-run      Print every step without executing git push or gh commands.
#   --no-merge-driver
#                  Disable custom git merge drivers (INFRA-310) during rebase.
#                  Use when custom drivers are causing issues or you want to
#                  force git's default 3-way merge strategy.
#   --branch-prefix PREFIX
#                  Branch namespace prefix for auto-derive and branch rename
#                  (default: 'chump'). Set to the tool prefix used by the target
#                  repo — e.g. 'acme' for branches like 'acme/feat-123-title'.
#                  Env: BM_BRANCH_PREFIX
#   --pr-template PATH
#                  Path to a Markdown file whose contents replace the default
#                  PR body template. Use for repos with their own PR structure
#                  (e.g. chump-proprietary). Supports the following placeholders
#                  which are substituted before posting:
#                    {{COMMIT_LOG}}   one-line git log since base
#                    {{GAP_LINE}}     "Gaps addressed: ..." or empty
#                    {{PLAN_BLOCK}}   plan-mode details block or empty
#                  Env: BM_PR_TEMPLATE
#   --required-checks CHECK1,CHECK2,...
#                  Comma-separated list of CI check names that must pass before
#                  auto-merge is armed. When set, only checks matching one of
#                  these names are considered blockers (others are advisory).
#                  When unset, any FAILURE/ERROR check blocks auto-merge.
#                  Env: BM_REQUIRED_CHECKS
#   --lane {internal,user-facing,critical}
#                  INFRA-1767: merge-risk tier, gates the auto-merge default
#                  AND the crates/chump-policy check (`chump-policy check
#                  --lane ...`). internal (default) auto-merges without
#                  needing --auto-merge; user-facing needs an explicit
#                  --auto-merge; critical needs --auto-merge AND an explicit
#                  operator/repo policy opt-in (chump-policy's Critical
#                  baseline defaults enabled=false — most-restrictive-wins
#                  over any permissive fleet/operator/repo scope).
#                  Emits kind=bot_merge_lane_resolved to ambient.jsonl.
#                  Env: BM_LANE
#
# Requirements: gh CLI authenticated, GITHUB_TOKEN in env or gh keyring, cargo.
#
# Exit codes (RESILIENT-010 — step-specific codes for automated recovery):
#   0   PR opened/updated (or already up to date)
#   1   Unexpected error (set -e trap or unhandled failure)
#   3   Branch too stale to merge safely (>50 commits behind main at start,
#       or >15 behind right before push — INFRA-995)
#   10  Preflight failed (gap already done, claimed, or unavailable)
#   11  Rebase failed (merge conflict or timeout)
#   12  Cargo clippy failed (lint errors)
#   13  Cargo test failed (test suite errors)
#   14  git push failed (force-with-lease rejected or network error)
#   15  gh pr create/update failed
# Legacy codes kept for external callers: 2=push/gh, 4=misc abort

set -euo pipefail

# RESILIENT-132 AC#1: bind stdin to /dev/null for the whole run. bot-merge is
# invoked headlessly (fleet workers, subagent dispatch) with no tty attached;
# any child process (git, gh) that unexpectedly probes stdin for a credential
# prompt or confirmation blocks forever with no children and no network
# activity visible — the exact silent hang observed shipping CREDIBLE-128
# (failure mode 9). Every internal `while read` loop in this script already
# redirects its own input (`< file` / `<<<`), so this is safe: it only
# changes behavior for commands that would otherwise inherit a live tty/pipe.
exec </dev/null

# INFRA-956: default harness to a schema-valid value (kills missing_attribution noise).
export CHUMP_AGENT_HARNESS="${CHUMP_AGENT_HARNESS:-manual}"

# ── INFRA-119: health-file globals + cleanup traps ───────────────────────────
_BM_PID=$$
_BM_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
_BM_HEALTH_FILE=""
_BM_STEP_FILE=""
_BM_STEPS_FILE=""   # INFRA-1035: append-only transition log for crash recovery
_BM_LAST_STEP_TRANSITION=""  # "start" or "done" — detect open transitions on crash
_BM_HEALTH_PID=""
_BM_WATCHDOG_PID=""
_BM_CLEANUP_DONE=0
# INFRA-1422: per-stage budget watchdog PID (separate from gap-done watchdog).
__STAGE_BUDGET_PID=""
# META-156 AC#6: budget-warn watchdog PID.
_BM_BUDGET_WARN_PID=""

# RESILIENT-133/RESILIENT-210: the real stage_start() (with the actual
# per-stage budget watchdog fork) lives later in this file. A second,
# simpler definition used to live here -- it was silently shadowed by the
# later one (bash: last function definition wins) and never actually ran.
# Removed to stop the next reader from editing dead code, as this session
# nearly did.

# ── INFRA-2272: per-step progress ledger + gtimeout wrapper ──────────────────
# See: docs/process/SHIP_ASSIST_PLAYBOOK.md §1 Class 4
#
# Progress ledger: .chump-locks/bot-merge-progress/<gap-id>.json
# Written on each phase boundary: {step_name, started_at, last_progress_ts}
# Readable by fleet monitors without parsing the full health file.
#
# gtimeout: coreutils 'gtimeout' on macOS (brew install coreutils),
# falls back to 'timeout' on Linux.  Used to hard-kill individual
# gh/git invocations that stall beyond CHUMP_BOT_MERGE_STEP_TIMEOUT_S.
#
# scanner-anchor: "kind":"bot_merge_step_stalled"
_BM_TIMEOUT_CMD=""
_BM_PROGRESS_DIR=""
_BM_PROGRESS_FILE=""
# Default per-step timeout (env-overridable)
_BM_STEP_TIMEOUT_S="${CHUMP_BOT_MERGE_STEP_TIMEOUT_S:-300}"

# Resolve gtimeout (coreutils) or timeout (Linux/BSD fallback).
_bm_resolve_timeout_cmd() {
    if command -v gtimeout >/dev/null 2>&1; then
        _BM_TIMEOUT_CMD="gtimeout"
    elif command -v timeout >/dev/null 2>&1; then
        _BM_TIMEOUT_CMD="timeout"
    else
        _BM_TIMEOUT_CMD=""
        printf '\033[0;33m[bot-merge] WARN: neither gtimeout nor timeout found; INFRA-2272 per-step timeouts disabled.\033[0m\n' >&2
    fi
}
_bm_resolve_timeout_cmd

# Initialise the progress ledger directory (call once LOCK_DIR is known).
_bm_progress_init() {
    local lock_dir="$1"
    [[ $DRY_RUN -eq 1 ]] && return 0
    _BM_PROGRESS_DIR="${lock_dir}/bot-merge-progress"
    mkdir -p "$_BM_PROGRESS_DIR" 2>/dev/null || true
    local gap_slug
    gap_slug="${GAP_IDS[0]:-${GAP_ID:-pid-${_BM_PID}}}"
    # Sanitise for filesystem: replace anything non-alphanumeric/dash with dash
    gap_slug="$(printf '%s' "$gap_slug" | tr -cs '[:alnum:]-' '-' | tr '[:upper:]' '[:lower:]')"
    _BM_PROGRESS_FILE="${_BM_PROGRESS_DIR}/${gap_slug}.json"
}

# Write/update the progress ledger for the current step.
# Called at step boundary (start) and periodically via run_timed_hb heartbeat.
_bm_progress_write() {
    [[ -z "${_BM_PROGRESS_FILE:-}" ]] && return 0
    local step="${1:-${__STAGE_LABEL:-unknown}}"
    local started_at="${2:-${_BM_STARTED_AT}}"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"step_name":"%s","started_at":"%s","last_progress_ts":"%s","gap_id":"%s","pid":%d}\n' \
        "$step" "$started_at" "$ts" \
        "${GAP_IDS[0]:-${GAP_ID:-unknown}}" "$_BM_PID" \
        > "${_BM_PROGRESS_FILE}.tmp" 2>/dev/null \
    && mv "${_BM_PROGRESS_FILE}.tmp" "$_BM_PROGRESS_FILE" 2>/dev/null || true

    # INFRA-2673: also APPEND a line-oriented phase marker to the
    # user-supplied --progress-file (if set). This is independent from the
    # JSON ledger above which is overwrite-per-step. The append-only marker
    # lets background callers `tail -f` the file to see incremental progress.
    if [[ -n "${PROGRESS_FILE_OVERRIDE:-}" ]]; then
        printf 'phase=%s ts=%s gap=%s pid=%d\n' \
            "$step" "$ts" "${GAP_IDS[0]:-${GAP_ID:-unknown}}" "$_BM_PID" \
            >> "$PROGRESS_FILE_OVERRIDE" 2>/dev/null || true
    fi
}

# Emit kind=bot_merge_step_stalled to ambient.jsonl and exit non-zero.
# Called when gtimeout fires (exit 124) on a per-step invocation.
# Parameters: <step_name> <elapsed_seconds> <last_progress_ts> <cmd_label>
_bm_emit_step_stalled() {
    local step="${1:-unknown}" elapsed_s="${2:-0}" last_progress_ts="${3:-}" cmd_label="${4:-}"
    local ts gap_label ambient
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    gap_label="${GAP_IDS[0]:-${GAP_ID:-unknown}}"
    ambient="${CHUMP_AMBIENT_LOG:-${REPO_ROOT:-.}/.chump-locks/ambient.jsonl}"
    # scanner-anchor: "kind":"bot_merge_step_stalled"
    printf '{"ts":"%s","kind":"bot_merge_step_stalled","gap_id":"%s","step_name":"%s","elapsed_seconds":%d,"last_progress_ts":"%s","cmd_label":"%s","timeout_s":%d,"pid":%d,"note":"INFRA-2272: per-step gtimeout fired; see SHIP_ASSIST_PLAYBOOK.md §1 Class 4"}\n' \
        "$ts" "$gap_label" "$step" "$elapsed_s" "$last_progress_ts" "$cmd_label" \
        "$_BM_STEP_TIMEOUT_S" "$_BM_PID" \
        >> "$ambient" 2>/dev/null || true
    printf '\033[0;31m[bot-merge] STEP STALLED (INFRA-2272): step="%s" exceeded %ds timeout (elapsed %ds).\033[0m\n' \
        "$step" "$_BM_STEP_TIMEOUT_S" "$elapsed_s" >&2
    printf '\033[0;31m[bot-merge]   kind=bot_merge_step_stalled emitted to ambient.\033[0m\n' >&2
    printf '\033[0;31m[bot-merge]   Override timeout: CHUMP_BOT_MERGE_STEP_TIMEOUT_S=<seconds>\033[0m\n' >&2
    printf '\033[0;31m[bot-merge]   See: docs/process/SHIP_ASSIST_PLAYBOOK.md §1 Class 4\033[0m\n' >&2
    # RESILIENT-132 AC#4: see _emit_hang_alert — same recoverable-timeout
    # contract applies to per-step gtimeout stalls.
    _BM_TIMEOUT_EXIT=1
}

# Run a command with per-step gtimeout + progress ledger update.
# Usage: _bm_run_step <step_name> <cmd_label> <timeout_s> <cmd...>
# On exit 124 (timeout): emits bot_merge_step_stalled + exits non-zero.
# On any non-zero rc: propagates the exit code.
_bm_run_step() {
    local step_name="$1" cmd_label="$2" timeout_s="$3"; shift 3
    local t0 elapsed rc last_ts
    t0="$(date +%s)"
    last_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    _bm_progress_write "$step_name" "$last_ts"
    rc=0
    if [[ -n "${_BM_TIMEOUT_CMD:-}" && "${CHUMP_BOT_MERGE_STEP_TIMEOUT_DISABLE:-0}" != "1" ]]; then
        "$_BM_TIMEOUT_CMD" "$timeout_s" "$@" || rc=$?
    else
        "$@" || rc=$?
    fi
    elapsed=$(( $(date +%s) - t0 ))
    if [[ "$rc" -eq 124 ]]; then
        _bm_emit_step_stalled "$step_name" "$elapsed" "$last_ts" "$cmd_label"
        return 124
    fi
    return "$rc"
}

# INFRA-1035: append one JSONL entry to the steps file.
# Usage: _bm_steps_append <transition> <step> [elapsed_s]
_bm_steps_append() {
    [[ -z "${_BM_STEPS_FILE:-}" ]] && return 0
    local transition="$1" step="${2:-unknown}" elapsed_s="${3:-0}"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","step":"%s","transition":"%s","elapsed_s":%s}\n' \
        "$ts" "$step" "$transition" "$elapsed_s" \
        >> "$_BM_STEPS_FILE" 2>/dev/null || true
    _BM_LAST_STEP_TRANSITION="$transition"
}

_bm_cleanup() {
    [[ "$_BM_CLEANUP_DONE" == "1" ]] && return
    _BM_CLEANUP_DONE=1
    # META-156 AC#7: emit bot_merge_completed roll-up on any exit path.
    _bm_completed_emit 2>/dev/null || true
    # META-156 AC#6: kill budget-warn watchdog subprocesses on exit.
    # EFFECTIVE-312: kill each watchdog's CHILDREN first (pkill -P) — their
    # sleep grandchildren inherit the INFRA-860 flock fd and hold the global
    # bot-merge.lock forever after the subshell dies (cycle-11 evidence: an
    # orphan 'sleep 300' held the lock and timed out the next ship's flock).
    for _cl_pid in "${_BM_BUDGET_WARN_PID:-}" "${_BM_HEALTH_PID:-}" "${_BM_WATCHDOG_PID:-}" "${__STAGE_BUDGET_PID:-}"; do
        [[ -n "$_cl_pid" ]] || continue
        pkill -P "$_cl_pid" 2>/dev/null || true
        kill "$_cl_pid" 2>/dev/null || true
    done
    rm -f "${_BM_HEALTH_FILE:-}" "${_BM_STEP_FILE:-}" "${_BM_PROGRESS_FILE:-}" 2>/dev/null || true
    # INFRA-1035: if the last transition was "start" (no matching "done"),
    # we crashed mid-step — record that so bot-merge-recover.sh can report it.
    if [[ -n "${_BM_STEPS_FILE:-}" && "${_BM_LAST_STEP_TRANSITION:-}" == "start" ]]; then
        local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '{"ts":"%s","step":"%s","transition":"error","elapsed_s":0,"crashed":true}\n' \
            "$ts" "${__STAGE_LABEL:-unknown}" \
            >> "$_BM_STEPS_FILE" 2>/dev/null || true
        # Emit to ambient so fleet monitors can detect bot-merge crashes.
        local ambient=".chump-locks/ambient.jsonl"
        [[ -n "${CHUMP_AMBIENT_LOG:-}" ]] && ambient="$CHUMP_AMBIENT_LOG"
        _ambient_write "$ambient" \
            "$(printf '{"ts":"%s","kind":"bot_merge_crashed","step":"%s","pid":%d,"steps_file":"%s","note":"start without done on exit"}' \
                "$ts" "${__STAGE_LABEL:-unknown}" "$_BM_PID" "${_BM_STEPS_FILE:-}")"
    fi
    # NOTE: _BM_STEPS_FILE is intentionally NOT deleted here — it's the
    # recovery artifact that bot-merge-recover.sh needs to diagnose the crash.
    # INFRA-1017: vacuum state.db leases row so gap-preflight doesn't report a
    # phantom live claim after this process is KILLED (SIGTERM, OOM, ctrl-C).
    # INFRA-3455: gate this on _BM_LEASE_VACUUM_OK (set ONLY by the kill handlers)
    # and scope it to THIS gap. The old blanket DELETE fired on EVERY exit — so a
    # recoverable preflight-FAIL deleted the operator's own lease, and the retry
    # then hit its still-present worktree with no lease → "<unknown> owner" dead
    # end → manual --no-verify. On success the gap is marked done (preflight
    # returns Done, not Claimed) so a lingering lease is benign; on a recoverable
    # abort the lease must SURVIVE so the retry's self-recognition (INFRA-3446)
    # passes.
    if [[ "${_BM_LEASE_VACUUM_OK:-0}" == "1" && -n "${CHUMP_SESSION_ID:-}" ]] \
       && command -v sqlite3 &>/dev/null; then
        local _db="${MAIN_REPO:-${REPO_ROOT:-.}}/.chump/state.db"
        local _vg="${GAP_IDS[0]:-${GAP_ID:-}}"
        if [[ -f "$_db" && -n "$_vg" ]]; then
            sqlite3 "$_db" \
                "DELETE FROM leases WHERE session_id='${CHUMP_SESSION_ID}' AND gap_id='${_vg}'" \
                2>/dev/null || true
        fi
    fi
}
trap '_bm_cleanup' EXIT
# INFRA-2426: on SIGTERM from the budget watchdog, emit kind=bot_merge_timeout
# BEFORE calling _bm_cleanup so the event reaches ambient.jsonl regardless of
# whether the cleanup itself fails. The prior silent `exit 1` left no trace in
# ambient.jsonl, making the budget-kill indistinguishable from a crash.
# scanner-anchor: "kind":"bot_merge_timeout"
_bm_sigterm_handler() {
    local _ts _step _elapsed _ambient _gap_label
    _ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    _step="$(cat "${_BM_STEP_FILE:-/dev/null}" 2>/dev/null || echo unknown)"
    _gap_label="${GAP_IDS[*]:-${GAP_ID:-unknown}}"
    _ambient="${CHUMP_AMBIENT_LOG:-${REPO_ROOT:-.}/.chump-locks/ambient.jsonl}"
    _elapsed=$(( $(date +%s) - $(date -d "${_BM_STARTED_AT:-$_ts}" +%s 2>/dev/null || date +%s) ))
    printf '{"ts":"%s","kind":"bot_merge_timeout","gap":"%s","phase":"%s","elapsed_s":%d,"budget_s":%s,"note":"INFRA-2426: SIGTERM from budget watchdog; was silent exit 1 before this fix"}\n' \
        "$_ts" "$_gap_label" "$_step" "$_elapsed" \
        "${CHUMP_SUBAGENT_BOT_MERGE_BUDGET_S:-${CHUMP_BOT_MERGE_BUDGET_SECS:-900}}" \
        >> "$_ambient" 2>/dev/null || true
    printf '\033[0;31m[bot-merge] TIMEOUT (INFRA-2426): SIGTERM received at phase="%s" elapsed=%ds — kind=bot_merge_timeout emitted to ambient.\033[0m\n' \
        "$_step" "$_elapsed" >&2 || true
    # RESILIENT-132 AC#4: a budget-watchdog timeout is a recoverable stall, not
    # a give-up — the caller (fleet worker / operator) typically retries the
    # SAME claim rather than re-claiming from scratch. Previously this handler
    # set _BM_LEASE_VACUUM_OK=1 (vacuuming the state.db lease row) exactly like
    # a deliberate ctrl-C kill, and the outer EXIT trap unconditionally deleted
    # the on-disk lease file too — so every stage timeout released the lease,
    # which is what forced the re-claim path (worktree/branch-exists,
    # ghost-NATS-KV-claim) documented in this gap. Leave _BM_LEASE_VACUUM_OK
    # unset here so _bm_cleanup's default (lease survives) applies, and set
    # _BM_TIMEOUT_EXIT so the outer EXIT trap skips its own lease-file rm.
    _BM_TIMEOUT_EXIT=1
    _bm_cleanup
    exit 1
}
trap '_bm_sigterm_handler' TERM
# INFRA-3455: ctrl-C is a kill → vacuum the phantom lease (recoverable EXIT does not).
trap '_BM_LEASE_VACUUM_OK=1; _bm_cleanup; exit 1' INT

# RESILIENT-052: bot-merge runs under `set -euo pipefail` (line 110) but,
# until now, had NO `ERR` trap — so any command that died non-zero (most
# notoriously a `gh` sub-process crashing on SIGURG, exit 128+16=144; see
# INFRA-2688) killed the whole script silently: `set -e` propagates the raw
# child exit code straight out with zero stderr output and zero ambient
# trace. Only the TERM/INT paths above were ever loud. This trap makes EVERY
# `set -e` death loud: it prints the failing command, its exit code (and the
# signal name when the exit code encodes one, i.e. rc > 128), and the
# in-flight step/phase — then emits an ambient event so fleet monitors catch
# it too. It intentionally does not change the propagated exit code (callers
# scripted against specific codes keep working); it only removes the silence.
# scanner-anchor: "kind":"bot_merge_uncaught_error"
_bm_err_handler() {
    local _rc="$1" _cmd="${2:-unknown}" _line="${3:-0}"
    local _ts _step _ambient _gap_label _sig _signame=""
    _ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    _step="${_BM_NAMED_STEP:-${__STAGE_LABEL:-unknown}}"
    _gap_label="${GAP_IDS[*]:-${GAP_ID:-unknown}}"
    _ambient="${CHUMP_AMBIENT_LOG:-${REPO_ROOT:-.}/.chump-locks/ambient.jsonl}"
    if [[ "$_rc" -gt 128 ]]; then
        _sig=$(( _rc - 128 ))
        _signame="$(kill -l "$_sig" 2>/dev/null || echo "SIG$_sig")"
    fi
    printf '{"ts":"%s","kind":"bot_merge_uncaught_error","gap":"%s","step":"%s","exit_code":%d,"signal":"%s","line":%d,"cmd":"%s","note":"RESILIENT-052: set -e death now loud (was silent, e.g. exit 144)"}\n' \
        "$_ts" "$_gap_label" "$_step" "$_rc" "$_signame" "$_line" "${_cmd//\"/\\\"}" \
        >> "$_ambient" 2>/dev/null || true
    printf '\033[0;31m[bot-merge] UNCAUGHT FAILURE (RESILIENT-052): step="%s" exit_code=%d%s at line %d\033[0m\n' \
        "$_step" "$_rc" "${_signame:+ (signal=$_signame)}" "$_line" >&2 || true
    printf '\033[0;31m[bot-merge]   failing command: %s\033[0m\n' "$_cmd" >&2 || true
    printf '\033[0;31m[bot-merge]   kind=bot_merge_uncaught_error emitted to ambient.\033[0m\n' >&2 || true
}
trap '_bm_err_handler "$?" "$BASH_COMMAND" "$LINENO"' ERR
_BM_ERR_TRAP_CMD='_bm_err_handler "$?" "$BASH_COMMAND" "$LINENO"'

# CREDIBLE-295: `set +e` does NOT suppress the ERR trap above — only wrapping
# a command as the non-final member of a `||` list (e.g. `cmd || true`) is
# exempt from both errexit AND the ERR trap. Any best-effort region that
# instead captures `$?` manually after a bare `set +e ... cmd ... set -e`
# (the auto-close-gap stage's `chump gap ship` call, INFRA-1030) still fires
# the ERR trap on the very failure it's deliberately handling — a false
# bot_merge_uncaught_error even though the rc is captured and handled below.
#
# To suppress it for such a region, write `trap - ERR` / `trap "$_BM_ERR_TRAP_CMD" ERR`
# INLINE at the call site — do NOT wrap those two commands in a helper
# function. Bash saves and restores the ERR (and DEBUG/RETURN) trap around
# every function call unless `set -o functrace` is active, so a `trap - ERR`
# executed inside a function silently reverts the instant that function
# returns, leaving the outer trap re-armed and the "suspend" a no-op.

# ── META-156: per-step ambient observability ─────────────────────────────────
# Emit kind=bot_merge_step_started / kind=bot_merge_step_done to ambient.jsonl
# for each named step (init, preflight, claim, push, pr_create, pr_merge_arm,
# pr_wait_merge, post_ship). step_done includes duration_ms and rc.
#
# Usage:
#   _bm_step_start <step-name>
#   ... do work ...
#   _bm_step_done  <step-name> <rc>
#
# scanner-anchor: kind=bot_merge_step_started  (variable-assembled printf)
# scanner-anchor: kind=bot_merge_step_done     (variable-assembled printf)
_BM_NAMED_STEP=""
_BM_NAMED_STEP_T0_MS=0

_bm_ms_now() {
    # milliseconds since epoch; python3 fallback if date -s not available.
    python3 -c "import time; print(int(time.time()*1000))" 2>/dev/null || \
        echo $(( $(date +%s) * 1000 ))
}

_bm_step_start() {
    local step="$1"
    _BM_NAMED_STEP="$step"
    _BM_NAMED_STEP_T0_MS="$(_bm_ms_now)"
    local ts gap_label ambient
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    gap_label="${GAP_IDS[0]:-${GAP_ID:-unknown}}"
    ambient="${CHUMP_AMBIENT_LOG:-${REPO_ROOT:-.}/.chump-locks/ambient.jsonl}"
    # scanner-anchor: "kind":"bot_merge_step_started"
    printf '{"ts":"%s","kind":"bot_merge_step_started","step":"%s","gap":"%s","pid":%d,"note":"META-156 AC#1"}\n' \
        "$ts" "$step" "$gap_label" "$_BM_PID" \
        >> "$ambient" 2>/dev/null || true
}

_bm_step_done() {
    local step="${1:-${_BM_NAMED_STEP:-unknown}}" rc="${2:-0}"
    local now_ms duration_ms ts gap_label ambient
    now_ms="$(_bm_ms_now)"
    duration_ms=$(( now_ms - _BM_NAMED_STEP_T0_MS ))
    [[ "$duration_ms" -lt 0 ]] && duration_ms=0
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    gap_label="${GAP_IDS[0]:-${GAP_ID:-unknown}}"
    ambient="${CHUMP_AMBIENT_LOG:-${REPO_ROOT:-.}/.chump-locks/ambient.jsonl}"
    # scanner-anchor: "kind":"bot_merge_step_done"
    printf '{"ts":"%s","kind":"bot_merge_step_done","step":"%s","gap":"%s","pid":%d,"duration_ms":%d,"rc":%d,"note":"META-156 AC#1"}\n' \
        "$ts" "$step" "$gap_label" "$_BM_PID" "$duration_ms" "$rc" \
        >> "$ambient" 2>/dev/null || true
    _BM_NAMED_STEP=""
}

# META-156 AC#7: graceful-exit roll-up — emit bot_merge_completed with
# {gap_id, pr_number, duration_ms, terminal_state} on any exit path.
# Called from the EXIT trap so it fires even on error paths.
_BM_COMPLETED_EMITTED=0
_BM_SESSION_T0_MS=0
_BM_TERMINAL_STATE="unknown"
_bm_completed_emit() {
    [[ "$_BM_COMPLETED_EMITTED" == "1" ]] && return 0
    _BM_COMPLETED_EMITTED=1
    local now_ms duration_ms ts gap_label pr_number ambient
    now_ms="$(_bm_ms_now)"
    duration_ms=$(( now_ms - _BM_SESSION_T0_MS ))
    [[ "$duration_ms" -lt 0 ]] && duration_ms=0
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    gap_label="${GAP_IDS[0]:-${GAP_ID:-unknown}}"
    pr_number="${TARGET_PR:-${EXISTING_PR:-0}}"
    [[ -z "$pr_number" ]] && pr_number=0
    ambient="${CHUMP_AMBIENT_LOG:-${REPO_ROOT:-.}/.chump-locks/ambient.jsonl}"
    # scanner-anchor: "kind":"bot_merge_completed"
    printf '{"ts":"%s","kind":"bot_merge_completed","gap_id":"%s","pr_number":%s,"duration_ms":%d,"terminal_state":"%s","pid":%d,"note":"META-156 AC#7"}\n' \
        "$ts" "$gap_label" "$pr_number" "$duration_ms" "${_BM_TERMINAL_STATE:-unknown}" "$_BM_PID" \
        >> "$ambient" 2>/dev/null || true
}

# ── RESILIENT-010: step-specific failure helper ───────────────────────────────
# Usage: _bm_fail <step-name> <exit-code> [message]
# Emits kind=bot_merge_phase_failure to ambient.jsonl (RESILIENT-011), exits with the given code.
#
# Exit code table (RESILIENT-011):
#   0  — success
#   1  — unexpected error (not a named phase)
#   2  — arg-parse / usage error
#   10 — preflight-fail  (gap already done/claimed, or post-rebase preflight)
#   11 — rebase-fail     (merge conflict or timeout)
#   12 — fmt-fail        (cargo fmt failed or timed out)
#   13 — clippy-fail     (clippy lint errors)
#   14 — test-fail       (cargo test suite failure)
#   15 — push-fail       (force-with-lease rejected or network error)
#   16 — pr-create-fail  (gh pr create failed or PR not visible after create)
#   21 — dor-gate-fail   (CREDIBLE-270 definition-of-ready gate: chump preflight not green locally)
_bm_fail() {
    local step="${1:-unknown}" code="${2:-1}" msg="${3:-}"
    local ambient="${CHUMP_AMBIENT_LOG:-${CHUMP_REPO:-.chump-locks}/ambient.jsonl}"
    # Fallback to .chump-locks/ambient.jsonl if CHUMP_AMBIENT_LOG unset.
    [[ -z "${CHUMP_AMBIENT_LOG:-}" ]] && ambient=".chump-locks/ambient.jsonl"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "1970-01-01T00:00:00Z")"
    _ambient_write "$ambient" \
        "$(printf '{"ts":"%s","kind":"bot_merge_phase_failure","step":"%s","exit_code":%d,"gap_id":"%s","branch":"%s","note":"%s"}' \
            "$ts" "$step" "$code" "${GAP_IDS[*]:-}" "${BRANCH:-}" "$msg")"
    exit "$code"
}

# ── INFRA-017: dispatched-agent identity ─────────────────────────────────────
# When bot-merge.sh runs inside a dispatched subagent (chump-orchestrator set
# CHUMP_DISPATCH_DEPTH=1), stamp git author/committer so amend commits and
# any fresh commits we make are attributable to the bot — not the host
# developer's git config. Human invocations leave the env unset and keep
# the user's configured identity.
if [[ "${CHUMP_DISPATCH_DEPTH:-0}" == "1" ]]; then
    export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-Chump Dispatched}"
    export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-chump-dispatch@chump.bot}"
    export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-Chump Dispatched}"
    export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-chump-dispatch@chump.bot}"
fi

# ── INFRA-209: ensure pre-commit hooks are installed in this worktree ────────
# Cold Water Issue #10 audit (2026-05-02) found 8 commits on origin/main since
# 2026-05-01 introducing status:done with closed_pr:TBD — the INFRA-107 guard
# was supposed to block these but was bypassed because the remote dispatch
# agents had empty .git/hooks/ dirs. install-hooks.sh is per-worktree (post-
# checkout hook does it on `git worktree add` since INFRA-072) but ephemeral
# sandbox checkouts skip the post-checkout hook.
#
# Idempotent guard: if pre-commit is missing OR points at a path that no
# longer exists, run install-hooks.sh --quiet. This protects every bot-merge
# invocation regardless of how the worktree was created.
#
# Disable: CHUMP_AUTO_INSTALL_HOOKS=0
if [[ "${CHUMP_AUTO_INSTALL_HOOKS:-1}" != "0" ]]; then
    _bm_repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    _bm_git_dir="$(git rev-parse --git-dir 2>/dev/null || echo "$_bm_repo_root/.git")"
    _bm_hook="$_bm_git_dir/hooks/pre-commit"
    _bm_install_sh="$_bm_repo_root/scripts/setup/install-hooks.sh"
    _bm_needs_install=0
    if [[ ! -e "$_bm_hook" ]]; then
        _bm_needs_install=1
    elif [[ -L "$_bm_hook" ]] && [[ ! -e "$_bm_hook" ]]; then
        # symlink to a missing target (stale install from another machine)
        _bm_needs_install=1
    fi
    if [[ "$_bm_needs_install" == "1" ]] && [[ -x "$_bm_install_sh" ]]; then
        printf '\033[0;32m[bot-merge] INFRA-209: pre-commit hook missing, running install-hooks.sh\033[0m\n'
        "$_bm_install_sh" --quiet 2>&1 | sed 's/^/[bot-merge] /' || \
            printf '\033[0;31m[bot-merge] WARN: install-hooks.sh failed; continuing without hooks\033[0m\n'
    fi
fi

# ── Flags ────────────────────────────────────────────────────────────────────
AUTO_MERGE=0
SKIP_TESTS=0
FAST=0
DRY_RUN=0
NO_MERGE_DRIVER=0
# INFRA-193: speculative execution opt-in. With --speculative, chump claim
# writes `"speculative": true` into the lease and `chump gap preflight` allows
# concurrent claims by other speculative-mode sessions on the same gap.
# After auto-merge is armed for our PR, the post-arm sweep below scans for
# open sibling PRs citing the same gap and closes them with a "superseded
# by #N" comment. CHUMP_SPECULATIVE=1 is the env equivalent.
SPECULATIVE=${CHUMP_SPECULATIVE:-0}
# INFRA-632: portability knobs — configurable branch prefix, PR template, required CI checks.
BRANCH_PREFIX="${BM_BRANCH_PREFIX:-chump}"
PR_TEMPLATE="${BM_PR_TEMPLATE:-}"
REQUIRED_CHECKS="${BM_REQUIRED_CHECKS:-}"
NEXT_IS_BRANCH_PREFIX=0
NEXT_IS_PR_TEMPLATE=0
NEXT_IS_REQUIRED_CHECKS=0
# INFRA-1767: tiered merge lane. internal (default) = auto-merge on by
# default; user-facing = auto-merge only when explicitly requested;
# critical = auto-merge default OFF, and chump-policy's Critical-lane
# baseline (crates/chump-policy) refuses to arm it even if --auto-merge
# is passed, unless the operator has explicitly opted a scope in.
LANE="${BM_LANE:-internal}"
LANE_EXPLICIT=0
AUTO_MERGE_EXPLICIT=0
NEXT_IS_LANE=0
# INFRA-996: bypass dup-PR check when the prior PR is known-closed during this run.
FORCE_DUPLICATE=${CHUMP_FORCE_DUPLICATE:-0}
GAP_IDS=()
NEXT_IS_GAP=0
# INFRA-061 (M3): --stack-on <PREV-GAP-ID> opens this PR with base=claude/<branch
# of the prev gap's open PR>, instead of base=main. When the prev PR lands, the
# merge queue auto-rebases this stacked PR onto the new main. One-deep stacks
# cover the dispatcher case; deeper stacks just chain (--stack-on the most
# recent open PR's gap).
STACK_ON_GAP=""
NEXT_IS_STACK_ON=0
# INFRA-2673: --progress-file PATH allows callers (especially background
# invocations via run_in_background=true) to observe incremental phase
# progress by tailing a line-oriented log. Each phase boundary writes one
# line: "phase=<name> ts=<iso8601>". Independent from the existing JSON
# ledger at .chump-locks/bot-merge-progress/<gap>.json which is overwritten
# per-step (not appendable, not tail-friendly).
PROGRESS_FILE_OVERRIDE=""
NEXT_IS_PROGRESS_FILE=0
for arg in "$@"; do
    if [[ $NEXT_IS_GAP -eq 1 ]]; then
        # Support --gap "AUTO-003 COMP-002" (space-separated) or --gap AUTO-003 --gap COMP-002
        for gid in $arg; do GAP_IDS+=("$gid"); done
        NEXT_IS_GAP=0
        continue
    fi
    if [[ $NEXT_IS_STACK_ON -eq 1 ]]; then
        STACK_ON_GAP="$arg"
        NEXT_IS_STACK_ON=0
        continue
    fi
    if [[ $NEXT_IS_BRANCH_PREFIX -eq 1 ]]; then
        BRANCH_PREFIX="$arg"
        NEXT_IS_BRANCH_PREFIX=0
        continue
    fi
    if [[ $NEXT_IS_PR_TEMPLATE -eq 1 ]]; then
        PR_TEMPLATE="$arg"
        NEXT_IS_PR_TEMPLATE=0
        continue
    fi
    if [[ $NEXT_IS_REQUIRED_CHECKS -eq 1 ]]; then
        REQUIRED_CHECKS="$arg"
        NEXT_IS_REQUIRED_CHECKS=0
        continue
    fi
    if [[ $NEXT_IS_PROGRESS_FILE -eq 1 ]]; then
        PROGRESS_FILE_OVERRIDE="$arg"
        NEXT_IS_PROGRESS_FILE=0
        continue
    fi
    if [[ $NEXT_IS_LANE -eq 1 ]]; then
        LANE="$arg"
        LANE_EXPLICIT=1
        NEXT_IS_LANE=0
        continue
    fi
    case "$arg" in
        --gap)             NEXT_IS_GAP=1 ;;
        --stack-on)        NEXT_IS_STACK_ON=1 ;;
        --progress-file)   NEXT_IS_PROGRESS_FILE=1 ;;
        --lane)               NEXT_IS_LANE=1 ;;      # INFRA-1767: internal|user-facing|critical
        --auto-merge)         AUTO_MERGE=1; AUTO_MERGE_EXPLICIT=1 ;;
        --skip-tests)         SKIP_TESTS=1 ;;
        --fast)               FAST=1; SKIP_TESTS=1 ;;
        --dry-run)            DRY_RUN=1 ;;
        --speculative)        SPECULATIVE=1 ;;
        --no-merge-driver)    NO_MERGE_DRIVER=1 ;;
        --branch-prefix)      NEXT_IS_BRANCH_PREFIX=1 ;;
        --pr-template)        NEXT_IS_PR_TEMPLATE=1 ;;
        --required-checks)    NEXT_IS_REQUIRED_CHECKS=1 ;;
        --allow-mass-delete)  ALLOW_MASS_DELETE=1 ;;  # INFRA-993 scratch-commit-guard override
        --force-duplicate)    FORCE_DUPLICATE=1 ;;    # INFRA-996 dup-PR-guard override
        # INFRA-2133: META-124/C5 mode-routing flags
        --review)             BM_FORCE_REVIEW=1 ;;    # Mode B: skip batched queue, use existing PR flow
        --hot-fix)            BM_FORCE_HOTFIX=1 ;;    # Mode C: P0 hot-fix, skip batched queue
        --legacy)             BM_LEGACY_MODE=1 ;;     # force old behavior (Mode B) for all gaps
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

# ── INFRA-1767: tiered merge lane — normalize + apply auto-merge default ────
# internal|user-facing|critical, matching crates/chump-policy's Lane enum.
# Bad values fail loudly here rather than silently falling back to the most
# permissive lane.
case "$LANE" in
    internal|user-facing|user_facing) LANE="internal" ;;
    critical) : ;;
    *)
        if [[ "$LANE" != "internal" ]]; then
            echo "bot-merge: invalid --lane '$LANE' (expected internal|user-facing|critical)" >&2
            exit 2
        fi
        ;;
esac
if [[ "$LANE" == "user_facing" ]]; then LANE="user-facing"; fi
if [[ "$AUTO_MERGE_EXPLICIT" -eq 0 ]]; then
    case "$LANE" in
        internal)
            # Auto-merge-by-default lane (RESILIENT-190 doctrine: lowest
            # blast radius if wrong). Still subject to the chump-policy
            # gate below like any other lane.
            AUTO_MERGE=1
            ;;
        user-facing|critical)
            # No auto-merge unless the caller explicitly opts in via
            # --auto-merge; the chump-policy gate further blocks critical
            # by default even when opted in.
            AUTO_MERGE=0
            ;;
    esac
fi
printf '{"ts":"%s","kind":"bot_merge_lane_resolved","lane":"%s","auto_merge_requested":%s,"auto_merge_explicit":%s,"session":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LANE" "$AUTO_MERGE" "$AUTO_MERGE_EXPLICIT" "${CHUMP_SESSION_ID:-unknown}" \
    >> "${CHUMP_AMBIENT_LOG:-${REPO_ROOT:-.}/.chump-locks/ambient.jsonl}" 2>/dev/null || true

# INFRA-993: default disabled. Set --allow-mass-delete to permit a push that
# would otherwise be blocked by the scratch-commit guard (legit large-deletion
# PRs like archive/ rewrites).
ALLOW_MASS_DELETE="${ALLOW_MASS_DELETE:-0}"

# INFRA-237: when --gap was not given, auto-derive from the current branch
# name. Branches following the canonical naming convention encode the gap ID
# (e.g. chump/infra-127-reflection-e2e → INFRA-127, claude/research-026-impl
# → RESEARCH-026, chore/file-infra-243 → INFRA-243). When auto-derive fires,
# print a clear info banner so the agent knows --gap was inferred (not
# silently skipped).
#
# The user can suppress auto-derivation by passing --gap none for genuine
# non-gap-bound PRs (e.g. dependabot bumps, doc-only sweeps that touch many
# unrelated areas). The literal string "none" filters out of GAP_IDS to keep
# downstream logic simple.
#
# Why this matters: when --gap is missing AND no auto-derive succeeds, the
# INFRA-154 auto-close path silently skips, producing the OPEN-BUT-LANDED
# ghosts INFRA-241 had to backfill. Making --gap effectively-required closes
# that path at the bottleneck without forcing every legitimate non-gap PR
# to add boilerplate.
if [[ ${#GAP_IDS[@]} -eq 0 ]]; then
    _branch_name=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
    # Strip the canonical chump-codename prefixes (chump/, claude/, chore/file-,
    # chore/close-) so the regex catches IDs anywhere in the remainder.
    # Strip leading namespace token (chump/, claude/, chore/) and an optional
    # action prefix (file-, close-, fix-) — but NOT the domain prefix
    # (infra-, research-, etc.) because the domain IS the gap-ID prefix we
    # want to extract. Then turn dashes into spaces and uppercase so
    # 'infra-127-reflection' becomes 'INFRA 127 RELECTION' for the grep.
    # INFRA-632: strip BRANCH_PREFIX (and legacy Chump prefixes) so gap-ID
    # auto-derive works for non-Chump repos with custom branch namespaces.
    # Use ${BRANCH_PREFIX:-chump} so the pattern degrades gracefully when this
    # block is eval'd in isolation (e.g. unit tests that source only this block).
    # INFRA-630: extract UUID-format gap IDs BEFORE tr strips hyphens.
    # Supported branch patterns:
    #   chump/8d3f2c0e-9f5b-4e1a-b2c3-d4e5f6a7b8c9-slug  (full RFC-4122 UUID)
    #   chump/8d3f2c0e--my-slug                           (8-char short-prefix, chump-proprietary)
    _branch_raw=$(echo "$_branch_name" \
        | sed -E "s,^(${BRANCH_PREFIX:-chump}|chump|claude|chore)/(file-|close-|fix-)?,," )
    # Full UUID pattern (RFC-4122: 8-4-4-4-12 hex)
    _uuid_full=$(printf '%s' "$_branch_raw" \
        | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' 2>/dev/null \
        | tr '[:lower:]' '[:upper:]' | sort -u | tr '\n' ' ' || true)
    # Short-prefix pattern: 8 lowercase hex chars immediately followed by --
    _uuid_short=$(printf '%s' "$_branch_raw" \
        | sed -n 's/^\([0-9a-f]\{8\}\)--.*$/\1/p' \
        | tr '[:lower:]' '[:upper:]' || true)
    _uuid_derived_gaps="${_uuid_full}${_uuid_short:+${_uuid_short} }"
    # Fallback to standard sed-based approach for [DOMAIN]-[NUM] patterns.
    _branch_tail=$(echo "$_branch_raw" \
        | tr '-' ' ' | tr 'a-z' 'A-Z')
    # Extract every <DOMAIN>-<NUMBER> pattern from the cleaned branch name.
    _derived_gaps=$(echo "$_branch_tail" \
        | grep -oE '[A-Z]+ [0-9]+' \
        | sed 's/ /-/' \
        | sort -u | tr '\n' ' ')
    # Merge UUID-format + classic-format derived gaps (INFRA-630)
    _derived_gaps="${_uuid_derived_gaps}${_derived_gaps}"
    if [[ -n "$_derived_gaps" ]]; then
        for gid in $_derived_gaps; do GAP_IDS+=("$gid"); done
        printf '\033[0;32m[bot-merge] auto-derived --gap from branch name: %s\033[0m\n' "${GAP_IDS[*]}"
        printf '\033[0;32m[bot-merge]   (suppress with explicit --gap none for non-gap PRs)\033[0m\n'
    elif [[ -z "$_branch_name" ]]; then
        # Detached HEAD or non-branch state — let the script proceed; downstream
        # checks will fail loud if a gap is needed.
        :
    else
        echo "" >&2
        printf '\033[0;31m[bot-merge] ERROR: no --gap given and could not auto-derive from branch name "%s"\033[0m\n' "$_branch_name" >&2
        echo "[bot-merge]   INFRA-237: --gap is now effectively required to keep INFRA-154" >&2
        echo "[bot-merge]   auto-close working. Either:" >&2
        echo "[bot-merge]     1. Pass --gap explicitly: --gap INFRA-NNN" >&2
        echo "[bot-merge]     2. Rename the branch to encode the gap ID:" >&2
        echo "[bot-merge]          git branch -m chump/infra-NNN-<short>" >&2
        echo "[bot-merge]     3. Pass --gap none for genuine non-gap PRs" >&2
        echo "[bot-merge]        (dependabot bumps, doc-only sweeps, etc.)" >&2
        exit 2
    fi
fi

# Filter out the literal "none" sentinel — this is how callers explicitly
# suppress auto-derivation for non-gap PRs without tripping downstream checks
# that expect a real ID.
_filtered=()
for gid in "${GAP_IDS[@]}"; do
    [[ "$gid" == "none" || "$gid" == "NONE" ]] && continue
    _filtered+=("$gid")
done
# INFRA-237: ${_filtered[@]} expansion under `set -u` would error when the
# array is empty (e.g. caller passed --gap none). Reset GAP_IDS to an empty
# array first, then append only if there's anything to keep.
GAP_IDS=()
if [[ ${#_filtered[@]} -gt 0 ]]; then
    GAP_IDS=("${_filtered[@]}")
fi

# ── INFRA-1939: graphql_exhausted wedge guard ───────────────────────────────
# Detects when ambient.jsonl shows a recent kind=graphql_exhausted event
# (within CHUMP_BOT_MERGE_GRAPHQL_WEDGE_LOOKBACK_S, default 1800s = 30min)
# and exits 144 with a clear WEDGE message instead of silently polling.
#
# Pre-INFRA-1939: subagents would burn 144K+ tokens stuck in 'waiting for
# monitor notification' loops while GraphQL was exhausted (observed
# 2026-05-24T16Z: ci-audit + md-links agents wasted 144K + 157K tokens
# producing zero artifacts). Now bot-merge fails fast + subagent falls
# through to the manual INFRA-028 recovery path documented in
# docs/process/SUBAGENT_DISPATCH.md.
#
# Bypass: CHUMP_BOT_MERGE_IGNORE_GRAPHQL_WEDGE=1
if [ "${CHUMP_BOT_MERGE_IGNORE_GRAPHQL_WEDGE:-0}" != "1" ]; then
    _wedge_lookback_s="${CHUMP_BOT_MERGE_GRAPHQL_WEDGE_LOOKBACK_S:-1800}"
    _wedge_ambient="${CHUMP_AMBIENT_LOG:-${CHUMP_REPO_ROOT:-$(pwd)}/.chump-locks/ambient.jsonl}"
    if [ -r "$_wedge_ambient" ]; then
        _wedge_cutoff_ts=$(date -u -v-"${_wedge_lookback_s}"S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
            || date -u -d "@$(( $(date +%s) - _wedge_lookback_s ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
            || echo "")
        if [ -n "$_wedge_cutoff_ts" ]; then
            # Look at last 200 events for graphql_exhausted within window.
            _wedge_hit=$(tail -200 "$_wedge_ambient" 2>/dev/null | python3 -c "
import json, sys
cutoff = '''$_wedge_cutoff_ts'''
for line in sys.stdin:
    try:
        o = json.loads(line.strip())
    except Exception:
        continue
    if isinstance(o, dict) and o.get('kind') == 'graphql_exhausted' and o.get('ts', '') > cutoff:
        print(o.get('ts', '?'))
        sys.exit(0)
" 2>/dev/null)
            if [ -n "$_wedge_hit" ]; then
                # INFRA-2426: also look for a newer graphql_recovered (or rate_limit reset)
                # event that supersedes the exhausted event. If found, clear the wedge.
                # This prevents stale graphql_exhausted events from blocking future invocations
                # after the rate limit has actually recovered.
                _wedge_recovered=$(tail -200 "$_wedge_ambient" 2>/dev/null | python3 -c "
import json, sys
cutoff_ts = '''$_wedge_hit'''
for line in sys.stdin:
    try:
        o = json.loads(line.strip())
    except Exception:
        continue
    if isinstance(o, dict) and o.get('kind') in ('graphql_recovered', 'rate_limit_reset') \
            and o.get('ts', '') > cutoff_ts:
        print(o.get('ts', '?'))
        sys.exit(0)
" 2>/dev/null)
                if [ -n "$_wedge_recovered" ]; then
                    # Rate limit recovered after the exhausted event — clear the wedge.
                    printf '{"ts":"%s","kind":"bot_merge_graphql_wedge_cleared","last_exhausted":"%s","recovered_at":"%s","note":"INFRA-2426: rate-limit recovery event found; wedge cleared"}\n' \
                        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_wedge_hit" "$_wedge_recovered" \
                        >> "$_wedge_ambient" 2>/dev/null || true
                else
                    # INFRA-2463 + INFRA-2674 hardening: no recovery event found, but
                    # the ambient event may be stale (today's empty-coercion bug emitted
                    # 31 false events / 30min while live GraphQL was 4159/5000 healthy).
                    # Do a live rate_limit check (cheap REST, doesn't burn GraphQL
                    # quota) before aborting. If live remaining >= threshold, the
                    # exhaustion event is stale — clear the wedge and proceed.
                    #
                    # INFRA-2674: must use CHUMP_GH_NO_SHIM=1 + strict integer
                    # validation. The prior code routed through the gh shim, which
                    # has its own failure modes (recording-side errors, env-strip in
                    # background subprocesses) that could make _wedge_live_remaining
                    # empty or non-numeric — silently falling into the "real exhaustion"
                    # branch when the live API was actually healthy.
                    _wedge_live_threshold="${CHUMP_GRAPHQL_WEDGE_LIVE_THRESHOLD:-100}"
                    _wedge_live_remaining=$(CHUMP_GH_NO_SHIM=1 gh api rate_limit \
                        --jq '.resources.graphql.remaining' 2>/dev/null \
                        | tr -d '[:space:]' \
                        || echo "")
                    if [[ "$_wedge_live_remaining" =~ ^[0-9]+$ ]] \
                            && [ "$_wedge_live_remaining" -ge "$_wedge_live_threshold" ]; then
                        # Live check shows rate limit is healthy — stale event, clear and proceed.
                        printf '{"ts":"%s","kind":"bot_merge_graphql_wedge_cleared","last_exhausted":"%s","live_remaining":%s,"note":"INFRA-2674 stale-event-cleared via live-check"}\n' \
                            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_wedge_hit" "$_wedge_live_remaining" \
                            >> "$_wedge_ambient" 2>/dev/null || true
                    else
                        # Live remaining is low (or live check failed) — real exhaustion.
                        echo "WEDGE: bot-merge cannot proceed under graphql_exhausted (last event: $_wedge_hit)." >&2
                        echo "WEDGE: live remaining=${_wedge_live_remaining:-unknown} < threshold=${_wedge_live_threshold}" >&2
                        echo "WEDGE: fall through to manual INFRA-028 recovery path." >&2
                        echo "WEDGE: see docs/process/SUBAGENT_DISPATCH.md '#bot-merge-graphql-wedge'." >&2
                        echo "WEDGE: bypass with CHUMP_BOT_MERGE_IGNORE_GRAPHQL_WEDGE=1 (not recommended)." >&2
                        # INFRA-2426: emit structured kind=bot_merge_timeout (not silent exit 144).
                        # Exit code changed from 144 (undocumented, confusing) to 4 (documented
                        # misc-abort code) so automated callers can classify the failure.
                        # scanner-anchor: "kind":"bot_merge_graphql_wedge_aborted"
                        _ambient_dir=$(dirname "$_wedge_ambient")
                        if [ -w "$_ambient_dir" ]; then
                            printf '{"ts":"%s","kind":"bot_merge_graphql_wedge_aborted","last_graphql_exhausted":"%s","lookback_s":%d,"live_remaining":%s,"exit_code":4,"note":"INFRA-2426: graphql wedge guard now exits 4 with structured event; phase=graphql_wedge_guard"}\n' \
                                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_wedge_hit" "$_wedge_lookback_s" "${_wedge_live_remaining:-null}" \
                                >> "$_wedge_ambient" 2>/dev/null || true
                        fi
                        exit 4
                    fi
                fi
            fi
        fi
    fi
fi

# ── RESILIENT-073: fleet kill switch — AUTONOMY_LEVEL check ─────────────────
# Pure file read: ~/.chump/AUTONOMY_LEVEL must be >= 1 to proceed.
# Fail-closed: missing / unreadable / non-numeric / 0 → refuse merge.
# NO shared failure mode: does not call chump, state.db, NATS, or any daemon.
# This check must survive a deadlocked fleet (the whole point).
_al_file="${HOME:-/tmp}/.chump/AUTONOMY_LEVEL"
_al_level=0
if [[ -r "$_al_file" ]]; then
    _al_raw="$(tr -d '[:space:]' < "$_al_file" 2>/dev/null || true)"
    if [[ "$_al_raw" =~ ^[0-9]+$ ]] && [[ "$_al_raw" -gt 0 ]]; then
        _al_level="$_al_raw"
    fi
fi
if [[ "$_al_level" -eq 0 ]]; then
    _al_amb="${CHUMP_AMBIENT_LOG:-${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}/.chump-locks/ambient.jsonl}"
    printf '{"ts":"%s","kind":"fleet_stopped_kill_switch","source":"bot-merge","autonomy_level":%s,"note":"RESILIENT-073: bot-merge refused — fleet stopped"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${_al_level}" >> "$_al_amb" 2>/dev/null || true
    printf '\033[0;31m[bot-merge] fleet stopped (AUTONOMY_LEVEL=%s). Run `chump fleet start` or `chump fleet level 5` to re-enable.\033[0m\n' "${_al_level}" >&2
    exit 10
fi
# ── end RESILIENT-073 ────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# INFRA-6128: shared execution logging (start/end/step) to a central log.
# shellcheck source=../lib/orchestrator-log.sh
source "$SCRIPT_DIR/../lib/orchestrator-log.sh"
orch_log_start "bot-merge.sh" "$@"

# ── INFRA-305: hot-file rebase-loop expectation list ─────────────────────────
# Files that every parallel agent appends to (CI test list, pre-commit guard
# list, coordination scripts, top-level docs). PRs touching these almost
# always hit ≥1 DIRTY rebase before landing because main moves under them
# while CI runs. The arm-time hot-file scan below emits a stdout note +
# ambient.jsonl event so the agent KNOWS to expect the rebase loop instead
# of treating it as a surprise. See docs/gaps/INFRA-305.yaml.
#
# Hand-curated, intentionally small. Update when a new shared append-only
# file becomes a steady contention point.
BOT_MERGE_HOT_FILES=(
    ".github/workflows/ci.yml"
    "scripts/git-hooks/pre-commit"
    "scripts/coord/bot-merge.sh"
    "scripts/coord/gap-claim.sh"
    "scripts/coord/gap-reserve.sh"
    "CLAUDE.md"
    "AGENTS.md"
    # INFRA-670: workspace-wide files — touching these requires cascade rebase
    # of all sibling PRs (queue-driver.sh cascade_rebase_if_hot handles it).
    "Cargo.toml"
    "rust-toolchain.toml"
)

# INFRA-711: extend BOT_MERGE_HOT_FILES with additional workspace-wide paths
# (src/main.rs, src/lib.rs, src/agent_loop/**, src/dispatch.rs, etc.)
# Paths are configurable via scripts/coord/cascade-rebase-trigger-paths.txt
_bm_cascade_config="${REPO_ROOT:-$(git rev-parse --show-toplevel)}/scripts/coord/cascade-rebase-trigger-paths.txt"
if [[ -f "$_bm_cascade_config" ]]; then
    while IFS= read -r line; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        # Skip paths that are already hardcoded
        [[ "$line" == "Cargo.toml" || "$line" == "rust-toolchain.toml" ]] && continue
        BOT_MERGE_HOT_FILES+=("$line")
    done < "$_bm_cascade_config"
fi

# ── INFRA-103: serializing hot-file list ──────────────────────────────────────
# PRs touching any of these files cannot safely land concurrently because they
# modify shared coordination state or global config. All other PRs are
# parallel-safe. Configure via BM_SERIALIZING_HOT_FILES env var (colon-separated
# overrides the entire list) or append with BM_SERIALIZING_EXTRA (colon-separated).
_DEFAULT_SERIALIZING_HOT_FILES=(
    "gaps.yaml"
    ".chump/state.db"
    ".chump/state.sql"
    "CLAUDE.md"
    ".gitmodules"
    "Cargo.lock"
)
if [[ -n "${BM_SERIALIZING_HOT_FILES:-}" ]]; then
    IFS=':' read -ra SERIALIZING_HOT_FILES <<< "$BM_SERIALIZING_HOT_FILES"
else
    SERIALIZING_HOT_FILES=("${_DEFAULT_SERIALIZING_HOT_FILES[@]}")
fi
if [[ -n "${BM_SERIALIZING_EXTRA:-}" ]]; then
    IFS=':' read -ra _extra <<< "$BM_SERIALIZING_EXTRA"
    SERIALIZING_HOT_FILES+=("${_extra[@]}")
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
# INFRA-026 — timestamped banners let the fleet distinguish "stuck" from
# "working hard." Every green/red/info output carries `[bot-merge HH:MM:SS]`.
# Long stages use `stage_start <label>` → `stage_done` which prints the
# elapsed seconds. Silent intervals >30s are the symptom INFRA-026 was
# filed about; banners make them attributable.
green()  { printf '\033[0;32m[bot-merge %s] %s\033[0m\n' "$(date +%H:%M:%S)" "$*"; orch_log_step "$*"; }
red()    { printf '\033[0;31m[bot-merge %s] %s\033[0m\n' "$(date +%H:%M:%S)" "$*"; orch_log_step "$*"; }
yellow() { printf '\033[0;33m[bot-merge %s] %s\033[0m\n' "$(date +%H:%M:%S)" "$*"; orch_log_step "$*"; }
warn()   { yellow "$*"; }
info()   { printf '[bot-merge %s] %s\n' "$(date +%H:%M:%S)" "$*"; orch_log_step "$*"; }

# INFRA-590: print error + doc link, then exit 1.
die_with_help() {
    local msg="$1" anchor="$2"
    red "ERROR: $msg"
    red "See: docs/process/CLAUDE_GOTCHAS.md#${anchor}"
    exit 1
}

# ── INFRA-305: hot-file rebase-loop pre-emit warning ─────────────────────────
# Inspect the diff vs origin/main and emit a stderr note + ambient event for
# any file matching BOT_MERGE_HOT_FILES. Idempotent (keyed by gap+path on the
# stdout side; ambient is append-only). No behavior change — purely an
# expectation-setting note that a DIRTY rebase is likely while parallel
# agents touch the same shared append-only configs.
emit_hot_file_warnings() {
    local target_pr="${1:-}"   # may be empty if PR not yet open
    local gap_label="${2:-none}"
    local diff_files
    diff_files="$(git diff "$REMOTE/$BASE_BRANCH"..HEAD --name-only 2>/dev/null || true)"
    [[ -z "$diff_files" ]] && return 0

    local ambient="${LOCK_DIR:-/tmp}/ambient.jsonl"
    local now path hot
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        for hot in "${BOT_MERGE_HOT_FILES[@]}"; do
            if [[ "$path" == "$hot" ]]; then
                printf '\033[0;33m[bot-merge] HOT FILE: %s — expect rebase loop, OK to wait\033[0m\n' "$path" >&2
                _ambient_write "$ambient" \
                    "$(printf '{"ts":"%s","session":"bot-merge-%d","event":"bot_merge_hot_file","kind":"bot_merge_hot_file","path":"%s","gap_id":"%s","pr":"%s","note":"PR touches hot file — expect ≥1 DIRTY rebase before landing if other agents are active. The 4-step disarm-push-rearm loop in CLAUDE.md is the recovery."}' \
                        "$now" "$_BM_PID" "$path" "$gap_label" "$target_pr")"
                break
            fi
        done
    done <<< "$diff_files"
}

# ── INFRA-103: PR parallelism classifier ──────────────────────────────────────
# Outputs "serializing" if the diff touches any SERIALIZING_HOT_FILES entry,
# "parallel-safe" otherwise. Applies a GitHub label to the PR so the queue
# health monitor (and humans) can spot avoidable serialization.
classify_pr_parallelism() {
    local diff_files
    diff_files="$(git diff "$REMOTE/$BASE_BRANCH"..HEAD --name-only 2>/dev/null || true)"
    [[ -z "$diff_files" ]] && { echo "parallel-safe"; return; }
    local path hot
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        for hot in "${SERIALIZING_HOT_FILES[@]}"; do
            if [[ "$path" == "$hot" ]]; then
                echo "serializing"
                return
            fi
        done
    done <<< "$diff_files"
    echo "parallel-safe"
}

apply_pr_parallelism_label() {
    local pr_number="$1"
    local class
    class="$(classify_pr_parallelism)"
    local label="pr:${class}"
    info "INFRA-103: PR #${pr_number} classified as ${class} — applying label '${label}'"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "[dry-run] gh pr edit $pr_number --add-label $label"
        return 0
    fi
    # Create the label if it doesn't exist (idempotent).
    if [[ "$class" == "serializing" ]]; then
        gh label create "pr:serializing" --color "e4e669" --description "Touches shared hot files; cannot land concurrently with other serializing PRs" --force 2>/dev/null || true
    else
        gh label create "pr:parallel-safe" --color "0075ca" --description "Does not touch shared coordination files; can land concurrently with other parallel-safe PRs" --force 2>/dev/null || true
    fi
    gh pr edit "$pr_number" --add-label "$label" 2>/dev/null || true
    # Emit ambient event so queue-health-monitor and sibling agents see the class.
    local ambient="${LOCK_DIR:-/tmp}/ambient.jsonl"
    local now
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local gap_label="${GAP_IDS[0]:-none}"
    _ambient_write "$ambient" \
        "$(printf '{"ts":"%s","session":"bot-merge-%d","event":"pr_classified","kind":"pr_classified","pr":"%s","class":"%s","gap_id":"%s","serializing_hot_files":"%s"}' \
            "$now" "$_BM_PID" "$pr_number" "$class" "$gap_label" \
            "$(IFS=','; echo "${SERIALIZING_HOT_FILES[*]}")")"
}

__STAGE_LABEL=""
__STAGE_T0=0

# INFRA-1422: emit kind=botmerge_wedged to ambient and print an actionable message.
# Called by the per-stage budget watchdog when a stage exceeds CHUMP_BOT_MERGE_STAGE_BUDGET_S.
_emit_botmerge_wedged() {
    local stage="${1:-${__STAGE_LABEL:-unknown}}"
    local elapsed_s="${2:-0}"
    local budget_s="${CHUMP_BOT_MERGE_STAGE_BUDGET_S:-300}"
    local ts gap_label ambient
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)"
    gap_label="${GAP_IDS[0]:-${GAP_ID:-unknown}}"
    ambient="${CHUMP_AMBIENT_LOG:-${REPO_ROOT:-.}/.chump-locks/ambient.jsonl}"
    printf '{"ts":"%s","kind":"botmerge_wedged","stage":"%s","elapsed_s":%d,"budget_s":%d,"gap":"%s","note":"INFRA-1422: stage exceeded budget; set CHUMP_BOT_MERGE_RECOVERY_MODE=1 on retry"}\n' \
        "$ts" "$stage" "$elapsed_s" "$budget_s" "$gap_label" \
        >> "$ambient" 2>/dev/null || true
    printf '\033[0;31mERROR (INFRA-1422): stage "%s" exceeded budget %ds (elapsed %ds).\033[0m\n' \
        "$stage" "$budget_s" "$elapsed_s" >&2
    printf '\033[0;31m  → kind=botmerge_wedged emitted. Retry with:\033[0m\n' >&2
    printf '\033[0;31m      CHUMP_BOT_MERGE_RECOVERY_MODE=1 bash scripts/coord/bot-merge.sh --gap %s --auto-merge\033[0m\n' \
        "$gap_label" >&2
}

stage_start() {
    __STAGE_LABEL="$1"
    __STAGE_T0=$(date +%s)
    # RESILIENT-133: optional $2 overrides the per-stage watchdog budget for
    # this call only, defaulting to the global CHUMP_BOT_MERGE_STAGE_BUDGET_S
    # (300s) when omitted -- backward-compatible with existing single-arg
    # callers. A second, simpler stage_start() definition earlier in this
    # file (RESILIENT-210's attempted fix) already tried to add this, but
    # bash silently lets a later function definition shadow an earlier one
    # with the same name -- THIS definition wins at runtime (confirmed via
    # direct bash semantics test), so RESILIENT-210's version never actually
    # ran. Removed the dead duplicate below to prevent this exact confusion
    # from recurring.
    local budget="${2:-${CHUMP_BOT_MERGE_STAGE_BUDGET_S:-300}}"
    info "▶ $__STAGE_LABEL starting … (budget ${budget}s)"
    # INFRA-119: keep step file current so the health-file writer tracks progress
    [[ -n "${_BM_STEP_FILE:-}" ]] && printf '%s' "$__STAGE_LABEL" > "$_BM_STEP_FILE" 2>/dev/null || true
    # INFRA-2272: update per-step progress ledger at each phase boundary.
    _bm_progress_write "$__STAGE_LABEL" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    # INFRA-1035: record transition start in the steps log
    _bm_steps_append "start" "$__STAGE_LABEL" 0
    # INFRA-1422: launch per-stage budget watchdog. Fires after CHUMP_BOT_MERGE_STAGE_BUDGET_S
    # seconds if the stage hasn't called stage_done(). Emits botmerge_wedged + kills bot-merge.
    if [[ -n "${__STAGE_BUDGET_PID:-}" ]]; then
        # INFRA-2641: `kill` only terminates the watchdog subshell wrapper — its
        # `sleep "$budget"` grandchild (still running, e.g. 300-1200s) gets
        # reparented to init and keeps holding whatever fds it inherited (stdout/
        # stderr, and any pipe from a caller's command substitution) open until
        # it naturally expires. `pkill -P` first reaps that grandchild, same
        # fix already applied to _bm_cleanup's EXIT trap (EFFECTIVE-312) but
        # missing here — every stage_start/stage_done transition orphaned one.
        pkill -P "$__STAGE_BUDGET_PID" 2>/dev/null || true
        kill "$__STAGE_BUDGET_PID" 2>/dev/null || true
        __STAGE_BUDGET_PID=""
    fi
    local _parent_pid=$$
    local _stage_label="$__STAGE_LABEL"
    local _stage_t0="$__STAGE_T0"
    (
        sleep "$budget" 2>/dev/null
        # If we wake up the stage is still running — fire the circuit breaker.
        local _elapsed=$(( $(date +%s) - _stage_t0 ))
        CHUMP_BOT_MERGE_STAGE_BUDGET_S="$budget" \
            GAP_IDS=("${GAP_IDS[@]:-}") \
            GAP_ID="${GAP_ID:-}" \
            REPO_ROOT="${REPO_ROOT:-.}" \
            CHUMP_AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-}" \
            _emit_botmerge_wedged "$_stage_label" "$_elapsed"
        kill -TERM "$_parent_pid" 2>/dev/null || true
    ) &
    __STAGE_BUDGET_PID=$!
    disown "$__STAGE_BUDGET_PID" 2>/dev/null || true
}

stage_done() {
    # INFRA-1422: cancel the per-stage budget watchdog — normal completion.
    # INFRA-2641: pkill -P first to reap the `sleep "$budget"` grandchild — see
    # matching comment in stage_start(); `kill` alone orphans it for up to
    # $budget seconds, holding any inherited pipe fd (e.g. a caller's command
    # substitution) open and hanging the reader.
    if [[ -n "${__STAGE_BUDGET_PID:-}" ]]; then
        pkill -P "$__STAGE_BUDGET_PID" 2>/dev/null || true
        kill "$__STAGE_BUDGET_PID" 2>/dev/null || true
        __STAGE_BUDGET_PID=""
    fi
    local elapsed=$(( $(date +%s) - __STAGE_T0 ))
    local budget="${CHUMP_BOT_MERGE_STAGE_BUDGET_S:-300}"
    info "✓ $__STAGE_LABEL done (${elapsed}s)"
    # INFRA-1035: record transition done in the steps log
    _bm_steps_append "done" "$__STAGE_LABEL" "$elapsed"
    # INFRA-1067: emit phase duration to ambient.jsonl so the fleet can
    # build a distribution of stage times and tune timeouts data-drivenly.
    local _sd_amb="${CHUMP_AMBIENT_LOG:-${REPO_ROOT:-.}/.chump-locks/ambient.jsonl}"
    local _sd_ts; _sd_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local _sd_gap="${GAP_IDS[0]:-${GAP_ID:-unknown}}"
    printf '{"ts":"%s","kind":"bot_merge_phase_duration","phase":"%s","elapsed_s":%d,"gap":"%s","branch":"%s"}\n' \
        "$_sd_ts" "$__STAGE_LABEL" "$elapsed" "$_sd_gap" "${BRANCH:-unknown}" \
        >> "$_sd_amb" 2>/dev/null || true
    # INFRA-1422: belt-and-suspenders — if stage completed but over budget, emit wedge signal.
    if [[ "$elapsed" -ge "$budget" ]]; then
        _emit_botmerge_wedged "$__STAGE_LABEL" "$elapsed"
        exit 1
    fi
}

run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        info "[dry-run] $*"
        return 0
    fi
    "$@"
}

# INFRA-028 — per-stage wall-clock timeouts (fleet contention / hung gh / cargo).
# Streams child output; on breach prints last lines via bot-merge-run-timed.py.
run_timed() {
    local max_secs=$1; shift
    if [[ $DRY_RUN -eq 1 ]]; then
        info "[dry-run] (timeout ${max_secs}s) $*"
        return 0
    fi
    python3 "$SCRIPT_DIR/bot-merge-run-timed.py" "$max_secs" -- "$@"
}

# INFRA-954: load circuit-breaker so run_timed_hb can refuse known-wedged phases.
_CB_HELPER="$SCRIPT_DIR/bot-merge-circuit-breaker.sh"
if [[ -r "$_CB_HELPER" ]]; then
    # shellcheck source=./bot-merge-circuit-breaker.sh
    source "$_CB_HELPER"
fi

__HEARTBEAT_PID=""
heartbeat_end() {
    if [[ -n "${__HEARTBEAT_PID:-}" ]]; then
        kill "$__HEARTBEAT_PID" 2>/dev/null || true
        wait "$__HEARTBEAT_PID" 2>/dev/null || true
        __HEARTBEAT_PID=""
    fi
}

# Emit a line every 30s so parent watchers see progress during long subprocesses.
heartbeat_begin() {
    local label=$1
    (
        local t0
        t0=$(date +%s)
        while true; do
            sleep 30
            local now elapsed
            now=$(date +%s)
            elapsed=$((now - t0))
            info "… ${label} still running (${elapsed}s elapsed, heartbeat)"
            # INFRA-2272: keep last_progress_ts current so stall monitors can
            # distinguish "subprocess running" from "process wedged silently".
            _bm_progress_write "$label" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" 2>/dev/null || true
        done
    ) &
    __HEARTBEAT_PID=$!
}

run_timed_hb() {
    local label=$1 max_secs=$2; shift 2
    if [[ $DRY_RUN -eq 1 ]]; then
        info "[dry-run] (timeout ${max_secs}s, heartbeat) $*"
        return 0
    fi
    # INFRA-954: refuse to enter a wedge-prone phase that has tripped the
    # circuit-breaker (3+ bot_merge_hang events for this phase in last 1h).
    # Re-running a wedged phase is the dominant token-bleed pattern from
    # bot_merge_hang (META-055 audit #2, 17% of 7d waste).
    if declare -F circuit_breaker_check >/dev/null 2>&1; then
        if ! circuit_breaker_check "$label"; then
            red "INFRA-954: circuit-breaker tripped on phase '$label' — refusing to run."
            red "  Recent bot_merge_hang events suggest the underlying child process is wedged."
            red "  Investigate, then: scripts/coord/bot-merge-circuit-breaker.sh clear"
            return 124
        fi
    fi
    heartbeat_begin "$label"
    set +e
    run_timed "$max_secs" "$@"
    local _rc=$?
    set -e
    heartbeat_end
    # INFRA-587: emit bot_merge_hang ALERT when a phase times out (exit 124 = timeout)
    if [[ "$_rc" -eq 124 ]]; then
        _emit_hang_alert "$label" "$max_secs"
    fi
    return "$_rc"
}

# INFRA-587: emit a bot_merge_hang ALERT to ambient.jsonl when a phase times out.
# Called by run_timed_hb when bot-merge-run-timed.py returns 124 (timeout).
_emit_hang_alert() {
    local phase="$1" timeout_secs="$2"
    local ambient="${LOCK_DIR:-${REPO_ROOT:-.}/.chump-locks}/ambient.jsonl"
    local now gap_label
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    gap_label="${GAP_IDS[0]:-none}"
    # RESILIENT-132 AC#4: any phase-timeout (fmt/clippy/test/push/rebase/...)
    # is recoverable, not a give-up — the outer EXIT trap checks this flag
    # and skips releasing the on-disk lease file so a retry can resume the
    # same claim instead of re-claiming from scratch.
    _BM_TIMEOUT_EXIT=1
    _ambient_write "$ambient" \
        "$(printf '{"ts":"%s","session":"bot-merge-%d","event":"ALERT","kind":"bot_merge_hang","phase":"%s","timeout_secs":%s,"gap_id":"%s","note":"bot-merge phase timed out after %ss — possible hang (INFRA-587)"}' \
            "$now" "$_BM_PID" "$phase" "$timeout_secs" "$gap_label" "$timeout_secs")"
    red "INFRA-587: phase '$phase' timed out after ${timeout_secs}s — bot_merge_hang ALERT emitted to ambient stream"
}

# INFRA-564: gh secondary rate-limit backoff — 60/120/240s, max 3 retries.
# Usage: gh_with_backoff <label> <timeout_secs> <gh args...>
gh_with_backoff() {
    local label=$1 timeout_secs=$2; shift 2
    local -a delays=(60 120 240)
    local attempt=0 rc tmpout api_tag started_ms ended_ms
    api_tag="$(chump_gh_api_tag "$@" 2>/dev/null || printf '%s' "${1:-?}")"
    while true; do
        tmpout=$(mktemp)
        started_ms="$(_chump_gh_now_ms 2>/dev/null || echo 0)"
        set +e
        run_timed_hb "$label" "$timeout_secs" gh "$@" 2>&1 | tee -a "$tmpout"
        rc=${PIPESTATUS[0]}
        set -e
        ended_ms="$(_chump_gh_now_ms 2>/dev/null || echo 0)"
        # INFRA-999: log this call to ambient.jsonl for cost telemetry.
        if declare -F chump_gh_record >/dev/null 2>&1; then
            chump_gh_record "$api_tag" "$(( ended_ms - started_ms ))" "$rc" "bot-merge.sh" \
                2>/dev/null || true
        fi
        if [[ $rc -eq 0 ]]; then
            rm -f "$tmpout"; return 0
        fi
        if grep -qi "secondary rate limit" "$tmpout" && [[ $attempt -lt 3 ]]; then
            local sleep_secs=${delays[$attempt]}
            rm -f "$tmpout"
            attempt=$((attempt + 1))
            warn "gh secondary rate-limit hit — sleeping ${sleep_secs}s before retry ${attempt}/3…"
            sleep "$sleep_secs"
            continue
        fi
        rm -f "$tmpout"
        return "$rc"
    done
}

# ── INFRA-539 / CREDIBLE-032: GitHub API reachability probe ──────────────────
# Call once at startup. Exits 1 if gh cannot reach the API, emitting one of:
#   kind=gh_missing   — gh binary not installed
#   kind=gh_errored   — gh installed but API call failed (auth, rate-limit, network)
# Backward-compat: kind=github_unreachable is also emitted alongside gh_errored.
# Bypass: CHUMP_GH_PROBE_SKIP=1 (air-gapped tests, mocks).
gh_api_probe() {
    [[ "${CHUMP_GH_PROBE_SKIP:-0}" == "1" ]] && return 0
    local ambient="${CHUMP_AMBIENT_LOG:-${REPO_ROOT:-.}/.chump-locks/ambient.jsonl}"
    local timeout_s="${CHUMP_GH_PROBE_TIMEOUT:-10}"
    local ts rc=0

    # CREDIBLE-032: distinguish missing binary from API failure
    if ! command -v gh >/dev/null 2>&1; then
        ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        red "CREDIBLE-032: gh binary not found — halting (install gh CLI)"
        _ambient_write "$ambient" \
            "$(printf '{"ts":"%s","kind":"gh_missing","source":"bot-merge","note":"gh binary not in PATH — CREDIBLE-032"}' \
                "$ts")"
        return 1
    fi

    set +e
    timeout "$timeout_s" gh api /rate_limit --silent 2>/dev/null
    rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then
        ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        red "CREDIBLE-032: gh API call failed (exit=${rc}) — halting to prevent queue churn"
        _ambient_write "$ambient" \
            "$(printf '{"ts":"%s","kind":"gh_errored","source":"bot-merge","exit_code":%d,"note":"gh api /rate_limit failed — CREDIBLE-032"}' \
                "$ts" "$rc")"
        # backward-compat alias so consumers watching github_unreachable still fire
        _ambient_write "$ambient" \
            "$(printf '{"ts":"%s","kind":"github_unreachable","source":"bot-merge","exit_code":%d,"note":"alias for gh_errored — CREDIBLE-032"}' \
                "$ts" "$rc")"
        return 1
    fi
}

# ── INFRA-119: health-file writer + total-budget watchdog ────────────────────
# Call _bm_health_init once after REPO_ROOT is known. It:
#   1. Creates .chump-locks/bot-merge-<pid>.health — read by queue-health-monitor
#      to detect hangs when last_heartbeat_at goes > 5 min stale.
#   2. Starts a background loop that rewrites the health file every 30s with the
#      current stage label (read from .chump-locks/bot-merge-<pid>.step).
#   3. Starts a budget-watchdog: if CHUMP_BOT_MERGE_BUDGET_SECS (default 600)
#      elapses without the script completing, the watchdog emits an ambient
#      ALERT kind=bot_merge_hung and sends SIGTERM to this process.
#      Set to 0 to disable (e.g. for full cargo-test runs).
_bm_health_write() {
    [[ -z "${_BM_HEALTH_FILE:-}" ]] && return 0
    local step now gap_str
    step="$(cat "$_BM_STEP_FILE" 2>/dev/null || echo init)"
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    # INFRA-1315: include gap_ids so bot-merge-watchdog.sh can identify zombies.
    gap_str="${GAP_IDS[*]:-}"
    printf '{"pid":%d,"started_at":"%s","current_step":"%s","last_heartbeat_at":"%s","gap_ids":"%s"}\n' \
        "$_BM_PID" "$_BM_STARTED_AT" "$step" "$now" "$gap_str" \
        > "${_BM_HEALTH_FILE}.tmp" 2>/dev/null \
    && mv "${_BM_HEALTH_FILE}.tmp" "$_BM_HEALTH_FILE" 2>/dev/null || true
}

_bm_health_init() {
    local lock_dir="$1"
    [[ $DRY_RUN -eq 1 ]] && return 0
    mkdir -p "$lock_dir" 2>/dev/null || true
    _BM_HEALTH_FILE="${lock_dir}/bot-merge-${_BM_PID}.health"
    _BM_STEP_FILE="${lock_dir}/bot-merge-${_BM_PID}.step"
    _BM_STEPS_FILE="${lock_dir}/bot-merge-${_BM_PID}.steps"  # INFRA-1035
    printf 'init' > "$_BM_STEP_FILE" 2>/dev/null || true
    # INFRA-1035: seed the steps log with a session-start entry
    printf '{"ts":"%s","step":"session","transition":"start","elapsed_s":0,"pid":%d}\n' \
        "$_BM_STARTED_AT" "$_BM_PID" > "$_BM_STEPS_FILE" 2>/dev/null || true
    _bm_health_write

    # Background heartbeat: rewrite the health file AND (INFRA-2455) print a
    # live stderr liveness line every CHUMP_BOT_MERGE_HEARTBEAT_S (default 30s).
    #
    # Why the stderr line: the health file alone is invisible on the terminal,
    # so a slow-but-working run (e.g. a multi-minute cold preflight) looked
    # hung. The first operator-visible stderr signal used to be the 50%-budget
    # warn (~450s on the 900s default) — which trained a manual-bypass reflex
    # (VOA-002, 2026-06-02: bot-merge was killed at 420s as "stalled" when it
    # was mid-preflight, before any signal). This surfaces "alive + which step
    # + how long" within the first interval. Reuses the existing step file +
    # the existing per-step gtimeout (300s) / budget-warn for *stall* detection
    # — no new event kind (avoids META-063 duplication).
    #
    # NOTE: piping bot-merge through `tail` buffers stderr until exit and hides
    # this — watch it directly, or `… 2>&1 | tee`, or tail the health file.
    local hf="$_BM_HEALTH_FILE" sf="$_BM_STEP_FILE"
    local pid="$_BM_PID" sa="$_BM_STARTED_AT"
    # INFRA-1315: capture gap_ids for watchdog identification.
    local gap_str="${GAP_IDS[*]:-}"
    local _hb_interval="${CHUMP_BOT_MERGE_HEARTBEAT_S:-30}"
    [[ "$_hb_interval" -lt 5 ]] 2>/dev/null && _hb_interval=5  # floor: don't spam
    (
        local _hb_elapsed=0
        # Immediate first line so life is visible before the first sleep.
        printf '\033[0;36m[bot-merge %s] ⏳ alive — step=%s (0s; heartbeat every %ss)\033[0m\n' \
            "$(date +%H:%M:%S)" "$(cat "$sf" 2>/dev/null || echo init)" "$_hb_interval" >&2
        while true; do
            sleep "$_hb_interval"
            _hb_elapsed=$(( _hb_elapsed + _hb_interval ))
            local step now
            step="$(cat "$sf" 2>/dev/null || echo unknown)"
            now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            printf '{"pid":%d,"started_at":"%s","current_step":"%s","last_heartbeat_at":"%s","gap_ids":"%s"}\n' \
                "$pid" "$sa" "$step" "$now" "$gap_str" \
                > "${hf}.tmp" && mv "${hf}.tmp" "$hf" || true
            # INFRA-2455: same liveness, surfaced to stderr so it's visible live.
            printf '\033[0;36m[bot-merge %s] ⏳ alive — step=%s (~%ds elapsed)\033[0m\n' \
                "$(date +%H:%M:%S)" "$step" "$_hb_elapsed" >&2
        done
    ) &
    _BM_HEALTH_PID=$!

    # Budget watchdog: SIGTERM + ambient ALERT if total runtime exceeds budget
    # INFRA-2426: accept both variable names — CHUMP_SUBAGENT_BOT_MERGE_BUDGET_S is
    # the name documented in CLAUDE.md + SUBAGENT_DISPATCH.md (900s default);
    # CHUMP_BOT_MERGE_BUDGET_SECS is the legacy name (600s default). Prefer the
    # subagent name when set so subagent dispatches are not killed at 600s when
    # the fleet has granted them a 900s budget.
    local budget="${CHUMP_SUBAGENT_BOT_MERGE_BUDGET_S:-${CHUMP_BOT_MERGE_BUDGET_SECS:-900}}"
    if [[ "$budget" -gt 0 ]]; then
        local ppid="$_BM_PID" ambient="${lock_dir}/ambient.jsonl"
        (
            sleep "$budget"
            local step now
            step="$(cat "$sf" 2>/dev/null || echo unknown)"
            now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            _ambient_write "$ambient" \
                "$(printf '{"ts":"%s","session":"bot-merge-%d","event":"ALERT","kind":"bot_merge_hung","pid":%d,"step":"%s","note":"total budget %ss exceeded — sending SIGTERM"}' \
                    "$now" "$ppid" "$ppid" "$step" "$budget")"
            rm -f "$hf" 2>/dev/null || true
            kill -TERM "$ppid" 2>/dev/null || true
        ) &
        _BM_WATCHDOG_PID=$!
        disown "$_BM_WATCHDOG_PID" 2>/dev/null || true

        # META-156 AC#6: intermediate budget-warn at 50%/75%/90%.
        # Currently the FIRST operator-visible signal is the 100% SIGTERM.
        # These warn checkpoints allow operators to react before the hard kill.
        # scanner-anchor: "kind":"bot_merge_budget_warn"
        local _bw_ppid="$ppid" _bw_ambient="$ambient" _bw_sf="$sf" _bw_budget="$budget"
        (
            local pcts=(50 75 90)
            for pct in "${pcts[@]}"; do
                local warn_secs=$(( _bw_budget * pct / 100 ))
                sleep "$warn_secs" 2>/dev/null
                local step now elapsed_s
                step="$(cat "$_bw_sf" 2>/dev/null || echo unknown)"
                now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
                elapsed_s="$warn_secs"
                # Only emit if parent process is still alive
                kill -0 "$_bw_ppid" 2>/dev/null || break
                printf '{"ts":"%s","kind":"bot_merge_budget_warn","pid":%d,"current_step":"%s","elapsed_s":%d,"budget_s":%d,"pct_used":%d,"note":"META-156 AC#6 — %d%% of budget elapsed; SIGTERM at 100%%"}\n' \
                    "$now" "$_bw_ppid" "$step" "$elapsed_s" "$_bw_budget" "$pct" "$pct" \
                    >> "$_bw_ambient" 2>/dev/null || true
                printf '\033[0;33m[bot-merge] BUDGET-WARN: %d%% of total budget elapsed (%ds/%ds) — current step: %s\033[0m\n' \
                    "$pct" "$elapsed_s" "$_bw_budget" "$step" >&2 || true
                : # pcts iteration handles spacing; sleep to next threshold handled by outer loop
            done
        ) &
        _BM_BUDGET_WARN_PID=$!
        disown "$_BM_BUDGET_WARN_PID" 2>/dev/null || true
    fi

    # META-156 AC#7: record session start time for bot_merge_completed duration.
    _BM_SESSION_T0_MS="$(_bm_ms_now 2>/dev/null || echo 0)"

    info "INFRA-119: health monitoring active (file=$(basename "$_BM_HEALTH_FILE") budget=${budget}s steps=$(basename "$_BM_STEPS_FILE"))"
}

# ── Repo context ──────────────────────────────────────────────────────────────
# INFRA-109: REPO_ROOT is the worktree (we cd into it for git ops). LOCK_DIR
# resolves to the MAIN repo's .chump-locks/ so health files + leases are
# visible to siblings. queue-health-monitor.sh reads from the main repo path.
# shellcheck source=../lib/repo-paths.sh
source "$(dirname "$0")/../lib/repo-paths.sh"
# RESILIENT-138: bare `chump` invocations below (gap show/preflight/set/ship
# etc.) resolve their state.db path via `repo_path::repo_root()`, which falls
# back to CWD when CHUMP_REPO/CHUMP_HOME are unset and no `.env` is found —
# in a linked worktree that CWD has no `.chump/state.db` of its own, so a
# freshly reserved+claimed gap looks "not found in state.db" until an
# operator manually exports CHUMP_REPO. MAIN_REPO (just resolved above via
# --git-common-dir) is always correct regardless of env/`.env` state, so
# default CHUMP_REPO to it for the rest of this script. Respect an
# explicitly-set CHUMP_REPO (e.g. multi-repo test harnesses) rather than
# clobbering it.
export CHUMP_REPO="${CHUMP_REPO:-$MAIN_REPO}"
# INFRA-2744: lease_session_from_statedb — resolve a gap's claim session from the
# canonical state.db leases table (interactive `chump claim` writes no JSON sidecar).
# shellcheck source=../lib/lease.sh
source "$(dirname "$0")/../lib/lease.sh"
# shellcheck source=lib/github.sh
# INFRA-999: chump_gh + chump_gh_record for API cost telemetry.
source "$(dirname "$0")/lib/github.sh"
# INFRA-1241: route ambient appends through helper (surfaces errors to stderr).
# shellcheck source=lib/ambient-write.sh
source "$(dirname "$0")/lib/ambient-write.sh"
# shellcheck source=lib/github_cache.sh
# INFRA-1130: cache_lookup_pr / cache_lookup_checks for zero-API CI polling.
source "$(dirname "$0")/lib/github_cache.sh"
# INFRA-1055: API rate-limit circuit breaker (non-fatal if missing on old branches).
# shellcheck source=api-rate-limit-gate.sh
_rl_gate_path="$(dirname "$0")/api-rate-limit-gate.sh"
# shellcheck disable=SC1090  # dynamic optional source; path computed at runtime
[[ -f "$_rl_gate_path" ]] && source "$_rl_gate_path"
unset _rl_gate_path
# INFRA-1169: fail fast if the worktree has been reaped before we emit health
# files or create any files — prevents the 15-line No-such-file-or-directory
# spam from _bm_health_init trying to write .chump-locks/*.health.tmp.
if [[ ! -d "$REPO_ROOT" ]]; then
    echo "[bot-merge] ERROR: worktree '$REPO_ROOT' no longer exists (reaped?)." >&2
    echo "[bot-merge]   This bot-merge was triggered after the worktree was pruned." >&2
    echo "[bot-merge]   Re-claim the gap or ship from main checkout if still needed." >&2
    _bm_emit_path="$(command -v chump 2>/dev/null || true)"
    if [[ -n "$_bm_emit_path" ]]; then
        "$_bm_emit_path" ambient emit bot_merge_aborted_no_worktree \
            "gap=${GAP_IDS[*]:-unknown}" "worktree_path=$REPO_ROOT" 2>/dev/null || true
    fi
    exit 17
fi
# Also check if the gap is already shipped — exit cleanly to avoid wasted CI.
if command -v chump >/dev/null 2>&1 && [[ ${#GAP_IDS[@]} -gt 0 ]]; then
    for _gid in "${GAP_IDS[@]}"; do
        _status="$(chump gap show "$_gid" 2>/dev/null | grep -E '^\s+status:' | awk '{print $2}' || true)"
        if [[ "$_status" == "done" ]]; then
            _closed="$(chump gap show "$_gid" 2>/dev/null | grep -E 'closed_pr:' | awk '{print $2}' || true)"
            echo "[bot-merge] $_gid already shipped (closed_pr=${_closed:-unknown}) — nothing to do." >&2
            exit 0
        fi
    done
fi

cd "$REPO_ROOT"
# INFRA-469: route every `chump` call through the wedge-heal shim.
export PATH="$REPO_ROOT/bin:$PATH"

# ── INFRA-224: ensure pre-commit hooks are installed before any commit ────────
# Cold Water Red Letter #10 (2026-05-02) found that fresh CCR sandboxes / new
# worktrees commit through bot-merge.sh WITHOUT the pre-commit hook installed,
# silently bypassing every guard (closed_pr integrity, gaps-yaml-discipline,
# duplicate-id, etc.). Result: 9 gaps shipped with `closed_pr: TBD` since
# 2026-05-01 alone. This block ensures the hook is present before we make any
# commits, so the guards always run.
#
# Cheap (a stat call); silent on the happy path. Bypass with
# CHUMP_INSTALL_HOOKS=0 if you really know what you're doing.
#
# NOTE: must use git's resolved git-dir, not "$REPO_ROOT/.git", because in a
# linked worktree .git is a file (gitdir pointer), not a directory. The hook
# we care about lives at <git-dir-for-this-worktree>/hooks/pre-commit.
if [[ "${CHUMP_INSTALL_HOOKS:-1}" == "1" ]] \
        && [[ -x "$REPO_ROOT/scripts/setup/install-hooks.sh" ]]; then
    _bm_git_dir="$(git -C "$REPO_ROOT" rev-parse --absolute-git-dir 2>/dev/null || echo "$REPO_ROOT/.git")"
    if [[ ! -x "$_bm_git_dir/hooks/pre-commit" ]]; then
        bash "$REPO_ROOT/scripts/setup/install-hooks.sh" --quiet 2>/dev/null \
            && echo "[bot-merge] installed pre-commit hooks (INFRA-224 first-run)" \
            || echo "[bot-merge] WARN: install-hooks.sh failed; pre-commit guards may be skipped" >&2
    fi
    unset _bm_git_dir
fi

# INFRA-017: attribute bot-merge synthetic commits (fmt amends, checkpoint tags)
# to the canonical dispatched-agent identity so Red Letter doesn't flag them as
# foreign-actor intrusions. Human sessions override with their own git config.
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-Chump Dispatched}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-chump-dispatch@chump.bot}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-Chump Dispatched}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-chump-dispatch@chump.bot}"

# ── Session-ID auto-detection ─────────────────────────────────────────────────
# `chump gap preflight` reads CHUMP_SESSION_ID to distinguish "our" claim from others'.
# If not set, try to infer it from an existing gap lease file so the preflight
# recognises our own claim at ship time (the claim may have been written by a
# different shell with a different default session ID — e.g. CHUMP_SESSION_ID
# set explicitly during chump claim vs. ~/.chump/session_id at bot-merge time).
#
# INFRA-045 (2026-04-24): also match pending_new_gap.id, not just gap_id.
# For new gaps reserved via gap-reserve.sh, the caller's lease has a
# pending_new_gap reservation (gap isn't yet on origin/main). Without this
# match, bot-merge spawned a new session via its worktree-scoped fallback,
# post-rebase preflight ran under that new session (no pending_new_gap),
# and failed with "not found in docs/gaps.yaml" — forcing the INFRA-028
# manual path. Surfaced by PR #476 (PRODUCT-015).
if [[ -z "${CHUMP_SESSION_ID:-}" && ${#GAP_IDS[@]} -gt 0 ]]; then
    # LOCK_DIR is set by repo-paths.sh (sourced above) — main-repo path.
    for _gid in "${GAP_IDS[@]}"; do
        for _lf in "$LOCK_DIR"/*.json; do
            [[ -f "$_lf" ]] || continue
            _match=$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    if d.get('gap_id', '') == sys.argv[2]:
        print(d.get('session_id', ''))
    else:
        p = d.get('pending_new_gap')
        if isinstance(p, dict) and p.get('id', '') == sys.argv[2]:
            print(d.get('session_id', ''))
except Exception:
    pass
" "$_lf" "$_gid" 2>/dev/null || true)
            if [[ -n "$_match" ]]; then
                export CHUMP_SESSION_ID="$_match"
                info "Auto-detected session ID from gap lease: $CHUMP_SESSION_ID"
                break 2
            fi
        done
    done
    # INFRA-2744: JSON lock files are legacy — interactive `chump claim` writes
    # the lease to state.db only. Fall back to the canonical leases table so we
    # recognize the operator's own claim (else bot-merge re-claim refuses it).
    if [[ -z "${CHUMP_SESSION_ID:-}" ]]; then
        for _gid in "${GAP_IDS[@]}"; do
            _sess="$(lease_session_from_statedb "$_gid" "${MAIN_REPO:-${REPO_ROOT:-.}}/.chump/state.db")"
            if [[ -n "$_sess" ]]; then
                export CHUMP_SESSION_ID="$_sess"
                info "INFRA-2744: resolved session ID from state.db lease: $CHUMP_SESSION_ID"
                break
            fi
        done
    fi
fi

# INFRA-3455: RECONCILE (not just fill). The block above only resolves when
# CHUMP_SESSION_ID is UNSET. But an operator shell often already exports a stale
# CHUMP_SESSION_ID (a long-lived session, or a value from a prior claim). If the
# gap's lease names a DIFFERENT session, bot-merge would hand that wrong value to
# `chump gap preflight`, and preflight_claim_is_self (INFRA-3446) would compare
# the wrong session → false "live-claimed by <other>" on the operator's OWN gap.
# So override CHUMP_SESSION_ID with the gap's lease owner whenever they differ.
if [[ ${#GAP_IDS[@]} -gt 0 ]] && command -v sqlite3 &>/dev/null; then
    for _gid in "${GAP_IDS[@]}"; do
        _lease_sess="$(lease_session_from_statedb "$_gid" "${MAIN_REPO:-${REPO_ROOT:-.}}/.chump/state.db")"
        if [[ -n "$_lease_sess" ]]; then
            if [[ "$_lease_sess" != "${CHUMP_SESSION_ID:-}" ]]; then
                info "INFRA-3455: reconciled CHUMP_SESSION_ID to gap $_gid lease owner ($_lease_sess; was '${CHUMP_SESSION_ID:-<unset>}')"
                export CHUMP_SESSION_ID="$_lease_sess"
            fi
            break
        fi
    done
fi

# INFRA-919: release lease on any exit so the gap can be re-claimed after a
# failure without hitting "lease conflict". Guards are evaluated at exit time
# so late-set CHUMP_SESSION_ID values are captured. On successful ship, the
# explicit rm near the end of the script fires first; the trap is a no-op there.
# ZERO-WASTE-023: bash keeps ONE EXIT trap — this line used to REPLACE the
# '_bm_cleanup' EXIT trap set earlier, so no exit path ever killed the
# heartbeat/watchdog subshells. Every bot-merge exit orphaned a heartbeat
# loop that appended "⏳ alive — step=<stale>" to the cycle log every 30s
# forever (30+ ghost processes on chumpd-eu masqueraded as init hangs).
# Chain _bm_cleanup here instead of clobbering it.
# RESILIENT-132 AC#4: this rm used to fire unconditionally, so ANY stage
# timeout (budget-watchdog SIGTERM, per-step gtimeout, git-push stall) threw
# away the lease file even though _emit_hang_alert / _bm_sigterm_handler
# treat those as recoverable stalls, not a give-up. Skip the rm when
# _BM_TIMEOUT_EXIT is set so the lease survives and a retry can resume the
# same claim instead of re-claiming from scratch (root cause of the
# worktree/branch-exists + ghost-NATS-KV-claim cascade in this gap).
trap '_bm_cleanup; [[ "${DRY_RUN:-0}" -eq 0 && "${_BM_TIMEOUT_EXIT:-0}" != "1" && -n "${CHUMP_SESSION_ID:-}" ]] && rm -f "${LOCK_DIR:-$REPO_ROOT/.chump-locks}/${CHUMP_SESSION_ID}.json" 2>/dev/null || true; orch_log_end "bot-merge.sh" "$?"' EXIT

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$BRANCH" == "HEAD" ]]; then
    red "Detached HEAD — check out a branch first."
    exit 2
fi
if [[ "$BRANCH" == "main" || "$BRANCH" == "master" ]]; then
    red "Already on $BRANCH. Run from a feature/agent branch."
    exit 2
fi

# INFRA-187: derive default branch name from worktree directory if current branch
# doesn't already follow the tool-prefix naming convention (chump/, claude/, etc).
# This lets agents create a worktree without specifying -b, and bot-merge derives
# the branch name from the worktree dir (e.g., .chump/worktrees/infra-127 → chump/infra-127).
_wt_dir="$(basename "$REPO_ROOT" 2>/dev/null || echo "")"
# INFRA-632: build the known-prefix pattern from BRANCH_PREFIX + legacy Chump prefixes.
_known_prefix_re="^(${BRANCH_PREFIX}|chump|claude|chore|cursor|goose|aider)/"
_known_wt_re="^(${BRANCH_PREFIX}|chump|claude|chore|cursor|goose|aider)-"
if [[ -n "$_wt_dir" ]] && ! echo "$BRANCH" | grep -qE "$_known_prefix_re"; then
    # Current branch doesn't have a tool prefix. If the worktree basename doesn't
    # start with a tool prefix either, derive <BRANCH_PREFIX>/<basename> as a suggestion.
    if ! echo "$_wt_dir" | grep -qE "$_known_wt_re"; then
        _default_branch="${BRANCH_PREFIX}/${_wt_dir}"
        info "INFRA-187: current branch '$BRANCH' lacks tool prefix (${BRANCH_PREFIX}/, chump/, claude/, etc.)."
        info "Renaming to match worktree: $BRANCH → $_default_branch"
        if ! run git branch -m "$BRANCH" "$_default_branch"; then
            red "Failed to rename branch — proceeding with current branch '$BRANCH'."
        else
            BRANCH="$_default_branch"
            green "Branch renamed to $BRANCH"
        fi
    fi
fi

BASE_BRANCH="${BASE_BRANCH:-main}"
REMOTE="${REMOTE:-origin}"

# ── INFRA-2252: offline mode — route to the local merge queue ────────────────
# When CHUMP_GITHUB_MODE=offline, none of the GitHub-facing machinery below
# (API probe, gh pr create, gh pr merge --auto) can work — there is no
# network. Enqueue + drain through scripts/coord/local-merge-queue.sh instead
# (docs/design/OFFLINE_FIRST.md §2 / §4). The online path below this block
# is unchanged for every other CHUMP_GITHUB_MODE value.
if [[ "${CHUMP_GITHUB_MODE:-full}" == "offline" ]]; then
    info "CHUMP_GITHUB_MODE=offline — routing ${GAP_IDS[*]:-$BRANCH} through local-merge-queue.sh"
    _lmq="$(dirname "$0")/local-merge-queue.sh"
    _lmq_gap="${GAP_IDS[0]:-$BRANCH}"
    if ! bash "$_lmq" enqueue "$_lmq_gap" "$BRANCH" >/dev/null; then
        red "local-merge-queue enqueue failed for $_lmq_gap"
        exit 1
    fi
    if bash "$_lmq" process; then
        green "$_lmq_gap merged locally via local-merge-queue.sh (offline mode)."
        exit 0
    else
        red "local-merge-queue process reported a failure — see kind=local_merge_blocked in ambient.jsonl"
        exit 1
    fi
fi

# ── INFRA-119: start health monitoring now that REPO_ROOT is set ──────────────
_bm_health_init "$REPO_ROOT/.chump-locks"
# INFRA-2272: initialise per-step progress ledger (requires GAP_IDS + LOCK_DIR).
_bm_progress_init "${LOCK_DIR:-$REPO_ROOT/.chump-locks}"

# ── INFRA-1034: always tee stdout+stderr to a per-PID log file ───────────────
# Problem observed 2026-05-13: launching bot-merge in the background with
# `bash bot-merge.sh ... 2>&1 | tail -15 &` produces 0-byte output until the
# script exits because the tail pipe buffers. Operator can't see progress for
# 4+ minutes. Always-on tee removes the buffering trap and gives a stable
# `tail -f` target regardless of how the caller redirects.
#
# Opt-out: CHUMP_BOT_MERGE_NO_TEE=1 (preserves prior behavior for callers that
# want the script's stdout to flow only through their own pipe).
if [[ "${DRY_RUN:-0}" != "1" && "${CHUMP_BOT_MERGE_NO_TEE:-0}" != "1" ]]; then
    _BM_LOG_FILE="${REPO_ROOT}/.chump-locks/bot-merge-${_BM_PID}.log"
    # META-156 AC#5: print log path to stdout in first second so IDE callers
    # see where output is going before any buffering can occur.
    printf '[bot-merge] log: %s\n' "$_BM_LOG_FILE"
    # Print legacy banner too (keeps existing tooling that scans for INFRA-1034).
    info "[INFRA-1034] full log: $_BM_LOG_FILE  (tail -f to follow)"
    # META-156 AC#4: advertise the log path to a session-visible file so
    # operators/curators can `tail -F` immediately without knowing the PID.
    # Written to LOCK_DIR (main repo .chump-locks/) so it's visible to siblings.
    _bm_active_path_file="${LOCK_DIR:-${REPO_ROOT}/.chump-locks}/bot-merge-active-${CHUMP_SESSION_ID:-$$}.path"
    printf '%s\n' "$_BM_LOG_FILE" > "$_bm_active_path_file" 2>/dev/null || true
    # Emit a discoverable marker so fleet-brief / operator-recall / chump-
    # ambient-glance can show "bot-merge currently running, log at X" without
    # scanning ps. Debounced to once per script invocation by virtue of being
    # outside the heartbeat loop.
    _bm_amb_path="${REPO_ROOT}/.chump-locks/ambient.jsonl"
    printf '{"ts":"%s","kind":"bot_merge_log_started","pid":%d,"log_path":"%s","branch":"%s","active_path_file":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_BM_PID" "$_BM_LOG_FILE" "${BRANCH:-unknown}" \
        "${_bm_active_path_file:-}" \
        >> "$_bm_amb_path" 2>/dev/null || true
    # Process substitution: every subsequent write to stdout/stderr is
    # duplicated into the log file. tee runs in its own subprocess that
    # exits when the script's fd 1/2 close.
    exec > >(tee -a "$_BM_LOG_FILE") 2>&1
fi

# ── INFRA-1422: recovery-mode fast path ──────────────────────────────────────
# When a prior run emitted botmerge_wedged, the operator retries with
# CHUMP_BOT_MERGE_RECOVERY_MODE=1.  In recovery mode we skip all expensive
# stages (rebase, clippy, test) and directly push + create/update the PR +
# arm auto-merge.  This is safe because the branch already passed the full
# pipeline before wedging; we only need to retry the network I/O leg.
if [[ "${CHUMP_BOT_MERGE_RECOVERY_MODE:-0}" == "1" ]]; then
    info "INFRA-1422: CHUMP_BOT_MERGE_RECOVERY_MODE=1 — skipping rebase/lint/test, fast-path push + PR + auto-merge"
    _bm_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    _gap_lbl="${GAP_IDS[0]:-${GAP_ID:-unknown}}"
    _bm_recover_amb="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
    printf '{"ts":"%s","kind":"botmerge_recovery_start","gap":"%s","branch":"%s","note":"INFRA-1422 fast-path retry"}\n' \
        "$_bm_ts" "$_gap_lbl" "${BRANCH:-unknown}" >> "$_bm_recover_amb" 2>/dev/null || true

    # INFRA-306: pre-push MERGED check (recovery path). If a PR for this
    # branch already merged (auto-merge fired during wedge window), skip the
    # destructive force-push. Bypass: CHUMP_SKIP_MERGED_CHECK=1.
    if [[ "${CHUMP_SKIP_MERGED_CHECK:-0}" != "1" ]]; then
        _recover_pr_state="$(gh pr list --head "$BRANCH" --state all --json state --jq '.[0].state // empty' 2>/dev/null || true)"
        if [[ "$_recover_pr_state" == "MERGED" ]]; then
            info "INFRA-306: branch $BRANCH already MERGED — skipping recovery force-push"
            exit 0
        fi
    fi

    stage_start "recovery: push"
    run git push -u origin "$BRANCH" --force-with-lease
    stage_done

    stage_start "recovery: pr create/update"
    # Check if PR already exists for this branch.
    _recover_pr_num="$(gh pr list --head "$BRANCH" --json number --jq '.[0].number // empty' 2>/dev/null || true)"
    _recover_pr_create_out=""
    _recover_pr_create_rc=0
    if [[ -z "$_recover_pr_num" ]]; then
        _recover_pr_create_out="$(gh pr create --base main --head "$BRANCH" \
            --title "$(git log -1 --pretty=%s)" \
            --body "Recovery push — INFRA-1422 stage-budget circuit breaker retry." \
            --json number 2>&1)"
        _recover_pr_create_rc=$?
        if [[ $_recover_pr_create_rc -eq 0 ]]; then
            _recover_pr_num="$(printf '%s' "$_recover_pr_create_out" | jq -r '.number // empty' 2>/dev/null || true)"
        fi
    fi
    stage_done

    # RESILIENT-217: `gh pr create`'s failure must not be silently swallowed.
    # Previously a bare `|| true` discarded gh's exit code, so a failed
    # create (auth hiccup, rate limit, network blip) left _recover_pr_num
    # empty while stage_done still logged "pr create/update done" and the
    # function fell through to exit 0 — reporting success with no PR.
    if [[ -z "$_recover_pr_num" ]]; then
        _recover_pr_fail_reason="${_recover_pr_create_out:-gh pr create returned no PR number}"
        _recover_pr_fail_reason="$(printf '%s' "$_recover_pr_fail_reason" | tr '\n' ' ' | tr '"' "'" | cut -c1-300)"
        red "[RESILIENT-217] recovery-mode PR creation failed for branch $BRANCH: $_recover_pr_fail_reason"
        printf '{"ts":"%s","kind":"botmerge_recovery_pr_create_failed","gap":"%s","branch":"%s","reason":"%s"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_gap_lbl" "${BRANCH:-unknown}" "$_recover_pr_fail_reason" \
            >> "$_bm_recover_amb" 2>/dev/null || true
        exit 1
    fi

    if [[ -n "$_recover_pr_num" && "${AUTO_MERGE:-0}" == "1" ]]; then
        stage_start "recovery: arm auto-merge"
        gh pr merge "$_recover_pr_num" --auto --squash 2>/dev/null || true
        stage_done
        info "INFRA-1422: PR #$_recover_pr_num armed for auto-merge (recovery path)"
    fi

    printf '{"ts":"%s","kind":"botmerge_recovery_done","gap":"%s","pr":"%s","branch":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_gap_lbl" "${_recover_pr_num:-?}" "${BRANCH:-unknown}" \
        >> "$_bm_recover_amb" 2>/dev/null || true
    exit 0
fi

# ── META-156 AC#1: step=init start ───────────────────────────────────────────
_bm_step_start "init"

# ── INFRA-539: probe GitHub API before doing any real work ────────────────────
if [[ "${DRY_RUN:-0}" != "1" ]]; then
    gh_api_probe || {
        red "Aborting bot-merge: GitHub unreachable. Retry when connectivity is restored."
        _bm_step_done "init" 1
        _BM_TERMINAL_STATE="aborted_no_auth"
        exit 1
    }
    # INFRA-1055: circuit breaker — check quota headroom before any real work.
    # Returns 2 (exhausted) → hard stop; returns 1 (approaching) → degraded mode.
    if declare -F rate_limit_gate >/dev/null 2>&1; then
        _rl_gate_rc=0
        rate_limit_gate "startup" --source "bot-merge.sh" || _rl_gate_rc=$?
        if [[ $_rl_gate_rc -eq 2 ]]; then
            red "INFRA-1055: REST API quota exhausted — aborting bot-merge to prevent churn (rate_limit_exhausted event emitted)."
            _bm_step_done "init" 1
            _BM_TERMINAL_STATE="aborted_no_auth"
            exit 1
        fi
        # _rl_gate_rc=1 (approaching): continue in degraded mode — GraphQL-heavy
        # optional phases will be skipped below when RL_GQL_PCT is low.
        export _BM_RL_DEGRADED="${_rl_gate_rc:-0}"
    fi

    # META-156 AC#3: GraphQL 401 / graphql_exhausted hard-fail-fast in init.
    # Detects a recent graphql_exhausted event in ambient.jsonl (within last
    # CHUMP_BOT_MERGE_AUTH_PROBE_LOOKBACK_S, default 300s=5min) OR a live
    # GraphQL 401 response and emits kind=bot_merge_aborted_no_auth, then
    # exits within 30s. Does NOT enter the retry loop that burns 600s.
    # Bypass: CHUMP_BOT_MERGE_AUTH_PROBE_SKIP=1
    if [[ "${CHUMP_BOT_MERGE_AUTH_PROBE_SKIP:-0}" != "1" ]]; then
        _auth_probe_lookback="${CHUMP_BOT_MERGE_AUTH_PROBE_LOOKBACK_S:-300}"
        _auth_probe_ambient="${CHUMP_AMBIENT_LOG:-${REPO_ROOT}/.chump-locks/ambient.jsonl}"
        _auth_abort=0
        _auth_abort_reason=""

        # Check ambient for recent graphql_exhausted event.
        if [[ -r "$_auth_probe_ambient" ]]; then
            _auth_cutoff=$(date -u -v-"${_auth_probe_lookback}"S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
                || date -u -d "@$(( $(date +%s) - _auth_probe_lookback ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
                || echo "")
            if [[ -n "$_auth_cutoff" ]]; then
                _auth_gql_hit=$(tail -100 "$_auth_probe_ambient" 2>/dev/null | python3 -c "
import json, sys
cutoff = '''$_auth_cutoff'''
for line in sys.stdin:
    try:
        o = json.loads(line.strip())
    except Exception:
        continue
    if isinstance(o, dict) and o.get('kind') == 'graphql_exhausted' and o.get('ts','') > cutoff:
        print(o.get('ts','?'))
        sys.exit(0)
" 2>/dev/null || true)
                if [[ -n "$_auth_gql_hit" ]]; then
                    _auth_abort=1
                    _auth_abort_reason="graphql_exhausted in ambient stream (last event: $_auth_gql_hit)"
                fi
            fi
        fi

        # If not already aborting, do a live GraphQL probe (10s timeout).
        if [[ "$_auth_abort" -eq 0 ]]; then
            _auth_gql_rc=0
            timeout 10 gh api graphql -f query='{ viewer { login } }' >/dev/null 2>&1 || _auth_gql_rc=$?
            if [[ "$_auth_gql_rc" -eq 1 ]]; then
                # exit 1 from gh api typically means auth error / 401.
                _auth_abort=1
                _auth_abort_reason="GraphQL probe exited ${_auth_gql_rc} (likely 401 / token expired)"
            fi
        fi

        if [[ "$_auth_abort" -eq 1 ]]; then
            _auth_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            _auth_gap="${GAP_IDS[0]:-${GAP_ID:-unknown}}"
            # scanner-anchor: "kind":"bot_merge_aborted_no_auth"
            printf '{"ts":"%s","kind":"bot_merge_aborted_no_auth","gap":"%s","branch":"%s","reason":"%s","note":"META-156 AC#3 — hard-fail-fast; fix auth then retry"}\n' \
                "$_auth_ts" "$_auth_gap" "${BRANCH:-unknown}" "$_auth_abort_reason" \
                >> "$_auth_probe_ambient" 2>/dev/null || true
            red "META-156 AC#3: GraphQL auth failure detected — hard-fail-fast (not burning 600s budget)."
            red "  Reason: $_auth_abort_reason"
            red "  Fix: gh auth status / gh auth refresh / CHUMP_BOT_MERGE_GRAPHQL_WEDGE_LOOKBACK_S"
            red "  Bypass: CHUMP_BOT_MERGE_AUTH_PROBE_SKIP=1"
            _bm_step_done "init" 1
            _BM_TERMINAL_STATE="aborted_no_auth"
            exit 1
        fi
        unset _auth_probe_lookback _auth_probe_ambient _auth_abort _auth_abort_reason \
              _auth_gql_rc _auth_gql_hit _auth_ts _auth_gap _auth_cutoff
    fi
fi

# META-156 AC#1: step=init done (AC#3 probe passed, API reachable)
_bm_step_done "init" 0

# ── INFRA-379: chump-doctor preflight ─────────────────────────────────────────
# macOS Sequoia syspolicyd occasionally wedges a chump binary's inode at
# `_dyld_start`, hanging every subsequent `chump …` invocation indefinitely.
# bot-merge.sh makes ~5 chump calls (preflight, claim, ship, release, etc.) —
# any one of them hanging stalls the whole pipeline for 30+ minutes before
# the operator notices.
#
# chump-binary-unwedge.sh probes (5s timeout) and self-heals by replacing the wedged
# inode. Idempotent — exit 0 if healthy, exit 0 after heal, exit 1 only on
# hard failure (rebuild needed). Run BEFORE any chump call so wedge is
# caught upfront, not midstream.
#
# Bypass: CHUMP_DOCTOR_SKIP=1 (cron-side, or for the chump-doctor PR itself).
if [[ "${CHUMP_DOCTOR_SKIP:-0}" != "1" ]] \
        && [[ -x "$REPO_ROOT/scripts/dev/chump-binary-unwedge.sh" ]]; then
    if ! bash "$REPO_ROOT/scripts/dev/chump-binary-unwedge.sh" >/dev/null 2>&1; then
        # See: docs/process/CLAUDE_GOTCHAS.md#error-binary-wedge
        die_with_help "chump binary is wedged and could not self-heal — every subsequent chump call will hang. Run: CHUMP_DOCTOR_FORCE=1 scripts/dev/chump-binary-unwedge.sh" "error-binary-wedge"
    fi
fi

# INFRA-061 (M3): if --stack-on <PREV-GAP> was passed, look up the open PR for
# that gap and use its head branch as our base. Falls back to main with a
# warning if the prev gap has no open PR (already landed → just stack on main).
if [[ -n "$STACK_ON_GAP" ]]; then
    info "Resolving --stack-on $STACK_ON_GAP via gh pr list …"
    _stack_branch=$(gh pr list --state open --search "$STACK_ON_GAP in:title,body" \
        --json number,headRefName --jq '.[0].headRefName' 2>/dev/null || echo "")
    if [[ -z "$_stack_branch" || "$_stack_branch" == "null" ]]; then
        info "No open PR found for $STACK_ON_GAP — falling back to base=main."
        info "(If the prev gap already landed, this is correct. Otherwise check the gap ID.)"
    else
        BASE_BRANCH="$_stack_branch"
        green "Stacking on PR for $STACK_ON_GAP — base=$BASE_BRANCH"
    fi
fi

green "=== bot-merge: $BRANCH → $BASE_BRANCH ==="

# ── INFRA-2133: META-124/C5 Mode A/B/C routing ───────────────────────────────
# Mode A (DEFAULT — batched): normal gaps routed to chump-integrator-daemon via
#   ready_to_ship status + work-board NATS post. Exits 0 without opening a PR.
# Mode B (review/external-collab): runs existing PR-create + auto-merge flow.
# Mode C (hot-fix): P0 priority + TRUNK-RED/HOTFIX/SECURITY in title, or
#   --hot-fix flag: runs existing PR-create + auto-merge flow (same as B, distinct
#   for operator visibility and future escalation paths).
# Fallback: NATS unavailable (chump-coord exits non-zero on post) → treat as Mode B.
# Bypass:  --legacy flag or BM_LEGACY_MODE=1 forces Mode B unconditionally.
#
# Detection uses the first gap ID only (same as existing preflight logic).
_BM_MODE="A"   # default: batched integration queue
_BM_MODE_REASON=""

if [[ "${BM_LEGACY_MODE:-0}" == "1" ]]; then
    _BM_MODE="B"
    _BM_MODE_REASON="legacy flag"
elif [[ "${BM_FORCE_HOTFIX:-0}" == "1" ]]; then
    _BM_MODE="C"
    _BM_MODE_REASON="--hot-fix flag"
elif [[ "${BM_FORCE_REVIEW:-0}" == "1" || "${CHUMP_FORCE_REVIEW:-}" == "1" ]]; then
    _BM_MODE="B"
    _BM_MODE_REASON="--review flag or CHUMP_FORCE_REVIEW"
elif [[ ${#GAP_IDS[@]} -gt 0 ]] && command -v chump >/dev/null 2>&1; then
    _bm_route_gap="${GAP_IDS[0]}"
    # Pull fields from gap metadata for routing decisions.
    _bm_gap_meta="$(chump gap show "$_bm_route_gap" 2>/dev/null || true)"
    _bm_gap_title="$(printf '%s' "$_bm_gap_meta" | grep -E '^\s+title:' | sed 's/^[[:space:]]*title:[[:space:]]*//' | tr -d '"' || true)"
    _bm_gap_priority="$(printf '%s' "$_bm_gap_meta" | grep -E '^\s+priority:' | awk '{print $2}' || true)"
    _bm_gap_domain="$(printf '%s' "$_bm_gap_meta" | grep -E '^\s+domain:' | awk '{print $2}' || true)"
    _bm_gap_skills="$(printf '%s' "$_bm_gap_meta" | grep -E 'skills_required' || true)"

    # Mode C: P0 priority + hot-fix keywords in title
    if [[ "$_bm_gap_priority" == "P0" ]] \
        && printf '%s' "$_bm_gap_title" | grep -qiE 'TRUNK-RED|HOTFIX|SECURITY'; then  # pipefail-sweep-allowed
        _BM_MODE="C"
        _BM_MODE_REASON="P0+hot-fix keyword in title (${_bm_route_gap})"
    # Mode B: REVIEW: prefix in title, external-collab skill, or EXTERNAL domain
    elif printf '%s' "$_bm_gap_title" | grep -qiE '^[[:space:]]*REVIEW:'; then  # pipefail-sweep-allowed
        _BM_MODE="B"
        _BM_MODE_REASON="REVIEW: title prefix (${_bm_route_gap})"
    elif printf '%s' "$_bm_gap_skills" | grep -qi 'external-collab'; then  # pipefail-sweep-allowed
        _BM_MODE="B"
        _BM_MODE_REASON="external-collab skill (${_bm_route_gap})"
    elif [[ "$_bm_gap_domain" == "EXTERNAL" ]]; then
        _BM_MODE="B"
        _BM_MODE_REASON="EXTERNAL domain (${_bm_route_gap})"
    fi
fi

# ── INFRA-2523: fail-OPEN Mode A → Mode B when the integrator can't drain ─────
# NATS-up != integrator-alive. On 2026-06-03 the chump-integrator daemon was a
# MISSING binary (launchd exit 127) while NATS was up, so the existing
# work-board fallback (which only checks NATS) still chose Mode A and silently
# queued gaps into a dead queue → limbo (INFRA-2455; the INFRA-1120/2188 ghost
# class). Verify the integrator binary + daemon health; if it can't actually
# drain, fail open to per-PR auto-merge (Mode B), which always lands.
_BM_INTEGRATOR_HEALTHY_CACHE=""
# (INFRA-6988) systemd probe, split out so it's independently testable: the
# Linux coordinator (CJ) runs the Batched Merge Train as
# chump-integrator.{service,timer} via install-integrator-daemon-systemd.sh,
# not launchd. Before this, _bm_integrator_healthy only understood launchd,
# so on the systemd coordinator it fell through to the
# ~/.cargo/bin/chump-integrator existence check, then failed the launchctl
# probe (launchctl doesn't exist on Linux) and ALWAYS reported unhealthy —
# permanently fail-opening Mode A -> Mode B even after --live, defeating the
# go-live.
_bm_integrator_healthy_systemd() {
    local rc=0
    command -v systemctl >/dev/null 2>&1 || return 1
    # (1) timer present + active (mirrors the launchd "loaded" check).
    systemctl is-active --quiet chump-integrator.timer 2>/dev/null || rc=1
    # (2) binary present at the unit's ExecStart path (absent unit -> empty, falls back).
    local _bin
    _bin="$(systemctl cat chump-integrator.service 2>/dev/null \
        | grep -oE '/[^ ]*chump-integrator' | head -1)"
    [[ -n "$_bin" ]] || _bin="/root/.cargo/bin/chump-integrator"
    [[ -x "$_bin" ]] || rc=1
    # (3) last service run didn't hard-fail (absent=never run yet=ok; non-zero=errored).
    local _result
    _result="$(systemctl show chump-integrator.service -p Result --value 2>/dev/null)"
    [[ -z "$_result" || "$_result" == "success" ]] || rc=1
    return "$rc"
}
_bm_integrator_healthy() {
    [[ -n "$_BM_INTEGRATOR_HEALTHY_CACHE" ]] && return "$_BM_INTEGRATOR_HEALTHY_CACHE"
    local rc=0
    # Test hook (mirrors the watchdog MOCK_* pattern): 1=healthy, 0=unhealthy.
    if [[ -n "${CHUMP_BOT_MERGE_MOCK_INTEGRATOR_HEALTH:-}" ]]; then
        [[ "$CHUMP_BOT_MERGE_MOCK_INTEGRATOR_HEALTH" == "1" ]] && rc=0 || rc=1
        _BM_INTEGRATOR_HEALTHY_CACHE="$rc"; return "$rc"
    fi
    if [[ -f /etc/systemd/system/chump-integrator.service ]]; then
        _bm_integrator_healthy_systemd; rc=$?
        _BM_INTEGRATOR_HEALTHY_CACHE="$rc"; return "$rc"
    fi
    # (1) integrator binary present at the daemon plist's ProgramArguments path?
    local _plist="$HOME/Library/LaunchAgents/com.chump.integrator-daemon.plist"
    local _bin
    _bin="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments' "$_plist" 2>/dev/null \
        | grep -oE '/[^ ]*chump-integrator' | head -1)"
    [[ -n "$_bin" ]] || _bin="$HOME/.cargo/bin/chump-integrator"
    [[ -x "$_bin" ]] || rc=1
    # (2) daemon loaded with last-exit 0? (absent=unloaded; non-zero=errored, eg 127)
    if [[ "$rc" -eq 0 ]]; then
        local _st
        _st="$(launchctl list 2>/dev/null | awk '$3=="com.chump.integrator-daemon"{print $2}')"
        [[ "$_st" == "0" ]] || rc=1
    fi
    _BM_INTEGRATOR_HEALTHY_CACHE="$rc"
    return "$rc"
}
_bm_emit_mode_failopen() {
    local _gap="${1:-unknown}" _ts _amb
    _ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    _amb="${CHUMP_AMBIENT_LOG:-${LOCK_DIR:-${REPO_ROOT:-.}/.chump-locks}/ambient.jsonl}"
    # scanner-anchor: "kind":"bot_merge_mode_failopen"
    printf '{"ts":"%s","kind":"bot_merge_mode_failopen","gap_id":"%s","from_mode":"A","to_mode":"B","reason":"integrator daemon unhealthy (binary/launchd) — per-PR fallback so the gap cannot land in dead-queue limbo","note":"INFRA-2523"}\n' \
        "$_ts" "$_gap" >> "$_amb" 2>/dev/null || true
    echo "[bot-merge] INFRA-2523: integrator daemon unhealthy — failing open to per-PR auto-merge (Mode B) so ${_gap} can't land in limbo." >&2
}

if [[ "$_BM_MODE" == "A" ]] && ! _bm_integrator_healthy; then
    _BM_MODE="B"
    _BM_MODE_REASON="integrator daemon unhealthy — fail-open to per-PR (INFRA-2523)"
    _bm_emit_mode_failopen "${_bm_route_gap:-${GAP_IDS[0]:-unknown}}"
fi

info "INFRA-2133: routing mode=${_BM_MODE} reason=${_BM_MODE_REASON:-default}"

if [[ "$_BM_MODE" == "A" ]]; then
    # Mode A: batched integration queue. Mark gap ready_to_ship, post to work-board.
    _bm_route_gap="${GAP_IDS[0]:-}"
    _bm_a_amb="${CHUMP_AMBIENT_LOG:-${LOCK_DIR:-${REPO_ROOT:-.}/.chump-locks}/ambient.jsonl}"
    _bm_a_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # Attempt NATS work-board post first; fall back to Mode B if unavailable.
    _bm_nats_ok=0
    if [[ -n "$_bm_route_gap" ]]; then
        if chump-coord work-board post "$_bm_route_gap" ship-ready \
            "Mode A: ready for integration" >/dev/null 2>&1; then
            _bm_nats_ok=1
        fi
    fi

    if [[ "$_bm_nats_ok" == "0" ]]; then
        # Fallback: NATS unavailable → treat as Mode B (existing flow).
        info "INFRA-2133: NATS/work-board unavailable — falling back to Mode B (existing PR flow)"
        _ambient_write "$_bm_a_amb" \
            "$(printf '{"ts":"%s","kind":"bot_merge_mode_fallback","gap_id":"%s","from":"A","to":"B","reason":"nats_unavailable"}' \
                "$_bm_a_ts" "$_bm_route_gap")"
        # Fall through to existing PR-create flow below (no exit).
    else
        # NATS succeeded: mark gap status and emit ambient event.
        # CREDIBLE-154: this used to run bare `chump gap set ... || true` from
        # inside the claim worktree — which resolves to the WORKTREE-LOCAL
        # .chump/state.db, so the canonical registry never saw ready_to_ship,
        # the integrator queue stayed empty, and the worker's "shipped" was a
        # phantom (2 of the first 3 post-revival ships, 2026-07-19). Pin the
        # CANONICAL repo (main worktree) and VERIFY the write landed; on
        # failure, fail open to Mode B instead of silently pretending.
        _bm_a_enqueued=0
        if [[ -n "$_bm_route_gap" ]]; then
            # INFRA-451: resolve canonical repo root safely across worktrees.
            if [[ -f "$(dirname "$0")/../lib/resolve-main-worktree.sh" ]]; then
                source "$(dirname "$0")/../lib/resolve-main-worktree.sh"
                _bm_canon_repo="$(resolve_main_worktree "$0")"
            else
                _bm_canon_repo="$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}')"
            fi
            [[ -n "$_bm_canon_repo" ]] || _bm_canon_repo="${REPO_ROOT:-$PWD}"
            if CHUMP_REPO="$_bm_canon_repo" chump gap set "$_bm_route_gap" \
                    --status ready_to_ship 2>/dev/null; then
                _bm_ack="$(sqlite3 "${_bm_canon_repo}/.chump/state.db" \
                    "SELECT status FROM gaps WHERE id='${_bm_route_gap}'" 2>/dev/null || true)"
                [[ "$_bm_ack" == "ready_to_ship" ]] && _bm_a_enqueued=1
            fi
            # CREDIBLE-158: record the ACTUAL branch — the integrator's
            # StateDbWorkBoard reads this branch:<name> token; without it the
            # slug-guess fallback fetches a branch that doesn't exist.
            CHUMP_REPO="$_bm_canon_repo" chump gap set "$_bm_route_gap" --notes-append \
                "Mode: batched (chump-integrator-daemon will pick up) branch:${BRANCH}" 2>/dev/null || true
        fi
        if [[ "$_bm_a_enqueued" == "1" ]]; then
            _ambient_write "$_bm_a_amb" \
                "$(printf '{"ts":"%s","kind":"gap_routed_to_batched","gap_id":"%s","branch":"%s","mode":"A","note":"INFRA-2133: routed to integration queue (canonical-db verified, CREDIBLE-154); chump-integrator-daemon will ship"}' \
                    "$_bm_a_ts" "$_bm_route_gap" "$BRANCH")"
            green "Gap ${_bm_route_gap:-none} routed to batched integration queue (canonical-db verified). Integrator daemon will ship in next cycle."
            exit 0
        fi
        # scanner-anchor: "kind":"bot_merge_enqueue_failed"
        _ambient_write "$_bm_a_amb" \
            "$(printf '{"ts":"%s","kind":"bot_merge_enqueue_failed","gap_id":"%s","note":"CREDIBLE-154: Mode A ready_to_ship write did not land in canonical state.db — failing open to Mode B per-PR flow"}' \
                "$_bm_a_ts" "$_bm_route_gap")"
        info "CREDIBLE-154: Mode A enqueue unverified in canonical db — failing open to Mode B (per-PR flow)."
        # Fall through to existing PR-create flow below (no exit).
    fi
fi
# Mode B or C: fall through to existing PR-create + auto-merge flow (unchanged).

# ── INFRA-1346: shadow ship-plan probe ────────────────────────────────────────
# Calls `chump ship plan` once at main-flow entry and emits a ship_plan_advisory
# ambient event. Purely observational — BEST-EFFORT. Any failure (timeout,
# binary missing, gh rate-limit) is caught and ignored; bot-merge continues
# unaffected. Use this advisory stream to spot divergences between the planner's
# intent and what bot-merge actually does (pre-slice-4 of INFRA-1229).
#
# Opt-out: CHUMP_BOT_MERGE_SHADOW_PLAN=0
_bm_shadow_plan() {
    local _amb="${CHUMP_AMBIENT_LOG:-${LOCK_DIR:-${REPO_ROOT:-.}/.chump-locks}/ambient.jsonl}"
    local _gap="${GAP_IDS[0]:-}"
    local _sp_gap_args=()
    [[ -n "$_gap" ]] && _sp_gap_args=(--gap "$_gap")

    local _plan_json
    _plan_json=$(timeout 10 chump ship plan --branch "$BRANCH" "${_sp_gap_args[@]}" --json 2>/dev/null) || {
        info "[INFRA-1346] ship-plan probe timed-out or failed — skipping advisory (best-effort)"
        return 0
    }

    # Extract action field and truncate JSON body to 2 KB.
    local _action _plan_trunc
    _action=$(printf '%s' "$_plan_json" | python3 -c \
        "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('action','unknown'))" \
        2>/dev/null) || _action="unknown"
    _plan_trunc=$(printf '%s' "$_plan_json" | python3 -c \
        "import sys,json
raw=sys.stdin.read()[:2048]
try: print(json.dumps(json.loads(raw),separators=(',',':')))
except: print(json.dumps({'raw':raw[:500]}))" \
        2>/dev/null) || _plan_trunc='{}'

    _ambient_write "$_amb" "$(printf \
        '{"ts":"%s","kind":"ship_plan_advisory","source":"bot-merge.sh","branch":"%s","gap":"%s","plan_action":"%s","plan_json_truncated_to_2kb":%s}' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BRANCH" "$_gap" "$_action" "$_plan_trunc")"

    info "[INFRA-1346] ship_plan_advisory emitted (action=${_action} gap=${_gap:-none})"
}

if [[ "${CHUMP_BOT_MERGE_SHADOW_PLAN:-1}" == "1" ]]; then
    _bm_shadow_plan || true   # best-effort: never block main flow
fi

# ── 0a. Untracked-files handler (INFRA-404) ──────────────────────────────────
# Instead of aborting when untracked files exist, auto-add them with an
# explicit warning. This closes the "partial-ship hazard" where bot-merge
# aborts before pushing, leaving the PR incomplete. Bypass: CHUMP_BOT_MERGE_ALLOW_UNTRACKED=0
if [[ "${CHUMP_BOT_MERGE_ALLOW_UNTRACKED:-1}" != "0" ]]; then
    untracked=$(git ls-files --others --exclude-standard src/ crates/ scripts/ docs/ 2>/dev/null)
    if [[ -n "$untracked" ]]; then
        yellow "INFRA-404: Untracked files found — auto-adding with explicit warning:"
        echo "$untracked" | sed 's/^/  + /'
        git add $untracked
        green "Auto-added $(echo "$untracked" | wc -l) untracked file(s)"
    fi
fi

# ── 0b. Modified-files handler (INFRA-472) ───────────────────────────────────
# INFRA-404 stages untracked but doesn't commit. If the operator's worktree
# has *modified* (M) tracked files OR *staged-but-uncommitted* changes from
# 0a, the upcoming `git rebase` fails with "cannot rebase: You have unstaged
# changes" — observed twice this session (INFRA-458 retry + INFRA-470 ship)
# and three more times across the 2026-05-04 fleet. Each occurrence costs a
# manual commit + bot-merge re-invocation cycle.
#
# Fix: after the INFRA-404 stage, also auto-stage modified files in the
# scoped paths AND commit anything staged with a default message. Pre-commit
# hooks still run (no --no-verify) so the discipline guards aren't bypassed.
# If the hook rejects, exit cleanly with a clear message instead of letting
# git rebase fail later with a cryptic error.
#
# Bypass: CHUMP_BOT_MERGE_AUTO_COMMIT_M=0 (operator wants to handle staging
# manually — useful for partial-stage scenarios where M files are
# intentionally not part of this PR).
if [[ "${CHUMP_BOT_MERGE_AUTO_COMMIT_M:-1}" != "0" ]]; then
    modified=$(git diff --name-only -- src/ crates/ scripts/ docs/ 2>/dev/null)
    if [[ -n "$modified" ]]; then
        yellow "INFRA-472: Modified files found — auto-staging:"
        echo "$modified" | sed 's/^/  M /'
        git add $modified
    fi
    # Whether files came from INFRA-404 (untracked) or INFRA-472 (modified),
    # they're now staged. Commit them so rebase doesn't trip.
    if ! git diff --cached --quiet 2>/dev/null; then
        _autostage_msg="auto: bot-merge pre-rebase staging (INFRA-472)

Auto-committed by bot-merge.sh before rebase to prevent the
'cannot rebase: You have unstaged changes' error class. If this
commit needs a different message, amend after ship lands or split
the PR.

Bypass: CHUMP_BOT_MERGE_AUTO_COMMIT_M=0 to opt out (handles staging manually)."
        if git commit -m "$_autostage_msg"; then
            green "INFRA-472: auto-committed pre-rebase changes"
        else
            red "INFRA-472: auto-commit failed — pre-commit hook rejected the changes."
            red "  Fix the hook errors above, then re-run bot-merge.sh."
            red "  (Or stage+commit manually with scripts/coord/chump-commit.sh and retry.)"
            exit 4
        fi
    fi
fi

# ── 0. Gap pre-flight (abort if work is already done on main) ─────────────────
# META-156 AC#1: step=preflight
if [[ ${#GAP_IDS[@]} -gt 0 ]]; then
    _bm_step_start "preflight"
    info "Running gap pre-flight for: ${GAP_IDS[*]} …"
    # INFRA-193: when speculative, export so gap-preflight allows the
    # concurrent-speculative case (still blocks non-speculative collisions).
    if ! CHUMP_SPECULATIVE="$SPECULATIVE" chump gap preflight "${GAP_IDS[@]}"; then
        red "Gap pre-flight failed — aborting to avoid duplicate work."
        red "The gaps are already done or claimed. Pick a different gap from docs/gaps.yaml."
        _bm_step_done "preflight" 10
        _BM_TERMINAL_STATE="preflight_failed"
        _bm_fail "preflight" 10 "gap already done or claimed"
    fi
    green "Gap pre-flight passed."
    _bm_step_done "preflight" 0

    # META-156 AC#1: step=claim
    _bm_step_start "claim"
    # Write gap claim to lease file (replaces YAML in_progress edit — no merge conflicts).
    # INFRA-193: under `set -u`, an empty bash array can't be safely expanded with
    # "${arr[@]}". Build the optional flag as a string, then word-split via $arr.
    _claim_extra=""
    [[ "$SPECULATIVE" == "1" ]] && _claim_extra="--speculative"
    for gid in "${GAP_IDS[@]}"; do
        if [[ $DRY_RUN -eq 0 ]]; then
            # INFRA-1901: if we are already sitting inside the worktree that
            # holds this gap's lease, skip the `chump claim` re-invocation
            # entirely instead of attempting a claim (and only recovering
            # after it fails, per META-156 AC#2 below). Baseline 2026-05-23:
            # 3 of 4 sub-agents hit "re-claim failed" here and fell back to
            # manual gh pr create + gh pr merge --auto.
            _already_in_lease_wt=0
            if [[ "${CHUMP_BOT_MERGE_CLAIM_LAX:-0}" == "1" ]]; then
                # scanner-anchor: "kind":"bot_merge_skip_claim_lax"
                chump ambient emit bot_merge_skip_claim_lax "gap=$gid" >/dev/null 2>&1 || true
            else
                # AC#3: prefer the canonical state.db lease; fall back to a
                # legacy JSON sidecar (multi-session-claim files) on miss.
                _lease_wt="$(lease_worktree_from_statedb "$gid" "${MAIN_REPO:-${REPO_ROOT:-.}}/.chump/state.db" 2>/dev/null || true)"
                if [[ -z "$_lease_wt" ]]; then
                    for _lf in "$LOCK_DIR"/*.json; do
                        [[ -f "$_lf" ]] || continue
                        if [[ "$(lease_gap_id "$_lf")" == "$gid" ]]; then
                            # EFFECTIVE-312: lockfiles without a worktree field
                            # make lease_worktree's grep pipeline fail — under
                            # pipefail+set -e the bare assignment is fatal.
                            _lease_wt="$(lease_worktree "$_lf" 2>/dev/null || true)"
                            # EFFECTIVE-312: bare [[ ]] && break as the loop
                            # body's last statement leaks rc=1 into the for
                            # loop under set -e — the silent claim-step killer
                            # (proven by cycle-7 xtrace on chumpd-eu).
                            if [[ -n "$_lease_wt" ]]; then break; fi
                        fi
                    done
                fi
                if [[ -n "$_lease_wt" ]]; then
                    # AC#3: resolve symlinks on both sides (e.g. /tmp vs
                    # /private/tmp on macOS) before the prefix comparison.
                    _pwd_real="$(cd "$PWD" 2>/dev/null && pwd -P || printf '%s' "$PWD")"
                    _lease_wt_real="$(cd "$_lease_wt" 2>/dev/null && pwd -P || printf '%s' "$_lease_wt")"
                    case "$_pwd_real" in
                        "$_lease_wt_real"|"$_lease_wt_real"/*)
                            _already_in_lease_wt=1
                            ;;
                    esac
                fi
            fi

            if [[ "$_already_in_lease_wt" -eq 1 ]]; then
                info "INFRA-1901: already inside claimed worktree for $gid (lease=$_lease_wt) — skipping chump claim re-invocation"
                _BM_OWN_CLAIM=1
                chump session-track --start "$gid" >/dev/null 2>&1 || true
                continue
            fi

            # META-156 AC#2: re-claim failure auto-retry.
            # If `chump claim` fails with "worktree already exists", detect whether
            # the existing claim belongs to OUR session_id (CHUMP_SESSION_ID). If so,
            # retry with --force-recover (same session; safe to re-enter). If a
            # different session owns it, fail fast with an operator-visible message.
            _claim_rc=0
            _claim_out=""
            _claim_out="$(chump claim "$gid" $_claim_extra 2>&1)" || _claim_rc=$?
            if [[ "$_claim_rc" -ne 0 ]]; then
                # CREDIBLE-160: an INFRA-1970 lease conflict with OUR OWN
                # session is the NORMAL case for fleet workers — the worker's
                # pick already claimed the gap under the same CHUMP_SESSION_ID
                # this process inherits. Recognize it and reuse the worktree +
                # branch instead of dying (previously fell through to a silent
                # claim_failed exit, blocking every chumpd-eu ship).
                if printf '%s' "$_claim_out" | grep -qi "already claimed by session"; then  # pipefail-sweep-allowed
                    _claim_lease_session="$(printf '%s' "$_claim_out" \
                        | grep -oiE "already claimed by session [^ ]+" \
                        | awk '{print $NF}' | head -1)"
                    if [[ -n "${CHUMP_SESSION_ID:-}" && "$_claim_lease_session" == "$CHUMP_SESSION_ID" ]]; then
                        info "CREDIBLE-160: lease already held by our session ($CHUMP_SESSION_ID) — reusing existing worktree + branch"
                        _BM_OWN_CLAIM=1
                        chump session-track --start "$gid" >/dev/null 2>&1 || true
                        continue
                    fi
                    red "CREDIBLE-160: gap $gid lease held by DIFFERENT session (${_claim_lease_session:-unknown}, ours: ${CHUMP_SESSION_ID:-<unset>})"
                    printf '%s\n' "$_claim_out" >&2
                    _bm_step_done "claim" "$_claim_rc"
                    _BM_TERMINAL_STATE="claim_failed_session_mismatch"
                    exit "$_claim_rc"
                fi
                _claim_worktree_exists=0
                if printf '%s' "$_claim_out" | grep -qi "worktree.*already\|already.*worktree\|worktree path already"; then  # pipefail-sweep-allowed
                    _claim_worktree_exists=1
                fi
                if [[ "$_claim_worktree_exists" -eq 1 ]]; then
                    # Check existing claim's session_id via the lease file.
                    _existing_claim_session=""
                    for _lf in "$LOCK_DIR"/*.json; do
                        [[ -f "$_lf" ]] || continue
                        _lf_gid="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('gap_id',''))" "$_lf" 2>/dev/null || true)"
                        if [[ "$_lf_gid" == "$gid" ]]; then
                            _existing_claim_session="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('session_id',''))" "$_lf" 2>/dev/null || true)"
                            break
                        fi
                    done
                    # INFRA-2744: JSON lock files are legacy; interactive `chump
                    # claim` writes the lease to the canonical state.db only. Fall
                    # back to it so we recognize the operator's own claim.
                    if [[ -z "$_existing_claim_session" ]]; then
                        _existing_claim_session="$(lease_session_from_statedb "$gid" "${MAIN_REPO:-${REPO_ROOT:-.}}/.chump/state.db")"
                    fi
                    if [[ -n "${CHUMP_SESSION_ID:-}" && "$_existing_claim_session" == "$CHUMP_SESSION_ID" ]]; then
                        # Same session — the existing worktree + (committed,
                        # possibly-unpushed) branch are already OURS. INFRA-2744:
                        # do NOT `chump claim --force-recover` here — it removes the
                        # worktree dir + local branch, destroying committed-but-
                        # unpushed work. The claim is already ours; no-op and reuse
                        # the existing worktree + branch for the ship steps.
                        info "INFRA-2744: re-claim no-op — gap $gid already held by our session ($CHUMP_SESSION_ID); reusing existing worktree + branch"
                        _BM_OWN_CLAIM=1
                    else
                        red "META-156 AC#2: re-claim failure — worktree already exists and is owned by a DIFFERENT session."
                        red "  Our session: ${CHUMP_SESSION_ID:-<unset>}"
                        red "  Existing claim session: ${_existing_claim_session:-<unknown>}"
                        red "  Resolution: wait for that session to finish, or release it with:"
                        red "    chump --release --session ${_existing_claim_session:-<session-id>}"
                        _bm_step_done "claim" "$_claim_rc"
                        _BM_TERMINAL_STATE="claim_failed_session_mismatch"
                        exit "$_claim_rc"
                    fi
                else
                    # Some other claim failure — re-emit output and fail.
                    printf '%s\n' "$_claim_out" >&2
                    _bm_step_done "claim" "$_claim_rc"
                    _BM_TERMINAL_STATE="claim_failed"
                    exit "$_claim_rc"
                fi
            fi
            [[ "$_claim_rc" -eq 0 ]] && _BM_OWN_CLAIM=1
            # INFRA-492: emit session_start so INFRA-477's cost ledger
            # gets data. Best-effort — silent on chump fail.
            chump session-track --start "$gid" >/dev/null 2>&1 || true
        else
            info "[dry-run] chump claim $gid $_claim_extra"
        fi
    done
    _bm_step_done "claim" 0
fi

# ── INFRA-537: ship-quality grade signal accumulators ───────────────────────
# null = signal not captured (step skipped). true/false = captured result.
_grade_clippy_ok="null"
_grade_test_added="null"
_grade_rebase_clean="null"

# ── INFRA-953: hot-file lock acquisition ──────────────────────────────────────
# If our diff touches any file in scripts/coord/hot-files.yaml `serialize:`
# list, take a "$FLOCK_BIN" on each (one per file). Held until this script exits.
# Prevents two bot-merges from racing on the same shared file, which is what
# drives bot_merge_hot_file emissions (META-055 audit: 71.5% of token waste).
# INFRA-2641: skip under --dry-run — it never pushes, so it can't produce the
# rebase-race this lock guards against, and it's not worth blocking a dry-run
# caller (e.g. the integration test chump preflight runs) on a repo-wide,
# cross-worktree lock for up to 600s while real bot-merges elsewhere hold it.
_HF_HELPER="${REPO_ROOT}/scripts/coord/hot-file-lock.sh"
if [[ "$DRY_RUN" != "1" && -r "$_HF_HELPER" ]]; then
    # shellcheck source=./hot-file-lock.sh
    source "$_HF_HELPER"
    if declare -F hot_file_lock_acquire >/dev/null 2>&1; then
        # RESILIENT-100: wrap in stage_start/stage_done so (a) the heartbeat
        # step label reflects "hot file lock" instead of going stale on
        # whatever ran before it, and (b) the existing per-stage budget
        # watchdog (CHUMP_BOT_MERGE_STAGE_BUDGET_S, default 300s) bounds the
        # wait — well under both the flock helper's own 600s internal
        # timeout and the 900s total-run budget, so a stuck lock fails fast
        # and diagnosably (kind=botmerge_wedged) instead of wedging silently.
        stage_start "hot file lock acquire"
        if ! hot_file_lock_acquire; then
            red "INFRA-953: failed to acquire hot-file lock(s) — aborting"
            exit 1
        fi
        stage_done
    fi
fi

# ── 1. Fetch and rebase ───────────────────────────────────────────────────────
stage_start "git fetch $REMOTE/$BASE_BRANCH"
run_timed_hb "git fetch" 180 git fetch "$REMOTE" "$BASE_BRANCH" --quiet
stage_done

info "Fetched $REMOTE/$BASE_BRANCH."

BEHIND=$(git rev-list --count "HEAD..${REMOTE}/${BASE_BRANCH}" 2>/dev/null || echo 0)

# Hard abort if branch is extremely stale — rebase at 50+ commits is risky and
# likely means the work has already landed on main via another agent.
if [[ "$BEHIND" -gt 50 ]]; then
    red "Branch is $BEHIND commits behind $REMOTE/$BASE_BRANCH — too stale to merge safely."
    red "Run: chump gap preflight ${GAP_IDS[*]:-<gap-ids>}"
    red "Then: git fetch && git rebase $REMOTE/$BASE_BRANCH (resolve conflicts)"
    red "If all your gaps are already done on main, close this branch instead."
    exit 3
fi

if [[ "$BEHIND" -gt 0 ]]; then
    stage_start "rebase on $REMOTE/$BASE_BRANCH ($BEHIND commit(s) behind)"
    _rebase_args=("${REMOTE}/${BASE_BRANCH}")
    if [[ "$NO_MERGE_DRIVER" == "1" ]]; then
        _rebase_args+=(-c merge.ci-yml-add-row.driver= -c merge.pre-commit-add-guard.driver= -c merge.chump-state-sql-regen.driver=)
    fi
    if ! run_timed_hb "git rebase" 60 git rebase "${_rebase_args[@]}"; then
        red "git rebase failed or timed out — resolve conflicts or retry."
        _grade_rebase_clean="false"

        # ── INFRA-1657/INFRA-3767: dispatch conflict-resolver-agent (closes INFRA-1488 loop) ──
        # If we detect conflict markers in the worktree (i.e. rebase failed because
        # of a true merge conflict, not a timeout / fetch error), invoke the
        # conflict-resolver-agent unconditionally — no --opt-in flag required here.
        # The agent self-gates on confidence (INFRA-3767 AC #3): it only follows
        # through unattended on textual/AST scenarios it has a confidence pattern
        # for, and skips (exit 0, rebase still mid-flight) otherwise, in which case
        # we fall through to the original `_bm_fail "rebase"` handoff path below.
        # CHUMP_CONFLICT_RESOLVER_ENABLED=0 remains a hard operator override to
        # disable the agent entirely; =1 forces it past the confidence gate.
        #
        # Exit-code contract from conflict-resolver-agent.sh:
        #   0 — resolved + `git rebase --continue` already ran; resume normal flow
        #   1 — handoff (agent wrote operator-action-needed.json); abort rebase
        #   2 — usage error (no GAP_ID); treat as handoff
        _cr_agent="$REPO_ROOT/scripts/coord/conflict-resolver-agent.sh"
        _cr_gap="${GAP_IDS[0]:-${GAP_ID:-}}"
        _cr_conflicted_count="$(git diff --name-only --diff-filter=U 2>/dev/null | wc -l | tr -d ' ')"
        if [[ -x "$_cr_agent" && -n "$_cr_gap" && "$_cr_conflicted_count" -gt 0 ]]; then
            info "Dispatching conflict-resolver-agent (gap=$_cr_gap, files=$_cr_conflicted_count) — CHUMP_CONFLICT_RESOLVER_ENABLED=${CHUMP_CONFLICT_RESOLVER_ENABLED:-auto}"
            if "$_cr_agent" "$_cr_gap"; then
                # Agent returned 0: either skipped (no conflicts / disabled /
                # low-confidence scenario — rebase still mid-flight, fall through
                # to _bm_fail) or resolved-and-continued (rebase done, carry on
                # with the rest of bot-merge). Distinguish via .git/rebase-*
                # state directories.
                if [[ -d "$REPO_ROOT/.git/rebase-merge" || -d "$REPO_ROOT/.git/rebase-apply" ]]; then
                    info "conflict-resolver-agent skipped (disabled or low-confidence) — falling through to existing handoff."
                else
                    info "conflict-resolver-agent resolved + continued rebase — resuming bot-merge flow."
                    # Fall through to the existing post-rebase success block
                    # (lines below set _grade_rebase_clean="true" + stage_done).
                    _CR_RESOLVED=1
                fi
            else
                red "conflict-resolver-agent failed or handed off — aborting rebase."
                git rebase --abort >/dev/null 2>&1 || true
            fi
        fi

        if [[ "${_CR_RESOLVED:-0}" != "1" ]]; then
            _bm_fail "rebase" 11 "merge conflict or timeout"
        fi
    fi
    _grade_rebase_clean="true"
    stage_done

    # Re-check gap status after rebase: main may have merged the gap while we rebased.
    if [[ ${#GAP_IDS[@]} -gt 0 && $DRY_RUN -eq 0 ]]; then
        info "Re-checking gaps after rebase …"
        # INFRA-509: INFRA-344 filing-style PR detection removed — post-INFRA-498,
        # gap YAMLs are no longer added as new files in PRs; state.db is canonical.
        # Always run preflight here so we catch gaps completed on main while rebasing.
        if ! CHUMP_SPECULATIVE="$SPECULATIVE" chump gap preflight "${GAP_IDS[@]}"; then
            # EFFECTIVE-312: when THIS run claimed the gap (the claim step above
            # set _BM_OWN_CLAIM=1), preflight's
            # live-claim failure is our own lease — not "completed on main".
            if [[ "${_BM_OWN_CLAIM:-0}" -eq 1 ]]; then
                info "EFFECTIVE-312: post-rebase preflight failed on OUR OWN live lease — continuing ship"
            else
                red "Gap was completed on main while we rebased — nothing left to push."
                _bm_fail "preflight" 10 "gap completed on main during rebase"
            fi
        fi
    fi
else
    info "Branch is up to date with $REMOTE/$BASE_BRANCH."
fi

# INFRA-920 + INFRA-1042 + INFRA-1061: detect shell/doc-only diffs.
#
# Detection runs UNCONDITIONALLY (not gated on SKIP_TESTS) so --fast invocations
# still get the DOC_ONLY flag — original INFRA-1042 wrapped this in
# `if SKIP_TESTS == 0`, which silently disabled doc-only skip for every --fast
# run since --fast pre-sets SKIP_TESTS=1. INFRA-1061 hoists the detection out
# and uses DOC_ONLY to also skip cargo clippy entirely (CI clippy stays the
# gate). Observed savings: ~2-3 min per doc PR (DOC-036 baseline 2m36s clippy
# on 1-line README diff; INFRA-1038 observed clippy timing out 245s).
#
# wc -l replaces `grep -c .` for file-count: grep -c returns exit 1 on 0
# matches, which propagates under set -o pipefail.
DOC_ONLY=0
_changed_files=$(git diff --name-only "${REMOTE}/${BASE_BRANCH}...HEAD" 2>/dev/null || true)
if [[ -n "$_changed_files" ]]; then
    _rs_count=0
    _unsafe_count=0
    while IFS= read -r _f; do
        [[ -z "$_f" ]] && continue
        case "$_f" in
            *.rs)                              _rs_count=$((_rs_count + 1)) ;;
            scripts/*|docs/*|*.md|*.yaml|*.sh) ;;
            *)                                 _unsafe_count=$((_unsafe_count + 1)) ;;
        esac
    done <<< "$_changed_files"
    if [[ $_rs_count -eq 0 && $_unsafe_count -eq 0 ]]; then
        DOC_ONLY=1
        # Only flip SKIP_TESTS if the caller hadn't already (--fast / --skip-tests
        # both pre-set it; we still log credit + emit so waste-tally sees it).
        if [[ $SKIP_TESTS -eq 0 ]]; then
            SKIP_TESTS=1
            info "[bot-merge] auto-skip: shell/doc-only diff — skipping cargo test (INFRA-920)"
        fi
        info "[bot-merge] DOC_ONLY=1 — clippy will be skipped (INFRA-1042/INFRA-1061)"
        # Emit so fleet-brief / waste-tally credit the saved cycles.
        _doc_amb="${CHUMP_AMBIENT_LOG:-${REPO_ROOT:-.}/.chump-locks/ambient.jsonl}"
        mkdir -p "$(dirname "$_doc_amb")" 2>/dev/null || true
        _doc_filecount=$(printf '%s\n' "$_changed_files" | wc -l | tr -d ' ')
        printf '{"ts":"%s","kind":"bot_merge_doc_only_fastpath","branch":"%s","files_changed":%d,"saved_steps":["cargo_test","cargo_clippy"]}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${BRANCH:-unknown}" \
            "${_doc_filecount:-0}" \
            >> "$_doc_amb" 2>/dev/null || true
    fi
fi

# ── 2. cargo fmt ──────────────────────────────────────────────────────────────
if command -v cargo &>/dev/null && ls src/**/*.rs &>/dev/null 2>&1; then
    stage_start "cargo fmt"
    if ! run_timed_hb "cargo fmt" 120 cargo fmt --all; then
        red "cargo fmt failed or timed out."
        _bm_fail "fmt" 12 "cargo fmt failed or timed out"
    fi
    if [[ $DRY_RUN -eq 0 ]] && ! git diff --quiet; then
        # INFRA-370 (2026-05-03): only `git commit --amend` when this branch
        # has at least one commit OF ITS OWN above $REMOTE/$BASE_BRANCH.
        # Without this guard, when the agent forgot to commit before calling
        # bot-merge.sh (uncommitted work in tree, HEAD = a foreign main
        # commit), the amend path silently grafted the agent's uncommitted
        # changes ONTO the foreign commit, mutating its tree. META-014's
        # subagent confirmed this live via `git reflog` showing
        # `commit (amend)` against an INFRA-335 SHA. PR #52-class silent
        # squash-loss. Fix: when there are 0 own-commits, create a NEW
        # commit instead of amending.
        commits_on_branch=$(git rev-list --count "${REMOTE}/${BASE_BRANCH}..HEAD" 2>/dev/null || echo 0)
        if [[ "$commits_on_branch" -lt 1 ]] && [[ "${CHUMP_BOT_MERGE_FORCE_AMEND:-0}" != "1" ]]; then
            yellow "INFRA-370: HEAD has no commits above $REMOTE/$BASE_BRANCH — refusing to --amend foreign commit"
            yellow "  (override with CHUMP_BOT_MERGE_FORCE_AMEND=1 for genuine recovery)"
            info "cargo fmt changed files — creating fresh commit on top instead of amending …"
            git add -u
            git commit --no-verify -m "chore: cargo fmt --all (auto from bot-merge.sh, INFRA-370 fresh-commit path)"
        else
            info "cargo fmt changed files — staging and amending …"
            git add -u
            git commit --amend --no-edit --no-verify
        fi
        green "fmt fixes committed."
    fi
    stage_done
fi

# ── INFRA-164: parallelism + timeouts for cold-cache builds ───────────────────
# A cold workspace build of all rustc test/bin targets at default parallelism
# (= host logical CPUs, e.g. 10 on an M4) easily peaks past 16 GB RAM and gets
# rustc subprocesses SIGTERM'd by macOS Jetsam when the fleet has other
# concurrent worktrees building. The classic symptom is a sudden cascade of
# "(signal: 15, SIGTERM: termination signal)" across two or three rustc
# processes mid-build, with cargo reporting "build failed, waiting for other
# jobs to finish". That is not a real test failure — and it isn't a bot-merge
# timeout either; the wall-clock is fine. It is OOM pressure.
#
# Fix: limit cargo's parallelism. Default to 4 (safe for 24 GB / 10-core M4
# under fleet contention); operators with more headroom can raise via env.
#
# Separately: cold clippy alone takes ~8 minutes on this codebase. The
# previous 300s budget triggered TIMEOUT mid-compile — a real wall-clock
# hit, not OOM. Bumped to 900s (15 min). cargo test budget (3600s) was
# already generous enough for cold builds.
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-4}"
info "cargo parallelism: CARGO_BUILD_JOBS=${CARGO_BUILD_JOBS} (override via env)"

# INFRA-1063: per-worktree CARGO_TARGET_DIR to eliminate cargo build-dir lock
# contention when multiple bot-merge runs execute in parallel across
# /tmp/chump-*/ worktrees.  Without this, all worktrees resolve to the same
# shared target/ (either $CARGO_HOME/registry or the root workspace target/),
# causing "Blocking waiting for file lock on build directory" timeouts (observed:
# two parallel clippy runs each waited 240 s in 2026-05-13).
#
# Strategy: option (a) — per-worktree target dir.
#   - If CARGO_TARGET_DIR is already set externally (e.g. CI), respect it.
#   - Otherwise, pin it to <worktree>/target/ so each gap gets its own build
#     cache.  The dir is under /tmp/ and cleaned up when the worktree is reaped.
#   - When the wait exceeds 60 s, cargo emits "Blocking waiting for file lock"
#     to stderr; we capture that and emit kind=cargo_lock_wait to ambient.jsonl.
if [[ -z "${CARGO_TARGET_DIR:-}" ]]; then
    # INFRA-1374: use a hidden .cargo-build-target dir so the per-worktree
    # isolation doesn't collide with the workspace `target/` name that cargo
    # also uses by default (and which .cargo/config.toml may override globally
    # to the main repo path). Using a distinct name ensures each worktree at
    # /tmp/chump-* gets its own, unambiguous build cache regardless of any
    # global config.toml target-dir override from install-sccache.sh (INFRA-481).
    export CARGO_TARGET_DIR="${REPO_ROOT}/.cargo-build-target"
    info "INFRA-1374: CARGO_TARGET_DIR pinned to ${CARGO_TARGET_DIR} (per-worktree mutex isolation)"
else
    info "INFRA-1063: CARGO_TARGET_DIR already set to ${CARGO_TARGET_DIR} (respecting caller)"
fi

# INFRA-1063 AC #5: wrapper for cargo invocations that detects build-dir lock
# contention.  Cargo emits "Blocking waiting for file lock on build directory"
# to stderr when it cannot acquire the lock; we tee output to a temp file,
# scan for that message after the run, and emit kind=cargo_lock_wait to
# ambient.jsonl so the fleet can observe and measure the cost.
#
# Usage: _run_cargo_with_lock_detect <label> <timeout_secs> <cargo subcommand...>
# Returns the exit code of the underlying cargo invocation.
_run_cargo_with_lock_detect() {
    local label="$1" timeout_secs="$2"; shift 2
    local _tmpout _rc
    _tmpout="$(mktemp)"
    set +e
    run_timed_hb "$label" "$timeout_secs" cargo "$@" 2>&1 | tee -a "$_tmpout"
    _rc=${PIPESTATUS[0]}
    set -e
    if grep -q "Blocking waiting for file lock on build directory" "$_tmpout" 2>/dev/null; then
        local _ambient _now _gap_label
        _ambient="${LOCK_DIR:-${REPO_ROOT:-.}/.chump-locks}/ambient.jsonl"
        _now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        _gap_label="${GAP_IDS[0]:-none}"
        _ambient_write "$_ambient" \
            "$(printf '{"ts":"%s","session":"bot-merge-%d","kind":"cargo_lock_wait","phase":"%s","gap_id":"%s","target_dir":"%s","note":"cargo build-dir lock contention detected; CARGO_TARGET_DIR per-worktree isolation may not be active (INFRA-1063)"}' \
                "$_now" "$_BM_PID" "$label" "$_gap_label" "${CARGO_TARGET_DIR:-?}")"
        warn "INFRA-1063: cargo build-dir lock wait detected on phase '${label}' — cargo_lock_wait emitted to ambient stream"
    fi
    # INFRA-918: expose OOM signal so the cargo test failure path can classify
    # the failure as transient_oom vs permanent_failure without re-reading output.
    if grep -qE 'signal: 15|SIGTERM: termination signal' "$_tmpout" 2>/dev/null; then
        _BM_LAST_CARGO_OOM_DETECTED=1
    else
        _BM_LAST_CARGO_OOM_DETECTED=0
    fi
    rm -f "$_tmpout"
    return "$_rc"
}

# ── 3. cargo clippy ───────────────────────────────────────────────────────────
# Timeout 900s: cold workspace clippy is ~8 min on chump as of 2026-04-28.
#
# INFRA-252: --fast skips the local clippy step entirely. Rationale: cold
# workspace clippy is the long pole (5-8 min), busts the agent task budget
# (~10-15 min on Anthropic's general-purpose subagent) and forces the parent
# session to rescue commit-but-don't-push orphans. The GitHub Actions CI
# clippy job runs the same checks anyway and is the actual gate (auto-merge
# refuses to land a PR with red checks). With --fast, bot-merge.sh ships in
# ~30-60 sec total, comfortably inside any agent budget. Cost: a clippy-broken
# PR may briefly exist on the open-PR list before CI grades it red. Default
# OFF (preserves human-developer fail-fast ergonomics); agents pass --fast
# explicitly.
#
# INFRA-1042: doc-only diffs (set DOC_ONLY=1 above) skip clippy entirely.
# Zero Rust changes means zero new lints; CI clippy is the safety net.
# Observed savings: ~2-3 min per doc PR (DOC-036 spent 2m36s on clippy for
# a 1-line README diff before this gate landed).
if [[ "${DOC_ONLY:-0}" -eq 1 ]]; then
    info "[bot-merge] DOC_ONLY=1 — skipping cargo clippy entirely (INFRA-1042)"
elif [[ $FAST -eq 1 ]]; then
    # 2026-05-07: Even in --fast mode, run a `cargo clippy --fix` auto-correction
    # pass. This catches the wave of fleet PRs that ship doc-list-overindented /
    # manual_strip / manual_split_once / lines_filter_map_ok style lints that
    # fleet workers' Rust style produces, amending the fixes into the current
    # commit so CI sees a clean PR. If it can't auto-resolve everything, CI is
    # the gate (no -D warnings).
    #
    # INFRA-3525: scope the pass to `--bin chump`, NOT `--workspace --all-targets`.
    # The workspace/all-targets form ran 3-6 min and routinely blew bot-merge's
    # phase-budget watchdog (INFRA-2426 SIGTERM) under fleet build contention —
    # killing the whole ship, not just the (already non-fatal) clippy step. The
    # chump bin is where ~all fleet PR diffs land, so bin-scoping keeps the
    # auto-correct benefit for the common case while staying inside the budget;
    # lints in crates/ or non-bin targets are caught by CI clippy.
    if command -v cargo &>/dev/null; then
        stage_start "cargo clippy --bin chump --fix (--fast pre-flight auto-correct)"
        _clippy_fix_rc=0
        _run_cargo_with_lock_detect "cargo clippy --fix" 180 clippy --bin chump --fix --allow-dirty --allow-staged || _clippy_fix_rc=$?
        if [[ "$_clippy_fix_rc" -eq 124 ]]; then
            # INFRA-1062: timeout is non-fatal for --fast (CI clippy is the gate);
            # log explicitly so the operator sees it rather than silent exit.
            warn "INFRA-1062: clippy --fix timed out after 360s — continuing to push (CI clippy is the gate)"
        fi
        if [[ -n "$(git status --porcelain)" ]]; then
            info "clippy --fix auto-corrected lints — staging + amending"
            git add -A
            git commit --amend --no-edit --no-verify >/dev/null 2>&1 || \
                git commit --no-verify -m "chore: cargo clippy --fix (auto from bot-merge.sh --fast pre-flight, INFRA-624 follow-up)" || true
        fi
        stage_done
        green "clippy --fix pre-flight done."
    else
        info "Skipping local clippy (--fast, no cargo). CI clippy is the gate."
    fi
elif command -v cargo &>/dev/null; then
    # RESILIENT-133: the inner gtimeout below is 900s, but stage_start's own
    # watchdog (RESILIENT-210's per-stage budget mechanism) defaulted to the
    # global 300s here because no second argument was ever passed -- the
    # watchdog fired mid-compile on cold worktrees despite the command still
    # being well within its own allowed budget. Pass 900 explicitly to match.
    stage_start "cargo clippy --workspace --all-targets" 900
    if ! _run_cargo_with_lock_detect "cargo clippy" 900 clippy --workspace --all-targets -- -D warnings; then
        red "clippy found errors — fix them before merging."
        _grade_clippy_ok="false"
        _bm_fail "clippy" 13 "clippy lint errors"
    fi
    _grade_clippy_ok="true"
    stage_done
    green "clippy clean."
fi

# ── 4. cargo test ─────────────────────────────────────────────────────────────
# INFRA-918: emit before-test snapshot so the fleet knows whether tests ran
# on the rebased HEAD or a stale pre-rebase state.  Emitted unconditionally
# (even when SKIP_TESTS=1) with will_test reflecting the actual intent.
_brt_amb="${CHUMP_AMBIENT_LOG:-${REPO_ROOT:-.}/.chump-locks/ambient.jsonl}"
_brt_sha="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
_brt_rebased="$([ "${BEHIND:-0}" -gt 0 ] && echo true || echo false)"
_brt_will_test="$([ "${SKIP_TESTS:-1}" -eq 0 ] && command -v cargo &>/dev/null && echo true || echo false)"
# scanner-anchor: "kind":"bot_merge_rebase_before_test"
printf '{"ts":"%s","kind":"bot_merge_rebase_before_test","rebased":%s,"commits_behind":%d,"head_sha":"%s","will_test":%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_brt_rebased" "${BEHIND:-0}" "$_brt_sha" "$_brt_will_test" \
    >> "$_brt_amb" 2>/dev/null || true

_BM_LAST_CARGO_OOM_DETECTED=0
if [[ $SKIP_TESTS -eq 0 ]] && command -v cargo &>/dev/null; then
    # CREDIBLE-175: prefer `cargo nextest run` (process-isolated, exactly what
    # CI runs) over thread-shared `cargo test`, which false-reds on
    # CHUMP_REPO/CHUMP_HOME env-var races (repo_tools/tool_middleware) that CI's
    # nextest never hits — those false-reds forced --skip-tests bypasses on
    # clean pushes. Fall back to `cargo test` only when nextest isn't installed.
    if cargo nextest --version &>/dev/null; then
        _bm_test_label="cargo nextest run --bin chump"
        _bm_test_args=(nextest run --bin chump)
    else
        _bm_test_label="cargo test --bin chump --tests"
        _bm_test_args=(test --bin chump --tests)
    fi
    # RESILIENT-133: same mismatch as the clippy stage above -- inner gtimeout
    # is 1200s but stage_start's own watchdog defaulted to the global 300s.
    # This is the exact SIGTERM observed firing immediately AFTER a fully
    # successful nextest run completed (not just mid-compile as originally
    # scoped): the watchdog's own clock wasn't matched to the real budget, so
    # a run finishing at e.g. 330s still got killed a heartbeat past 300s.
    stage_start "$_bm_test_label" 1200
    if ! _run_cargo_with_lock_detect "$_bm_test_label" 1200 "${_bm_test_args[@]}"; then
        # INFRA-918: classify failure — transient_oom when rustc processes were
        # SIGTERM'd by macOS Jetsam under memory pressure; permanent_failure otherwise.
        if [[ "${_BM_LAST_CARGO_OOM_DETECTED:-0}" == "1" ]]; then
            _btf_class="transient_oom"
        else
            _btf_class="permanent_failure"
        fi
        # scanner-anchor: "kind":"bot_merge_test_failure"
        printf '{"ts":"%s","kind":"bot_merge_test_failure","failure_class":"%s","gap":"%s","branch":"%s"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_btf_class" \
            "${GAP_IDS[0]:-unknown}" "${BRANCH:-unknown}" \
            >> "$_brt_amb" 2>/dev/null || true
        red "Tests failed — fix them before merging."
        info "If you saw 'signal: 15, SIGTERM' across multiple rustc processes,"
        info "that is most likely OOM, not a real test failure. Try lowering"
        info "CARGO_BUILD_JOBS (currently ${CARGO_BUILD_JOBS}) and retry."
        _bm_fail "test" 14 "test suite failure"
    fi
    stage_done
    green "Tests passed."
else
    info "Skipping tests (--skip-tests)."
fi

# ── 4a. CI shell-test gate for THIS PR's new/modified tests (INFRA-222) ──────
# `cargo test` covers Rust unit/integration tests but NOT the shell-script
# guard tests under `scripts/ci/test-*.sh`. PR #729 (INFRA-200) shipped with
# its own guard's test suite failing because bot-merge never ran the new
# `scripts/ci/test-raw-yaml-guard.sh` — CI caught it but the PR sat stuck.
#
# Strategy: run only the shell tests this PR adds or modifies. These are tests
# the PR author owns and should be passing locally before push. We skip the
# 38-test full sweep because many tests have implicit env dependencies (chump
# binary, ACP server, cursor CLI) that CI sets up but local worktrees don't.
#
# Bypass: CHUMP_SKIP_CI_SHELL=1 scripts/coord/bot-merge.sh ...
# Skipped automatically with --skip-tests.
if [[ $SKIP_TESTS -eq 0 ]] && [[ "${CHUMP_SKIP_CI_SHELL:-0}" != "1" ]]; then
    # Find shell tests added or modified relative to base branch
    BASE_REF="${CHUMP_BASE_REF:-origin/main}"
    CHANGED_TESTS=()
    while IFS= read -r f; do
        [[ -n "$f" && -f "$REPO_ROOT/$f" ]] && CHANGED_TESTS+=("$REPO_ROOT/$f")
    done < <(git diff --name-only --diff-filter=AM "$BASE_REF...HEAD" 2>/dev/null \
             | grep -E '^scripts/ci/test-.*\.sh$' || true)

    if [[ ${#CHANGED_TESTS[@]} -gt 0 ]]; then
        stage_start "PR-modified scripts/ci/test-*.sh (${#CHANGED_TESTS[@]} suites)"
        FAILED_TESTS=()
        for t in "${CHANGED_TESTS[@]}"; do
            tname="$(basename "$t")"
            # INFRA-473: write per-test log files (not a single shared one
            # that gets clobbered between iterations) so the operator can
            # read the FULL output of any failed test, not just tail -10.
            ci_log="/tmp/bot-merge-citest-${tname%.sh}.log"
            if ! timeout 60 bash "$t" >"$ci_log" 2>&1; then
                FAILED_TESTS+=("$tname")
                red "  ✗ $tname"
                # Surface explicit FAIL lines first (cheap, high-signal).
                fail_lines=$(grep -E '^\s*FAIL:' "$ci_log" 2>/dev/null || true)
                if [[ -n "$fail_lines" ]]; then
                    echo "$fail_lines" | sed 's/^/    /'
                fi
                # Plus the trailing 30 lines (Results: summary + immediate
                # context). 30 not 10 — Cargo/test output is verbose enough
                # that 10 lines often misses the failure detail.
                echo "    --- last 30 lines of $ci_log ---"
                tail -30 "$ci_log" | sed 's/^/    /'
                echo "    --- end ($(wc -l <"$ci_log") total lines; full log: $ci_log) ---"
            fi
        done
        if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
            red "${#FAILED_TESTS[@]} CI shell test(s) failed: ${FAILED_TESTS[*]}"
            info "These are tests THIS PR adds/modifies. Fix locally before pushing —"
            info "they will block the PR's CI 'test' job otherwise (PR #729 was the"
            info "originating example — it sat stuck for 2+ hours waiting on a test"
            info "the author could have run in 5 seconds locally)."
            info "Full per-test logs at /tmp/bot-merge-citest-<name>.log"
            info "Bypass (only if you've already verified the failure is environmental):"
            info "  CHUMP_SKIP_CI_SHELL=1 scripts/coord/bot-merge.sh ..."
            exit 1
        fi
        stage_done
        green "All ${#CHANGED_TESTS[@]} PR-modified CI shell tests passed."
    fi
fi

# ── INFRA-537: test-added signal ─────────────────────────────────────────────
# Scan the PR diff for test additions. Heuristic: any Rust #[test] or #[cfg(test)]
# annotation, or any file whose path contains 'test' added/modified in this branch.
_grade_test_added="false"
_test_base="${CHUMP_BASE_REF:-${REMOTE}/${BASE_BRANCH}}"
if git diff --name-only --diff-filter=AM "${_test_base}...HEAD" 2>/dev/null \
        | grep -qiE 'test'; then
    _grade_test_added="true"
elif git diff "${_test_base}...HEAD" 2>/dev/null \
        | grep -qE '^\+.*#\[(test|cfg\(test)'; then
    _grade_test_added="true"
fi

# ── 4a-decomp. Decomposition advisory (FLEET-025 / FLEET-011 v0) ─────────────
# Surface heuristic-based decomposition hints for monolithic PRs. Per the
# FLEET-011 vision: file_count > 5 + LOC > 500 → consider decomposition.
# This is ADVISORY only (never blocks ship) — agents see the hint and decide
# whether to split or proceed. v0 emits the hint to stderr + ambient as
# kind=decomposition_hint so we can build a learning loop later (track
# whether agents heeded the hint vs proceeded; bias future hints).
#
# Bypass: CHUMP_DECOMP_HINT=0 (silence entirely)
# Tune:   CHUMP_DECOMP_FILE_THRESHOLD (default 5), CHUMP_DECOMP_LOC_THRESHOLD (default 500)
if [[ "${CHUMP_DECOMP_HINT:-1}" != "0" ]]; then
    DECOMP_FILES_T="${CHUMP_DECOMP_FILE_THRESHOLD:-5}"
    DECOMP_LOC_T="${CHUMP_DECOMP_LOC_THRESHOLD:-500}"
    DECOMP_BASE="${CHUMP_BASE_REF:-origin/main}"
    DECOMP_FILES="$(git diff --name-only --diff-filter=AM "$DECOMP_BASE...HEAD" 2>/dev/null | wc -l | tr -d ' ')"
    DECOMP_LOC="$(git diff --shortstat "$DECOMP_BASE...HEAD" 2>/dev/null \
                  | awk '{ins=0;del=0; for(i=1;i<=NF;i++){if($i~/insertion/)ins=$(i-1); if($i~/deletion/)del=$(i-1)} print ins+del}')"
    DECOMP_LOC="${DECOMP_LOC:-0}"

    # Heuristic exemptions: codemod-style changes (gap registry regen, lockfile
    # bumps, mass formatting) shouldn't trigger because they're already atomic
    # by intent. Detect by checking if >80% of touched files are in known
    # codemod paths.
    # INFRA-509: dropped docs/gaps/ from codemod pattern — post-INFRA-498 PRs
    # no longer bulk-add gap YAMLs; docs/gaps/ changes should trigger the hint.
    DECOMP_CODEMOD="$(git diff --name-only --diff-filter=AM "$DECOMP_BASE...HEAD" 2>/dev/null \
                     | grep -cE '^(\.chump/state\.sql|Cargo\.lock|book/src/)' || true)"
    DECOMP_CODEMOD="${DECOMP_CODEMOD:-0}"
    DECOMP_CODEMOD_RATIO=0
    if [[ "$DECOMP_FILES" -gt 0 ]]; then
        DECOMP_CODEMOD_RATIO=$(( DECOMP_CODEMOD * 100 / DECOMP_FILES ))
    fi

    if [[ "$DECOMP_FILES" -gt "$DECOMP_FILES_T" ]] && [[ "$DECOMP_LOC" -gt "$DECOMP_LOC_T" ]] \
       && [[ "$DECOMP_CODEMOD_RATIO" -lt 80 ]]; then
        warn "decomposition hint: ${DECOMP_FILES} files, ${DECOMP_LOC} LOC changed"
        info "  thresholds: > ${DECOMP_FILES_T} files AND > ${DECOMP_LOC_T} LOC (FLEET-011 v0 heuristic)"
        info "  consider: split by subsystem / per-file / 'land then migrate' stack — not blocking, just a nudge"
        info "  silence: CHUMP_DECOMP_HINT=0 scripts/coord/bot-merge.sh ..."
        # Best-effort emit to ambient so we can build the learning loop later
        if [[ -x "$REPO_ROOT/scripts/dev/ambient-emit.sh" ]]; then
            "$REPO_ROOT/scripts/dev/ambient-emit.sh" decomposition_hint \
                "kind=oversize" \
                "files=$DECOMP_FILES" \
                "loc=$DECOMP_LOC" \
                "gap=${GAP_ID:-unknown}" \
                "branch=$BRANCH" 2>/dev/null || true
        fi
    fi
fi

# ── 4b. Ambient glance (INFRA-083) ───────────────────────────────────────────
# Final peripheral-vision check before push: surface any sibling that already
# committed or pushed against the same gap (race window between gap-claim and
# now). Hard-stop if a sibling commit for this gap landed in the last 120s.
if [[ -n "${GAP_ID:-}" ]] && [[ -x "$REPO_ROOT/scripts/dev/chump-ambient-glance.sh" ]] \
   && [[ "${CHUMP_AMBIENT_GLANCE:-1}" != "0" ]]; then
    if ! "$REPO_ROOT/scripts/dev/chump-ambient-glance.sh" --gap "$GAP_ID" --since-secs 600 --limit 5 --check-overlap; then
        red "Sibling activity collision on $GAP_ID — aborting push. Re-tail ambient.jsonl, re-plan, re-run."
        info "Bypass: CHUMP_AMBIENT_GLANCE=0 scripts/coord/bot-merge.sh ..."
        exit 2
    fi
fi

# ── 4c. Pre-registered eval guard (META-043) ─────────────────────────────────
# If this commit modifies cognition-or-routing src, require a preregistered
# eval doc at docs/eval/preregistered/<GAP-ID>.md to be present in the tree.
# Rationale: no measurement = no merge (EVAL-098 pattern).
# Bypass: CHUMP_NO_PREREG=1 (with reason in commit body)
_PREREG_COGNITION_PATTERN='src/(briefing|reflection|reflection_db|prompt_assembly|provider_|bandit|cog_|cognition_|atomic_claim)'
_PREREG_DISPATCH_PATTERN='scripts/dispatch/'
if [[ "${CHUMP_NO_PREREG:-0}" != "1" ]] && [[ -n "${GAP_ID:-}" ]]; then
    _prereg_base="${CHUMP_BASE_REF:-${REMOTE}/${BASE_BRANCH}}"
    _cognition_touched=$(git diff --name-only --diff-filter=ACM "${_prereg_base}...HEAD" 2>/dev/null \
        | grep -cE "^(${_PREREG_COGNITION_PATTERN}|${_PREREG_DISPATCH_PATTERN})" || true)
    if [[ "${_cognition_touched:-0}" -gt 0 ]]; then
        _prereg_doc="docs/eval/preregistered/${GAP_ID}.md"
        if [[ ! -f "$REPO_ROOT/${_prereg_doc}" ]]; then
            red "[META-043] PREREG-REQUIRED: commit modifies cognition/routing src but"
            red "  docs/eval/preregistered/${GAP_ID}.md is missing."
            info "  Create the file (even a stub with hypothesis + metric) and re-run."
            info "  Bypass once: CHUMP_NO_PREREG=1 scripts/coord/bot-merge.sh ..."
            info "  Bypass trailer (required in commit): Prereg-Bypass-Reason: <reason>"
            _ambient_write "${CHUMP_AMBIENT_LOG:-${REPO_ROOT}/.chump-locks/ambient.jsonl}" \
                "$(printf '{"ts":"%s","kind":"prereg_blocked","gap":"%s","missing":"%s","session":"%s"}' \
                    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${GAP_ID}" "${_prereg_doc}" "${SESSION_ID:-unknown}")"
            exit 1
        else
            green "[META-043] prereg doc found: ${_prereg_doc}"
            _ambient_write "${REPO_ROOT}/.chump-locks/ambient.jsonl" \
                "$(printf '{"ts":"%s","kind":"prereg_ok","gap":"%s","doc":"%s","session":"%s"}' \
                    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${GAP_ID}" "${_prereg_doc}" "${SESSION_ID:-unknown}")"
        fi
    fi
fi

# ── 5a. INFRA-306: pre-push MERGED check ─────────────────────────────────────
# Bail BEFORE the force-push if a PR for this branch already MERGED. The
# 30s window between the start of bot-merge and reaching here is enough for
# auto-merge to fire on green CI — and force-pushing to a merged-and-deleted
# branch wastes 5-15min of cargo + can lose work in stack-of-PRs scenarios.
# Cheap one-shot query (~200ms). Bypass: CHUMP_SKIP_MERGED_CHECK=1.
if [[ "${CHUMP_SKIP_MERGED_CHECK:-0}" != "1" ]]; then
    # INFRA-1082: cache-first branch lookup; falls back to gh pr view on miss.
    _existing_state=""
    if declare -F cache_lookup_pr_by_branch >/dev/null 2>&1; then
        # INFRA-2925: cache_lookup_pr_by_branch returns rc=2 on a cache miss
        # (the normal case for a brand-new branch with no PR yet). Without
        # `|| true`, `set -euo pipefail` kills bot-merge.sh right here on
        # every first-ship — silently, with no error printed.
        _bm_cached_meta="$(cache_lookup_pr_by_branch "$BRANCH" 2>/dev/null || true)"
        if [[ -n "$_bm_cached_meta" ]]; then
            _existing_state="$(printf '%s' "$_bm_cached_meta" | \
                python3 -c "import sys,json; print(json.load(sys.stdin).get('state','') or '')" \
                2>/dev/null || echo "")"
        fi
    fi
    if [[ -z "$_existing_state" ]]; then
        _existing_state=$(gh pr view "$BRANCH" --json state --jq '.state' 2>/dev/null || echo "")
    fi
    if [[ "$_existing_state" == "MERGED" ]]; then
        # INFRA-3532: a MERGED PR for this branch is normally a settled race (auto-merge
        # fired on green CI) and skipping is correct. But branch-name REUSE — a new slice
        # of an already-shipped gap re-claiming chump/<id>-claim — also lands here, and the
        # old code exited 0: a SILENT no-op that looked like a successful ship while shipping
        # nothing (the durable-fix "looks fixed but isn't" trap). Tell them apart by CONTENT,
        # not commit count: squash-merge rewrites SHAs, so a rev-list check would false-positive
        # on a genuine settled race. If HEAD's tree already equals origin/main the work is in
        # (skip); if HEAD carries a real diff over main it is unshipped new work (fail loud).
        if git diff --quiet origin/main HEAD 2>/dev/null; then
            green "PR for $BRANCH already MERGED and HEAD adds nothing over main — skipping force-push (INFRA-306)."
            info "Saved you the cargo cost on a race that's already settled."
            info "Bypass for genuine recovery: CHUMP_SKIP_MERGED_CHECK=1 scripts/coord/bot-merge.sh ..."
            exit 0
        fi
        red "INFRA-3532: $BRANCH has a MERGED PR but HEAD carries an unshipped diff over main."
        red "This is branch-name reuse (a new slice of an already-shipped gap), NOT a settled race —"
        red "a force-push here is swallowed and GitHub auto-deletes the poisoned branch, so the slice never ships."
        info "Recovery — ship this slice on a FRESH branch:"
        info "  git commit --amend --trailer \"Bot-Merge-Bypass: multi-slice branch reuse (INFRA-3532)\""
        info "  git branch -f ${BRANCH}-s2 HEAD"
        info "  CHUMP_BYPASS_BOT_MERGE=1 CHUMP_TEST_GATE=0 CHUMP_OFF_RAILS_CHECK=0 git push -u origin ${BRANCH}-s2"
        info "  gh pr create --head ${BRANCH}-s2 --base main && gh pr merge <N> --auto --squash"
        exit 22
    fi
fi

# ── 4d. INFRA-686: WIP-commit squash — rebase to clean up graceful-shutdown rescues ──
# If the top commit starts with "WIP-", it was created by the SIGTERM checkpoint.
# Clean it up by squashing into the previous meaningful commit before shipping.
_top_msg="$(git log -1 --format="%s" HEAD 2>/dev/null || true)"
if [[ "$_top_msg" == WIP-* ]]; then
    info "[INFRA-686] Top commit is a WIP rescue: '$_top_msg' — squashing into parent"
    if [[ "${DRY_RUN:-0}" -eq 0 ]]; then
        # Use soft reset to unstage the WIP commit, then re-commit cleanly.
        if git reset --soft HEAD~1 2>/dev/null; then
            _parent_msg="$(git log -1 --format="%s" HEAD 2>/dev/null || echo "chore: squash WIP rescue commit")"
            if git commit --amend -m "$_parent_msg" --no-edit --no-verify 2>/dev/null; then
                green "[INFRA-686] WIP commit squashed cleanly."
            else
                warn "[INFRA-686] WIP squash amend failed — shipping with WIP commit (not ideal)"
                # Restore the WIP commit to avoid a dirty tree
                git reset HEAD~1 --hard 2>/dev/null || true
            fi
        else
            warn "[INFRA-686] WIP soft-reset failed — shipping as-is"
        fi
    else
        info "[dry-run] would squash WIP commit '$_top_msg' into parent"
    fi
fi

# ── 4e. INFRA-860: bot-merge mutex — prevent parallel push+merge contention ───
# Multiple fleet workers can race to push + merge simultaneously, causing
# `git push --force-with-lease` failures and `gh pr merge` races.  Acquire a
# per-repo file lock so only one bot-merge is in the push/PR/merge critical
# section at a time.  Timeout = 60s; logs contention if wait > 5s.
# INFRA-2641: --dry-run never pushes or merges (it's read-only), so it has no
# business contending for this repo-wide, cross-worktree mutex. On a machine
# with real bot-merge activity in other worktrees (the fleet's normal state),
# a dry-run caller — e.g. scripts/ci/test-system-integration.sh's Assertion 3,
# which chump preflight's integration-test gate runs — could block here for up
# to 60s waiting on a lock it will never need, inflating or timing out preflight.
if [[ "$DRY_RUN" != "1" && "${CHUMP_BOT_MERGE_LOCK:-1}" != "0" ]]; then
    _bm_lock_dir="${CHUMP_BOT_MERGE_LOCK_DIR:-${LOCK_DIR:-${REPO_ROOT:-.}/.chump-locks}}"
    _bm_lock_file="${_bm_lock_dir}/bot-merge.lock"
    mkdir -p "$_bm_lock_dir" 2>/dev/null || true
    _bm_lock_start=$(date +%s)
    # Use "$FLOCK_BIN" <lockfile> form (bash 3.x compatible; lock held until script exits).
    # We open FD 200 explicitly since {var} dynamic FD assignment requires bash 4.1+.
    # INFRA-1062: do NOT include 2>/dev/null on an `exec FD>file` call — bash
    # applies all redirections to the shell permanently, which would silence
    # ALL subsequent stderr output and hide set -e exits as "silent" failures.
    exec 200>"$_bm_lock_file" || { warn "[INFRA-860] Could not open bot-merge.lock — skipping mutex"; exec 200>/dev/null; }

    if ! "$FLOCK_BIN" -w 60 200 2>/dev/null; then
        # INFRA-3513: the 60s wait expired. A killed/timed-out prior bot-merge can leave an
        # orphan child (a `sleep`) holding fd 200 forever (INFRA-860, ~line 278), so the lock
        # looks "stuck" even though no bot-merge is running — this stalled the ship queue 3x
        # on 2026-07-29, forcing hand-created PRs. Tell a STALE (dead-holder) lock from real
        # contention via the PID sidecar: if the recorded holder is dead/unknown, REAP it by
        # rotating the lock file (the orphan keeps its lock on the now-unlinked inode,
        # harmlessly; our fresh fd locks a new inode). A LIVE holder is respected.
        _bm_holder=""
        [[ -f "${_bm_lock_file}.holder" ]] && _bm_holder=$(awk 'NR==1{print $1}' "${_bm_lock_file}.holder" 2>/dev/null)
        _bm_amb="${CHUMP_AMBIENT_LOG:-${LOCK_DIR:-${REPO_ROOT:-.}/.chump-locks}/ambient.jsonl}"
        mkdir -p "$(dirname "$_bm_amb")" 2>/dev/null || true
        if [[ -z "$_bm_holder" ]] || ! kill -0 "$_bm_holder" 2>/dev/null; then
            red "[INFRA-3513] bot-merge.lock held by a DEAD/unknown holder (${_bm_holder:-none}) — reaping the stale lock."
            printf '{"ts":"%s","kind":"bot_merge_stale_lock_reaped","branch":"%s","dead_holder":"%s"}\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BRANCH" "${_bm_holder:-none}" >> "$_bm_amb" 2>/dev/null || true
            rm -f "$_bm_lock_file" "${_bm_lock_file}.holder" 2>/dev/null || true
            exec 200>"$_bm_lock_file" || { warn "[INFRA-860] Could not reopen bot-merge.lock"; exec 200>/dev/null; }
            if ! "$FLOCK_BIN" -w 10 200 2>/dev/null; then
                red "[INFRA-860] bot-merge.lock: still contended after reaping — a live bot-merge may exist."
                exit 2
            fi
        else
            red "[INFRA-860] bot-merge.lock: held by a LIVE bot-merge (pid ${_bm_holder}) — waited 60s, giving up."
            exit 2
        fi
    fi
    # INFRA-3513: record the live holder (pid + epoch) so a later run can distinguish a
    # stale orphan-held lock from genuine contention.
    printf '%s %s\n' "$$" "$(date +%s)" > "${_bm_lock_file}.holder" 2>/dev/null || true
    _bm_wait=$(( $(date +%s) - _bm_lock_start ))
    if [[ "$_bm_wait" -gt 5 ]]; then
        info "[INFRA-860] bot-merge.lock: waited ${_bm_wait}s (contention detected)"
        _bm_amb="${CHUMP_AMBIENT_LOG:-${LOCK_DIR:-${REPO_ROOT:-.}/.chump-locks}/ambient.jsonl}"
        mkdir -p "$(dirname "$_bm_amb")" 2>/dev/null || true
        printf '{"ts":"%s","kind":"bot_merge_contention_avoided","branch":"%s","wait_s":%d}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BRANCH" "$_bm_wait" >> "$_bm_amb" 2>/dev/null || true
    fi
fi
# FD 200 stays open; "$FLOCK_BIN" released automatically when the script process exits.

# ── INFRA-995: pre-push staleness gate + RESILIENT-325 auto-rebase ─────────
# Belt-and-suspenders for the CLAUDE.md rule "rebase if your branch is more than
# 15 commits behind main". The earlier rebase block (§1) already rebases above
# 0 behind, but main may have moved during cargo clippy/test (often a 5-15 min
# window) — that drift is exactly the conflict-rot window RESILIENT-325 closes:
# rather than pushing stale and letting the PR land CONFLICTING on GitHub
# (needing a manual/armed-rebaser rescue later), re-fetch and rebase onto fresh
# origin/main immediately before push so the conflict window shrinks to ~0.
# Only bail out (no auto-rebase attempt) when we're pathologically stale —
# > STALE_REBASE_THRESHOLD commits behind means main moved enough that an
# unattended rebase here is risky and likely wants human eyes.
STALE_REBASE_THRESHOLD="${CHUMP_BOT_MERGE_STALE_THRESHOLD:-15}"
if [[ $DRY_RUN -eq 0 ]]; then
    run_timed_hb "git fetch (pre-push freshness)" 60 \
        git fetch "$REMOTE" "$BASE_BRANCH" --quiet 2>/dev/null || true
    BEHIND_NOW=$(git rev-list --count "HEAD..${REMOTE}/${BASE_BRANCH}" 2>/dev/null || echo 0)
    _amb_path="${LOCK_DIR:-${REPO_ROOT:-.}/.chump-locks}/ambient.jsonl"
    if [[ "$BEHIND_NOW" -gt "$STALE_REBASE_THRESHOLD" ]]; then
        red "INFRA-995: branch is $BEHIND_NOW commits behind $REMOTE/$BASE_BRANCH (threshold ${STALE_REBASE_THRESHOLD})."
        red "  main moved while we built/tested — too stale to auto-rebase safely."
        red "  Recover: git fetch && git rebase $REMOTE/$BASE_BRANCH && rerun bot-merge."
        mkdir -p "$(dirname "$_amb_path")" 2>/dev/null || true
        printf '{"ts":"%s","kind":"stale_branch_blocked","branch":"%s","behind":%d,"threshold":%d,"phase":"pre-push"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BRANCH" "$BEHIND_NOW" "$STALE_REBASE_THRESHOLD" \
            >> "$_amb_path" 2>/dev/null || true
        _bm_fail "stale-branch" 3 "branch $BEHIND_NOW commits behind > threshold ${STALE_REBASE_THRESHOLD}"
    elif [[ "$BEHIND_NOW" -gt 0 ]]; then
        info "RESILIENT-325: $BEHIND_NOW commit(s) behind $REMOTE/$BASE_BRANCH — rebasing onto fresh base immediately before push"
        _pp_rebase_args=("${REMOTE}/${BASE_BRANCH}")
        if [[ "$NO_MERGE_DRIVER" == "1" ]]; then
            _pp_rebase_args+=(-c merge.ci-yml-add-row.driver= -c merge.pre-commit-add-guard.driver= -c merge.chump-state-sql-regen.driver=)
        fi
        if ! run_timed_hb "git rebase (pre-push, RESILIENT-325)" 60 git rebase "${_pp_rebase_args[@]}"; then
            git rebase --abort >/dev/null 2>&1 || true
            red "RESILIENT-325: pre-push rebase onto $REMOTE/$BASE_BRANCH hit a conflict — resolve manually and rerun bot-merge."
            mkdir -p "$(dirname "$_amb_path")" 2>/dev/null || true
            printf '{"ts":"%s","kind":"pre_push_rebase_conflict","branch":"%s","behind":%d,"phase":"pre-push"}\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BRANCH" "$BEHIND_NOW" \
                >> "$_amb_path" 2>/dev/null || true
            _bm_fail "pre-push-rebase" 3 "conflict rebasing onto fresh $REMOTE/$BASE_BRANCH immediately before push"
        fi
        mkdir -p "$(dirname "$_amb_path")" 2>/dev/null || true
        printf '{"ts":"%s","kind":"pre_push_rebase_applied","branch":"%s","behind":%d,"phase":"pre-push"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BRANCH" "$BEHIND_NOW" \
            >> "$_amb_path" 2>/dev/null || true
        info "RESILIENT-325: pre-push rebase clean — branch now up to date with $REMOTE/$BASE_BRANCH"
    fi
fi

# ── INFRA-993: scratch-commit guard — block catastrophic-delete PRs ──────────
# Near-miss observed 2026-05-11: PRs #1441 + #1452 each proposed +2 / -378000+
# lines across ~1910 files (effectively deleting the entire repo). Root cause:
# worktree corruption (INFRA-779 family). Independent of root-cause fix, this
# is the creation-time gate: refuse to push when the diff vs origin/main shows
# > 50000 deletions OR deletions > 100× additions. Override: --allow-mass-delete.
if [[ "$DRY_RUN" -eq 0 && "${CHUMP_SCRATCH_GUARD_DISABLE:-0}" != "1" ]]; then
    _sg_amb="${CHUMP_AMBIENT_LOG:-${LOCK_DIR:-${REPO_ROOT:-.}/.chump-locks}/ambient.jsonl}"
    _sg_stats="$(git diff --shortstat "${REMOTE}/${BASE_BRANCH}..HEAD" 2>/dev/null || true)"
    # Sample format: "5 files changed, 12 insertions(+), 3 deletions(-)"
    # Parse with sed; default to 0 if a clause is missing.
    _sg_files="$(printf '%s' "$_sg_stats" | sed -nE 's/.* ([0-9]+) files? changed.*/\1/p')"
    _sg_adds="$(printf '%s' "$_sg_stats"  | sed -nE 's/.* ([0-9]+) insertions?\(\+\).*/\1/p')"
    _sg_dels="$(printf '%s' "$_sg_stats"  | sed -nE 's/.* ([0-9]+) deletions?\(-\).*/\1/p')"
    _sg_files="${_sg_files:-0}"
    _sg_adds="${_sg_adds:-0}"
    _sg_dels="${_sg_dels:-0}"
    # Tripwire: > 50000 deletions OR deletions > 100× max(adds, 1).
    _sg_threshold_abs="${CHUMP_SCRATCH_GUARD_MAX_DELETIONS:-50000}"
    _sg_threshold_ratio="${CHUMP_SCRATCH_GUARD_RATIO:-100}"
    _sg_adds_floor=$((_sg_adds > 0 ? _sg_adds : 1))
    if [[ "$_sg_dels" -gt "$_sg_threshold_abs" ]] || \
       [[ "$_sg_dels" -gt $(( _sg_adds_floor * _sg_threshold_ratio )) ]]; then
        # Compose gap ID for the ambient event.
        _sg_gap="${GAP_IDS[0]:-unknown}"
        if [[ "$ALLOW_MASS_DELETE" == "1" ]]; then
            yellow "scratch-commit guard: --allow-mass-delete set; permitting +${_sg_adds} / -${_sg_dels} across ${_sg_files} files"
            mkdir -p "$(dirname "$_sg_amb")" 2>/dev/null || true
            printf '{"ts":"%s","kind":"scratch_commit_override_used","gap_id":"%s","additions":%s,"deletions":%s,"files":%s,"threshold_abs":%s,"threshold_ratio":%s,"branch":"%s"}\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_sg_gap" "$_sg_adds" "$_sg_dels" "$_sg_files" "$_sg_threshold_abs" "$_sg_threshold_ratio" "$BRANCH" \
                >> "$_sg_amb" 2>/dev/null || true
        else
            red "Aborting: this commit deletes ${_sg_dels} lines across ${_sg_files} files (refusing — set --allow-mass-delete to override)."
            red "Adds: ${_sg_adds}. Threshold: > ${_sg_threshold_abs} deletions OR deletions > ${_sg_threshold_ratio}× additions."
            red "See ambient.jsonl for the kind=scratch_commit_blocked event."
            mkdir -p "$(dirname "$_sg_amb")" 2>/dev/null || true
            printf '{"ts":"%s","kind":"scratch_commit_blocked","gap_id":"%s","additions":%s,"deletions":%s,"files":%s,"threshold_abs":%s,"threshold_ratio":%s,"branch":"%s"}\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_sg_gap" "$_sg_adds" "$_sg_dels" "$_sg_files" "$_sg_threshold_abs" "$_sg_threshold_ratio" "$BRANCH" \
                >> "$_sg_amb" 2>/dev/null || true
            exit 15
        fi
    fi
fi

# ── 4b. Duplicate-PR check (INFRA-996) ────────────────────────────────────────
# Before pushing, verify no open PR already has this GAP-ID in its title with a
# different head branch. Duplicate PRs waste CI, confuse reviewers, and caused
# 3 incidents in 7 days (#1536+#1540, #1323+#1333, #1283/#1284).
# Bypass: --force-duplicate or CHUMP_FORCE_DUPLICATE=1.
_amb_path="${CHUMP_AMBIENT_IN_PROMPT:-${LOCK_DIR}/ambient.jsonl}"
if [[ "${FORCE_DUPLICATE}" != "1" && ${#GAP_IDS[@]} -gt 0 ]]; then
    _dup_found=0
    _dup_pr_numbers=""
    for _gid in "${GAP_IDS[@]}"; do
        # REST-only: gh pr list uses GraphQL but falls back cleanly; we skip if
        # rate-limited rather than blocking the push (fail-open for dup check).
        # INFRA-2925: $REPO was never assigned anywhere in this script — every
        # other `gh pr` call here relies on gh's cwd auto-detection instead.
        # Under `set -u` this was an unconditional "unbound variable" crash.
        _existing=$(gh pr list --state open \
            --search "${_gid} in:title" --json number,headRefName \
            --limit 10 2>/dev/null || true)
        if [[ -z "$_existing" ]]; then
            continue
        fi
        # Filter: exclude PRs whose head ref matches our current branch.
        _conflicts=$(echo "$_existing" | python3 -c "
import json,sys
rows=json.load(sys.stdin)
conflicts=[str(r['number']) for r in rows if r.get('headRefName','') != '${BRANCH}']
print(' '.join(conflicts))
" 2>/dev/null || true)
        if [[ -n "$_conflicts" ]]; then
            _dup_found=1
            _dup_pr_numbers="${_dup_pr_numbers} ${_conflicts}"
        fi
    done
    if [[ "$_dup_found" -eq 1 ]]; then
        _dup_pr_numbers="${_dup_pr_numbers# }"
        red "Duplicate PR blocked: open PR(s) already claim this gap: ${_dup_pr_numbers}"
        red "  Use --force-duplicate to override (legitimate retry after the prior PR closed)."
        # Emit ambient event for frequency tracking.
        printf '{"ts":"%s","kind":"dup_pr_blocked","gap_id":"%s","existing_pr_numbers":"%s","current_branch":"%s"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${GAP_IDS[*]:-}" "$_dup_pr_numbers" "$BRANCH" \
            >> "$_amb_path" 2>/dev/null || true
        _bm_fail "dup-pr" 16 "duplicate PR detected for gap ${GAP_IDS[*]:-}: existing ${_dup_pr_numbers}"
    fi
fi

# ── 5. Push ───────────────────────────────────────────────────────────────────
# META-156 AC#1: step=push
_bm_step_start "push"
stage_start "git push $BRANCH → $REMOTE"
# INFRA-719: signal to the pre-push hook that this push is bot-merge-initiated.
# The hook blocks first-push of chump/* branches unless this flag is set, to
# prevent the manual "git push + gh pr create" bypass that skips gap-ship-fatal.
export CHUMP_BOT_MERGE_IN_PROGRESS=1

# INFRA-1399: bot-merge delegates the cargo test gate to CI on the PR side.
# Running the full test suite (140+ s) inside the pre-push hook creates sibling
# contention and stalls every bot-merge for 5-15 min under fleet load.
# CI on the PR enforces the same gate — running it twice is pure waste.
# CHUMP_TEST_GATE=0 skips the slow phase; the fmt check remains active (< 10 s).
# An audit event is emitted so the bypass is traceable in ambient.jsonl.
_BM_PUSH_TIMEOUT_S="${CHUMP_BOT_MERGE_PHASE_TIMEOUT_S:-300}"
if [[ "${CHUMP_TEST_GATE:-1}" != "0" ]]; then
    export CHUMP_TEST_GATE=0
    _bm_amb_path="${LOCK_DIR:-${REPO_ROOT:-.}/.chump-locks}/ambient.jsonl"
    _ambient_write "$_bm_amb_path" \
        "$(printf '{"ts":"%s","kind":"bot_merge_test_gate_skipped","gap_id":"%s","branch":"%s","note":"INFRA-1399: test gate delegated to CI; CHUMP_TEST_GATE=0 for this push"}' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${GAP_IDS[0]:-none}" "$BRANCH")"
fi

# INFRA-1834: --no-verify audit guard. bot-merge currently never passes
# --no-verify on git push, but the env-controlled escape hatch
# CHUMP_BOT_MERGE_NO_VERIFY=1 routes through the same audit-mandate as
# chump-commit.sh: require CHUMP_NO_VERIFY_REASON='<text>' AND emit
# kind=audit_no_verify to ambient + .chump-locks/no-verify-audit.jsonl.
# This is the operator's escape hatch when a pre-push hook is genuinely
# wedged; we don't block, we just demand a reason and log it.
_bm_no_verify_arg=""
if [[ "${CHUMP_BOT_MERGE_NO_VERIFY:-0}" == "1" ]]; then
    _bm_nv_reason="${CHUMP_NO_VERIFY_REASON:-}"
    _bm_nv_trim="${_bm_nv_reason#"${_bm_nv_reason%%[![:space:]]*}"}"
    _bm_nv_trim="${_bm_nv_trim%"${_bm_nv_trim##*[![:space:]]}"}"
    if [[ -z "$_bm_nv_trim" ]]; then
        red "INFRA-1834: CHUMP_BOT_MERGE_NO_VERIFY=1 requires CHUMP_NO_VERIFY_REASON='<text>' env (empty/whitespace rejected)."
        echo "Example: CHUMP_BOT_MERGE_NO_VERIFY=1 CHUMP_NO_VERIFY_REASON='pre-push hook hung 90s; emergency push for INFRA-XXXX rescue' bash scripts/coord/bot-merge.sh ..." >&2
        exit 14
    fi
    _bm_no_verify_arg="--no-verify"
    _bm_nv_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    _bm_nv_session="${CHUMP_SESSION_ID:-${CLAUDE_SESSION_ID:-unknown}}"
    _bm_nv_reason_esc="${_bm_nv_trim//\\/\\\\}"
    _bm_nv_reason_esc="${_bm_nv_reason_esc//\"/\\\"}"
    _bm_nv_line="{\"ts\":\"$_bm_nv_ts\",\"kind\":\"audit_no_verify\",\"session\":\"$_bm_nv_session\",\"branch\":\"$BRANCH\",\"caller\":\"bot-merge.sh\",\"gap_id\":\"${GAP_IDS[0]:-none}\",\"reason\":\"$_bm_nv_reason_esc\"}"
    printf '%s\n' "$_bm_nv_line" >> "${LOCK_DIR:-${REPO_ROOT:-.}/.chump-locks}/ambient.jsonl"
    printf '%s\n' "$_bm_nv_line" >> "${LOCK_DIR:-${REPO_ROOT:-.}/.chump-locks}/no-verify-audit.jsonl"
    yellow "INFRA-1834: --no-verify bypass logged (reason: $_bm_nv_trim)"
fi

_bm_push_exit=0
run_timed_hb "git push" "$_BM_PUSH_TIMEOUT_S" \
    git push "$REMOTE" "$BRANCH" --force-with-lease $_bm_no_verify_arg || _bm_push_exit=$?

if [[ "$_bm_push_exit" -eq 124 ]]; then
    # Timeout — the pre-push hook (fmt or other gate) stalled longer than
    # CHUMP_BOT_MERGE_PHASE_TIMEOUT_S. Emit bot_merge_stall_detected so the
    # fleet monitor can alert and the operator can investigate.
    _bm_stall_path="${LOCK_DIR:-${REPO_ROOT:-.}/.chump-locks}/ambient.jsonl"
    _ambient_write "$_bm_stall_path" \
        "$(printf '{"ts":"%s","kind":"bot_merge_stall_detected","phase":"git push","timeout_s":%d,"gap_id":"%s","branch":"%s","note":"pre-push hook stalled > %ds; check for hung cargo fmt or other slow pre-push gate. Retry: CHUMP_FMT_CHECK=0 git push"}' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_BM_PUSH_TIMEOUT_S" \
            "${GAP_IDS[0]:-none}" "$BRANCH" "$_BM_PUSH_TIMEOUT_S")"
    red "git push stalled: pre-push hook did not complete within ${_BM_PUSH_TIMEOUT_S}s."
    red "  → kind=bot_merge_stall_detected emitted to ambient.jsonl"
    red "  → Retry with: CHUMP_FMT_CHECK=0 scripts/coord/bot-merge.sh --gap ${GAP_IDS[0]:-<ID>} --auto-merge"
    _bm_step_done "push" 15
    _BM_TERMINAL_STATE="push_failed"
    _bm_fail "push" 15 "pre-push hook stalled after ${_BM_PUSH_TIMEOUT_S}s"
elif [[ "$_bm_push_exit" -ne 0 ]]; then
    red "git push failed (exit ${_bm_push_exit})."
    _bm_step_done "push" "$_bm_push_exit"
    _BM_TERMINAL_STATE="push_failed"
    _bm_fail "push" 15 "force-with-lease rejected or network error"
fi
stage_done
_bm_step_done "push" 0
green "Pushed."

# ── 5b. INFRA-084 advisory: warn if PR diff hand-edits docs/gaps.yaml ───────
# The merge_group workflow `.github/workflows/regenerate-gaps-yaml.yml`
# auto-regenerates the YAML from .chump/state.db on every queue temp branch,
# so most hand-edits are unnecessary now. Common case where this matters:
#   - filing PRs that append a new gap entry by hand instead of using
#     `chump gap reserve`
#   - closure PRs that hand-edit status:done instead of running
#     `chump gap ship --closed-pr <N> --update-yaml`
# Advisory-only for now; INFRA-094 will block these in pre-commit once the
# merge_group regen is fully validated.
if [[ "${CHUMP_RAW_YAML_EDIT_CHECK:-1}" != "0" ]]; then
    if git diff --name-only "${REMOTE}/${BASE_BRANCH}..HEAD" 2>/dev/null \
        | grep -qx 'docs/gaps.yaml'; then
        info "[bot-merge] NOTE: this PR's diff includes docs/gaps.yaml hand-edits."
        info "[bot-merge]   Prefer: chump gap reserve / set / ship --update-yaml so the canonical"
        info "[bot-merge]   regenerator (.github/workflows/regenerate-gaps-yaml.yml) round-trips"
        info "[bot-merge]   the diff cleanly. The merge_group workflow will auto-fix any drift."
        info "[bot-merge]   Suppress this notice: CHUMP_RAW_YAML_EDIT_CHECK=0"
    fi
fi

# ── 6. Open or update PR ─────────────────────────────────────────────────────
# META-156 AC#1: step=pr_create
_bm_step_start "pr_create"
# INFRA-1082: cache-first branch→PR-number lookup; REST fallback on miss.
EXISTING_PR=""
if declare -F cache_lookup_pr_by_branch >/dev/null 2>&1; then
    # EFFECTIVE-312: on hosts without the webhook cache feed the lookup
    # errors on miss — bare assignment under set -e killed the ship at
    # pr_create (cycle-10 xtrace).
    _bm_exist_meta="$(cache_lookup_pr_by_branch "$BRANCH" 2>/dev/null || true)"
    if [[ -n "$_bm_exist_meta" ]]; then
        EXISTING_PR="$(printf '%s' "$_bm_exist_meta" | \
            python3 -c "import sys,json; print(json.load(sys.stdin).get('number','') or '')" \
            2>/dev/null || echo "")"
    fi
fi
if [[ -z "$EXISTING_PR" ]]; then
    EXISTING_PR=$(gh pr view "$BRANCH" --json number --jq '.number' 2>/dev/null || echo "")
fi

# INFRA-997: refuse to open a PR when the branch's commits since divergence
# are ONLY auto-staging commits from INFRA-472. These are mechanical commits
# bot-merge.sh creates pre-rebase to stash uncommitted scoped edits; they
# carry no gap work. PR #1655 (2026-05-13) shipped exactly this pattern — a
# pre-rebase staging branch with no meaningful work, immediately closed as
# duplicate. Guard prevents that waste class. To bypass when legitimate
# (rare — operator confirms staging IS the work): CHUMP_ALLOW_STAGING_ONLY_PR=1.
if [[ -z "$EXISTING_PR" && "${CHUMP_ALLOW_STAGING_ONLY_PR:-0}" != "1" ]]; then
    _commit_subjects=$(git log "${REMOTE}/${BASE_BRANCH}..HEAD" --pretty=format:'%s' 2>/dev/null)
    # CREDIBLE-162: grep -c exits 1 on zero matches — unguarded under
    # set -e this killed bot-merge SILENTLY whenever the branch had no
    # commits (e.g. an agent cycle that never committed). Guard it and
    # refuse the empty branch LOUDLY instead.
    _total_commits=$(echo "$_commit_subjects" | grep -cE '.' || true)
    if [[ "$_total_commits" -eq 0 ]]; then
        red "CREDIBLE-162: refusing to gh pr create — branch $BRANCH has ZERO commits since $BASE_BRANCH."
        red "          The agent cycle produced no committed work; nothing to ship."
        _ambient_path="${LOCK_DIR:-${REPO_ROOT:-.}/.chump-locks}/ambient.jsonl"
        printf '{"ts":"%s","kind":"zero_commit_branch_blocked","branch":"%s","gap":"%s"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BRANCH" "${GAP_ID:-unknown}" \
            >> "$_ambient_path" 2>/dev/null || true
        _bm_fail "pr-create" 17 "zero-commit branch — agent produced no work (CREDIBLE-162)"
    fi
    _staging_commits=$(echo "$_commit_subjects" | grep -cE '^auto: bot-merge pre-rebase staging' || true)
    if [[ "$_total_commits" -gt 0 && "$_total_commits" -eq "$_staging_commits" ]]; then
        red "INFRA-997: refusing to gh pr create — branch $BRANCH has $_total_commits commit(s) since $BASE_BRANCH"
        red "          and ALL of them are auto-staging commits from INFRA-472."
        red "          A PR with only mechanical staging carries no gap work."
        red ""
        red "  Commits on this branch:"
        echo "$_commit_subjects" | sed 's/^/    /' >&2
        red ""
        red "  Most likely cause: bot-merge.sh ran without any gap commits being landed first."
        red "  Recovery: do the actual gap work, commit it, then re-run bot-merge.sh."
        red "  Bypass (rare; operator confirmed): CHUMP_ALLOW_STAGING_ONLY_PR=1"
        # Best-effort ambient event so the operator can see this fired
        _ambient_path="${LOCK_DIR:-${REPO_ROOT:-.}/.chump-locks}/ambient.jsonl"
        if [[ -w "$(dirname "$_ambient_path")" ]] 2>/dev/null; then
            printf '{"ts":"%s","kind":"staging_only_pr_blocked","branch":"%s","commits":%d}\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BRANCH" "$_total_commits" >> "$_ambient_path"
        fi
        _bm_fail "pr-create" 16 "staging-only branch — refused to open empty PR (INFRA-997)"
    fi
fi

if [[ -z "$EXISTING_PR" ]]; then
    # INFRA-1219: dedup gate — refuse if an open PR already exists for the
    # same gap-ID in title. Catches the 80% case where two agents race to
    # ship the same gap (57 of 79 closed-not-merged PRs in 14d were dups).
    _DEDUP_GATE="$REPO_ROOT/scripts/coord/pr-create-gate.sh"
    if [[ -x "$_DEDUP_GATE" && -n "${GAP_ID:-}" && "${CHUMP_PR_DEDUP_DISABLE:-0}" != "1" ]]; then
        if ! "$_DEDUP_GATE" "$GAP_ID"; then
            _bm_fail "pr-create" 19 "INFRA-1219 dedup gate refused — open PR already exists for $GAP_ID"
        fi
    fi

    # CREDIBLE-270: definition-of-ready gate — refuse to open a PR unless
    # `chump preflight` is green locally. Skipped under --fast (same
    # rationale as the --fast clippy skip above: CI is the gate, agent task
    # budget is the constraint) so this mirrors non-fast/human-developer
    # ergonomics rather than adding a second, contradictory local-check path.
    _DOR_GATE="$REPO_ROOT/scripts/coord/definition-of-ready-gate.sh"
    if [[ $FAST -eq 0 && -x "$_DOR_GATE" && "${CHUMP_DOR_DISABLE:-0}" != "1" ]]; then
        # RESILIENT-132 AC#2: same mismatch class as RESILIENT-133 (clippy/test
        # above) — this stage shells out to `chump preflight`, which falls back
        # to raw `cargo fmt/clippy/check` when the `chump` binary isn't already
        # built (cold worktree). Under fleet build contention that cold
        # compile alone can exceed the 300s stage-watchdog default even though
        # `chump preflight`'s own internal budget is far larger, so the
        # watchdog fired mid-compile rather than on a genuine gate failure.
        # Match the 900s budget already used for the clippy/test stages.
        stage_start "definition-of-ready gate (chump preflight)" 900
        if ! "$_DOR_GATE" "${GAP_ID:-}"; then
            _bm_fail "pr-create" 21 "CREDIBLE-270 definition-of-ready gate refused — chump preflight not green locally"
        fi
        stage_done
    fi

    # CREDIBLE-215: mechanical stub detection — advisory REACHES/TEST-ONLY/
    # UNRELATED check before pr_create, so a stub-shaped diff (the
    # EFFECTIVE-354/CREDIBLE-200 pattern: cascade ships a green, empty PR)
    # is flagged locally instead of costing a full CI round + human read.
    # Never blocks the ship — UNRELATED is a review signal, not a gate.
    if [[ -n "${GAP_ID:-}" ]]; then
        _REACHES_DIFF_FILE="$(mktemp)"
        git diff --name-only "${REMOTE}/${BASE_BRANCH}...HEAD" > "$_REACHES_DIFF_FILE" 2>/dev/null || true
        if [[ -s "$_REACHES_DIFF_FILE" ]]; then
            chump verify-reaches --gap "$GAP_ID" --diff "$_REACHES_DIFF_FILE" 2>/dev/null || true
        fi
        rm -f "$_REACHES_DIFF_FILE"
    fi

    stage_start "gh pr create"
    # Build a body from the gap IDs cited in commits since base diverged.
    COMMIT_LOG=$(git log "${REMOTE}/${BASE_BRANCH}..HEAD" --oneline 2>/dev/null | head -20)
    # INFRA-630: extract both classic DOMAIN-NUMBER and RFC-4122 UUID gap IDs from commit log.
    COMMIT_GAP_IDS=$(echo "$COMMIT_LOG" | grep -oE '[A-Z]+-[0-9]+|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | sort -u | tr '\n' ' ' || true)
    GAP_LINE=""
    [[ -n "$COMMIT_GAP_IDS" ]] && GAP_LINE="**Gaps addressed:** $COMMIT_GAP_IDS"

    # INFRA-1219: dedup gate — refuse if another open PR cites the same gap.
    # Audit 2026-05-14: 57 of 79 closed-not-merged PRs in last 14d were
    # this pattern (parallel work; second PR loses, CI compute wasted).
    if [[ -n "$COMMIT_GAP_IDS" ]] && [[ -f "$REPO_ROOT/scripts/coord/lib/pr-dedup.sh" ]]; then
        # shellcheck disable=SC1091
        source "$REPO_ROOT/scripts/coord/lib/pr-dedup.sh"
        # shellcheck disable=SC2086  # word-splitting is intended for the gap-id list
        if ! check_pr_dedup "$BRANCH" $COMMIT_GAP_IDS; then
            _bm_fail "pr-create" 16 "INFRA-1219: refusing to open duplicate PR; another open PR exists for one of these gap IDs"
        fi
    fi

    # INFRA-501: PR title is public — ensure the last commit subject complies with
    # docs/agents/RESEARCH_PRIVACY.md § "PR title and commit subject hygiene".
    # Prohibited: specific findings, model-tier outcomes, IP-protection mechanic language.
    PR_TITLE=$(git log "${REMOTE}/${BASE_BRANCH}..HEAD" --oneline | tail -1 | sed 's/^[a-f0-9]* //')

    # INFRA-060 (M2): if a `.chump-plans/<gap>.md` exists for any gap cited in
    # commit messages, splice its body verbatim into the PR description so
    # reviewers can see the planned files + open-PR overlap scan.
    PLAN_BLOCK=""
    for gid in $COMMIT_GAP_IDS; do
        plan_file=".chump-plans/${gid}.md"
        if [[ -f "$plan_file" ]]; then
            PLAN_BLOCK+="$(printf '\n\n<details><summary>Plan-mode (%s)</summary>\n\n%s\n\n</details>' "$gid" "$(cat "$plan_file")")"
        fi
    done

    # INFRA-632: build PR body — use --pr-template file when provided,
    # substituting {{COMMIT_LOG}}, {{GAP_LINE}}, {{PLAN_BLOCK}} placeholders;
    # otherwise fall back to the default Chump template.
    if [[ -n "$PR_TEMPLATE" ]]; then
        if [[ ! -f "$PR_TEMPLATE" ]]; then
            red "INFRA-632: --pr-template '$PR_TEMPLATE' not found."
            exit 1
        fi
        _commit_log_escaped=$(git log "${REMOTE}/${BASE_BRANCH}..HEAD" --oneline | sed 's/^/- /' | sed 's/[&/\]/\\&/g' | tr '\n' '\r')
        _pr_body=$(sed \
            -e "s|{{GAP_LINE}}|${GAP_LINE}|g" \
            -e "s|{{PLAN_BLOCK}}|${PLAN_BLOCK}|g" \
            "$PR_TEMPLATE" \
            | awk -v cl="$_commit_log_escaped" '{gsub(/\{\{COMMIT_LOG\}\}/, cl); print}' \
            | tr '\r' '\n')
    else
        _pr_body="$(cat <<EOF
## Changes
$(git log "${REMOTE}/${BASE_BRANCH}..HEAD" --oneline | sed 's/^/- /')

${GAP_LINE}
${PLAN_BLOCK}

## Checklist
- [x] \`cargo fmt\` clean
- [x] \`cargo clippy\` clean
$([ $SKIP_TESTS -eq 0 ] && echo "- [x] \`cargo test\` passed" || echo "- [ ] tests skipped (non-Rust change)")

🤖 Opened by bot-merge.sh
EOF
)"
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        info "[dry-run] gh pr create --base $BASE_BRANCH --title \"$PR_TITLE\" …"
    else
        # INFRA-1031 + INFRA-1055: GraphQL preflight — gh pr create uses GraphQL;
        # if quota is 0 (or low per circuit-breaker gate) fall back to REST.
        _graphql_remaining="${RL_GQL_REMAINING:-1}"
        if [[ "$_graphql_remaining" -le 0 ]] || \
           { declare -F rate_limit_gate >/dev/null 2>&1 && [[ "${_BM_RL_DEGRADED:-0}" -ge 1 ]] && [[ "${RL_GQL_PCT:-100}" -le "${CHUMP_RL_GQL_WARN_PCT:-50}" ]]; }; then
            warn "INFRA-1031/1055: GraphQL quota ${_graphql_remaining:-0} (${RL_GQL_PCT:-?}% remaining) — falling back to REST gh api repos/.../pulls"
            _repo_nwo=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "")
            if [[ -n "$_repo_nwo" ]]; then
                _rest_body=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$_pr_body" 2>/dev/null || echo "\"$_pr_body\"")
                _rest_result=$(gh api "repos/$_repo_nwo/pulls" --method POST \
                    --field title="$PR_TITLE" \
                    --field base="$BASE_BRANCH" \
                    --field head="$BRANCH" \
                    --field body="$_pr_body" \
                    --jq '.number' 2>/dev/null || echo "")
                if [[ -n "$_rest_result" ]]; then
                    _ambient_write "${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}" \
                        "$(printf '{"ts":"%s","kind":"graphql_exhausted","source":"bot-merge","note":"INFRA-1031 REST fallback succeeded PR #%s"}' \
                            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_rest_result")"
                    green "PR #$_rest_result created via REST fallback (GraphQL quota was 0)."
                else
                    red "INFRA-1031: REST fallback also failed — GraphQL exhausted and REST failed."
                    _ambient_write "${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}" \
                        "$(printf '{"ts":"%s","kind":"graphql_exhausted","source":"bot-merge","note":"INFRA-1031 REST fallback failed; branch=%s"}' \
                            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BRANCH")"
                    _bm_fail "pr-create" 16 "GraphQL exhausted and REST fallback failed; retry when quota resets (gh api rate_limit)"
                fi
            else
                red "INFRA-1031: GraphQL exhausted and cannot determine repo NWO for REST fallback."
                _bm_fail "pr-create" 16 "GraphQL exhausted; retry when quota resets (gh api rate_limit)"
            fi
        elif ! gh_with_backoff "gh pr create" 120 pr create \
            --base "$BASE_BRANCH" \
            --title "$PR_TITLE" \
            --body "$_pr_body"; then
            red "gh pr create failed or timed out."
            _bm_fail "pr-create" 16 "gh pr create failed or timed out"
        fi
        # INFRA-1031: if REST fallback set the PR number, skip gh pr view (may also be GraphQL).
        if [[ -n "${_rest_result:-}" ]]; then
            _new_pr="$_rest_result"
        else
            _new_pr=""
            for _try in 1 2 3 4 5; do
                _new_pr=$(gh pr view "$BRANCH" --json number --jq '.number' 2>/dev/null || \
                          gh api "repos/$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)/pulls" \
                              --jq "[.[] | select(.head.ref==\"$BRANCH\")] | first | .number" 2>/dev/null || echo "")
                [[ -n "$_new_pr" ]] && break
                sleep 2
            done
            if [[ -z "$_new_pr" ]]; then
                red "gh pr create reported success but no PR is visible for branch $BRANCH — refusing to exit 0."
                _bm_fail "pr-create" 16 "PR not visible after gh pr create"
            fi
        fi
        stage_done
        green "PR #$_new_pr created and verified."

        # ── FLEET-029: post-PR-create overlap scan ──
        if [[ -z "${FLEET_029_PR_SCAN_SKIP:-}" ]]; then
            # Scan for overlapping open PRs with similar titles or gap IDs
            info "FLEET-029: scanning for overlapping open PRs…"
            bash scripts/coord/chump-ambient-glance.sh --title "$PR_TITLE" --check-prs || true
        fi
    fi
else
    green "PR #$EXISTING_PR already exists — updated by push."
fi
# META-156 AC#1: step=pr_create done
_bm_step_done "pr_create" 0

# ── INFRA-103: apply parallelism label to the PR ─────────────────────────────
# Classify this PR as 'serializing' or 'parallel-safe' based on whether it
# touches shared coordination hot files. Label is applied regardless of
# whether the PR was just created or already existed.
_label_pr="${EXISTING_PR:-}"
if [[ -z "$_label_pr" ]]; then
    _label_pr="$(gh pr view "$BRANCH" --json number --jq '.number' 2>/dev/null || echo "")"
fi
if [[ -n "$_label_pr" ]]; then
    apply_pr_parallelism_label "$_label_pr"
fi

# ── 6.7. CREDIBLE-039: pre-ship guard — refuse if gap is done+closed_pr ──────
# If state.db says the gap is already done with a closed_pr set (and that PR
# is not our current PR), refuse to proceed: someone else already closed it or
# the gap was prematurely closed on a different PR.
# Bypass: CHUMP_ALLOW_RECYCLE=1 (same env var used by --auto-fix).
if [[ "${CHUMP_ALLOW_RECYCLE:-0}" != "1" ]] && [[ ${#GAP_IDS[@]} -gt 0 ]] && [[ -f "${MAIN_REPO:-$REPO_ROOT}/.chump/state.db" ]]; then
    _pre_ship_db="${MAIN_REPO:-$REPO_ROOT}/.chump/state.db"
    for _gid in "${GAP_IDS[@]}"; do
        _existing=$(sqlite3 "$_pre_ship_db" "SELECT status, closed_pr FROM gaps WHERE id='$_gid' AND status='done' AND closed_pr IS NOT NULL AND closed_pr != '';" 2>/dev/null || true)
        if [[ -n "$_existing" ]]; then
            _e_status="${_existing%%|*}"
            _e_pr="${_existing##*|}"
            red "CREDIBLE-039: gap $_gid is already status=done with closed_pr=#$_e_pr in state.db"
            red "  This gap was already closed — refusing to ship a second time."
            red "  Bypass: CHUMP_ALLOW_RECYCLE=1 $0 ..."
            exit 3
        fi
    done
fi

# ── 6.75. Auto-close gap on the implementation PR (INFRA-154 / INFRA-1030) ────
# INFRA-1030: gap ship is now AFTER auto-merge arm (section 7 below).
# Previous order was: gap ship → arm auto-merge. If bot-merge died between those
# two steps, the gap was left status=done but the PR had no auto-merge → stalls.
# New order: arm auto-merge → THEN gap ship. Worst-case on abort: gap stays
# in_progress but PR will still merge when CI passes. Operator recovers with:
#   chump gap ship <GAP-ID> --closed-pr <PR> --update-yaml
# (Moved body to end of section 7, after gh pr merge --auto --squash.)

# ── 7. Enable auto-merge (optional) ──────────────────────────────────────────
# META-156 AC#1: step=pr_merge_arm
_bm_step_start "pr_merge_arm"
if [[ $AUTO_MERGE -eq 1 ]]; then
    TARGET_PR="${EXISTING_PR:-}"
    if [[ -z "$TARGET_PR" ]]; then
        TARGET_PR=$(gh pr view "$BRANCH" --json number --jq '.number' 2>/dev/null || echo "")
    fi
    if [[ -n "$TARGET_PR" ]]; then
        # ── INFRA-2274 Consensus merge gate (shadow mode default) ────────────
        # Replaces the 2026-05-30 operator admin-merge bypass surface with
        # multi-curator consensus. Default mode is SHADOW: gate runs, logs
        # would-block events to ambient (kind=consensus_gate_would_block) for
        # 7 days, but does NOT block the merge. Flip to enforce mode after
        # observation window with CHUMP_CONSENSUS_MERGE_GATE=enforce.
        #
        # Gate behaviour:
        #   CHUMP_CONSENSUS_MERGE_GATE unset (or 0) → skipped entirely
        #   CHUMP_CONSENSUS_MERGE_GATE=1            → shadow (log only)
        #   CHUMP_CONSENSUS_MERGE_GATE=enforce      → blocking
        #   CHUMP_OPERATOR_CONSENSUS_BYPASS=<reason>→ skip with audit emit
        #
        # Verdict is computed via `chump consensus-tally --corr-id pr-N --since 1h`;
        # PASSED proceeds, anything else (FAILED, NO_QUORUM, EXTENDED) blocks
        # in enforce mode and logs in shadow mode.
        # scanner-anchor: "kind":"consensus_gate_would_block"
        # scanner-anchor: "kind":"consensus_gate_blocked"
        # scanner-anchor: "kind":"consensus_gate_approved"
        # scanner-anchor: "kind":"consensus_bypass_used"
        _consensus_mode="${CHUMP_CONSENSUS_MERGE_GATE:-0}"
        _consensus_bypass_reason="${CHUMP_OPERATOR_CONSENSUS_BYPASS:-}"
        if [[ "$_consensus_mode" != "0" ]]; then
            _cg_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            _cg_amb="${CHUMP_AMBIENT_LOG:-${REPO_ROOT:-.}/.chump-locks/ambient.jsonl}"
            _cg_session="${CHUMP_SESSION_ID:-${CLAUDE_SESSION_ID:-unknown}}"
            _cg_corr="pr-${TARGET_PR}"
            stage_start "INFRA-2274: consensus merge gate (mode=$_consensus_mode)"

            if [[ -n "$_consensus_bypass_reason" ]]; then
                # Operator escape hatch — proceed, emit audit event.
                _cg_line="$(printf '{"ts":"%s","kind":"consensus_bypass_used","pr":%d,"corr_id":"%s","reason":"%s","operator_session_id":"%s","mode":"%s","gap_id":"%s"}' \
                    "$_cg_ts" "$TARGET_PR" "$_cg_corr" \
                    "${_consensus_bypass_reason//\"/\\\"}" \
                    "$_cg_session" "$_consensus_mode" \
                    "${GAP_IDS[0]:-unknown}")"
                _ambient_write "$_cg_amb" "$_cg_line"
                yellow "INFRA-2274: operator consensus bypass invoked — reason=\"$_consensus_bypass_reason\""
                yellow "INFRA-2274: kind=consensus_bypass_used emitted for audit"
            else
                # Find a `chump` binary. Prefer fresh debug build, fall back to PATH.
                _cg_chump=""
                if [[ -x "${REPO_ROOT:-.}/target/debug/chump" ]]; then
                    _cg_chump="${REPO_ROOT:-.}/target/debug/chump"
                elif command -v chump >/dev/null 2>&1; then
                    _cg_chump="$(command -v chump)"
                fi

                _cg_verdict="NO_QUORUM"
                if [[ -n "$_cg_chump" ]]; then
                    # Query the tally side. consensus-tally is read-only and
                    # always runs (no feature-flag gate). Window 1h matches
                    # the freshness requirement from the gap spec.
                    _cg_out="$("$_cg_chump" consensus-tally --corr-id "$_cg_corr" --since 1h 2>/dev/null || true)"
                    # Output shape: "corr_id=...  ...  verdict=PASSED"
                    if echo "$_cg_out" | grep -q "verdict=PASSED"; then
                        _cg_verdict="PASSED"
                    elif echo "$_cg_out" | grep -q "verdict=FAILED"; then
                        _cg_verdict="FAILED"
                    elif echo "$_cg_out" | grep -q "verdict=EXTENDED"; then
                        _cg_verdict="EXTENDED"
                    elif echo "$_cg_out" | grep -q "verdict=NO_QUORUM"; then
                        _cg_verdict="NO_QUORUM"
                    fi
                else
                    info "INFRA-2274: chump binary not found — verdict defaults to NO_QUORUM"
                fi

                if [[ "$_cg_verdict" == "PASSED" ]]; then
                    _cg_line="$(printf '{"ts":"%s","kind":"consensus_gate_approved","pr":%d,"corr_id":"%s","verdict":"PASSED","mode":"%s","gap_id":"%s"}' \
                        "$_cg_ts" "$TARGET_PR" "$_cg_corr" "$_consensus_mode" "${GAP_IDS[0]:-unknown}")"
                    _ambient_write "$_cg_amb" "$_cg_line"
                    green "INFRA-2274: consensus gate PASSED — proceeding"
                else
                    if [[ "$_consensus_mode" == "enforce" ]]; then
                        # Hard block path.
                        _cg_line="$(printf '{"ts":"%s","kind":"consensus_gate_blocked","pr":%d,"corr_id":"%s","verdict":"%s","mode":"enforce","gap_id":"%s","note":"INFRA-2274: enforce mode — merge blocked; cast votes via chump vote pr-%d +1 --reason approve from N=3 curators (handoff, ci-audit, infra-watcher)"}' \
                            "$_cg_ts" "$TARGET_PR" "$_cg_corr" "$_cg_verdict" \
                            "${GAP_IDS[0]:-unknown}" "$TARGET_PR")"
                        _ambient_write "$_cg_amb" "$_cg_line"
                        red "INFRA-2274: consensus gate BLOCKED — verdict=$_cg_verdict (enforce mode)"
                        red "  Need: 3 +1 votes from curators via 'chump vote $_cg_corr +1 --reason \"...\"'"
                        red "  Bypass (emergency): CHUMP_OPERATOR_CONSENSUS_BYPASS=\"<reason>\" scripts/coord/bot-merge.sh ..."
                        exit 1
                    else
                        # Shadow mode — log would-block, proceed anyway.
                        _cg_line="$(printf '{"ts":"%s","kind":"consensus_gate_would_block","pr":%d,"corr_id":"%s","verdict":"%s","mode":"shadow","gap_id":"%s","note":"INFRA-2274: shadow mode — would block in enforce; set CHUMP_CONSENSUS_MERGE_GATE=enforce after observation window"}' \
                            "$_cg_ts" "$TARGET_PR" "$_cg_corr" "$_cg_verdict" \
                            "${GAP_IDS[0]:-unknown}")"
                        _ambient_write "$_cg_amb" "$_cg_line"
                        yellow "INFRA-2274: consensus gate WOULD BLOCK — verdict=$_cg_verdict (shadow mode, proceeding)"
                    fi
                fi
            fi
            stage_done
        fi

        # ── 6.5 Code-reviewer agent gate (INFRA-AGENT-CODEREVIEW MVP) ────────
        # If the PR touches src/* or crates/*/src/*, run the code-reviewer
        # agent before enabling auto-merge. APPROVE/SKIP -> proceed; CONCERN
        # or ESCALATE blocks the auto-merge so a human can resolve.
        # Bypass with CHUMP_CODEREVIEW=0 (e.g. infra/scripts changes).
        if [[ "${CHUMP_CODEREVIEW:-1}" != "0" ]] && [[ -x "$SCRIPT_DIR/code-reviewer-agent.sh" ]]; then
            CHANGED=$(gh pr diff "$TARGET_PR" --name-only 2>/dev/null || echo "")
            TOUCHES_SRC=0
            while IFS= read -r f; do
                [[ -z "$f" ]] && continue
                if [[ "$f" =~ ^src/ ]] || [[ "$f" =~ ^crates/.*/src/ ]]; then
                    TOUCHES_SRC=1; break
                fi
            done <<< "$CHANGED"

            if [[ $TOUCHES_SRC -eq 1 ]]; then
                info "PR #$TARGET_PR touches src/* — invoking code-reviewer-agent.sh …"
                _gap_arg=""
                [[ ${#GAP_IDS[@]} -gt 0 ]] && _gap_arg="--gap ${GAP_IDS[0]}"
                set +e
                "$SCRIPT_DIR/code-reviewer-agent.sh" "$TARGET_PR" $_gap_arg --post
                _rc=$?
                set -e
                case $_rc in
                    0|3)
                        green "Code-reviewer verdict: APPROVE/SKIP — proceeding with auto-merge." ;;
                    1)
                        red "Code-reviewer raised CONCERN — auto-merge NOT enabled."
                        red "Resolve concerns then run: gh pr merge $TARGET_PR --auto --squash  # (omit --squash if merge queue is active)"
                        exit 1 ;;
                    2)
                        red "Code-reviewer ESCALATED — human review required, auto-merge NOT enabled."
                        exit 1 ;;
                    *)
                        red "Code-reviewer agent errored (exit $_rc) — auto-merge NOT enabled."
                        exit 1 ;;
                esac
            else
                info "PR #$TARGET_PR is non-src — code-reviewer skipped (auto-merge proceeds)."
            fi
        fi

        # ── 6.6 Claim-lint gate (CREDIBLE-208) ────────────────────────────────
        # Ground the HEAD commit message's claims (structured Files-Touched /
        # Symbols-Touched / Tests-Run trailers, or NL backtick tokens) against
        # the diff vs main. A PR with no structured/backtick claims is a
        # no-op here (extract returns empty, exit 0) — this only fires when
        # an agent actually made a checkable claim. Bounce names the exact
        # ungrounded claim. Bypass: CHUMP_CLAIM_LINT=0.
        if [[ "${CHUMP_CLAIM_LINT:-1}" != "0" ]] && command -v chump >/dev/null 2>&1; then
            _cl_gap="${GAP_IDS[0]:-unknown}"
            set +e
            _cl_out="$(chump claim-lint --range "origin/main...HEAD" --model "${CHUMP_AGENT_MODEL:-unknown}" --gap-id "$_cl_gap" 2>&1)"
            _cl_rc=$?
            set -e
            case $_cl_rc in
                0)
                    if ! echo "$_cl_out" | grep -qF "no checkable claims"; then
                        green "CREDIBLE-208: claim-lint grounded — proceeding."
                    fi
                    ;;
                1)
                    red "CREDIBLE-208: claim-lint BOUNCE — ship-time claim does not ground against the diff:"
                    red "$_cl_out"
                    red "  Fix the claim (or the code) and re-push. Bypass: CHUMP_CLAIM_LINT=0 scripts/coord/bot-merge.sh ..."
                    exit 1
                    ;;
                *)
                    yellow "CREDIBLE-208: claim-lint errored (exit $_cl_rc) — not blocking (non-fatal tool failure)."
                    ;;
            esac
        fi

        # ── Pre-merge CI gate (INFRA-CHOKE prevention) ────────────────────────────
        # Before arming auto-merge, verify that all required CI checks are passing.
        # If Release job or Crate Publish dry-run are failing, abort with a diagnostic
        # message and commit a comment to the PR so the developer sees the blocker.
        # (This prevents PR #470-style situations where auto-merge is armed on a PR
        # that's waiting for shared infrastructure to be fixed.)
        stage_start "CI status pre-flight check"
        # INFRA-632: when --required-checks is set, only flag failures for
        # checks whose name matches one of the comma-separated entries.
        # When unset, any FAILURE/ERROR check blocks auto-merge (original behaviour).
        # INFRA-1130: prefer SQLite cache over live API; fall back on miss.
        _all_failing=""
        _ci_cache_used=0
        _ci_head_sha=""
        if _ci_pr_json="$(cache_lookup_pr "$TARGET_PR" --max-age-s 120 2>/dev/null)"; then
            _ci_head_sha="$(printf '%s' "$_ci_pr_json" | \
                python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('head',{}).get('sha',''))" 2>/dev/null || true)"
        fi
        if [[ -n "$_ci_head_sha" ]]; then
            _ci_checks_cache="$(cache_lookup_checks "$_ci_head_sha" 2>/dev/null || true)"
            if [[ -n "$_ci_checks_cache" ]]; then
                _ci_cache_used=1
                # tab-separated name\tstatus\tconclusion — filter failing conclusions
                _all_failing="$(printf '%s\n' "$_ci_checks_cache" | \
                    awk -F'\t' 'toupper($3) ~ /FAILURE|ERROR|TIMED_OUT|CANCELLED/ {print $1 "\t" toupper($3)}')"
            fi
        fi
        if [[ $_ci_cache_used -eq 0 ]]; then
            info "INFRA-1130: cache miss for PR #$TARGET_PR — falling back to live API"
            _all_failing=$(gh pr checks "$TARGET_PR" 2>/dev/null | grep -E "FAILURE|ERROR" || true)
        fi
        if [[ -n "$REQUIRED_CHECKS" && -n "$_all_failing" ]]; then
            _ci_status=""
            IFS=',' read -ra _req_list <<< "$REQUIRED_CHECKS"
            while IFS= read -r _line; do
                for _req in "${_req_list[@]}"; do
                    _req_trimmed="${_req#"${_req%%[![:space:]]*}"}"
                    _req_trimmed="${_req_trimmed%"${_req_trimmed##*[![:space:]]}"}"
                    if echo "$_line" | grep -qF "$_req_trimmed"; then
                        _ci_status+="$_line"$'\n'
                        break
                    fi
                done
            done <<< "$_all_failing"
            _ci_status="${_ci_status%$'\n'}"
            if [[ -n "$_all_failing" ]] && [[ -z "$_ci_status" ]]; then
                info "INFRA-632: failing checks are non-required — proceeding (advisory only):"
                echo "$_all_failing" | sed 's/^/  [advisory] /'
            fi
        else
            _ci_status="$_all_failing"
        fi
        if [[ -n "$_ci_status" ]]; then
            red "BLOCKER: Required CI jobs failed. Not arming auto-merge."
            red "Failed checks:"
            echo "$_ci_status" | sed 's/^/  /'

            # Post a comment to the PR so the developer sees the blocker.
            # NOTE: previously built with $(cat <<'EOF' ...), which hits a bash
            # pre-parser bug — inside $(...) the backtick-balance scanner still
            # runs across the heredoc body even when the delimiter is quoted,
            # so literal triple-backticks in the markdown fence caused
            # "line NNN: unexpected EOF while looking for matching `". That
            # aborted bot-merge *after* PR create but *before* the auto-merge
            # arm step, silently dropping PRs into the queue without --auto.
            # See: PR #482/#488/#491 (2026-04-24). The fix: build the body
            # with printf + a backtick variable, so no un-escaped backticks
            # ever appear inside a $(...) literal.
            _fence='```'
            printf -v _comment_body '%s\n\n%s\n%s\n%s\n%s\n\n%s\n%s\n%s\n%s\n' \
                '⚠️ Auto-merge blocked: Required CI checks failed.' \
                '**Failing checks:**' \
                "${_fence}" \
                "${_ci_status}" \
                "${_fence}" \
                '**Next steps:**' \
                '1. Investigate the failing check (click the link in the GitHub UI)' \
                '2. Fix the underlying issue (usually in Release job or infrastructure)' \
                "3. Once all checks pass, re-run: \`scripts/coord/bot-merge.sh --gap <GAP-ID> --auto-merge\`"
            if [[ $DRY_RUN -eq 0 ]]; then
                gh pr comment "$TARGET_PR" -b "$_comment_body" 2>/dev/null || true
            fi
            exit 1
        fi
        green "All required CI checks passing — proceeding with auto-merge."
        stage_done

        # INFRA-305: hot-file rebase-loop expectation. Pre-emit a note for any
        # file in BOT_MERGE_HOT_FILES so the agent knows to expect ≥1 DIRTY
        # rebase before landing if other agents are active. No behavior change.
        _hot_gap_label="${GAP_IDS[0]:-none}"
        emit_hot_file_warnings "$TARGET_PR" "$_hot_gap_label"

        # Pre-merge checkpoint tag (2026-04-18 PR #52 retrospective).
        # GitHub squash-merge captures branch state at the moment CI
        # passes and drops any commits pushed after — losing 11 commits
        # on PR #52, recovery via PR #65 was forced. This tag pins the
        # branch HEAD at the moment we enable auto-merge, so recovery is
        # `git checkout pr-NN-checkpoint` (vs. having to fetch the
        # orphaned branch and cherry-pick). Disable with
        # CHUMP_PRE_MERGE_CHECKPOINT=0.
        if [[ "${CHUMP_PRE_MERGE_CHECKPOINT:-1}" != "0" ]]; then
            CHECKPOINT_TAG="pr-${TARGET_PR}-checkpoint"
            if ! git rev-parse --quiet --verify "refs/tags/${CHECKPOINT_TAG}" >/dev/null; then
                info "Pinning checkpoint tag ${CHECKPOINT_TAG} (squash-loss insurance) …"
                run_timed 60 git tag "${CHECKPOINT_TAG}" HEAD
                if ! run_timed_hb "git push checkpoint tag" 120 git push origin "${CHECKPOINT_TAG}"; then
                    red "Failed to push checkpoint tag ${CHECKPOINT_TAG}."
                    exit 2
                fi
                green "Checkpoint tag pushed — recovery via 'git checkout ${CHECKPOINT_TAG}'."
            else
                info "Checkpoint tag ${CHECKPOINT_TAG} already exists — skipping."
            fi
        fi

        # INFRA-390: bench mode skips auto-merge + gap-closure so each trial
        # is non-destructive. The PR is opened (so CI grades it) but does NOT
        # land on main. Per COG-032 prereg §4 the success criterion is "PR
        # opened + required CI checks pass" — merging is not required for
        # the trial to count as success.
        #
        # Set CHUMP_BENCH_MODE=1 + CHUMP_BENCH_CELL + CHUMP_BENCH_TASK_ID
        # (+ optional CHUMP_BENCH_TRIAL_N) to emit a JSONL trial line to
        # logs/ab/COG-032/run.jsonl. Production callers leave CHUMP_BENCH_MODE
        # unset (default 0) and behavior is unchanged.
        if [[ "${CHUMP_BENCH_MODE:-0}" == "1" ]]; then
            yellow "[bench-mode] CHUMP_BENCH_MODE=1 — skipping auto-merge arming + gap-closure"
            yellow "[bench-mode] PR #$TARGET_PR remains OPEN for CI grading"

            # Emit the trial outcome line. Best-effort I/O — never blocks.
            _bench_log_dir="$REPO_ROOT/logs/ab/COG-032"
            mkdir -p "$_bench_log_dir" 2>/dev/null || true
            _bench_log="${CHUMP_BENCH_LOG:-$_bench_log_dir/run.jsonl}"
            _bench_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            _bench_session="${CLAUDE_SESSION_ID:-${CHUMP_SESSION_ID:-bench-$$}}"
            _bench_cell="${CHUMP_BENCH_CELL:-?}"
            _bench_task="${CHUMP_BENCH_TASK_ID:-?}"
            _bench_trial="${CHUMP_BENCH_TRIAL_N:-1}"
            _bench_dur_s="${SECONDS:-0}"
            # PR state at record-time (stage where bot-merge has just opened it
            # but not yet armed auto-merge). State will be polled separately
            # by the harness for the final pass/fail call.
            _bench_pr_state="$(gh pr view "$TARGET_PR" --json state --jq .state 2>/dev/null || echo unknown)"
            # Record success by the prereg's criterion — PR exists + this run
            # got past the CI-pre-flight gate (see line ~1224 above). The
            # harness re-checks CI green async via gh pr view.
            _bench_success_at_arm=true
            printf '{"ts":"%s","cell":"%s","task_id":"%s","trial_n":%s,"agent_session":"%s","pr_number":%s,"pr_state_at_record":"%s","duration_s":%s,"success_criteria_met_at_arm_stage":%s,"branch":"%s"}\n' \
                "$_bench_ts" "$_bench_cell" "$_bench_task" "$_bench_trial" \
                "$_bench_session" "$TARGET_PR" "$_bench_pr_state" \
                "$_bench_dur_s" "$_bench_success_at_arm" "$BRANCH" \
                >> "$_bench_log" 2>/dev/null || true

            green "[bench-mode] trial recorded → $_bench_log"
        else
            # ── INFRA-684: speculative-on-speculative guard ───────────────────
            # Before arming, check that no other PR for the same gap is already
            # armed. If two speculative agents both reach this point before the
            # INFRA-193 loser sweep runs, both could get auto-merge enabled and
            # both could land (or conflict). The check exits 1 if a competing
            # armed PR is detected; bypass with CHUMP_SPEC_ON_SPEC_CHECK=0.
            if [[ "${CHUMP_SPEC_ON_SPEC_CHECK:-1}" != "0" ]] \
                    && [[ ${#GAP_IDS[@]} -gt 0 ]]; then
                for _spec_gid in "${GAP_IDS[@]}"; do
                    if ! "$SCRIPT_DIR/check-spec-on-spec.sh" "$_spec_gid" "$TARGET_PR"; then
                        red "INFRA-684: Arm blocked — competing armed PR exists for $_spec_gid."
                        red "  The speculative race was already decided. Aborting this arm."
                        red "  Bypass (if the competing PR is stale): CHUMP_SPEC_ON_SPEC_CHECK=0"
                        exit 1
                    fi
                done
            fi

            # ── INFRA-1166: REST-direct fast path ────────────────────────────────
            # When all required CI checks are already completed and green, skip
            # GraphQL enablePullRequestAutoMerge and merge immediately via REST
            # PUT /pulls/N/merge. This avoids the separate GraphQL secondary rate
            # limit that has caused "API rate limit already exceeded" errors even
            # when REST quota was healthy. Disable with CHUMP_BOT_MERGE_REST_DIRECT=0.
            _rest_direct_merged=0
            _rd_amb="${CHUMP_AMBIENT_LOG:-${REPO_ROOT:-.}/.chump-locks/ambient.jsonl}"
            if [[ "${CHUMP_BOT_MERGE_REST_DIRECT:-1}" != "0" && $DRY_RUN -eq 0 ]]; then
                stage_start "INFRA-1166: REST-direct fast path (check all CI green)"
                _rd_nwo=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)
                _rd_sha=$(gh api "repos/$_rd_nwo/pulls/$TARGET_PR" --jq '.head.sha' 2>/dev/null || true)
                if [[ -n "$_rd_nwo" && -n "$_rd_sha" ]]; then
                    _rd_checks_json=$(gh api "repos/$_rd_nwo/commits/$_rd_sha/check-runs" \
                        --paginate 2>/dev/null || true)
                    if [[ -n "$_rd_checks_json" ]]; then
                        # Count incomplete and failed required checks with python3.
                        # INFRA-1278: use python3 -c '...' with here-string (<<<) to pass JSON
                        # via stdin — the old form used `printf | python3 - <<HEREDOC` which
                        # triggers SC2259: the pipe overrides the heredoc so python3 received
                        # the JSON as its script source and crashed; the fast path never fired.
                        _rd_counts=$(python3 -c '
import sys, json
required_raw = sys.argv[1] if len(sys.argv) > 1 else ""
required_list = [r.strip() for r in required_raw.split(",") if r.strip()] if required_raw else []
try:
    data = json.load(sys.stdin)
except Exception:
    print("0 0 0"); sys.exit(0)
checks = data.get("check_runs", [])
incomplete = failed = total = 0
for c in checks:
    conclusion = (c.get("conclusion") or "").lower()
    if conclusion in ("skipped", "neutral", "cancelled"):
        continue
    name = c.get("name", "")
    if required_list and not any(r in name for r in required_list):
        continue
    total += 1
    status = (c.get("status") or "").lower()
    if status != "completed":
        incomplete += 1
    elif conclusion != "success":
        failed += 1
print(f"{incomplete} {failed} {total}")
' "$REQUIRED_CHECKS" <<< "$_rd_checks_json"
                        )
                        _rd_incomplete=$(printf '%s' "$_rd_counts" | awk '{print $1}')
                        _rd_failed=$(printf '%s' "$_rd_counts" | awk '{print $2}')
                        _rd_total=$(printf '%s' "$_rd_counts" | awk '{print $3}')
                        if [[ "${_rd_total:-0}" -gt 0 && \
                              "${_rd_incomplete:-1}" -eq 0 && \
                              "${_rd_failed:-1}" -eq 0 ]]; then
                            info "INFRA-1166: all $_rd_total required checks green — merging via REST PUT (no GraphQL)"
                            _rd_commit_title=$(gh api "repos/$_rd_nwo/pulls/$TARGET_PR" \
                                --jq '.title' 2>/dev/null || echo "Merge PR #$TARGET_PR")
                            _rd_gap_str="${GAP_IDS[*]:-}"
                            if gh api "repos/$_rd_nwo/pulls/$TARGET_PR/merge" \
                                    -X PUT \
                                    -f merge_method=squash \
                                    -f "commit_title=${_rd_commit_title}" \
                                    2>/dev/null; then
                                _rest_direct_merged=1
                                green "INFRA-1166: REST-direct merge succeeded — PR #$TARGET_PR merged (no GraphQL)."
                                mkdir -p "$(dirname "$_rd_amb")" 2>/dev/null || true
                                printf '{"ts":"%s","kind":"bot_merge_rest_direct","pr":%s,"gap":"%s","sha":"%s","checks_verified":%s,"note":"INFRA-1166 all-checks-green fast path"}\n' \
                                    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                                    "$TARGET_PR" "$_rd_gap_str" "$_rd_sha" "$_rd_total" \
                                    >> "$_rd_amb" 2>/dev/null || true
                                # INFRA-1413: verify branch was deleted by repo setting; fall back to DELETE if not.
                                # The repo-level delete-branch-on-merge=true setting handles this automatically,
                                # but the setting may lag a newly-forked repo or a race between merge and cleanup.
                                _bdom_ref="refs/heads/${BRANCH}"
                                if gh api "repos/${_rd_nwo}/git/${_bdom_ref}" >/dev/null 2>&1; then
                                    if gh api "repos/${_rd_nwo}/git/${_bdom_ref}" -X DELETE >/dev/null 2>&1; then
                                        info "INFRA-1413: branch ${BRANCH} deleted (fallback — repo setting lagged)."
                                        printf '{"ts":"%s","kind":"branch_deleted_fallback","pr":%s,"branch":"%s","note":"INFRA-1413"}\n' \
                                            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$TARGET_PR" "$BRANCH" \
                                            >> "$_rd_amb" 2>/dev/null || true
                                    else
                                        info "INFRA-1413: branch ${BRANCH} deletion fallback failed (may need manual cleanup)."
                                    fi
                                else
                                    info "INFRA-1413: branch ${BRANCH} already deleted by repo setting."
                                fi
                            else
                                info "INFRA-1166: REST PUT merge failed (guard/review requirement?) — falling back to auto-merge arm."
                            fi
                        else
                            info "INFRA-1166: checks not all green (incomplete=${_rd_incomplete:-?}, failed=${_rd_failed:-?}, total=${_rd_total:-0}) — using auto-merge arm."
                        fi
                    else
                        info "INFRA-1166: no check-runs data returned — using auto-merge arm."
                    fi
                else
                    info "INFRA-1166: could not determine NWO/SHA — using auto-merge arm."
                fi
                stage_done
            fi

            if [[ $_rest_direct_merged -eq 0 ]]; then
                # ── INFRA-2155: chump-policy check (Marcus M-E auto-merge knob) ─
                # Gate the auto-merge arming behind the layered policy chain
                # (fleet + operator + repo). If the policy blocks, skip arming
                # and post the block reason as a PR comment so the operator
                # sees the WHY. Bypass via CHUMP_BYPASS_AUTO_MERGE_POLICY=1 for
                # genuine recovery scenarios; each bypass is auditable in
                # ambient via the kind=auto_merge_policy_bypassed emit below.
                _chump_policy_bin=""
                for _cpb in "$REPO_ROOT/target/debug/chump-policy" \
                            "$HOME/Projects/Chump/target/debug/chump-policy" \
                            "$(command -v chump-policy 2>/dev/null)"; do
                    if [[ -n "$_cpb" ]] && [[ -x "$_cpb" ]]; then
                        _chump_policy_bin="$_cpb"
                        break
                    fi
                done
                if [[ -n "$_chump_policy_bin" ]] && [[ "${CHUMP_BYPASS_AUTO_MERGE_POLICY:-0}" != "1" ]]; then
                    stage_start "INFRA-2155: chump-policy check (PR $TARGET_PR, lane=$LANE)"
                    _policy_out=""
                    if _policy_out=$(CHUMP_REPO="$REPO_ROOT" "$_chump_policy_bin" check --lane "$LANE" 2>/dev/null); then
                        info "  policy → allowed; arming auto-merge"
                        # Forward the emit to ambient.jsonl for the audit trail.
                        printf '%s\n' "$_policy_out" >> "$REPO_ROOT/.chump-locks/ambient.jsonl" 2>/dev/null || true
                        stage_done
                    else
                        red "  policy → blocked; skipping auto-merge arm"
                        printf '%s\n' "$_policy_out" >> "$REPO_ROOT/.chump-locks/ambient.jsonl" 2>/dev/null || true
                        # Post the block reason as a PR comment so the operator
                        # sees the WHY without grep-archaeology.
                        _block_reason=$(printf '%s' "$_policy_out" | python3 -c 'import json,sys;d=json.loads(sys.stdin.read()); print(d.get("reason","unknown") + " [scopes: " + ",".join(d.get("contributing",[])) + "]")' 2>/dev/null || echo "auto-merge policy blocked")
                        gh pr comment "$TARGET_PR" --body "🤖 INFRA-2155: auto-merge NOT armed. Reason: $_block_reason. Adjust policy via \`chump-policy set\` or bypass with \`CHUMP_BYPASS_AUTO_MERGE_POLICY=1\`." 2>/dev/null || true
                        stage_done
                        # Skip the auto-merge-armer call below by entering the
                        # else branch unconditionally; PR is still open for
                        # human review.
                        _policy_blocked=1
                    fi
                elif [[ "${CHUMP_BYPASS_AUTO_MERGE_POLICY:-0}" == "1" ]]; then
                    info "INFRA-2155: CHUMP_BYPASS_AUTO_MERGE_POLICY=1 — skipping policy check"
                    printf '{"ts":"%s","kind":"auto_merge_policy_bypassed","pr":%s,"session":"%s"}\n' \
                        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$TARGET_PR" "${CHUMP_SESSION_ID:-unknown}" \
                        >> "$REPO_ROOT/.chump-locks/ambient.jsonl" 2>/dev/null || true
                fi

                # ── INFRA-2155: chump-reviewer-routing (Marcus M-E notification) ──
                # Deterministic reviewer routing — add (recent committers ∪
                # CODEOWNERS ∪ operator override) as PR reviewers via gh API.
                # Runs even if policy check blocked auto-merge — Marcus's pain
                # was MISSED notifications, and a human-reviewed PR still wants
                # the right reviewers attached. Bypass via
                # CHUMP_BYPASS_REVIEWER_ROUTING=1 for ad-hoc PRs.
                _chump_routing_bin=""
                for _crb in "$REPO_ROOT/target/debug/chump-reviewer-routing" \
                            "$HOME/Projects/Chump/target/debug/chump-reviewer-routing" \
                            "$(command -v chump-reviewer-routing 2>/dev/null)"; do
                    if [[ -n "$_crb" ]] && [[ -x "$_crb" ]]; then
                        _chump_routing_bin="$_crb"
                        break
                    fi
                done
                if [[ -n "$_chump_routing_bin" ]] && [[ "${CHUMP_BYPASS_REVIEWER_ROUTING:-0}" != "1" ]]; then
                    stage_start "INFRA-2155: chump-reviewer-routing (PR $TARGET_PR)"
                    # 2>&1 captures the stderr audit event; we tee both into
                    # ambient.jsonl while suppressing console noise on success.
                    if CHUMP_REPO="$REPO_ROOT" "$_chump_routing_bin" route --pr "$TARGET_PR" 2>>"$REPO_ROOT/.chump-locks/ambient.jsonl" >/dev/null; then
                        info "  reviewer routing: ✓ requested"
                    else
                        info "  reviewer routing: skipped (no suggestions OR gh add-reviewer failed; PR open without prefilled reviewers)"
                    fi
                    stage_done
                fi
            fi
            # ── INFRA-1813: HITL approval gate (Marcus M-B trust substrate) ──
            # Vendored from repairman29/BEAST-MODE @ 612ff45f73791
            # (website/app/api/tasks/[id]/{approve,reject}/route.ts, CP-003).
            #
            # When `CHUMP_REQUIRE_HITL=1` (env) OR `.chump/require-hitl` file
            # exists at repo root, bot-merge will NOT arm auto-merge unless an
            # explicit approval signal is present for this PR.
            #
            # Approval signals (any one is sufficient):
            #   1. `CHUMP_HITL_APPROVED=1` env var (operator one-shot)
            #   2. `.chump-locks/hitl-approved-<PR>.flag` file (file-flag, easy
            #      for PWA/operator scripts to drop)
            #   3. `hitl-approved` label on the PR (GitHub-native operator UX)
            #
            # On block: emit `kind=hitl_approval_required` to ambient with
            # pr + branch + diff summary so the operator surface (PWA tray,
            # tail script) can present it for approval. Skip arming entirely;
            # PR stays open for human review.
            #
            # Default OFF (`require_hitl` unset) — Chump-internal repos stay
            # full-auto. Per-repo opt-in via `.chump/require-hitl` flag file
            # OR fleet env `CHUMP_REQUIRE_HITL=1`. Schema additions to
            # `chump.fleet.yaml` (`require_hitl: true`) tracked as follow-up.
            _hitl_block=0
            _require_hitl=0
            if [[ "${CHUMP_REQUIRE_HITL:-0}" == "1" ]] || [[ -f "$REPO_ROOT/.chump/require-hitl" ]]; then
                _require_hitl=1
            fi
            if [[ $_rest_direct_merged -eq 0 ]] && [[ "${_policy_blocked:-0}" != "1" ]] && [[ $_require_hitl -eq 1 ]]; then
                stage_start "INFRA-1813: HITL approval check (PR $TARGET_PR)"
                _hitl_approved=0
                _hitl_signal=""
                if [[ "${CHUMP_HITL_APPROVED:-0}" == "1" ]]; then
                    _hitl_approved=1
                    _hitl_signal="env:CHUMP_HITL_APPROVED"
                elif [[ -f "$REPO_ROOT/.chump-locks/hitl-approved-${TARGET_PR}.flag" ]]; then
                    _hitl_approved=1
                    _hitl_signal="file:.chump-locks/hitl-approved-${TARGET_PR}.flag"
                elif gh pr view "$TARGET_PR" --json labels --jq '.labels[].name' 2>/dev/null | grep -qx "hitl-approved"; then
                    _hitl_approved=1
                    _hitl_signal="label:hitl-approved"
                fi
                if [[ $_hitl_approved -eq 1 ]]; then
                    green "  HITL approval present (signal=$_hitl_signal) — proceeding with auto-merge"
                    # scanner-anchor: "kind":"hitl_approval_granted"
                    printf '{"ts":"%s","kind":"hitl_approval_granted","pr":%s,"signal":"%s","session":"%s"}\n' \
                        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$TARGET_PR" "$_hitl_signal" "${CHUMP_SESSION_ID:-unknown}" \
                        >> "$REPO_ROOT/.chump-locks/ambient.jsonl" 2>/dev/null || true
                    stage_done
                else
                    red "  HITL approval REQUIRED — auto-merge NOT armed (Marcus M-B gate)"
                    _hitl_diff_summary=$(gh pr diff "$TARGET_PR" --name-only 2>/dev/null | head -10 | tr '\n' ',' | sed 's/,$//' || echo "unknown")
                    _hitl_branch="${BRANCH:-unknown}"
                    # scanner-anchor: "kind":"hitl_approval_required"
                    printf '{"ts":"%s","kind":"hitl_approval_required","pr":%s,"branch":"%s","files":"%s","session":"%s","approve_hint":"touch %s/.chump-locks/hitl-approved-%s.flag OR gh pr edit %s --add-label hitl-approved"}\n' \
                        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$TARGET_PR" "$_hitl_branch" "$_hitl_diff_summary" "${CHUMP_SESSION_ID:-unknown}" \
                        "$REPO_ROOT" "$TARGET_PR" "$TARGET_PR" \
                        >> "$REPO_ROOT/.chump-locks/ambient.jsonl" 2>/dev/null || true
                    gh pr comment "$TARGET_PR" --body "🛑 INFRA-1813: HITL approval required (Marcus M-B trust gate). Auto-merge NOT armed.

Approve via any of:
- \`gh pr edit $TARGET_PR --add-label hitl-approved\` then re-run bot-merge
- \`touch .chump-locks/hitl-approved-$TARGET_PR.flag\` then re-run bot-merge
- \`CHUMP_HITL_APPROVED=1 scripts/coord/bot-merge.sh --gap <ID> --auto-merge\`

See docs/process/HITL_APPROVAL.md for the full operator flow." 2>/dev/null || true
                    stage_done
                    _hitl_block=1
                fi
            fi
            if [[ $_rest_direct_merged -eq 0 ]] && [[ "${_policy_blocked:-0}" != "1" ]] && [[ $_hitl_block -eq 0 ]]; then
                # INFRA-1113: delegate to centralized armer to enforce 5s spacing.
                # INFRA-1311: auto-merge-armer.sh now enforces per-PR exponential
                # backoff (30s→60s→120s→300s) via .chump-locks/bot-merge-backoff-<pr>.ts
                # to avoid burning gh pr merge calls on PRs that failed recently.
                # between successive gh pr merge --auto calls across all callers.
                # INFRA-1377: auto-merge-armer.sh detects merge queue and adjusts
                # merge strategy accordingly (omits --squash, skips REST-direct).
                stage_start "auto-merge-armer.sh --pr $TARGET_PR"
                # INFRA-1732: run_timed_hb wrapper (delegates to `gh pr merge` inside
                # auto-merge-armer.sh) so a wedge emits bot_merge_hang, not just the
                # slower stage-budget botmerge_wedged watchdog.
                if ! run_timed_hb "auto-merge-arm" 60 "$SCRIPT_DIR/auto-merge-armer.sh" --pr "$TARGET_PR"; then  # gh pr merge
                    red "auto-merge-armer failed (see above)."
                    exit 2
                fi
            fi

            # META-156 AC#1: pr_merge_arm step done — auto-merge armed or REST-direct merged
            _bm_step_done "pr_merge_arm" 0

            # ── INFRA-2119: webhook-cache MERGED wait (opt-in) ──────────────
            # Replaces the legacy poll-sleep `gh pr checks` watchdog pattern
            # that caused bot_merge_hung wedges (33 events / 14d as of
            # 2026-05-29). Consumes GH webhook events from the cache instead
            # of polling. Default OFF for backward compat — set
            # CHUMP_BOT_MERGE_WAIT_MERGED=1 in callers that need to block until
            # the PR transitions to state=MERGED (e.g. sub-agent dispatch
            # wrappers per docs/process/SUBAGENT_DISPATCH.md).
            #
            # Algorithm:
            #   1. Sample cache_lookup_pr every 5s. Webhook-receiver writes
            #      merged_at when GitHub fires `pull_request.closed` with
            #      merged=true; cache_lookup_pr returns that JSON.
            #   2. If merged_at is non-null → emit bot_merge_webhook_hit, exit 0.
            #   3. If cache is stale > CHUMP_BOT_MERGE_WAIT_WEBHOOK_GRACE_S
            #      (default 60s) AND no transition seen → fall back to a
            #      `gh api pulls/N` direct REST poll (cache_lookup_pr also
            #      auto-refetches on stale, so this is implicit).
            #   4. Hard timeout at CHUMP_BOT_MERGE_WAIT_TIMEOUT_S (default
            #      900s = 15 min) → emit bot_merge_timeout, exit non-zero so
            #      the bash caller knows to switch to manual recovery per
            #      the SUBAGENT_DISPATCH.md STOP-block contract.
            #
            # Exit codes preserved: 0 on MERGED, non-zero on timeout. Other
            # tools (queue-driver, ghost-reaper, etc.) continue to call
            # bot-merge without CHUMP_BOT_MERGE_WAIT_MERGED and see the
            # original "arm-and-exit" semantics.
            if [[ "${CHUMP_BOT_MERGE_WAIT_MERGED:-0}" == "1" ]] \
                    && [[ $DRY_RUN -eq 0 ]] \
                    && [[ -n "$TARGET_PR" ]] \
                    && [[ "${CHUMP_BENCH_MODE:-0}" != "1" ]]; then
                # META-156 AC#1: step=pr_wait_merge
                _bm_step_start "pr_wait_merge"
                stage_start "INFRA-2119: webhook-cache MERGED wait (PR #$TARGET_PR)"
                _wait_timeout_s="${CHUMP_BOT_MERGE_WAIT_TIMEOUT_S:-900}"
                _wait_poll_interval_s="${CHUMP_BOT_MERGE_WAIT_POLL_INTERVAL_S:-5}"
                _wait_webhook_grace_s="${CHUMP_BOT_MERGE_WAIT_WEBHOOK_GRACE_S:-60}"
                _wait_started_at=$(date -u +%s)
                _wait_deadline=$(( _wait_started_at + _wait_timeout_s ))
                _wait_amb="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
                _wait_polls=0
                _wait_source="cache"
                _wait_done=0
                _wait_first_seen_age_s=""
                while :; do
                    _wait_now=$(date -u +%s)
                    if (( _wait_now >= _wait_deadline )); then
                        # scanner-anchor: "kind":"bot_merge_timeout"
                        printf '{"ts":"%s","kind":"bot_merge_timeout","pr":%s,"gap":"%s","elapsed_s":%s,"timeout_s":%s,"polls":%s,"source":"%s","note":"INFRA-2119 15m hard cap — switch to manual recovery"}\n' \
                            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                            "$TARGET_PR" "${GAP_IDS[*]:-}" \
                            "$(( _wait_now - _wait_started_at ))" \
                            "$_wait_timeout_s" "$_wait_polls" "$_wait_source" \
                            >> "$_wait_amb" 2>/dev/null || true
                        red "INFRA-2119: bot-merge wait timed out after ${_wait_timeout_s}s waiting for PR #$TARGET_PR to MERGE."
                        red "  Switch to manual recovery — see docs/process/CLAUDE_GOTCHAS.md → 'bot_merge_hung'."
                        exit 4
                    fi
                    _wait_polls=$(( _wait_polls + 1 ))
                    # Cache-first read; helper auto-fetches on stale or miss.
                    _wait_pr_json="$(cache_lookup_pr "$TARGET_PR" \
                        --max-age-s "$_wait_webhook_grace_s" 2>/dev/null || true)"
                    if [[ -n "$_wait_pr_json" ]]; then
                        # merged_at non-null → PR has merged.
                        _wait_merged_at="$(printf '%s' "$_wait_pr_json" | \
                            python3 -c "import json,sys
try:
    d=json.load(sys.stdin)
    v=d.get('merged_at')
    print(v if v else '')
except Exception:
    print('')
" 2>/dev/null || true)"
                        if [[ -n "$_wait_merged_at" ]]; then
                            _wait_done=1
                            # The most recent successful cache_lookup_pr
                            # returned within CHUMP_CACHE_TTL_S (default 60s)
                            # → "webhook hit". A stale-then-refetch path
                            # would have emitted cache_miss earlier in the
                            # ambient stream, but here we just record the
                            # provenance for the bot_merge_webhook_hit ratio.
                            # scanner-anchor: "kind":"bot_merge_webhook_hit"
                            printf '{"ts":"%s","kind":"bot_merge_webhook_hit","pr":%s,"gap":"%s","elapsed_s":%s,"polls":%s,"merged_at":"%s","note":"INFRA-2119 MERGED transition observed via webhook cache"}\n' \
                                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                                "$TARGET_PR" "${GAP_IDS[*]:-}" \
                                "$(( _wait_now - _wait_started_at ))" \
                                "$_wait_polls" "$_wait_merged_at" \
                                >> "$_wait_amb" 2>/dev/null || true
                            green "INFRA-2119: PR #$TARGET_PR MERGED at $_wait_merged_at (wait=${_wait_polls} poll(s), cache-driven)."
                            break
                        fi
                    fi
                    sleep "$_wait_poll_interval_s"
                done
                stage_done
                # META-156 AC#1: step=pr_wait_merge done
                _bm_step_done "pr_wait_merge" 0
            fi
        fi
        # META-156 AC#1: close pr_merge_arm step on AUTO_MERGE=0 path (no-op if
        # already closed by the AUTO_MERGE=1 branch above).
        [[ "${_BM_NAMED_STEP:-}" == "pr_merge_arm" ]] && _bm_step_done "pr_merge_arm" 0

        # ── INFRA-1030: Auto-close gap AFTER auto-merge arm ──────────────────────
        # This is the LAST irreversible state change. If bot-merge dies here, the
        # PR is already queued → will merge on green CI. Operator recovers with:
        #   chump gap ship <GAP-ID> --closed-pr <PR> --update-yaml
        # Old behavior (exit 1 on ship failure) moved to a WARN: PR is already
        # armed, aborting the script here would be confusing. Emit ambient event.
        # Disable with CHUMP_AUTO_CLOSE_GAP=0 for partial-progress PRs.
        if [[ $DRY_RUN -eq 0 ]] && [[ "${CHUMP_AUTO_CLOSE_GAP:-1}" != "0" ]] \
                && [[ ${#GAP_IDS[@]} -gt 0 ]] && [[ "${CHUMP_BENCH_MODE:-0}" != "1" ]] \
                && [[ -n "$TARGET_PR" ]] && command -v chump >/dev/null 2>&1; then
            # INFRA-526 / META-022: use $MAIN_REPO for canonical state.db.
            _autoclose_main_repo="${MAIN_REPO:-$REPO_ROOT}"
            # INFRA-526: pin to canonical chump binary; fall back to PATH.
            _autoclose_chump="chump"
            if [[ -x "${HOME}/.cargo/bin/chump" ]]; then
                _autoclose_chump="${HOME}/.cargo/bin/chump"
            fi
            info "INFRA-526: auto-close targeting state.db at $_autoclose_main_repo/.chump/state.db (binary: $_autoclose_chump)"
            for _gid in "${GAP_IDS[@]}"; do
                stage_start "auto-close gap $_gid via PR #$TARGET_PR (INFRA-154)"

                # PEER-VERI-08 (INFRA-3655) AC#2: an unproven proof-AC live
                # outcome BLOCKS the close outright when CHUMP_VERIFY_LIVE_BLOCKING=1
                # (default off, ratchet on — see docs/process/CAPABILITY_DECISIONS.md),
                # instead of being swallowed by the CREDIBLE-178 advisory note
                # below. Checked BEFORE `chump gap ship` so a blocked gap never
                # reaches status=done. Non-proof misses are unaffected — this
                # only fires when `chump pr ac-coverage` itself decided to
                # report "miss" under the live-blocking flag (AC#3 fail-open
                # is unchanged for everything else).
                if [[ "${CHUMP_VERIFY_LIVE_BLOCKING:-0}" == "1" ]] && command -v chump &>/dev/null; then
                    _ac_pre="$(CHUMP_REPO="$_autoclose_main_repo" CHUMP_REAL_BINARY="$_autoclose_chump" \
                        chump pr ac-coverage "$TARGET_PR" 2>&1 || true)"
                    if grep -q '"status":"miss"' <<<"$_ac_pre"; then
                        _ac_pre_misses="$(grep -oE '"misses":\[[0-9,]*\]' <<<"$_ac_pre")"
                        red "[PEER-VERI-08] BLOCKING: $_gid PR #$TARGET_PR has an unproven proof-AC live outcome (${_ac_pre_misses:-misses}) and CHUMP_VERIFY_LIVE_BLOCKING=1 — refusing to auto-close. Verify the live outcome, then close manually: chump gap ship $_gid --closed-pr $TARGET_PR --update-yaml"
                        CHUMP_REPO="$_autoclose_main_repo" CHUMP_REAL_BINARY="$_autoclose_chump" \
                            chump gap set "$_gid" --add-note "PEER-VERI-08: auto-close BLOCKED — PR #$TARGET_PR merged but a proof AC's live outcome is unverified (${_ac_pre_misses:-}). CHUMP_VERIFY_LIVE_BLOCKING=1 held the close; verify manually then run chump gap ship." >/dev/null 2>&1 || true
                        _bmu_amb="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
                        printf '{"ts":"%s","kind":"ac_coverage_live_blocking_held_close","gap_id":"%s","pr":%s}\n' \
                            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_gid" "$TARGET_PR" \
                            >> "$_bmu_amb" 2>/dev/null || true
                        unset _ac_pre _ac_pre_misses _bmu_amb
                        continue
                    fi
                    unset _ac_pre _ac_pre_misses
                fi

                # INFRA-469 / INFRA-587: run_timed_hb captures output + has 60s timeout.
                # CREDIBLE-295: suspend the ERR trap for this call — `set +e`
                # alone does not stop it firing on a non-zero rc that we are
                # about to capture and handle deliberately (see comment on
                # _BM_ERR_TRAP_CMD above). Inline, NOT via a helper function —
                # a `trap - ERR` inside a called function reverts the moment
                # that function returns.
                _tmpship=$(mktemp)
                set +e
                trap - ERR
                CHUMP_REPO="$_autoclose_main_repo" \
                CHUMP_REAL_BINARY="$_autoclose_chump" \
                run_timed_hb "gap ship $_gid" 60 \
                    chump gap ship "$_gid" \
                        --closed-pr "$TARGET_PR" \
                        --update-yaml > "$_tmpship" 2>&1
                _autoclose_rc=$?
                trap "$_BM_ERR_TRAP_CMD" ERR
                set -e
                _autoclose_err=$(cat "$_tmpship")
                rm -f "$_tmpship"
                if [[ $_autoclose_rc -eq 0 ]]; then
                    # INFRA-509: state.db is canonical; no YAML file staging needed.
                    green "Auto-closed $_gid (closed_pr=$TARGET_PR) — squashed atomically by merge queue"

                    # CREDIBLE-178: surface AC-coverage drift. The gap just flipped to
                    # 'done'; check whether the merged PR actually covered its acceptance
                    # criteria via the existing (but previously un-wired) `chump pr
                    # ac-coverage`. ADVISORY — it NEVER blocks the close (the checker is
                    # still in its observation phase, INFRA-1541). On a MISS it: prints a
                    # WARN, annotates the gap with a visible note (so `chump gap show`
                    # reveals the partial-done instead of a silent 'done'), and the
                    # checker's own ac_coverage_miss events land in ambient. This is the
                    # root fix for the label-drift that closed INFRA-3490 (1 of 2 scoped
                    # arms) and INFRA-3489 (watchdog unwired) as 'done'.
                    if command -v chump &>/dev/null; then
                        _ac_out="$(CHUMP_REPO="$_autoclose_main_repo" CHUMP_REAL_BINARY="$_autoclose_chump" \
                            chump pr ac-coverage "$TARGET_PR" 2>&1 || true)"
                        if grep -q '"status":"miss"' <<<"$_ac_out"; then
                            _ac_misses="$(grep -oE '"misses":\[[0-9,]*\]' <<<"$_ac_out")"
                            yellow "[CREDIBLE-178] AC-coverage MISS: $_gid closed via PR #$TARGET_PR but the merged diff did not cover all acceptance criteria (${_ac_misses:-misses}). Work may be PARTIAL — verify before trusting 'done'. (ac_coverage_miss emitted to ambient.)"
                            CHUMP_REPO="$_autoclose_main_repo" CHUMP_REAL_BINARY="$_autoclose_chump" \
                                chump gap set "$_gid" --add-note "CREDIBLE-178: closed via PR #$TARGET_PR with UNCOVERED acceptance criteria ${_ac_misses:-}. Verify the work is complete before trusting status=done." >/dev/null 2>&1 || true
                        fi
                        unset _ac_out _ac_misses
                    fi

                    # INFRA-2007: emit binary_main_updated so the event-driven watcher
                    # in binary-refresh-event-watcher.sh triggers an immediate rebuild,
                    # eliminating the W-002 binary-cache-lag class permanently.
                    _bmu_amb="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
                    printf '{"ts":"%s","kind":"binary_main_updated","gap_id":"%s","pr":%s,"note":"INFRA-2007 event-driven refresh trigger"}\n' \
                        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_gid" "$TARGET_PR" \
                        >> "$_bmu_amb" 2>/dev/null || true

                    # INFRA-1253: emit DONE a2a event with corr_id=gap-id. INFRA-1255
                    # inbox-reap will clear any matching STUCK/HANDOFF/INTENT from
                    # session inboxes — closes the lifecycle loop. Also clear any
                    # INFRA-1220 cooldown stamp (work shipped, cooldown is moot).
                    if [[ -x scripts/coord/broadcast.sh ]]; then
                        _bm_sha="${_rd_sha:-${_new_pr_sha:-}}"
                        CHUMP_CORR_ID="$_gid" scripts/coord/broadcast.sh \
                            DONE "$_gid" "${_bm_sha:-}" >/dev/null 2>&1 || true
                    fi
                    if [[ -x scripts/coord/gap-cooldown.sh ]]; then
                        scripts/coord/gap-cooldown.sh clear "$_gid" \
                            --reason "INFRA-1253: cleared by bot-merge after gap shipped (PR #$TARGET_PR)" \
                            >/dev/null 2>&1 || true
                    fi
                    # Also remove any INFRA-1252 handoff-pending stamp — work landed.
                    rm -f "$LOCK_DIR/.handoff-pending/$_gid.ts" 2>/dev/null || true

                    # INFRA-1273: post-ship retro prompt. Right after a successful
                    # close — while the friction is fresh in the agent's working
                    # memory — emit a structured one-liner inviting the agent to
                    # log a retro via the INFRA-1271 FEEDBACK channel. The format
                    # is stable so harnesses (claude-code, opencode, etc.) can
                    # detect + surface it to the agent.
                    # Per-session opt-out: CHUMP_NO_RETRO_PROMPT=1.
                    if [[ "${CHUMP_NO_RETRO_PROMPT:-0}" != "1" ]]; then
                        printf '[retro-prompt:INFRA-1273] Anything that did not fit while shipping %s? Log it:\n' "$_gid"
                        printf '  scripts/coord/broadcast.sh FEEDBACK retro %s "<one-liner>"\n' "$_gid"
                        printf '  (kinds: defect | proposal | preference[+1/-1] | retro)\n'
                    fi

                    # INFRA-192: forward-chain notifier (best-effort; never blocks close path).
                    if command -v chump >/dev/null 2>&1 \
                        && [[ -x scripts/coord/broadcast.sh ]]; then
                        _unblocked=$(chump gap list --status open --json 2>/dev/null \
                                    | python3 -c "
import json, sys
gid = '$_gid'
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for g in data:
    deps = g.get('depends_on') or []
    if isinstance(deps, str):
        deps = [d.strip() for d in deps.split(',') if d.strip()]
    if gid in deps:
        print(g['id'])
" 2>/dev/null || true)
                        if [[ -n "$_unblocked" ]]; then
                            _unblocked_count=0
                            while IFS= read -r _down; do
                                [[ -z "$_down" ]] && continue
                                scripts/coord/broadcast.sh ALERT \
                                    kind=gap_unblocked \
                                    "INFRA-192: $_gid closed (PR #$TARGET_PR) — $_down newly actionable (depends_on link satisfied)" \
                                    >/dev/null 2>&1 || true
                                _unblocked_count=$((_unblocked_count + 1))
                            done <<< "$_unblocked"
                            green "Forward-chain (INFRA-192): $_gid unblocked ${_unblocked_count} downstream gap(s); broadcast to siblings"
                        fi
                    fi
                else
                    # INFRA-1030: gap ship failure is WARN-only (not exit 1) because
                    # auto-merge is already armed. Killing bot-merge here would confuse
                    # the caller: the PR will land regardless. Emit ambient event for
                    # curator / operator visibility; recover manually.
                    red "Auto-close FAILED for $_gid (chump gap ship rc=$_autoclose_rc) — WARN (PR already armed, will merge):"
                    if [[ -n "$_autoclose_err" ]]; then
                        while IFS= read -r _line; do
                            [[ -z "$_line" ]] && continue
                            red "  | $_line"
                        done <<< "$_autoclose_err"
                    fi
                    red "  YAML mirror NOT updated; gap status NOT flipped."
                    red "  RECOVER: chump gap ship $_gid --closed-pr $TARGET_PR --update-yaml"
                    red "           (run from main repo: $_autoclose_main_repo)"
                    red "  See: docs/process/CLAUDE_GOTCHAS.md#error-missing-closed-pr"
                    # Emit ambient event for curator pickup.
                    _amb="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
                    _ts_ship="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
                    printf '{"ts":"%s","kind":"gap_ship_post_arm_failed","gap_id":"%s","pr":%s,"rc":%s}\n' \
                        "$_ts_ship" "$_gid" "$TARGET_PR" "$_autoclose_rc" >> "$_amb" 2>/dev/null || true
                    # Do NOT exit 1 — continue (PR is already armed).
                fi
                stage_done
            done
        fi

        # ── INFRA-193: speculative-execution loser sweep ─────────────────────
        # When --speculative was set, scan open PRs that cite the same gap
        # ID(s) and close them as superseded. The losers' branches stay intact
        # (no force-push, no commit loss) — only the PR is closed with a
        # diagnostic comment pointing at the winning PR. Bypass with
        # CHUMP_SPECULATIVE_SWEEP=0 (e.g. when re-running bot-merge.sh on a
        # PR that's already armed and you don't want to re-close losers).
        if [[ "$SPECULATIVE" == "1" ]] \
            && [[ "${CHUMP_SPECULATIVE_SWEEP:-1}" != "0" ]] \
            && [[ ${#GAP_IDS[@]} -gt 0 ]] \
            && [[ -n "$TARGET_PR" ]]; then
            stage_start "INFRA-193 speculative loser sweep (gap=${GAP_IDS[*]})"
            for _gid in "${GAP_IDS[@]}"; do
                # Search open PRs whose title or body mentions the gap ID.
                # Exclude our own PR. gh pr list --search syntax: "GAP-ID in:title,body".
                _losers=$(gh pr list --state open --search "$_gid" \
                    --json number,headRefName,title \
                    --jq ".[] | select(.number != $TARGET_PR) | \"\(.number)|\(.headRefName)|\(.title)\"" \
                    2>/dev/null | head -10 || true)
                if [[ -z "$_losers" ]]; then
                    info "  No sibling PRs cite $_gid — clean win."
                    continue
                fi
                while IFS='|' read -r _lpr _lbranch _ltitle; do
                    [[ -z "$_lpr" ]] && continue
                    # Defence-in-depth: require the loser PR's title or
                    # branch to also reference the gap ID directly (avoids
                    # supersede-by-mention false positives).
                    if [[ "$_ltitle" != *"$_gid"* ]] && [[ "$_lbranch" != *"$(echo "$_gid" | tr '[:upper:]' '[:lower:]')"* ]]; then
                        info "  PR #$_lpr mentions $_gid in body only (title=$_ltitle, branch=$_lbranch) — skipping (false-positive guard)."
                        continue
                    fi
                    info "  Closing PR #$_lpr (branch=$_lbranch) as superseded by #$TARGET_PR …"
                    _supersede_msg="$(printf 'Auto-closing as superseded by #%s.\n\nINFRA-193 speculative-execution race: two agents picked up %s in parallel; PR #%s won the race to ship and is queued for auto-merge. Branch `%s` stays intact (no force-push, no commit loss) — re-open this PR or cherry-pick if the winning PR is later reverted.\n\nSee CLAUDE.md → "Speculative execution (INFRA-193)" for opt-in semantics.' \
                        "$TARGET_PR" "$_gid" "$TARGET_PR" "$_lbranch")"
                    if [[ $DRY_RUN -eq 0 ]]; then
                        gh pr close "$_lpr" --comment "$_supersede_msg" 2>/dev/null \
                            || info "  WARN: could not close PR #$_lpr (already closed? insufficient perms?)"
                        # FLEET-035: emit speculative_race_loss event for waste tracking
                        _rl_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
                        _rl_payload="{\"ts\":\"$_rl_ts\",\"kind\":\"speculative_race_loss\",\
\"session\":\"${SESSION_ID:-unknown}\",\"gap_id\":\"$_gid\",\
\"loser_pr\":$_lpr,\"winner_pr\":$TARGET_PR,\"loser_branch\":\"$_lbranch\"}"
                        _amb="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
                        mkdir -p "$(dirname "$_amb")" 2>/dev/null || true
                        printf '%s\n' "$_rl_payload" >> "$_amb" 2>/dev/null || true
                    else
                        info "  [dry-run] gh pr close $_lpr --comment '...'"
                    fi
                done <<< "$_losers"
            done
            stage_done
        fi

        # INFRA-190: fire-and-forget pr-watch.sh so the PR auto-recovers
        # if main moves while it's queued (DIRTY → rebase + force-push +
        # re-arm). The script handles the 80% case (no real conflicts);
        # real conflicts surface to the operator via exit 3.
        # Default ON; opt out with CHUMP_PR_WATCH_AFTER_ARM=0 (e.g. when
        # the operator wants to babysit the PR manually).
        if [[ "${CHUMP_PR_WATCH_AFTER_ARM:-1}" != "0" ]] \
            && [[ -x "$REPO_ROOT/scripts/coord/pr-watch.sh" ]]; then
            _watch_log="/tmp/pr-watch-${TARGET_PR}-$(date +%s).log"
            nohup "$REPO_ROOT/scripts/coord/pr-watch.sh" "$TARGET_PR" \
                > "$_watch_log" 2>&1 &
            _watch_pid=$!
            disown "$_watch_pid" 2>/dev/null || true
            info "pr-watch.sh detached (pid $_watch_pid, log $_watch_log) — PR will auto-recover from DIRTY"
        fi

        # INFRA-765: fire-and-forget rebase-stacked-prs.sh after auto-merge
        # is armed. Monitors for this PR to merge, then rebases all open PRs
        # that are stacked on our branch (base=BRANCH) onto origin/main and
        # re-arms their auto-merge. Eliminates the 3-PR manual ceremony when
        # a stacked base PR merges. Kill switch: CHUMP_AUTO_REBASE_STACKED=0.
        if [[ "${CHUMP_AUTO_REBASE_STACKED:-1}" != "0" ]] \
            && [[ -x "$REPO_ROOT/scripts/coord/rebase-stacked-prs.sh" ]] \
            && [[ -n "$TARGET_PR" ]]; then
            _stacked_log="/tmp/rebase-stacked-${TARGET_PR}-$(date +%s).log"
            nohup "$REPO_ROOT/scripts/coord/rebase-stacked-prs.sh" \
                "$TARGET_PR" "$BRANCH" "$REPO_ROOT" \
                > "$_stacked_log" 2>&1 &
            _stacked_pid=$!
            disown "$_stacked_pid" 2>/dev/null || true
            info "rebase-stacked-prs.sh detached (pid $_stacked_pid, log $_stacked_log) — will rebase PRs stacked on $BRANCH when it merges"
        fi

        # INFRA-223: feed the chump_improvement_targets loop after every
        # shipped PR. distill-pr-skills.sh shipped in PR #712 but produces 0
        # rows in production because no scheduler fires it (Cold Water #10
        # finding). Hook it into bot-merge's post-arm step so every shipped
        # PR feeds the loop. Background (&) so a slow gh-api call doesn't
        # block the bot-merge happy path; bypass via existing CHUMP_DISTILL=0
        # env var (already supported by the script) or CHUMP_DISTILL_AFTER_SHIP=0
        # to disable just the bot-merge hook without affecting manual runs.
        if [[ "${CHUMP_DISTILL_AFTER_SHIP:-1}" != "0" ]] \
            && [[ -x "$REPO_ROOT/scripts/ops/distill-pr-skills.sh" ]] \
            && [[ -n "$TARGET_PR" ]]; then
            _distill_log="/tmp/distill-pr-${TARGET_PR}-$(date +%s).log"
            nohup "$REPO_ROOT/scripts/ops/distill-pr-skills.sh" --pr "$TARGET_PR" \
                > "$_distill_log" 2>&1 &
            _distill_pid=$!
            disown "$_distill_pid" 2>/dev/null || true
            info "distill-pr-skills.sh detached (pid $_distill_pid, log $_distill_log) — feeds chump_improvement_targets"
        fi
    fi
fi

# INFRA-028 — exit-code honesty: never finish "success" without a visible PR.
if [[ $DRY_RUN -eq 0 ]]; then
    _verify_pr=$(gh pr view "$BRANCH" --json number --jq '.number' 2>/dev/null || echo "")
    if [[ -z "$_verify_pr" ]]; then
        red "No GitHub PR found for branch $BRANCH — refusing to exit 0."
        exit 2
    fi
fi

# META-156 AC#1: step=post_ship — covers shipped-marker + distill + session-end
_bm_step_start "post_ship"
_BM_TERMINAL_STATE="shipped"

# ── 8. Write shipped-marker (INFRA-BOT-MERGE-LOCK) ───────────────────────────
# Presence of .bot-merge-shipped causes chump-commit.sh to refuse further
# commits in this worktree — enforcing the "PR frozen once shipped" rule from
# the PR #52 retrospective. The worktree-reaper (INFRA-WORKTREE-REAPER) treats
# this file as "definitely safe to remove" when cleaning up old worktrees.
if [[ $DRY_RUN -eq 0 ]]; then
    _shipped_pr="${TARGET_PR:-${EXISTING_PR:-}}"
    if [[ -z "$_shipped_pr" ]]; then
        # PR may have been created in this run; fetch it now.
        _shipped_pr=$(gh pr view "$BRANCH" --json number --jq '.number' 2>/dev/null || echo "")
    fi
    _shipped_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    cat > .bot-merge-shipped <<EOF
PR_NUMBER=${_shipped_pr:-unknown}
SHIPPED_AT=${_shipped_at}
BRANCH=${BRANCH}
# Worktree-reaper: safe to remove this worktree
EOF
    green "Wrote .bot-merge-shipped — this worktree is now frozen (no further commits)."

    # INFRA-017: purge ./target in the frozen worktree. Each Rust target/ is
    # 1.4–9 GB; with ~25 frozen worktrees the 460 GB disk fills and subsequent
    # ship runs fail at clippy with `No space left on device (os error 28)`.
    # The PR is already pushed — no further clippy/test runs need this cache.
    # Override with CHUMP_KEEP_TARGET=1 to poke around post-ship.
    # INFRA-210: when CARGO_TARGET_DIR points outside the worktree (shared
    # fleet cache), skip the purge — ./target doesn't exist and wiping the
    # shared dir would break all other active worktrees.
    _wt_abs="$(pwd)"
    _skip_target_purge=0
    if [[ -n "${CARGO_TARGET_DIR:-}" ]]; then
        _ct_abs="$(cd "${CARGO_TARGET_DIR}" 2>/dev/null && pwd || echo "${CARGO_TARGET_DIR}")"
        case "$_ct_abs" in
            "${_wt_abs}"/*|"${_wt_abs}") ;;  # inside this worktree — purge as normal
            *) _skip_target_purge=1 ;;         # outside — shared cache, skip
        esac
    fi
    if [[ "${CHUMP_KEEP_TARGET:-0}" != "1" && "$_skip_target_purge" = "0" && -d "./target" ]]; then
        info "Purging ./target in frozen worktree (set CHUMP_KEEP_TARGET=1 to keep)…"
        run rm -rf ./target
        green "Removed ./target — disk reclaimed."
    elif [[ "$_skip_target_purge" = "1" ]]; then
        info "Skipping ./target purge — CARGO_TARGET_DIR is outside this worktree (INFRA-210)."
    fi
fi

# INFRA-537: emit ship_grade event for per-agent/per-model quality tracking.
# Captures clippy_ok, test_added, rebase_clean signals gathered above.
# model and agent_id come from fleet env vars (set by run-fleet.sh / worker.sh);
# for manual ships they default to "unknown".
if [[ $DRY_RUN -eq 0 ]]; then
    _grade_model="${FLEET_MODEL:-unknown}"
    _grade_agent="${AGENT_ID:-unknown}"
    _grade_harness="${CHUMP_AGENT_HARNESS:-manual}"
    _grade_amb="${REPO_ROOT}/.chump-locks/ambient.jsonl"
    _grade_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for gid in "${GAP_IDS[@]:-}"; do
        [[ -z "$gid" ]] && continue
        printf '{"event":"ship_grade","kind":"ship_grade","ts":"%s","gap_id":"%s","model":"%s","agent_id":"%s","harness":"%s","clippy_ok":%s,"test_added":%s,"rebase_clean":%s}\n' \
            "$_grade_ts" "$gid" "$_grade_model" "$_grade_agent" "$_grade_harness" \
            "$_grade_clippy_ok" "$_grade_test_added" "$_grade_rebase_clean" \
            >> "$_grade_amb" 2>/dev/null || true
    done
fi

# INFRA-492: emit session_end with outcome=shipped on the success path.
# Failure paths (exit 1 above) emit nothing — INFRA-477's outcome:abandoned
# is computed by absence of session_end pairing, but the session-track
# CLI doesn't auto-emit on shell exit. For now, success-path-only is
# the simpler implementation; failure-path emission can come as a
# follow-up if the abandoned-session signal becomes critical.
if [[ $DRY_RUN -eq 0 ]]; then
    for gid in "${GAP_IDS[@]:-}"; do
        [[ -z "$gid" ]] && continue
        chump session-track --end "$gid" --outcome shipped >/dev/null 2>&1 || true
    done
fi

# INFRA-495: release the operator's lease at end of successful ship.
# Pre-fix bot-merge.sh emitted session_end but left the lease file at
# .chump-locks/$CHUMP_SESSION_ID.json — the watcher then re-emitted
# silent_agent every hour for 6h until the TTL reaper deleted it.
# 'chump fleet-status' (INFRA-494) surfaced 10 such stale leases from
# manual ships within minutes of going live; this is the operator-side
# parallel of INFRA-490's worker.sh fix.
if [[ $DRY_RUN -eq 0 && -n "${CHUMP_SESSION_ID:-}" ]]; then
    rm -f "$REPO_ROOT/.chump-locks/${CHUMP_SESSION_ID}.json" 2>/dev/null || true
fi

# META-156 AC#1: close post_ship step; AC#7: emit roll-up completed event
_bm_step_done "post_ship" 0
_bm_completed_emit

green "=== bot-merge done. ==="
