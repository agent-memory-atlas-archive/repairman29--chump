#!/usr/bin/env bash
# scripts/ops/node-converge.sh — RESILIENT-1189
#
# The NODE AUTO-CONVERGE organ. Keeps a fleet node's SOURCE checkout current
# with origin/main on a cadence, so a merged fix actually REACHES the iron —
# closing the "merged != deployed" loop for the whole class of BASH organs that
# a binary refresh can never deploy.
#
# WHY THIS EXISTS (the #1 systemic wound, confirmed live):
#   Nothing on the fleet converges the SOURCE checkout the organs run out of.
#   The one script that came close — scripts/ops/node-refresh-chump.sh — has a
#   binary-SHA idempotency short-circuit (RESILIENT-200): when the installed
#   `chump` binary already matches green-main it `exit 0`s BEFORE the
#   converge_mirror_hard_reset. A merged BASH-only fix (e.g. the rot-reaper fix
#   #4637, or any scripts/ops/*.sh / scripts/coord/*.sh edit) never bumps the
#   binary SHA, so node-refresh treats the node as "already current" and skips
#   the source reset entirely — the checkout stays days stale, and every organ
#   whose systemd ExecStart is `bash scripts/…/foo.sh` keeps running the OLD
#   script straight out of the stale tree. CJ's /home/jeff/Projects/chump had to
#   be hand `git reset --hard`'d to break exactly this.
#
# THE FIX — an UNCONDITIONAL, lightweight, gh-auth-INDEPENDENT source converge:
#   This organ does ONE thing on a ~10-min cadence: fetch origin/main and
#   `converge_mirror_hard_reset origin/main` (the RESILIENT-001 primitive) so
#   the working tree is byte-for-byte origin/main. It never builds, never pins
#   to green-main, never calls gh — a public-repo fetch needs no auth, and the
#   whole point is that this path can NEVER silently degrade the way
#   node-refresh's gh-dependent green-lookup does (RESILIENT-1040/1041). Once the
#   source is converged, the EXISTING organs do the rest: a bash organ's next
#   timer firing runs the new script straight from the converged tree, and any
#   changed *.service/.timer UNIT files are installed by the separate
#   chump-organ-deploy.timer / chump-organ-reconcile.timer. This organ is only
#   the missing FIRST hop — get the source current — that everything downstream
#   already assumed was happening.
#
# RELATION TO node-refresh-chump.sh (extend, don't duplicate): that script owns
#   the BINARY (build/pull/install + green-main pin); this organ owns the SOURCE
#   TREE. They converge to almost the same ref through the SAME shared primitive
#   (converge_mirror_hard_reset), so they cannot race to different states — and
#   this organ's unconditional reset covers the exact case node-refresh skips
#   (bash-only merges that leave the binary SHA unchanged).
#
# SAFETY (active-worker-safe by construction):
#   * Resets ONLY the main checkout ($REPO_ROOT). Workers build gaps in LINKED
#     git worktrees under .claude/worktrees/* — those have their own HEAD and
#     working tree, so a `git reset --hard` in the main checkout does not touch
#     them; and .claude/worktrees/ is gitignored, so the reset never sees it as
#     a collision to overwrite either. A worker's in-flight gap is untouched.
#   * converge_mirror_hard_reset is a `git reset --hard`, never a `git clean -x`,
#     so gitignored runtime state survives: .chump/state.db (+ -wal/-shm),
#     .chump-locks/, .claude/worktrees/, per-worktree target dirs. A live DB
#     write is not corrupted.
#   * DEFERS (clean skip, no reset) if a rebase / merge / cherry-pick / bisect is
#     in progress in the main checkout — never yanks the tree out from under an
#     operator or another organ mid-operation. It just tries again next tick.
#   * Idempotent: a tree already at origin/main is a no-op (node_converge_skipped).
#
# Emits (appended to $NODE_AMBIENT if its dir exists, else logfile only):
#   node_converged          — the checkout was behind and is now at origin/main
#   node_converge_skipped   — already current / no repo / operation-in-progress
#   node_converge_failed    — fetch-then-reset failed (tree left as-is)
#
# Env overrides:
#   CHUMP_NODE_REPO   source checkout to converge (default: first of
#                     ~/chump-host, ~/Projects/Chump, ~/chump that is a git repo)
#   NODE_AMBIENT      ambient stream to append to (default: <repo>/.chump-locks/ambient.jsonl)
#   CHUMP_NODE_CONVERGE_REF   ref to converge to (default: origin/main; test hook)
#   CHUMP_NODE_CONVERGE_REMOTE / CHUMP_NODE_CONVERGE_BRANCH
#                     remote + branch to fetch (default: origin / main)
#
# NOTE: this organ deliberately adds NO skip/bypass env var (the bypass-var debt
# ceiling is capped, INFRA-3625). If a node must not converge, disable the timer.

set -uo pipefail

_CONVERGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# RESILIENT-001: the shared jam-proof mirror-converge primitive. Source it so
# this organ converges through the SAME implementation as node-refresh-chump.sh
# and backlog-sync.sh --reader — none of the three can regress to a merge-based
# advance that aborts on an untracked docs/gaps/*.yaml collision. Fallback to a
# bare reset only if the lib is missing from a partial checkout.
# shellcheck source=../coord/lib/converge-mirror.sh
source "$_CONVERGE_DIR/../coord/lib/converge-mirror.sh" 2>/dev/null || true
if ! command -v converge_mirror_hard_reset >/dev/null 2>&1; then
    converge_mirror_hard_reset() { git reset --hard "${1:?}"; }
fi

# --- resolve the source checkout to converge ---------------------------------
REPO_ROOT="${CHUMP_NODE_REPO:-}"
if [[ -z "$REPO_ROOT" ]]; then
    for candidate in "$HOME/chump-host" "$HOME/Projects/Chump" "$HOME/chump"; do
        if [[ -d "$candidate/.git" ]]; then REPO_ROOT="$candidate"; break; fi
    done
fi

CONVERGE_REMOTE="${CHUMP_NODE_CONVERGE_REMOTE:-origin}"
CONVERGE_BRANCH="${CHUMP_NODE_CONVERGE_BRANCH:-main}"
CONVERGE_REF="${CHUMP_NODE_CONVERGE_REF:-${CONVERGE_REMOTE}/${CONVERGE_BRANCH}}"
NODE_AMBIENT="${NODE_AMBIENT:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

LOG_DIR="${CHUMP_NODE_CONVERGE_LOGDIR:-$HOME/.chump/node-converge-logs}"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG="$LOG_DIR/converge-$(date -u +%Y%m%dT%H%M%SZ).log"

# RESILIENT-1215: role-organ reconcile, wired the same way node-refresh-chump.sh
# wires it (RESILIENT-1035/1205) — this organ is the FIRST hop to actually land
# a merge on the source tree, so it is also the earliest point a newly-merged
# organ (manifest line + installer roster entry) can reach the installer. Without
# this, a node whose binary SHA is unchanged (bash-only merge) waits on the
# separate, slower chump-organ-reconcile.timer cadence instead of picking up the
# organ the instant this tick's converge lands it.
if [[ -z "${CHUMP_NODE_ROLE:-}" ]]; then
    _nc_node_env="${CHUMP_STATE_DIR:-${HOME:-/root}/.chump}/node.env"
    [[ -f "$_nc_node_env" ]] && CHUMP_NODE_ROLE="$(grep -E '^(export )?CHUMP_NODE_ROLE=' "$_nc_node_env" 2>/dev/null | tail -1 | sed -E 's/^(export )?CHUMP_NODE_ROLE=//; s/^"(.*)"$/\1/')"
    [[ -z "${CHUMP_NODE_ROLE:-}" ]] && unset CHUMP_NODE_ROLE
fi
NODE_ROLE="${CHUMP_NODE_ROLE:-muscle}"
_reconcile_role_organs() {
    local installer="$REPO_ROOT/scripts/setup/chump-node-install.sh"
    if [[ ! -f "$installer" ]]; then
        log "WARN: $installer not found; skipping role-organ reconcile"
        return 0
    fi
    # RESILIENT-1615: never reconcile organs into a second scope.
    if ! _nc_second_scope_ok; then
        log "SKIP: refusing organ reconcile — a chump install exists in another scope (see node_second_scope_refused)"
        return 0
    fi
    if CHUMP_NODE_REPO="$REPO_ROOT" CHUMP_STATE_DIR="${CHUMP_STATE_DIR:-$HOME/.chump}" \
         bash "$installer" --role "$NODE_ROLE" --reconcile-organs-only >>"$LOG" 2>&1; then
        log "OK: role-organ reconcile complete (role=$NODE_ROLE)"
        emit node_organs_reconciled "\"role\":\"$NODE_ROLE\""
    else
        log "WARN: chump-node-install.sh --reconcile-organs-only exited non-zero (non-fatal, role=$NODE_ROLE)"
        emit node_organs_reconcile_failed "\"role\":\"$NODE_ROLE\""
    fi
}

emit() {
    local kind="$1" extra="${2:-}"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local line
    if [[ -n "$extra" ]]; then line="{\"ts\":\"$ts\",\"kind\":\"$kind\",$extra}"
    else line="{\"ts\":\"$ts\",\"kind\":\"$kind\"}"; fi
    [[ -d "$(dirname "$NODE_AMBIENT")" ]] && printf '%s\n' "$line" >> "$NODE_AMBIENT" 2>/dev/null || true
    printf '[%s] %s %s\n' "$ts" "$kind" "$extra" >> "$LOG"
}
log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG"; }

# RESILIENT-1615: honor a node pause BEFORE any mutation. A paused node must
# converge/install/restart NOTHING — the cuphead receipt (2026-10-17 04:41Z)
# was converge re-enabling 42 timers on a node the operator had paused. Detect
# the pause three ways, all of which `chump node pause` / the stopgap set:
#   * CHUMP_NODE_MODE=paused in node.env
#   * the .chump/fleet-paused sentinel
#   * CHUMP_NODE_WORK_ENABLED=0 (the 2026-10-17 hand-edit, honored for compat)
# Emit organ_skipped_paused once and exit 0 before touching a single unit.
_nc_paused() {
    local sd="${CHUMP_STATE_DIR:-${HOME:-/root}/.chump}"
    [[ -f "$sd/.chump/fleet-paused" ]] && return 0
    local ne="$sd/node.env"
    if [[ -f "$ne" ]]; then
        grep -Eq '^(export )?CHUMP_NODE_MODE=paused([[:space:]]|$)' "$ne" && return 0
        grep -Eq '^(export )?CHUMP_NODE_WORK_ENABLED=0([[:space:]]|$)' "$ne" && return 0
    fi
    [[ "${CHUMP_NODE_WORK_ENABLED:-}" == "0" ]] && return 0
    [[ "${CHUMP_NODE_MODE:-}" == "paused" ]] && return 0
    return 1
}
if _nc_paused; then
    log "SKIP: node is paused (CHUMP_NODE_MODE=paused / fleet-paused sentinel / CHUMP_NODE_WORK_ENABLED=0) — converging and installing nothing this tick"
    emit organ_skipped_paused "\"organ\":\"node-converge\",\"reason\":\"node_paused\""
    exit 0
fi

# RESILIENT-1615: a chump install in a SECOND supervisor scope means another
# fleet owns this box (cuphead ran a root/system-scope install for 24 days
# alongside the ubuntu user-scope one). Refuse to (re)install organs into a
# second scope. Resolves a chump binary (PATH, then the repo's built target)
# and defers to `chump node scopes --install-guard`, which emits
# kind=node_second_scope_refused when the OTHER scope already has an install.
_nc_second_scope_ok() {
    local chump
    chump="$(command -v chump 2>/dev/null || true)"
    [[ -z "$chump" && -x "$REPO_ROOT/target/release/chump" ]] && chump="$REPO_ROOT/target/release/chump"
    [[ -z "$chump" && -x "$REPO_ROOT/target/debug/chump" ]] && chump="$REPO_ROOT/target/debug/chump"
    [[ -z "$chump" ]] && return 0   # best-effort: no binary to check with yet
    "$chump" node scopes --install-guard >>"$LOG" 2>&1
}

# RESILIENT-1453: restart a running worker whose worker.sh changed under it.
# This organ hard-resets the SOURCE tree to origin/main, but the long-running
# chump-node*-worker.service was exec'd ONCE at service start and never reloads
# code. worker.sh's own in-process re-exec (RESILIENT-1450) only fires between
# gaps, so a merged worker.sh fix stays inert for the entire duration of an
# in-flight gap (the "merged != running" disease). This organ already runs on a
# ~10min timer with passwordless sudo, so it is the right place to bounce the
# worker EXTERNALLY the instant the tracked worker.sh content changes. The worker
# handles SIGTERM with a WIP checkpoint (INFRA-686), so an external restart is safe
# at any point. Host-agnostic: discovers the active chump-node*-worker.service unit
# rather than hard-coding node1.
WORKER_SH="$REPO_ROOT/scripts/dispatch/worker.sh"
WORKER_STAMP="$REPO_ROOT/.chump-locks/worker-code.stamp"
WORKER_RESTART_MARKER="$REPO_ROOT/.chump-locks/worker-restart.marker"
_worker_code_hash() { sha256sum "$WORKER_SH" 2>/dev/null | cut -d' ' -f1; }
_maybe_restart_stale_workers() {
    # $1: "reset_changed" when THIS converge's reset just changed worker.sh (a
    #     definitive signal that needs no cooperation from the worker). Otherwise
    #     fall back to the worker's own stamp (what it is executing) vs disk.
    local definitive="${1:-}"
    [[ -f "$WORKER_SH" ]] || return 0
    local disk; disk="$(_worker_code_hash)"; [[ -z "$disk" ]] && return 0
    local started=""; [[ -f "$WORKER_STAMP" ]] && started="$(tr -d '[:space:]' < "$WORKER_STAMP" 2>/dev/null)"
    local stale=0
    [[ "$definitive" == "reset_changed" ]] && stale=1
    [[ -n "$started" && "$started" != "$disk" ]] && stale=1
    [[ "$stale" -eq 0 ]] && return 0
    # Loop guard: never re-request a restart for the SAME worker.sh hash within
    # 25min. A healthy restart re-writes the stamp to == disk, clearing the stale
    # condition next tick; this only bounds a crash-looping worker that never
    # rewrites its stamp so we don't hammer it every 10min.
    if [[ -f "$WORKER_RESTART_MARKER" ]]; then
        local m_hash m_ts now age
        m_hash="$(sed -n '1p' "$WORKER_RESTART_MARKER" 2>/dev/null)"
        m_ts="$(sed -n '2p' "$WORKER_RESTART_MARKER" 2>/dev/null)"
        case "$m_ts" in ''|*[!0-9]*) m_ts=0 ;; esac
        now="$(date -u +%s)"; age=$(( now - m_ts ))
        if [[ "$m_hash" == "$disk" && "$age" -lt 1500 ]]; then
            log "worker.sh changed under a running worker (hash ${disk:0:12}) but a restart was already requested ${age}s ago — skipping to avoid a restart loop"
            return 0
        fi
    fi
    local units u restarted=0
    units="$(systemctl list-units --type=service --state=running --no-legend 'chump-node*-worker.service' 2>/dev/null | awk '{print $1}')"
    if [[ -z "$units" ]]; then
        log "worker.sh changed (disk ${disk:0:12}) but no running chump-node*-worker.service found — nothing to restart"
        return 0
    fi
    for u in $units; do
        if sudo -n systemctl restart "$u" >>"$LOG" 2>&1; then
            log "RESILIENT-1453: worker.sh changed under running $u (disk=${disk:0:12} started=${started:0:12} trigger=${definitive:-stamp_stale}) — restarted it (graceful SIGTERM/WIP checkpoint)"
            restarted=1
        else
            log "WARN: sudo -n systemctl restart $u failed (converge user needs passwordless sudo)"
        fi
    done
    if [[ "$restarted" -eq 1 ]]; then
        printf '%s\n%s\n' "$disk" "$(date -u +%s)" > "$WORKER_RESTART_MARKER" 2>/dev/null || true
        emit worker_restarted_on_code_change "\"disk_hash\":\"$disk\",\"started_hash\":\"${started:-none}\",\"trigger\":\"${definitive:-stamp_stale}\",\"units\":\"$(echo $units | tr '\n' ' ' | sed 's/ *$//')\""
    fi
}

# --- preconditions -----------------------------------------------------------
if [[ -z "$REPO_ROOT" || ! -d "$REPO_ROOT/.git" ]]; then
    log "SKIP: no chump source checkout found (set CHUMP_NODE_REPO)"
    emit node_converge_skipped "\"reason\":\"no_repo\""
    exit 0
fi
cd "$REPO_ROOT" || { log "FATAL: cannot cd $REPO_ROOT"; emit node_converge_failed "\"reason\":\"cwd_failed\""; exit 1; }

# DEFER if the main checkout is mid-operation. Resolve the state paths through
# `git rev-parse --git-path` so this is correct whether $REPO_ROOT is the main
# checkout or (defensively) a linked worktree. Never reset a tree an operator or
# another organ is actively rebasing/merging — just try again next tick.
_op_in_progress() {
    local p
    for p in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD BISECT_LOG; do
        local resolved; resolved="$(git rev-parse --git-path "$p" 2>/dev/null)"
        [[ -n "$resolved" && -e "$resolved" ]] && return 0
    done
    return 1
}
if _op_in_progress; then
    log "SKIP: a rebase/merge/cherry-pick/bisect is in progress in $REPO_ROOT — deferring converge"
    emit node_converge_skipped "\"reason\":\"operation_in_progress\",\"repo\":\"$REPO_ROOT\""
    exit 0
fi

# --- RESILIENT-1567: clear a stale .git/index.lock -------------------------
# A crashed git leaves index.lock behind; every later `git reset --hard` then
# fails and the node silently rots. Clear it only when no git process is alive
# and the lock is older than the min age (a live git holds it for seconds).
_clear_stale_index_lock() {
    local lock; lock="$(git rev-parse --git-path index.lock 2>/dev/null)"
    [[ -n "$lock" && -e "$lock" ]] || return 1
    pgrep -x git >/dev/null 2>&1 && return 1
    local min_age="${CHUMP_NODE_CONVERGE_LOCK_MIN_AGE_S:-120}" mtime age
    mtime="$(stat -c %Y "$lock" 2>/dev/null || echo 0)"
    age=$(( $(date +%s) - mtime ))
    (( age >= min_age )) || return 1
    rm -f "$lock" 2>/dev/null || return 1
    log "cleared stale $lock (age ${age}s, no git process running)"
    emit node_converge_stale_lock_cleared "\"lock\":\"$lock\",\"age_s\":$age"
    return 0
}
_clear_stale_index_lock || true

# --- INFRA-8210: repair a single-branch fetch refspec on every tick ----------
# A checkout cloned with --single-branch only ever fetches origin/main, so
# remote feature branches never populate refs/remotes/<remote>/* — which
# silently broke dispatch resume, salvage, and rebases on the cuphead hub. The
# installer sets the full refspec at install time; converge re-asserts it every
# tick so a hand-reclone or a legacy checkout self-heals without a reinstall.
# Same shared primitive as the installer; idempotent when already all-branches.
source "$_CONVERGE_DIR/../setup/lib/refspec-repair.sh" 2>/dev/null || true
if command -v repair_fetch_refspec >/dev/null 2>&1; then
    repair_fetch_refspec "$REPO_ROOT" "$CONVERGE_REMOTE"; _refspec_rc=$?
    if [[ "$_refspec_rc" -eq 10 ]]; then
        log "repaired fetch refspec for '$CONVERGE_REMOTE' -> all-branches (was single-branch/narrow)"
        emit node_converge_refspec_repaired "\"remote\":\"$CONVERGE_REMOTE\",\"repo\":\"$REPO_ROOT\""
    fi
fi

# --- RESILIENT-1604: pin the node admission ceiling into node.env ------------
# A node installed before the installer wrote CHUMP_MAX_CONCURRENT_CLAUDE /
# CHUMP_MAX_CONCURRENT_CARGO_JOBS (cuphead, 2026-10-16) self-heals here: each
# key node.env lacks is appended as max(1, nproc/2); a present key is never
# rewritten. Same shared primitive as the installer's write_node_env().
source "$_CONVERGE_DIR/../setup/lib/node-admission-ceiling.sh" 2>/dev/null || true
if command -v chump_ensure_admission_ceiling >/dev/null 2>&1; then
    _ceiling_written="$(chump_ensure_admission_ceiling "${CHUMP_STATE_DIR:-${HOME:-/root}/.chump}/node.env" || true)"
    if [[ -n "$_ceiling_written" ]]; then
        log "admission ceiling written to node.env: $(printf '%s' "$_ceiling_written" | tr '\n' ' ')"
    fi
fi

# --- fetch (auth-independent: a public-repo fetch needs no credentials) -------
if ! git fetch "$CONVERGE_REMOTE" "$CONVERGE_BRANCH" --quiet 2>>"$LOG"; then
    # Offline / transient network. Not fatal — nothing to converge to that we
    # can trust, so skip this tick rather than reset to a stale local ref.
    log "SKIP: git fetch $CONVERGE_REMOTE $CONVERGE_BRANCH failed (offline?); leaving tree as-is"
    emit node_converge_skipped "\"reason\":\"fetch_failed\",\"ref\":\"$CONVERGE_REF\""
    exit 0
fi

# --- idempotency: already at the ref? ----------------------------------------
TARGET_SHA="$(git rev-parse --short=12 "$CONVERGE_REF" 2>/dev/null || echo unknown)"
HEAD_SHA="$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
# Count how far the working HEAD is BEHIND the ref (commits on the ref not yet
# on HEAD). Zero + identical SHA = already converged; the reset would be a no-op.
BEHIND="$(git rev-list --count "HEAD..$CONVERGE_REF" 2>/dev/null || echo 0)"
case "$BEHIND" in ''|*[!0-9]*) BEHIND=0 ;; esac

# --- RESILIENT-1567: alarm when the node is far behind for too long ----------
# Silent far-behind == merged-but-not-running. Track when we first saw
# BEHIND > N; once it has persisted > M minutes, page (re-page every 6h).
FAR_N="${CHUMP_NODE_CONVERGE_FAR_BEHIND_N:-50}"
FAR_M="${CHUMP_NODE_CONVERGE_FAR_BEHIND_MIN:-30}"
FAR_STATE="$LOG_DIR/far-behind-since"
if (( BEHIND > FAR_N )); then
    _now="$(date +%s)"
    [[ -s "$FAR_STATE" ]] || echo "$_now" > "$FAR_STATE"
    _since="$(cat "$FAR_STATE" 2>/dev/null || echo "$_now")"
    case "$_since" in ''|*[!0-9]*) _since="$_now" ;; esac
    _last_page="$(cat "$FAR_STATE.paged" 2>/dev/null || echo 0)"
    case "$_last_page" in ''|*[!0-9]*) _last_page=0 ;; esac
    if (( _now - _since >= FAR_M * 60 && _now - _last_page >= 21600 )); then
        echo "$_now" > "$FAR_STATE.paged"
        log "ALARM: node is $BEHIND commits behind $CONVERGE_REF for >${FAR_M}min"
        emit node_converge_far_behind "\"behind\":$BEHIND,\"threshold\":$FAR_N,\"minutes\":$FAR_M,\"repo\":\"$REPO_ROOT\""
        _nc_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        if [[ -f "$_nc_dir/../coord/lib/notify-operator.sh" ]]; then
            ( source "$_nc_dir/../coord/lib/notify-operator.sh" && \
              CHUMP_NOTIFY_KIND="node_converge_far_behind" \
              notify_operator "Node $(hostname) is $BEHIND commits behind $CONVERGE_REF for >${FAR_M}min — merged fixes are not running here." ) >>"$LOG" 2>&1 || true
        fi
    fi
else
    rm -f "$FAR_STATE" "$FAR_STATE.paged" 2>/dev/null || true
fi

if [[ "$HEAD_SHA" == "$TARGET_SHA" && "$BEHIND" -eq 0 && "$TARGET_SHA" != "unknown" ]]; then
    log "SKIP: already at $CONVERGE_REF ($HEAD_SHA)"
    emit node_converge_skipped "\"reason\":\"already_current\",\"sha\":\"$HEAD_SHA\""
    # RESILIENT-1453: even when the tree did not move THIS tick, a worker started
    # before an earlier converge (or a restart via another path) may still be
    # executing older worker.sh — reconcile it against its stamp.
    _maybe_restart_stale_workers ""
    # Prune old logs (keep last 24) even on the fast path.
    ls -t "$LOG_DIR"/converge-*.log 2>/dev/null | tail -n +25 | xargs -r rm -f 2>/dev/null || true
    exit 0
fi

# --- converge ----------------------------------------------------------------
log "converging $REPO_ROOT: HEAD $HEAD_SHA -> $CONVERGE_REF ($TARGET_SHA), behind by $BEHIND"
PREV_WORKER_HASH="$(_worker_code_hash)"
if ! converge_mirror_hard_reset "$CONVERGE_REF" >>"$LOG" 2>&1 && \
   ! { _clear_stale_index_lock && converge_mirror_hard_reset "$CONVERGE_REF" >>"$LOG" 2>&1; }; then
    log "FATAL: converge (git reset --hard) to $CONVERGE_REF failed"
    emit node_converge_failed "\"reason\":\"reset_failed\",\"ref\":\"$CONVERGE_REF\",\"target_sha\":\"$TARGET_SHA\""
    exit 1
fi

NEW_SHA="$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
log "OK: $REPO_ROOT now at $NEW_SHA (was $HEAD_SHA, ref $CONVERGE_REF)"
emit node_converged "\"prev_sha\":\"$HEAD_SHA\",\"new_sha\":\"$NEW_SHA\",\"ref\":\"$CONVERGE_REF\",\"behind\":$BEHIND"

# RESILIENT-1215: the tree just landed whatever merged into $CONVERGE_REF,
# including any organ-manifest / installer-roster changes — reconcile the
# role's organ set now instead of waiting on the slower
# chump-organ-reconcile.timer cadence.
_reconcile_role_organs

# RESILIENT-1453: if the reset just changed worker.sh out from under a running
# worker, bounce the service onto the new code now (definitive signal — no stamp
# needed). Also reconciles against the stamp for any change via another path.
_reset_wc_flag=""
[[ -n "${PREV_WORKER_HASH:-}" && "$PREV_WORKER_HASH" != "$(_worker_code_hash)" ]] && _reset_wc_flag="reset_changed"
_maybe_restart_stale_workers "$_reset_wc_flag"

# Prune old logs (keep last 24).
ls -t "$LOG_DIR"/converge-*.log 2>/dev/null | tail -n +25 | xargs -r rm -f 2>/dev/null || true
exit 0
