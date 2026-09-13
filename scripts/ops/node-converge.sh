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

if [[ "$HEAD_SHA" == "$TARGET_SHA" && "$BEHIND" -eq 0 && "$TARGET_SHA" != "unknown" ]]; then
    log "SKIP: already at $CONVERGE_REF ($HEAD_SHA)"
    emit node_converge_skipped "\"reason\":\"already_current\",\"sha\":\"$HEAD_SHA\""
    # Prune old logs (keep last 24) even on the fast path.
    ls -t "$LOG_DIR"/converge-*.log 2>/dev/null | tail -n +25 | xargs -r rm -f 2>/dev/null || true
    exit 0
fi

# --- converge ----------------------------------------------------------------
log "converging $REPO_ROOT: HEAD $HEAD_SHA -> $CONVERGE_REF ($TARGET_SHA), behind by $BEHIND"
if ! converge_mirror_hard_reset "$CONVERGE_REF" >>"$LOG" 2>&1; then
    log "FATAL: converge (git reset --hard) to $CONVERGE_REF failed"
    emit node_converge_failed "\"reason\":\"reset_failed\",\"ref\":\"$CONVERGE_REF\",\"target_sha\":\"$TARGET_SHA\""
    exit 1
fi

NEW_SHA="$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
log "OK: $REPO_ROOT now at $NEW_SHA (was $HEAD_SHA, ref $CONVERGE_REF)"
emit node_converged "\"prev_sha\":\"$HEAD_SHA\",\"new_sha\":\"$NEW_SHA\",\"ref\":\"$CONVERGE_REF\",\"behind\":$BEHIND"

# Prune old logs (keep last 24).
ls -t "$LOG_DIR"/converge-*.log 2>/dev/null | tail -n +25 | xargs -r rm -f 2>/dev/null || true
exit 0
