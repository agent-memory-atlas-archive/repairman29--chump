#!/usr/bin/env bash
# run-fleet.sh — INFRA-203 / INFRA-211: canonical fleet launcher.
#
# Spawns N tmux panes, one per Claude Code agent, plus a control pane that
# tails ambient.jsonl, the PR queue, and per-agent activity. Each agent runs
# `worker.sh` which loops: pick highest-priority unclaimed gap → claim →
# create worktree → spawn `claude -p` (the same surface as
# WorkBackend::Headless from src/dispatch.rs, INFRA-191 Phase 2) → ship via
# bot-merge.sh → release → loop.
#
# Usage:
#   scripts/dispatch/run-fleet.sh                  # default FLEET_SIZE=8
#   FLEET_SIZE=4 scripts/dispatch/run-fleet.sh
#   FLEET_DOMAIN_FILTER=INFRA scripts/dispatch/run-fleet.sh
#   FLEET_SIZE=0 scripts/dispatch/run-fleet.sh     # tear down only
#
# Env knobs:
#   FLEET_SIZE              (default 8)   number of agent panes; 0 = stop only
#   FLEET_TIMEOUT_S         (default 1800) per-agent claude -p timeout
#   FLEET_PRIORITY_FILTER   (default "P0,P1") comma-separated priorities
#   FLEET_DOMAIN_FILTER     (default "")  e.g. "INFRA" or "INFRA,DOC"; "" = all
#   FLEET_AGENT_DOMAINS     (default "")  comma-separated domain list; agent K
#                           is assigned domains[(K-1) % N]. E.g. "INFRA,EVAL,DOC"
#                           makes agent-1=INFRA, agent-2=EVAL, agent-3=DOC (wraps
#                           round-robin). Overrides FLEET_DOMAIN_FILTER per-agent.
#                           "" = all agents use the fleet-wide FLEET_DOMAIN_FILTER.
#                           (INFRA-206)
#   FLEET_EFFORT_FILTER     (default "xs,s,m") comma-separated efforts
#   FLEET_SESSION           (default "chump-fleet") tmux session name
#   FLEET_LOG_DIR           (default /tmp/chump-fleet-<sid>) per-agent logs
#   FLEET_DRY_RUN           (default 0)   if 1, print plan and exit
#   FLEET_BACKEND           (default claude) "claude" runs each gap via
#                           `claude -p` with Anthropic API (AUTO-013 path).
#                           "chump-local" fans calls through
#                           src/provider_cascade.rs (free tiers) — requires
#                           CHUMP_FLEET_ALLOW_CHUMP_LOCAL_BACKEND=1 (INFRA-459:
#                           cascade bank too small for dev workload 2026-05-04).
#   FLEET_MODEL             (default sonnet, see L285 — RESILIENT-154 removed
#                           haiku from the default fleet) model passed to
#                           claude -p. Use opus for harder gaps.
#   CARGO_TARGET_DIR        recommended: shared target across worktrees
#                           (see INFRA-210 — exported below if unset)
#   CHUMP_CARGO_TARGET_GROUP_SIZE (default 2) workers per distinct
#                           CARGO_TARGET_DIR — see INFRA-3662 below.
#   CHUMP_CARGO_TARGET_ROOT override for the per-group target root (skips
#                           USB/cjdata* autodetect — see INFRA-3662 below).
#
# Stop:
#   FLEET_SIZE=0 scripts/dispatch/run-fleet.sh   ← preferred (cascade-kills orphans, INFRA-581)
#   tmux kill-session -t <FLEET_SESSION>          ← safe: orphan-reaper sentinel fires (INFRA-602)
#   or: Ctrl-C inside any pane (only kills that one agent's loop)
#
# INFRA-602: a sentinel watcher process (outside tmux) is spawned at fleet start.
# It polls `tmux has-session` every 3s; when the fleet session disappears for any
# reason it runs: pkill -f "timeout [0-9]*s claude -p "
# If you bypass tmux entirely (e.g. SIGKILL on the tmux server), follow with:
#   pkill -f "timeout [0-9]*s claude -p "
#
# INFRA-581: tmux kill-session kills the pane shell + worker.sh but
# already-spawned `timeout Ns claude -p ...` grandchildren may have
# setsid'd and survive as PPID=1 orphans consuming compute + racing new
# fleet picks. FLEET_SIZE=0 teardown reads ~/.chump/fleet-pids-<session>.txt
# (written at spawn) to cascade-kill worker subtrees; then pkill finishes
# off any survivors. If you must use raw `tmux kill-session`, follow with:
#   pkill -f "timeout [0-9]*s claude -p "

set -euo pipefail

# INFRA-2002 / META-107 sub-gap #6 — Rust port feature flag.
# When CHUMP_FLEET_RUST=1, exec the chump-fleet binary. Defaults to 0
# (run legacy tmux+bash body inline) for the 1-week parallel-run window.
if [[ "${CHUMP_FLEET_RUST:-0}" = "1" ]]; then
    _chump_fleet_bin="${CHUMP_FLEET_BIN:-}"
    if [[ -z "$_chump_fleet_bin" ]]; then
        for _cand in \
            "$(git rev-parse --show-toplevel 2>/dev/null)/target/debug/chump-fleet" \
            "$(git rev-parse --show-toplevel 2>/dev/null)/target/release/chump-fleet" \
            "$(command -v chump-fleet 2>/dev/null || true)"; do
            if [[ -n "$_cand" && -x "$_cand" ]]; then
                _chump_fleet_bin="$_cand"
                break
            fi
        done
    fi
    if [[ -n "$_chump_fleet_bin" && -x "$_chump_fleet_bin" ]]; then
        # Translate FLEET_SIZE to --size N when invoked without explicit flags.
        if [[ "$#" -eq 0 && -n "${FLEET_SIZE:-}" ]]; then
            exec "$_chump_fleet_bin" --size "$FLEET_SIZE"
        else
            exec "$_chump_fleet_bin" "$@"
        fi
    fi
    echo "[run-fleet.sh] CHUMP_FLEET_RUST=1 but chump-fleet binary not found; falling back to bash body" >&2
fi

# ── CLI flag parsing ──────────────────────────────────────────────────────────
# INFRA-634: --repo, --locks-dir, --tmux-session (non-Chump repo support).
# INFRA-844: --restart, --dry-run, --help (clean fleet reload).
# env vars (CHUMP_REPO, FLEET_LOCKS_DIR, FLEET_SESSION, FLEET_DRY_RUN)
# are equivalent and take lower precedence when a flag is given.
_ARG_REPO=""
_ARG_LOCKS_DIR=""
_ARG_TMUX_SESSION=""
_FLEET_RESTART=0
_FLEET_DRY_RUN_ARG=0
_POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)
            _ARG_REPO="$2"; shift 2 ;;
        --repo=*)
            _ARG_REPO="${1#--repo=}"; shift ;;
        --locks-dir)
            _ARG_LOCKS_DIR="$2"; shift 2 ;;
        --locks-dir=*)
            _ARG_LOCKS_DIR="${1#--locks-dir=}"; shift ;;
        --tmux-session)
            _ARG_TMUX_SESSION="$2"; shift 2 ;;
        --tmux-session=*)
            _ARG_TMUX_SESSION="${1#--tmux-session=}"; shift ;;
        --restart)
            _FLEET_RESTART=1; shift ;;
        --dry-run)
            _FLEET_DRY_RUN_ARG=1; shift ;;
        --help|-h)
            sed -n '2,/^set -/p' "$0" | sed 's/^# \?//' | head -60
            exit 0
            ;;
        *)
            _POSITIONAL+=("$1"); shift ;;
    esac
done
# Restore positional args (e.g. sub-commands passed by caller)
set -- "${_POSITIONAL[@]+"${_POSITIONAL[@]}"}"
if [[ "$_FLEET_DRY_RUN_ARG" -eq 1 ]]; then
    export FLEET_DRY_RUN=1
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
# --repo overrides git-inferred root (INFRA-634)
if [[ -n "$_ARG_REPO" ]]; then
    REPO_ROOT="$(cd "$_ARG_REPO" && pwd)"
    export CHUMP_REPO="$REPO_ROOT"
    echo "[run-fleet] INFRA-634: --repo override → REPO_ROOT=$REPO_ROOT (CHUMP_REPO exported)"
elif [[ -n "${CHUMP_REPO:-}" ]]; then
    REPO_ROOT="$(cd "$CHUMP_REPO" && pwd)"
fi

# --locks-dir overrides .chump-locks/ path (INFRA-634)
FLEET_LOCKS_DIR="${_ARG_LOCKS_DIR:-${FLEET_LOCKS_DIR:-$REPO_ROOT/.chump-locks}}"
if [[ -n "$_ARG_LOCKS_DIR" ]]; then
    echo "[run-fleet] INFRA-634: --locks-dir override → FLEET_LOCKS_DIR=$FLEET_LOCKS_DIR"
fi

# INFRA-634: emit ambient event when cross-repo mode is activated.
# Done early (before the main _amb_log setup) if any override flag was given.
if [[ -n "$_ARG_REPO" || -n "$_ARG_LOCKS_DIR" || -n "$_ARG_TMUX_SESSION" ]]; then
    _early_amb="${CHUMP_AMBIENT_LOG:-$FLEET_LOCKS_DIR/ambient.jsonl}"
    mkdir -p "$(dirname "$_early_amb")" 2>/dev/null || true
    _early_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","kind":"fleet_cross_repo_start","repo":"%s","locks_dir":"%s","session":"%s"}\n' \
      "$_early_ts" "$REPO_ROOT" "$FLEET_LOCKS_DIR" "${_ARG_TMUX_SESSION:-}" \
      >> "$_early_amb" 2>/dev/null || true
fi

SCRIPT_DIR="$REPO_ROOT/scripts/dispatch"
# INFRA-469: route every `chump` invocation through the wedge-heal shim.
export PATH="$REPO_ROOT/bin:$PATH"

# INFRA-351: source $REPO_ROOT/.env (if present) so spawned worker panes
# inherit ANTHROPIC_API_KEY / OPENAI_API_KEY / TOGETHER_API_KEY etc. and
# `claude -p` consumes workspace API credit instead of falling back to
# the launcher's claude.ai subscription cap. Caught 2026-05-02 22:27:
# Jeff had $92.71 unused workspace credit while the squad burned the
# $20 monthly subscription cap. Bypass: CHUMP_FLEET_NOENV=1.
if [[ -f "$REPO_ROOT/.env" && "${CHUMP_FLEET_NOENV:-0}" != "1" ]]; then
    # set -a auto-exports every assignment; matches the standard "source .env"
    # idiom used in tools like docker-compose. set +a restores prior behavior.
    set -a
    # shellcheck disable=SC1091
    source "$REPO_ROOT/.env"
    set +a
    echo "[run-fleet] sourced $REPO_ROOT/.env (INFRA-351) — set CHUMP_FLEET_NOENV=1 to skip"
fi

# INFRA-620: detect auth mode before consuming any fleet config, so the
# mode is available for the ambient emit and worker_env construction below.
# Subscription mode: CLAUDE_CODE_OAUTH_TOKEN set, ANTHROPIC_API_KEY absent.
# In subscription mode the parent Claude Code app refreshes the token
# in-process every ~30-60min; already-spawned workers keep the OLD token
# in their inherited env and all fail simultaneously. We write the current
# token to ~/.chump/oauth-token.json, start a background refresher, and
# tell workers to re-read from that file before each spawn.
_fleet_auth_mode="unknown"
_fleet_auth_path="none"
# INFRA-1717: detect OAUTH path via file too — Claude Code refreshes the
# token to ~/.chump/oauth-token.json every 5min (per CLAUDE.md auth modes);
# the env var is only populated when the parent app exports it. Sessions
# that source .env into a fresh shell will see the file but not the var.
_oauth_token_file="${HOME}/.chump/oauth-token.json"
# Operator decision 2026-06-08: OAuth-FIRST, API-key SECONDARY.
# claude prefers ANTHROPIC_API_KEY when both are set, so "oauth first" requires
# explicitly choosing OAuth and unsetting the key. CHUMP_AUTH_MODE=api-key forces
# the key; otherwise prefer subscription/OAuth (env token, then oauth-token.json),
# falling back to ANTHROPIC_API_KEY only when no OAuth credential is available.
if [[ "${CHUMP_AUTH_MODE:-auto}" == "api-key" && -n "${ANTHROPIC_API_KEY:-}" ]]; then
    _fleet_auth_mode="api_key"
    _fleet_auth_path="ANTHROPIC_API_KEY"
elif [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
    _fleet_auth_mode="subscription"
    _fleet_auth_path="CLAUDE_CODE_OAUTH_TOKEN"
    unset ANTHROPIC_API_KEY
elif [[ -s "$_oauth_token_file" ]]; then
    export CLAUDE_CODE_OAUTH_TOKEN="$(_OTF="$_oauth_token_file" python3 -c 'import json,os,sys; sys.stdout.write(json.load(open(os.environ["_OTF"]))["token"])' 2>/dev/null)"
    if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
        _fleet_auth_mode="subscription"
        _fleet_auth_path="oauth-token.json"
        unset ANTHROPIC_API_KEY
    elif [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
        _fleet_auth_mode="api_key"
        _fleet_auth_path="ANTHROPIC_API_KEY"
    fi
elif [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    _fleet_auth_mode="api_key"
    _fleet_auth_path="ANTHROPIC_API_KEY"
fi

FLEET_SIZE="${FLEET_SIZE:-8}"

# EFFECTIVE-086 AC #3: bind worker concurrency to the graduated autonomy
# dial via the existing fleet scaling gate (docs/process/FLEET_SLOS.md /
# INFRA-518) rather than a separate cap. The dial is a *ceiling* — the
# scale-up criteria in FLEET_SLOS.md still govern whether the fleet may
# actually use up to that ceiling. Mirrors
# crates/chump-atomic-claim/src/autonomy_level.rs::AutonomyLevel::max_workers
# — keep both in sync if the level->cap mapping changes.
if [[ "$FLEET_SIZE" != "0" ]]; then
    _al_path="${HOME:-/tmp}/.chump/AUTONOMY_LEVEL"
    _al_level=0
    if [[ -r "$_al_path" ]]; then
        _al_raw="$(tr -d '[:space:]' < "$_al_path" 2>/dev/null || echo "")"
        [[ "$_al_raw" =~ ^[0-9]+$ ]] && _al_level="$_al_raw"
    fi
    case "$_al_level" in
        0|1) _al_max_workers=0 ;;
        2) _al_max_workers=1 ;;
        3) _al_max_workers=2 ;;
        4) _al_max_workers=4 ;;
        *) _al_max_workers="" ;; # 5 (UNLEASHED) or out-of-range: no level-imposed ceiling
    esac
    if [[ -n "$_al_max_workers" ]] && (( FLEET_SIZE > _al_max_workers )); then
        echo "[run-fleet.sh] AUTONOMY_LEVEL=$_al_level caps FLEET_SIZE $FLEET_SIZE -> $_al_max_workers (EFFECTIVE-086)" >&2
        FLEET_SIZE=$_al_max_workers
    fi
fi

# INFRA-371: timeout default lowered 1800→600.
# INFRA-707: raised 600→900. Post-rebalancing (FLEET-046) the fleet picks
# substantive EFFECTIVE/CREDIBLE gaps that write 600-900 lines of Rust —
# these consistently hit the 600s wall. Data: INFRA-645 shipped (PR #1278)
# but got killed 6s after printing the PR number; INFRA-604/605 committed
# 600-900 LoC via WIP checkpoint but couldn't finish. 900s catches
# finish-line kills without wasting much more on true stalls (shipped gaps
# avg 200s, max 460s — plenty of headroom).
FLEET_TIMEOUT_S="${FLEET_TIMEOUT_S:-1800}"
# Memory guard (2026-07-19): cap per-worker cargo parallelism — concurrent
# rustc jobs (~1.2GB each) are the top RAM consumers during fleet build storms.
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-4}"

# INFRA-3659: cap AGGREGATE cargo concurrency (FLEET_SIZE * CARGO_BUILD_JOBS)
# to this host's core count — durable version of the 2026-08-22 CJ hand-cap
# (jobs=1 in ~/.cargo/config.toml + manually stopping cj-worker2/3). CJ is
# 4-core but ran ~14 workers x CARGO_BUILD_JOBS=4 = ~56 rustc threads ->
# swap thrash, 30-45min/gap, unverified_ship. Every launch now self-caps
# instead of relying on a human noticing and hand-editing config. No bypass
# knob on purpose (INFRA-2429 zero-bypass thesis) — a host that genuinely
# has spare headroom should raise CARGO_BUILD_JOBS/FLEET_SIZE explicitly
# rather than opt out of the safety net wholesale.
if [[ "$FLEET_SIZE" != "0" ]]; then
    _fleet_nproc="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
    if [[ "$_fleet_nproc" =~ ^[0-9]+$ ]] && (( _fleet_nproc > 0 )) && (( FLEET_SIZE * CARGO_BUILD_JOBS > _fleet_nproc )); then
        _fleet_size_before=$FLEET_SIZE
        _cargo_jobs_before=$CARGO_BUILD_JOBS
        # Prefer trimming FLEET_SIZE first (worker count is the cheaper knob
        # to give back — CARGO_BUILD_JOBS>1 still helps a single build finish
        # faster), then fall back to shrinking CARGO_BUILD_JOBS if one worker
        # alone still oversubscribes the box.
        if (( FLEET_SIZE > _fleet_nproc )); then
            FLEET_SIZE=$_fleet_nproc
        fi
        while (( FLEET_SIZE * CARGO_BUILD_JOBS > _fleet_nproc && FLEET_SIZE > 1 )); do
            FLEET_SIZE=$(( FLEET_SIZE - 1 ))
        done
        if (( FLEET_SIZE * CARGO_BUILD_JOBS > _fleet_nproc )); then
            CARGO_BUILD_JOBS=$(( _fleet_nproc / FLEET_SIZE ))
            (( CARGO_BUILD_JOBS < 1 )) && CARGO_BUILD_JOBS=1
            export CARGO_BUILD_JOBS
        fi
        echo "[run-fleet] INFRA-3659: capped concurrency to nproc=$_fleet_nproc -> FLEET_SIZE $_fleet_size_before->$FLEET_SIZE, CARGO_BUILD_JOBS $_cargo_jobs_before->$CARGO_BUILD_JOBS"
        _amb_cap_log="${CHUMP_AMBIENT_LOG:-$FLEET_LOCKS_DIR/ambient.jsonl}"
        mkdir -p "$(dirname "$_amb_cap_log")" 2>/dev/null || true
        printf '{"ts":"%s","kind":"fleet_concurrency_capped","nproc":%d,"fleet_size_before":%d,"fleet_size_after":%d,"cargo_jobs_before":%d,"cargo_jobs_after":%d}\n' \
          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_fleet_nproc" "$_fleet_size_before" "$FLEET_SIZE" "$_cargo_jobs_before" "$CARGO_BUILD_JOBS" \
          >> "$_amb_cap_log" 2>/dev/null || true
    fi
fi

FLEET_PRIORITY_FILTER="${FLEET_PRIORITY_FILTER:-P0,P1}"
FLEET_DOMAIN_FILTER="${FLEET_DOMAIN_FILTER:-}"
FLEET_AGENT_DOMAINS="${FLEET_AGENT_DOMAINS:-}"
FLEET_EFFORT_FILTER="${FLEET_EFFORT_FILTER:-xs,s,m}"
# INFRA-634: --tmux-session flag overrides FLEET_SESSION env var.
if [[ -n "$_ARG_TMUX_SESSION" ]]; then
    FLEET_SESSION="$_ARG_TMUX_SESSION"
    echo "[run-fleet] INFRA-634: --tmux-session override → FLEET_SESSION=$FLEET_SESSION"
else
    FLEET_SESSION="${FLEET_SESSION:-chump-fleet}"
fi
# INFRA-581: per-session PID file so teardown can cascade-kill orphaned workers.
FLEET_PIDS_FILE="${FLEET_PIDS_FILE:-$HOME/.chump/fleet-pids-${FLEET_SESSION}.txt}"
# RESILIENT-159: if run-fleet exits or is SIGTERM'd WITHOUT a live fleet session
# (e.g. killed during setup, before the tmux session is created), reap the
# background children we already spawned (token refresher, autorestart daemon)
# so they don't orphan to PPID 1. A SUCCESSFUL launch leaves the session up, so
# this is a no-op then — the children stay to support the running pool. Covers
# the 0-300s window before the refresher's own self-exit check can fire.
_reap_bg_if_no_fleet() {
    tmux has-session -t "$FLEET_SESSION" 2>/dev/null && return 0
    [[ -f "$FLEET_PIDS_FILE" ]] || return 0
    while read -r _bgpid; do
        [[ -n "$_bgpid" ]] && kill "$_bgpid" 2>/dev/null || true
    done < "$FLEET_PIDS_FILE"
}
trap _reap_bg_if_no_fleet EXIT
FLEET_DRY_RUN="${FLEET_DRY_RUN:-0}"
# INFRA-738 + INFRA-1717: auto-detect backend based on any working claude auth.
#   - Any auth path resolved (api_key | subscription via env | oauth-token.json file)
#       → FLEET_BACKEND defaults to claude
#   - No auth path resolvable → FLEET_BACKEND defaults to chump-local
#   - Explicit FLEET_BACKEND override always wins.
# Pre-INFRA-1717 the check was ANTHROPIC_API_KEY-only, which mis-routed
# OAUTH-subscription sessions to the exhausted chump-local cascade.
# EFFECTIVE-325: honor CHUMP_WORK_BACKEND as the default here too — this
# launcher EXPORTS FLEET_BACKEND to every worker it spawns, so if it resolved
# to `claude` while the operator had set CHUMP_WORK_BACKEND=chump-local, the
# worker would receive FLEET_BACKEND=claude already set and never reach its own
# CHUMP_WORK_BACKEND fallback. Keep the two selectors unified at both layers.
# Precedence: explicit FLEET_BACKEND > CHUMP_WORK_BACKEND > auth-based default.
if [[ "$_fleet_auth_mode" == "unknown" ]]; then
    FLEET_BACKEND="${FLEET_BACKEND:-${CHUMP_WORK_BACKEND:-chump-local}}"
    # INFRA-1716: warn when falling through to chump-local — the cascade bank
    # was exhausted in INFRA-459 and produces silent 15-min timeouts per worker.
    if [[ "${FLEET_BACKEND}" == "chump-local" ]]; then
        echo "[run-fleet] WARN: no claude auth found (ANTHROPIC_API_KEY / CLAUDE_CODE_OAUTH_TOKEN / oauth-token.json unset)." >&2
        echo "[run-fleet] WARN: cascade bank exhausted in prod (INFRA-459); workers will TIMEOUT silently." >&2
        echo "[run-fleet] WARN: set ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN to use backend=claude." >&2
    fi
else
    FLEET_BACKEND="${FLEET_BACKEND:-${CHUMP_WORK_BACKEND:-claude}}"
fi
# INFRA-459: default model is haiku — cost-efficient for xs/s/m fleet gaps.
# Override via FLEET_MODEL=sonnet for harder tasks.
FLEET_MODEL="${FLEET_MODEL:-sonnet}"
# INFRA-1052: harness tag written to CHUMP_AGENT_HARNESS in each worker env.
# Valid: claude, opencode, codex, manual. Default keeps legacy "fleet-dispatcher".
FLEET_HARNESS="${FLEET_HARNESS:-fleet-dispatcher}"
# INFRA-371: token-burn defaults applied to every fleet worker unless
# the caller overrides. These cut per-spawn token cost without losing
# capability — workers can still re-enable for harder workloads.
#   FLEET_INLINE_BRIEFING=1   inline gap YAML in prompt instead of
#                              forcing claude to read CLAUDE.md/AGENTS.md
#   CHUMP_LESSONS_AT_SPAWN_N=0 disable lessons block prepend at every
#                              prompt assembly (default OFF in COG-024
#                              but defensive here for any inherited env)
#   CHUMP_AMBIENT_INSTALL_SKIP=1 skip the install-ambient-hooks idempotent
#                              re-run on every session start (~500 tokens
#                              of bash output saved per cycle)
export FLEET_INLINE_BRIEFING="${FLEET_INLINE_BRIEFING:-1}"
export CHUMP_LESSONS_AT_SPAWN_N="${CHUMP_LESSONS_AT_SPAWN_N:-0}"
export CHUMP_AMBIENT_INSTALL_SKIP="${CHUMP_AMBIENT_INSTALL_SKIP:-1}"
# MISSION-018: allow workers to pick external-repo gaps (skills_required
# contains `external_repo:<owner>/<repo>`). Required for the fleet to claim
# BEAST-MODE work autonomously. Implemented at
# crates/chump-coord/src/worker/capability.rs:130 — without this, every
# external-repo gap is skipped by every worker. Operator-overridable
# (export CHUMP_EXTERNAL_REPO_PICK_OK=0 before invoking to disable).
export CHUMP_EXTERNAL_REPO_PICK_OK="${CHUMP_EXTERNAL_REPO_PICK_OK:-1}"

# INFRA-738: chump-local backend guard. When ANTHROPIC_API_KEY is set and the
# user explicitly chose chump-local, require CHUMP_FLEET_ALLOW_CHUMP_LOCAL_BACKEND=1
# as a safety gate (the cascade bank was too small for dev workload historically,
# INFRA-459). When ANTHROPIC_API_KEY is unset, chump-local is the only option
# and is allowed automatically.
if [[ "$FLEET_BACKEND" == "chump-local" \
        && -n "${ANTHROPIC_API_KEY:-}" \
        && "${CHUMP_FLEET_ALLOW_CHUMP_LOCAL_BACKEND:-0}" != "1" ]]; then
    echo "[run-fleet] REFUSING to start fleet on backend=chump-local" >&2
    echo "[run-fleet]   ANTHROPIC_API_KEY is set and cascade bank is too small for" >&2
    echo "[run-fleet]   dev workload (INFRA-459, 2026-05-04); calls stall silently." >&2
    echo "[run-fleet]   To override:    CHUMP_FLEET_ALLOW_CHUMP_LOCAL_BACKEND=1 $0" >&2
    echo "[run-fleet]   Unset ANTHROPIC_API_KEY to auto-default to chump-local." >&2
    exit 2
fi

case "$FLEET_BACKEND" in
    claude|chump-local) ;;
    *)
        echo "[run-fleet] ERROR: FLEET_BACKEND must be 'claude' or 'chump-local' (got: $FLEET_BACKEND)" >&2
        exit 2
        ;;
esac

SID="$(date +%Y%m%d-%H%M%S)-$$"
FLEET_LOG_DIR="${FLEET_LOG_DIR:-/tmp/chump-fleet-${SID}}"
# INFRA-623: record launch epoch so fleet-autorestart-daemon can compare
# oauth-token.json mtime against fleet start when refreshing credentials.
FLEET_START_EPOCH="${FLEET_START_EPOCH:-$(date +%s)}"

# INFRA-210: every worktree compiling its own target/ is the #1 disk hog.
# Default to a shared target dir unless the caller explicitly set their own.
# INFRA-535: when the fleet is launched from a /tmp/ clone, a worktree-local
# target/ fills /tmp/ and causes disk-full — so the shared dir must live in
# $HOME, outside /tmp/, surviving across sessions.
# ZERO-WASTE-029: the previous impl forked TWO extra targets — $REPO_ROOT/target
# (non-tmp) and ~/.cache/chump-fleet-target (tmp) — neither matching worker.sh's
# canonical ~/.cargo/chump-shared-target. Because run-fleet propagates
# CARGO_TARGET_DIR into every worker env (see the worker env block below), that
# override defeated worker.sh's default, producing a duplicate ~45G target dir
# (the 2026-07-26 disk-100% incident). Converge on worker.sh's exact canonical
# value so launcher, workers, and interactive builds all share one target dir.
if [ -z "${CARGO_TARGET_DIR:-}" ]; then
    export CARGO_TARGET_DIR="${CHUMP_SHARED_CARGO_TARGET:-$HOME/.cargo/chump-shared-target}"
fi

# INFRA-3662: one CARGO_TARGET_DIR shared by every worker means the cargo
# fingerprint/incremental cache is also shared — worktree A's build of a file
# that doesn't exist on worktree B's branch poisons B's fingerprint lookup
# ("couldn't read tests/foo.rs: No such file or directory", INFRA-1138). The
# per-worker-test-gate CARGO_TARGET_DIR override fixed `cargo test`, but the
# fleet's persistent worker.sh loop (which does NOT go through that gate for
# `cargo check`/`clippy`) still shares one target dir across every pane.
# Fix: split workers into groups of CHUMP_CARGO_TARGET_GROUP_SIZE (default 2)
# and give each group its own CARGO_TARGET_DIR — bounded fan-out (FLEET_SIZE/N
# distinct dirs, not FLEET_SIZE) so disk footprint stays close to today's
# single-dir baseline while isolating fingerprint state. sccache (rustc-wrapper
# in .cargo/config.toml) still shares compiled object code across ALL groups,
# so the hit-rate benefit is unaffected — only fingerprint/incremental state is
# now group-local instead of fleet-global.
CHUMP_CARGO_TARGET_GROUP_SIZE="${CHUMP_CARGO_TARGET_GROUP_SIZE:-2}"
if ! [[ "$CHUMP_CARGO_TARGET_GROUP_SIZE" =~ ^[0-9]+$ ]] || [[ "$CHUMP_CARGO_TARGET_GROUP_SIZE" -lt 1 ]]; then
    echo "[run-fleet] WARN: CHUMP_CARGO_TARGET_GROUP_SIZE='$CHUMP_CARGO_TARGET_GROUP_SIZE' invalid — defaulting to 2"
    CHUMP_CARGO_TARGET_GROUP_SIZE=2
fi

# Root directory under which each group's target dir is created. Prefers a
# mounted external/USB data disk (mirrors install-sccache.sh's cjdata3-first
# autodetect, INFRA-3660) so N group dirs don't compete with the OS drive for
# space; falls back to the existing single shared-target location so a
# machine with no USB/cjdata mount keeps today's behavior when N==FLEET_SIZE
# effectively collapses to group size 1 (see per-worker loop below).
_detect_cargo_target_root() {
    if [[ -n "${CHUMP_CARGO_TARGET_ROOT:-}" ]]; then
        echo "$CHUMP_CARGO_TARGET_ROOT"
        return
    fi
    if [[ -d /mnt/cjdata3 && -w /mnt/cjdata3 ]]; then
        echo "/mnt/cjdata3/chump-cargo-targets"
        return
    fi
    local root_fs best="" best_avail_kb=0
    root_fs="$(df -P / 2>/dev/null | awk 'NR==2{print $1}')"
    while read -r fs avail_kb mnt; do
        [[ "$fs" == "$root_fs" ]] && continue
        [[ -w "$mnt" ]] || continue
        if (( avail_kb > best_avail_kb )); then
            best_avail_kb=$avail_kb
            best="$mnt"
        fi
    done < <(df -Pk /mnt/cjdata* 2>/dev/null | awk 'NR>1{print $1, $4, $6}')
    if [[ -n "$best" ]]; then
        echo "$best/chump-cargo-targets"
        return
    fi
    echo "$(dirname "$CARGO_TARGET_DIR")/chump-cargo-target-groups"
}
CHUMP_CARGO_TARGET_ROOT="$(_detect_cargo_target_root)"

# ── INFRA-844: --restart — tear down existing fleet then relaunch ─────────────
if [[ "$_FLEET_RESTART" -eq 1 ]]; then
    _fleet_from_size=0
    if tmux has-session -t "$FLEET_SESSION" 2>/dev/null; then
        # Count existing fleet-worker-N panes
        _fleet_from_size=$(tmux list-panes -t "$FLEET_SESSION" -F '#{pane_title}' 2>/dev/null \
            | grep -c "fleet-worker" || true)
        echo "[run-fleet] --restart: tearing down $FLEET_SESSION ($FLEET_SIZE workers → restart)"
        if [[ -f "$FLEET_PIDS_FILE" ]]; then
            while IFS= read -r _pid; do
                [[ "$_pid" =~ ^[0-9]+$ ]] || continue
                kill -TERM "-${_pid}" 2>/dev/null || true
                pkill -TERM -P "$_pid" 2>/dev/null || true
                kill -TERM "$_pid" 2>/dev/null || true
            done < "$FLEET_PIDS_FILE"
            rm -f "$FLEET_PIDS_FILE"
        fi
        tmux kill-session -t "$FLEET_SESSION" 2>/dev/null || true
        pkill -f "timeout [0-9]*s claude -p " 2>/dev/null || true
        sleep 1  # let panes settle before relaunching
    fi
    _fleet_restart_amb="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
    mkdir -p "$(dirname "$_fleet_restart_amb")" 2>/dev/null || true
    if [[ "${FLEET_DRY_RUN:-0}" != "1" ]]; then
        printf '{"ts":"%s","kind":"fleet_restart","from_size":%d,"to_size":%d,"reason":"--restart flag"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_fleet_from_size" "$FLEET_SIZE" \
            >> "$_fleet_restart_amb" 2>/dev/null || true
        echo "[run-fleet] fleet_restart event emitted → ambient.jsonl"
    else
        echo "[run-fleet] [dry-run] would emit fleet_restart from_size=$_fleet_from_size to_size=$FLEET_SIZE"
    fi
fi

# Tear-down-only path: FLEET_SIZE=0 means "stop the fleet, don't spawn".
if [ "$FLEET_SIZE" = "0" ]; then
    # INFRA-581: cascade-kill pane subtrees BEFORE tmux kill-session so
    # worker.sh → timeout → claude children receive SIGTERM while still
    # reachable via the pane shell's process group. Post-session pkill
    # catches any that already setsid'd (PPID=1 orphans).
    if [[ -f "$FLEET_PIDS_FILE" ]]; then
        echo "[run-fleet] cascade-killing fleet worker subtrees (INFRA-581): $FLEET_PIDS_FILE"
        while IFS= read -r _pid; do
            [[ "$_pid" =~ ^[0-9]+$ ]] || continue
            # Try process-group kill first (tmux panes typically get their own pgid).
            kill -TERM "-${_pid}" 2>/dev/null || true
            # Also kill direct children in case pgid differs.
            pkill -TERM -P "$_pid" 2>/dev/null || true
            kill -TERM "$_pid" 2>/dev/null || true
        done < "$FLEET_PIDS_FILE"
        rm -f "$FLEET_PIDS_FILE"
    fi
    if tmux has-session -t "$FLEET_SESSION" 2>/dev/null; then
        echo "[run-fleet] tearing down tmux session: $FLEET_SESSION"
        tmux kill-session -t "$FLEET_SESSION"
    else
        echo "[run-fleet] no session named $FLEET_SESSION; nothing to do."
    fi
    # Belt-and-suspenders: pkill any timeout+claude orphans that setsid'd
    # before the SIGTERM above reached them (INFRA-581).
    pkill -f "timeout [0-9]*s claude -p " 2>/dev/null || true
    exit 0
fi

# Sanity checks before we open tmux.
if ! command -v tmux >/dev/null 2>&1; then
    echo "[run-fleet] ERROR: tmux not on PATH (brew install tmux)" >&2
    exit 1
fi
if [[ "$FLEET_BACKEND" == "claude" ]] && ! command -v claude >/dev/null 2>&1; then
    echo "[run-fleet] ERROR: claude CLI not on PATH (required for FLEET_BACKEND=claude)" >&2
    exit 1
fi
if [ ! -x "$SCRIPT_DIR/worker.sh" ]; then
    echo "[run-fleet] ERROR: $SCRIPT_DIR/worker.sh not executable" >&2
    exit 1
fi
if tmux has-session -t "$FLEET_SESSION" 2>/dev/null; then
    echo "[run-fleet] ERROR: tmux session '$FLEET_SESSION' already exists." >&2
    echo "  Stop it first:  tmux kill-session -t $FLEET_SESSION" >&2
    echo "  Or attach:      tmux attach -t $FLEET_SESSION" >&2
    exit 2
fi

# INFRA-539 / CREDIBLE-032: probe GitHub API before spawning workers.
# Emits kind=gh_missing if gh binary absent, kind=gh_errored if API call fails.
# Backward-compat: kind=github_unreachable also emitted alongside gh_errored.
# Bypass: CHUMP_GH_PROBE_SKIP=1 (air-gapped, mock environments).
if [[ "${CHUMP_GH_PROBE_SKIP:-0}" != "1" && "$FLEET_DRY_RUN" != "1" ]]; then
    _gh_probe_amb="${CHUMP_AMBIENT_LOG:-$FLEET_LOCKS_DIR/ambient.jsonl}"
    mkdir -p "$(dirname "$_gh_probe_amb")" 2>/dev/null || true
    _gh_probe_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    if ! command -v gh >/dev/null 2>&1; then
        echo "[run-fleet] CREDIBLE-032: gh binary not found — halting fleet launch" >&2
        printf '{"ts":"%s","kind":"gh_missing","source":"run-fleet","note":"gh binary not in PATH — CREDIBLE-032"}\n' \
            "$_gh_probe_ts" >> "$_gh_probe_amb" 2>/dev/null || true
        exit 1
    fi

    # RESILIENT-264: the gh probe is a convenience pre-check — every worker
    # re-checks its own gh auth before each push/merge (worker.sh). So a SINGLE
    # transient probe failure (rate-limit blip / API slowness / cold exit-124 at
    # the launch moment) must NOT abort the entire fleet launch with 0 panes.
    # Mirror the sibling auth-probe hardening (:INFRA-621 below): retry N times
    # with a short backoff and succeed on the first green one, and honor
    # CHUMP_FLEET_FORCE_LAUNCH=1 as proceed-with-warning on terminal failure.
    # Precedent: 2026-08-09 — 6/6 launches aborted here on transient gh blips
    # while the single-shot `exit 1` gate ignored FORCE_LAUNCH entirely.
    _gh_probe_rc=1
    _gh_probe_attempts="${CHUMP_FLEET_GH_PROBE_ATTEMPTS:-3}"
    for _gh_attempt in $(seq 1 "$_gh_probe_attempts"); do
        _gh_probe_rc=0
        timeout "${CHUMP_GH_PROBE_TIMEOUT:-10}" gh api /rate_limit --silent 2>/dev/null || _gh_probe_rc=$?
        [[ $_gh_probe_rc -eq 0 ]] && break
        if [[ "$_gh_attempt" -lt "$_gh_probe_attempts" ]]; then
            echo "[run-fleet] CREDIBLE-032: gh probe attempt $_gh_attempt/$_gh_probe_attempts failed (rc=$_gh_probe_rc); retrying in 3s..." >&2
            sleep 3
        fi
    done
    if [[ $_gh_probe_rc -ne 0 ]]; then
        echo "[run-fleet] CREDIBLE-032: gh API call failed (exit=${_gh_probe_rc}) after ${_gh_probe_attempts} attempts" >&2
        printf '{"ts":"%s","kind":"gh_errored","source":"run-fleet","exit_code":%d,"note":"gh api /rate_limit failed after retries — CREDIBLE-032/RESILIENT-264"}\n' \
            "$_gh_probe_ts" "$_gh_probe_rc" >> "$_gh_probe_amb" 2>/dev/null || true
        # backward-compat alias
        printf '{"ts":"%s","kind":"github_unreachable","source":"run-fleet","exit_code":%d,"note":"alias for gh_errored — CREDIBLE-032"}\n' \
            "$_gh_probe_ts" "$_gh_probe_rc" >> "$_gh_probe_amb" 2>/dev/null || true
        if [[ "${CHUMP_FLEET_FORCE_LAUNCH:-0}" != "1" ]]; then
            echo "[run-fleet] CREDIBLE-032: halting fleet launch (set CHUMP_FLEET_FORCE_LAUNCH=1 to proceed anyway — workers re-check gh themselves)" >&2
            exit 1
        else
            echo "[run-fleet] WARNING: CHUMP_FLEET_FORCE_LAUNCH=1 — proceeding despite gh probe failure (RESILIENT-264)" >&2
        fi
    else
        echo "[run-fleet] INFRA-539: GitHub API reachable — proceeding"
    fi
fi

# CREDIBLE-390 (CREDIBLE-130 slice): classify a probe error string into one
# of four discrete classes so callers stop conflating "billing exhausted"
# with "credentials invalid" (the 2026-06-08 auth-dead false-positive — a
# valid API key on a zero-balance account was reported as "authentication
# failed" and sent the on-call down an auth/flag/lease rabbit hole before a
# direct probe revealed the real cause was credit exhaustion). Order matters:
# billing/credit-exhaustion phrases must be checked BEFORE the generic
# 401/unauthorized check, since a credit-exhausted response can also carry a
# 401-shaped envelope depending on provider.
#
# CREDIBLE-449 (CREDIBLE-130 slice, filed after this landed) re-asked for the
# same three ACs — parse probe error body/status into auth-invalid vs
# credit-exhausted vs rate-limit vs network, with test coverage. Verified
# 2026-09-02 that classify_probe_error() below already satisfies all three
# (see scripts/ci/test-run-fleet-error-classification.sh, 10/10 passing);
# closed as duplicate rather than re-implementing.
#   echoes one of: auth-invalid | credit-exhausted | rate-limit | network
classify_probe_error() {
    local out="$1"
    local lower
    lower="$(tr '[:upper:]' '[:lower:]' <<<"$out")"

    if grep -qiE 'credit balance is too low|credit_limit|credit limit|insufficient quota|insufficient_quota|payment required|\b402\b|billing' <<<"$lower"; then
        echo "credit-exhausted"
        return
    fi
    if grep -qiE '\b429\b|rate.?limit|too many requests|overloaded_error|rate_limit_error' <<<"$lower"; then
        echo "rate-limit"
        return
    fi
    if grep -qiE 'could not resolve host|connection refused|econnrefused|network is unreachable|timed out|timeout|dns|no route to host|connection reset' <<<"$lower"; then
        echo "network"
        return
    fi
    if grep -qiE '\b401\b|unauthorized|invalid.*(api.?key|token)|authentication_error|permission_error|invalid x-api-key' <<<"$lower"; then
        echo "auth-invalid"
        return
    fi
    echo "auth-invalid"
}

# INFRA-621: launch-time auth verification. Probe the detected auth path with
# a minimal claude call to ensure credentials are valid before spawning workers.
# This catches misconfigurations early (e.g., expired OAUTH token, invalid API key)
# and emits a clear diagnostic to ambient.jsonl.
mkdir -p "$FLEET_LOG_DIR"
_amb_log="${CHUMP_AMBIENT_LOG:-$FLEET_LOCKS_DIR/ambient.jsonl}"
mkdir -p "$(dirname "$_amb_log")" 2>/dev/null || true

_auth_probe_failed=0
_auth_probe_error=""

if [[ "$FLEET_BACKEND" == "claude" ]]; then
    echo "[run-fleet] INFRA-621: probing auth path ($_fleet_auth_path)..."
    # CREDIBLE-138: the probe is a convenience pre-check — every worker
    # re-validates its own auth before each claude -p spawn (worker.sh
    # refresh_oauth_token, CREDIBLE-137). So a SINGLE transient probe failure
    # (rate-limit / concurrent-claude contention at launch / cold-start beyond
    # the old 30s budget) must NOT abort the entire fleet launch with 0 panes.
    # Retry up to N attempts with a short backoff and succeed on the first green
    # one. Two further hardenings vs the original `timeout 30 claude -p ok`:
    #  - 90s timeout: claude -p cold-start under launch-moment load spikes past 30s.
    #  - on the subscription path, probe with ANTHROPIC_API_KEY unset so we test
    #    the OAuth credential workers actually use, never a key claude prefers but
    #    that may be depleted ("Credit balance is too low") — same trap as worker.sh.
    _probe_rc=1
    _probe_out=""
    _probe_attempts="${CHUMP_FLEET_PROBE_ATTEMPTS:-3}"
    for _attempt in $(seq 1 "$_probe_attempts"); do
        if [[ "$_fleet_auth_mode" == "subscription" ]]; then
            _probe_out=$(env -u ANTHROPIC_API_KEY timeout 90 claude -p "ok" 2>&1) && _probe_rc=0 || _probe_rc=$?
        else
            _probe_out=$(timeout 90 claude -p "ok" 2>&1) && _probe_rc=0 || _probe_rc=$?
        fi
        [[ $_probe_rc -eq 0 ]] && break
        if [[ "$_attempt" -lt "$_probe_attempts" ]]; then
            echo "[run-fleet] INFRA-621: probe attempt $_attempt/$_probe_attempts failed (rc=$_probe_rc); retrying in 3s..." >&2
            sleep 3
        fi
    done

    # RESILIENT-088: a 404/model-not-found error means the API rejected the
    # *model* the probe (or claude's own default resolution) picked, not the
    # credentials — Anthropic authenticates the request before it looks up
    # the model, so reaching a 404 at all is itself proof auth was accepted.
    # Retired model IDs 404 identically for valid and invalid keys, so the
    # old code (any non-zero probe rc == auth failure) misread "model gone"
    # as "credentials bad" and halted the fleet on perfectly good auth.
    if [[ $_probe_rc -ne 0 ]] && grep -qiE '404|model_not_found|not_found_error|no such model|model[^0-9a-z]*(not found|does not exist)' <<<"$_probe_out" 2>/dev/null; then
        echo "[run-fleet] INFRA-621/RESILIENT-088: probe got model-not-found (404), not an auth failure — treating as auth-OK"
        _probe_rc=0
    fi

    if [[ $_probe_rc -eq 0 ]]; then
        echo "[run-fleet] INFRA-621: auth probe succeeded"
        printf '{"ts":"%s","kind":"fleet_auth_verified","auth_mode":"%s","auth_path":"%s"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            "$_fleet_auth_mode" "$_fleet_auth_path" \
            >> "$_amb_log" 2>/dev/null || true
    else
        _auth_probe_failed=1

        # CREDIBLE-390: classify the failure into a discrete class BEFORE
        # generating the operator-facing message, so credit-exhaustion never
        # gets mislabeled as an auth failure (CREDIBLE-130).
        _probe_error_class="$(classify_probe_error "$_probe_out")"

        if [[ "$_probe_error_class" == "credit-exhausted" ]]; then
            _auth_probe_error="Credit balance is too low on this account (not a credentials problem — auth accepted, billing exhausted). Top up credits, or switch CHUMP_AUTH_MODE to use a different auth path."
        elif [[ "$_probe_error_class" == "rate-limit" ]]; then
            _auth_probe_error="Anthropic API rate limit hit during the launch probe. This is transient — retry launch, or reduce fleet concurrency."
        elif [[ "$_probe_error_class" == "network" ]]; then
            _auth_probe_error="Network error reaching the Anthropic API (not a credentials problem). Check connectivity and retry."
        elif [[ "$_fleet_auth_mode" == "subscription" ]]; then
            _auth_probe_error="CLAUDE_CODE_OAUTH_TOKEN is expired or invalid. Refresh your subscription credentials."
        elif [[ "$_fleet_auth_mode" == "api_key" ]]; then
            _auth_probe_error="ANTHROPIC_API_KEY is invalid or has insufficient permissions."
        elif [[ "$_fleet_auth_mode" == "unknown" ]]; then
            _auth_probe_error="No auth credentials found. Set ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN."
        else
            _auth_probe_error="Auth probe failed: $_probe_out"
        fi

        # Check for conflicting auth setup (both set but one is empty).
        # Only relevant to the auth-invalid class — credit/rate-limit/network
        # failures aren't fixed by switching auth path.
        if [[ "$_probe_error_class" == "auth-invalid" ]]; then
            if [[ -n "${ANTHROPIC_API_KEY:-}" && -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]] \
                && [[ "$_fleet_auth_mode" != "api_key" ]]; then
                _auth_probe_error="$_auth_probe_error (hint: ANTHROPIC_API_KEY is set but appears invalid; unset it if you want to use OAUTH token instead)"
            fi
            if [[ -z "${ANTHROPIC_API_KEY:-}" && -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]] \
                && [[ "$_fleet_auth_mode" != "subscription" ]]; then
                _auth_probe_error="$_auth_probe_error (hint: CLAUDE_CODE_OAUTH_TOKEN is set but appears invalid; unset it if you want to use API key instead)"
            fi
        fi

        echo "[run-fleet] ERROR: INFRA-621: auth probe failed (class=$_probe_error_class)" >&2
        echo "[run-fleet]   $_auth_probe_error" >&2
        # shellcheck disable=SC2001  # sed needed for correct quoting in JSON context
        printf '{"ts":"%s","kind":"fleet_auth_misconfigured","auth_mode":"%s","auth_path":"%s","error_class":"%s","error":"%s"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            "$_fleet_auth_mode" "$_fleet_auth_path" "$_probe_error_class" \
            "$(echo "$_auth_probe_error" | sed 's/"/""/g')" \
            >> "$_amb_log" 2>/dev/null || true

        # CREDIBLE-130 AC3: credit-exhaustion also gets its own distinct kind
        # (separate from fleet_auth_misconfigured) so operator-recall and any
        # other ambient consumer can route on it without needing to parse the
        # error_class field out of a generically-named auth event. This is the
        # signal that would have short-circuited the 2026-06-08 misdiagnosis —
        # a consumer watching for fleet_auth_* kinds alone would still not see
        # this as an auth problem.
        if [[ "$_probe_error_class" == "credit-exhausted" ]]; then
            printf '{"ts":"%s","kind":"fleet_credit_exhausted","auth_mode":"%s","auth_path":"%s","error":"%s"}\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                "$_fleet_auth_mode" "$_fleet_auth_path" \
                "$(echo "$_auth_probe_error" | sed 's/"/""/g')" \
                >> "$_amb_log" 2>/dev/null || true
        fi

        if [[ "${CHUMP_FLEET_FORCE_LAUNCH:-0}" != "1" ]]; then
            exit 3
        else
            echo "[run-fleet] WARNING: CHUMP_FLEET_FORCE_LAUNCH=1 — proceeding despite auth probe failure"
        fi
    fi
fi

# INFRA-519: reap stale fleet-* leases before spawning new panes.
# tmux-kill bypasses worker.sh exit-cleanup, leaving orphaned lease files whose
# PIDs are no longer alive. Stale leases block the picker (treated as live
# within TTL), starving a fresh fleet of pickable gaps.
# session_id format: fleet-<FLEET_SESSION>-agent<N>-<PID>-<epoch>
# PID is the second-to-last dash-separated field — safe even if FLEET_SESSION
# contains dashes because the trailing <PID>-<epoch> suffix is always numeric.
_stale_reaped=0
for _lease in "$FLEET_LOCKS_DIR"/fleet-*.json; do
    [[ -f "$_lease" ]] || continue
    _sid="$(basename "$_lease" .json)"
    _pid="$(printf '%s' "$_sid" | rev | cut -d- -f2 | rev)"
    if [[ "$_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$_pid" 2>/dev/null; then
        echo "[run-fleet] reaping stale lease (pid $_pid dead): $(basename "$_lease")"
        rm -f "$_lease"
        (( _stale_reaped++ )) || true
    fi
done
if (( _stale_reaped > 0 )); then
    echo "[run-fleet] reaped $_stale_reaped stale fleet lease(s) — picker unblocked"
fi

# INFRA-465: seed state.db before spawning workers so fresh worktrees have
# pickable gaps. Compare state.db open-gap count against origin/main's
# state.sql line count as a cheap drift signal; run 'chump gap import' if
# state.db appears empty or behind. chump gap import is idempotent (skips
# already-present rows) so running it on an up-to-date db is safe.
_db="$REPO_ROOT/.chump/state.db"
_db_open=0
if command -v sqlite3 >/dev/null 2>&1 && [[ -f "$_db" ]]; then
    _db_open=$(sqlite3 "$_db" "SELECT COUNT(*) FROM gaps WHERE status='open';" 2>/dev/null || echo 0)
fi
# Count open gaps visible on origin/main via the tracked state.sql mirror.
# grep -c prints "0" AND exits 1 on zero-match; the old `|| true` then wrote a
# SECOND "0", yielding "0\n0" and a `((` syntax error (VOA-004). Capture the count
# as-is and default only if the whole expansion is empty.
# Registry privacy: the mirror is published to the private `registry` remote;
# origin/main only carries it in the legacy (pre-cutover) layout.
_reg_ref="origin/main"
git -C "$REPO_ROOT" remote get-url registry >/dev/null 2>&1 && _reg_ref="registry/main"
_sql_open=$(git -C "$REPO_ROOT" show "${_reg_ref}:.chump/state.sql" 2>/dev/null | grep -c "^INSERT.*'open'" 2>/dev/null)
_sql_open=${_sql_open:-0}
if (( _db_open < _sql_open )); then
    echo "[run-fleet] INFRA-465: state.db has $_db_open open gaps, origin/main has $_sql_open — running 'chump gap import'"
    (cd "$REPO_ROOT" && chump gap import) \
        && echo "[run-fleet] gap import complete — state.db seeded" \
        || echo "[run-fleet] WARNING: 'chump gap import' failed; workers may see no pickable gaps"
else
    echo "[run-fleet] state.db looks current ($_db_open open gaps) — skipping import"
fi

cat <<EOF
[run-fleet] starting fleet
  session       : $FLEET_SESSION
  size          : $FLEET_SIZE
  timeout/agent : ${FLEET_TIMEOUT_S}s
  priority      : $FLEET_PRIORITY_FILTER
  domain        : ${FLEET_DOMAIN_FILTER:-<any>}
  agent-domains : ${FLEET_AGENT_DOMAINS:-<uniform>}
  effort        : $FLEET_EFFORT_FILTER
  log dir       : $FLEET_LOG_DIR
  backend       : $FLEET_BACKEND
  CARGO_TARGET_DIR : $CHUMP_CARGO_TARGET_ROOT/group-<N> (groups of $CHUMP_CARGO_TARGET_GROUP_SIZE, INFRA-3662)
EOF

if [ "$FLEET_DRY_RUN" = "1" ]; then
    echo "[run-fleet] FLEET_DRY_RUN=1 — exiting before tmux."
    exit 0
fi

# Build the worker env once; passed into every pane via the launch command.
# INFRA-417: API keys must be in this list explicitly. INFRA-351 sources
# .env into the launcher process, but `tmux split-window` runs the new
# pane under the long-lived tmux server (not the launcher) — exported
# vars in the launcher do NOT propagate. Without these lines, claude -p
# in the worker pane falls back to the user's claude.ai subscription
# cap instead of consuming workspace API credit, the exact failure mode
# INFRA-351 set out to fix.

# INFRA-620: emit fleet_auth_mode ambient event so operators can see which
# auth path workers are using, and diagnose the subscription-token-expiry
# failure mode (auth_storm at T+30-60min after launch).
_amb_log="${CHUMP_AMBIENT_LOG:-$FLEET_LOCKS_DIR/ambient.jsonl}"
mkdir -p "$(dirname "$_amb_log")" 2>/dev/null || true
printf '{"ts":"%s","kind":"fleet_auth_mode","auth_mode":"%s","auth_path":"%s","sdk_has_refresh":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$_fleet_auth_mode" "$_fleet_auth_path" \
    "${CLAUDE_CODE_SDK_HAS_OAUTH_REFRESH:-0}" \
    >> "$_amb_log" 2>/dev/null || true
echo "[run-fleet] INFRA-620: auth_mode=$_fleet_auth_mode auth_path=$_fleet_auth_path"

# INFRA-620: subscription-mode token refresh setup. Write current token to
# a well-known file; start a background refresher; workers re-read before
# each claude -p spawn instead of using the stale inherited env value.
_oauth_token_file=""
if [[ "$_fleet_auth_mode" == "subscription" ]]; then
    _oauth_token_file="$HOME/.chump/oauth-token.json"
    mkdir -p "$HOME/.chump"
    chmod 700 "$HOME/.chump" 2>/dev/null || true
    printf '{"token":"%s","written_at":"%s","source":"launch_env"}\n' \
        "$CLAUDE_CODE_OAUTH_TOKEN" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$_oauth_token_file"
    chmod 600 "$_oauth_token_file"
    echo "[run-fleet] INFRA-620: wrote oauth token snapshot → $_oauth_token_file"

    # Background token refresher: every 5 min, try to extract the current
    # oauth token (the parent Claude Code app refreshes it in-process; we
    # probe macOS keychain and known Claude CLI credential paths). On
    # success, atomically replace the token file so workers pick it up on
    # their next spawn. On failure, the file retains the last good token and
    # workers fall back to ANTHROPIC_API_KEY when that token also expires.
    (
        _tf="$_oauth_token_file"
        _amb="$_amb_log"
        while true; do
            sleep 300
            # RESILIENT-159: self-exit when the fleet session is gone. Without this
            # the refresher loops `sleep 300` FOREVER after the fleet dies or never
            # comes up — orphaning to PPID 1 (this was the 49-orphan leak that the
            # always-on keeper would have amplified). First check is 300s in, by
            # which point a successful launch has created the session; revival is
            # the fleet-autopilot keeper's job (RESILIENT-158), not this loop's.
            tmux has-session -t "$FLEET_SESSION" 2>/dev/null || exit 0
            _refreshed=""
            # 1. Try macOS Keychain (service names used by claude CLI).
            for _svc in "Claude Code" "claude.ai" "Claude"; do
                _refreshed=$(security find-generic-password -s "$_svc" -w 2>/dev/null || true)
                [[ -n "$_refreshed" ]] && break
            done
            # 2. Try well-known credential files written by Claude CLI.
            if [[ -z "$_refreshed" ]]; then
                for _cred in \
                    "$HOME/.claude/.credentials.json" \
                    "$HOME/.config/claude/credentials.json"
                do
                    if [[ -f "$_cred" ]]; then
                        _refreshed=$(python3 -c "
import json, sys
try:
    d = json.load(open('$_cred'))
    t = d.get('access_token') or d.get('token') or d.get('claudeAiOauthToken','')
    print(t)
except Exception:
    pass
" 2>/dev/null || true)
                        [[ -n "$_refreshed" ]] && break
                    fi
                done
            fi
            if [[ -n "$_refreshed" ]]; then
                printf '{"token":"%s","written_at":"%s","source":"refresher"}\n' \
                    "$_refreshed" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                    > "${_tf}.tmp"
                mv "${_tf}.tmp" "$_tf"
                printf '{"ts":"%s","kind":"fleet_oauth_token_refreshed","source":"refresher"}\n' \
                    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$_amb" 2>/dev/null || true
            fi
        done
    ) &
    _token_refresher_pid=$!
    # Track refresher so FLEET_SIZE=0 teardown can kill it.
    mkdir -p "$(dirname "$FLEET_PIDS_FILE")"
    echo "$_token_refresher_pid" >> "$FLEET_PIDS_FILE"
    echo "[run-fleet] INFRA-620: token refresher started (pid=$_token_refresher_pid, interval=300s)"
fi

worker_env=(
    "REPO_ROOT=$REPO_ROOT"
    # INFRA-634: propagate cross-repo overrides to workers
    ${CHUMP_REPO:+"CHUMP_REPO=$CHUMP_REPO"}
    "FLEET_LOCKS_DIR=$FLEET_LOCKS_DIR"
    "FLEET_LOG_DIR=$FLEET_LOG_DIR"
    "FLEET_TIMEOUT_S=$FLEET_TIMEOUT_S"
    "FLEET_PRIORITY_FILTER=$FLEET_PRIORITY_FILTER"
    "FLEET_DOMAIN_FILTER=$FLEET_DOMAIN_FILTER"
    "FLEET_AGENT_DOMAINS=$FLEET_AGENT_DOMAINS"
    "FLEET_EFFORT_FILTER=$FLEET_EFFORT_FILTER"
    "FLEET_BACKEND=$FLEET_BACKEND"
    "FLEET_MODEL=${FLEET_MODEL:-}"
    # INFRA-461: pass FLEET_SESSION so worker.sh can build a unique
    # CHUMP_SESSION_ID per pane and not stomp the operator's interactive
    # lease via the .wt-session-id fallback.
    "FLEET_SESSION=$FLEET_SESSION"
    # INFRA-623: workers inherit launch epoch so fleet-restart --refresh-auth
    # can compare oauth-token.json mtime against fleet start time.
    "FLEET_START_EPOCH=$FLEET_START_EPOCH"
    # INFRA-3662: NOT setting CARGO_TARGET_DIR here on purpose — a single
    # fleet-wide value here would apply to every worker regardless of the
    # per-group override computed in the spawn loop below (last assignment
    # on the command line wins, but omitting it entirely avoids relying on
    # that ordering). Each worker gets CARGO_TARGET_DIR=<group dir> injected
    # per-pane in the spawn loop instead.
    # INFRA-371 token-burn defaults
    "FLEET_INLINE_BRIEFING=$FLEET_INLINE_BRIEFING"
    "CHUMP_LESSONS_AT_SPAWN_N=$CHUMP_LESSONS_AT_SPAWN_N"
    "CHUMP_AMBIENT_INSTALL_SKIP=$CHUMP_AMBIENT_INSTALL_SKIP"
    # INFRA-1052: harness attribution — FLEET_HARNESS set by `chump fleet start --harness`;
    # defaults to "fleet-dispatcher" for back-compat when not specified.
    "CHUMP_AGENT_HARNESS=${FLEET_HARNESS:-fleet-dispatcher}"
    # INFRA-417 API keys — only added when actually set in the launcher
    # env (so we don't pollute panes with empty values that would mask a
    # legitimately-set system-level key).
    ${ANTHROPIC_API_KEY:+"ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY"}
    ${OPENAI_API_KEY:+"OPENAI_API_KEY=$OPENAI_API_KEY"}
    ${TOGETHER_API_KEY:+"TOGETHER_API_KEY=$TOGETHER_API_KEY"}
    ${GROQ_API_KEY:+"GROQ_API_KEY=$GROQ_API_KEY"}
    ${MISTRAL_API_KEY:+"MISTRAL_API_KEY=$MISTRAL_API_KEY"}
    ${FIREWORKS_API_KEY:+"FIREWORKS_API_KEY=$FIREWORKS_API_KEY"}
    # INFRA-620: subscription oauth token refresh. Pass the token file path
    # so workers can re-read the current token before each claude -p spawn.
    # In subscription mode, explicitly clear the inherited CLAUDE_CODE_OAUTH_TOKEN
    # so workers don't silently use the stale launch-time value — they must
    # re-read from the file (which the background refresher keeps current).
    ${_oauth_token_file:+"CHUMP_OAUTH_TOKEN_FILE=$_oauth_token_file"}
    ${_oauth_token_file:+"CLAUDE_CODE_OAUTH_TOKEN="}
    # INFRA-2310: consensus merge gate SHADOW mode — passed to every worker that
    # calls bot-merge.sh.  =1 means log-only (kind=consensus_gate_would_block);
    # it NEVER blocks a merge.  Operator sets =enforce after ~7-day observation.
    # Operator's personal shell rc is NOT modified by this change; add
    # CHUMP_CONSENSUS_MERGE_GATE=1 there manually to cover interactive invocations.
    "CHUMP_CONSENSUS_MERGE_GATE=${CHUMP_CONSENSUS_MERGE_GATE:-1}"
)
env_prefix="$(printf '%s ' "${worker_env[@]}")"

# Pane 0 is the control pane (status dashboard). Agents start at index 1.
tmux new-session -d -s "$FLEET_SESSION" -n fleet -c "$REPO_ROOT" \
    "${env_prefix} FLEET_SESSION=$FLEET_SESSION FLEET_SIZE=$FLEET_SIZE $SCRIPT_DIR/control.sh"

mkdir -p "$(dirname "$FLEET_PIDS_FILE")"
# Truncate any stale pids file from a prior run of the same session name.
: > "$FLEET_PIDS_FILE"

# INFRA-602: orphan-reaper sentinel. Runs outside tmux; polls until the fleet
# session disappears (for ANY reason — kill-session, server crash, Ctrl-C), then
# pkills any surviving timeout+claude workers. Covers the path FLEET_SIZE=0
# teardown misses: a raw `tmux kill-session` by the operator.
(
    while tmux has-session -t "$FLEET_SESSION" 2>/dev/null; do
        sleep 3
    done
    pkill -f "timeout [0-9]*s claude -p " 2>/dev/null || true
) &
_sentinel_pid=$!
echo "$_sentinel_pid" >> "$FLEET_PIDS_FILE"

# INFRA-611/INFRA-623: auto-restart daemon — watches ambient.jsonl for trigger
# conditions (currently: fleet_auth_storm) and restarts the fleet with fresh
# credentials when the threshold is reached.
if [[ -x "$SCRIPT_DIR/fleet-autorestart-daemon.sh" ]]; then
    FLEET_SESSION="$FLEET_SESSION" \
    FLEET_START_EPOCH="$FLEET_START_EPOCH" \
    CHUMP_AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$FLEET_LOCKS_DIR/ambient.jsonl}" \
    REPO_ROOT="$REPO_ROOT" \
    "$SCRIPT_DIR/fleet-autorestart-daemon.sh" &
    _daemon_pid=$!
    echo "$_daemon_pid" >> "$FLEET_PIDS_FILE"
    echo "[run-fleet] INFRA-611 autorestart daemon spawned (pid $_daemon_pid)"
fi

# INFRA-1622: the first PWA_WORKER_COUNT workers are PWA-tagged so
# _pick_and_claim_gap.py:492 can match them against PWA-prefixed gaps via the
# skills_required affinity. Without this, every worker is general-purpose and
# PWA gaps compete for attention with INFRA/CREDIBLE/RESILIENT work. Override
# the default by setting CHUMP_PWA_WORKERS=N at fleet launch (N=0 disables).
PWA_WORKER_COUNT="${CHUMP_PWA_WORKERS:-2}"

# INFRA-1697 (META-066 phase 4): immediately AFTER the PWA pool, tag the next
# CONTENT_BOT_WORKER_COUNT workers with WORKER_SKILLS=content-bot,pmm,docubot,
# evangelist,copybot so content-bot gaps (those with skills_required containing
# any of the bot IDs) preferentially route to dedicated workers. The Content
# Bots Suite is the productization layer (META-066) that runs alongside the
# engineering custodian on customer repos. Override default of 1 via
# CHUMP_CONTENT_BOT_WORKERS=N (0 disables, recommended for repos that haven't
# opted in to any content bots).
CONTENT_BOT_WORKER_COUNT="${CHUMP_CONTENT_BOT_WORKERS:-1}"
CONTENT_BOT_FIRST=$((PWA_WORKER_COUNT + 1))
CONTENT_BOT_LAST=$((PWA_WORKER_COUNT + CONTENT_BOT_WORKER_COUNT))

for i in $(seq 1 "$FLEET_SIZE"); do
    log="$FLEET_LOG_DIR/agent-${i}.log"
    worker_skills_env=""
    if [[ "$PWA_WORKER_COUNT" -gt 0 && "$i" -le "$PWA_WORKER_COUNT" ]]; then
        worker_skills_env="WORKER_SKILLS=pwa,frontend,javascript "
    elif [[ "$CONTENT_BOT_WORKER_COUNT" -gt 0 \
         && "$i" -ge "$CONTENT_BOT_FIRST" \
         && "$i" -le "$CONTENT_BOT_LAST" ]]; then
        worker_skills_env="WORKER_SKILLS=content-bot,pmm,docubot,evangelist,copybot "
    fi
    # INFRA-3662: group workers into CHUMP_CARGO_TARGET_GROUP_SIZE-sized
    # cohorts, each with its own CARGO_TARGET_DIR under CHUMP_CARGO_TARGET_ROOT.
    # Ends the fleet-wide shared-target fingerprint clobbering (INFRA-1138)
    # while keeping the group count bounded (FLEET_SIZE/N dirs, not FLEET_SIZE)
    # so combined disk footprint stays a small multiple of the old single dir.
    _group_idx=$(( (i - 1) / CHUMP_CARGO_TARGET_GROUP_SIZE + 1 ))
    _worker_target_dir="$CHUMP_CARGO_TARGET_ROOT/group-${_group_idx}"
    mkdir -p "$_worker_target_dir" 2>/dev/null || true
    cmd="${env_prefix}${worker_skills_env}CARGO_TARGET_DIR=$_worker_target_dir AGENT_ID=$i $SCRIPT_DIR/worker.sh 2>&1 | tee -a '$log'"
    tmux split-window -t "$FLEET_SESSION:fleet" -c "$REPO_ROOT" "$cmd"
    # INFRA-581: capture the newly-created pane's shell PID so teardown can
    # cascade-kill worker.sh → timeout → claude subtrees on FLEET_SIZE=0.
    _pane_pid="$(tmux display-message -t "$FLEET_SESSION:fleet" -p '#{pane_pid}' 2>/dev/null || true)"
    [[ "$_pane_pid" =~ ^[0-9]+$ ]] && echo "$_pane_pid" >> "$FLEET_PIDS_FILE"
    tmux select-layout -t "$FLEET_SESSION:fleet" tiled >/dev/null
done

tmux select-layout -t "$FLEET_SESSION:fleet" tiled >/dev/null
tmux select-pane -t "$FLEET_SESSION:fleet.0"

cat <<EOF
[run-fleet] fleet up.
  attach :  tmux attach -t $FLEET_SESSION
  stop   :  tmux kill-session -t $FLEET_SESSION
  logs   :  tail -f $FLEET_LOG_DIR/agent-*.log
EOF
