#!/usr/bin/env bash
# scripts/ops/auto-deploy.sh — MISSION-012
#
# Auto-deploy daemon: ensures the installed /opt/homebrew/bin/chump binary
# tracks origin/main.  Called by the com.chump.auto-deploy launchd agent
# every 1200s (~20 min).
#
# Logic:
#   (a) git fetch origin main                             — get latest remote state
#   (b) compare origin/main HEAD SHA to stored last-deployed SHA
#   (c) if advanced → delegate to refresh-runner-binary.sh (isolated build)
#   (d) verify the PATH-resolved worker binary (not TARGET_BIN) matches
#       origin/main HEAD — on mismatch, emit binary_auto_deploy_failed
#       reason=worker_binary_sha_mismatch and exit non-zero (RESILIENT-408)
#   (e) on success → record new deployed SHA
#   (f) emit ambient kind=binary_auto_deployed
#
# Build isolation guarantee: this script NEVER checks out main or modifies the
# main worktree.  All building is delegated to refresh-runner-binary.sh which
# creates an isolated detached git worktree in /tmp, builds, installs, then
# tears it down.  The main checkout's local state is untouched.
#
# Idempotent: exits 0 (no-op) when the installed binary is already current.
#
# RESILIENT-211: canary rollout. This script's own local install (the
# machine it runs on — the launchd-scheduled canary node) is step 1 of a
# two-step SEQUENTIAL rollout across Chump's two-node fleet (Helsinki +
# closetjunky, see docs/process/ADD_A_FLEET_NODE.md). After the local
# rebuild+install succeeds, a health-check gate (mission-scoreboard.sh, or
# `chump health --slo-check` as fallback) must pass on THIS node before the
# second node is told to refresh. A failed gate BLOCKS the second-node
# rollout and emits kind=canary_rollout_failed rather than propagating a bad
# binary silently. No new environment tier is introduced — both nodes are
# existing production nodes; this only sequences and gates between them.
#
# Environment overrides:
#   CHUMP_REPO_ROOT               — repo root (default: resolved relative to script)
#   CHUMP_REFRESH_RUNNER_SCRIPT   — path to refresh-runner-binary.sh
#   CHUMP_SKIP_AUTO_DEPLOY        — set 1 to exit 0 immediately (bypass)
#   CHUMP_HEALTHCHECK_CMD        — override the canary health-check command
#                                   (full shell command string; used by tests
#                                   and operators to force pass/fail). Default:
#                                   scripts/dev/mission-scoreboard.sh, falling
#                                   back to `<TARGET_BIN> health --slo-check`.
#   CHUMP_SECOND_NODE_SSH         — ssh target (alias or user@host) for the
#                                   second fleet node. Unset = no second node
#                                   configured on this box; second-node deploy
#                                   is skipped (not a failure — single-node
#                                   contexts, e.g. dev checkouts, are fine).
#   CHUMP_SECOND_NODE_REFRESH_CMD — remote command run over ssh to refresh the
#                                   second node's binary (default: invokes
#                                   node-refresh-chump.sh on that node).
#   CHUMP_SECOND_NODE_DEPLOY_CMD  — full override for the entire second-node
#                                   deploy step (local shell command, no ssh).
#                                   Used by tests to assert propagation
#                                   happened/didn't without real network I/O.
#   CHUMP_WORKER_BIN              — RESILIENT-408: override for the
#                                   PATH-resolved binary workers actually
#                                   exec (test hook). Default resolution:
#                                   ~/.cargo/bin/chump if present, else
#                                   `command -v chump`, else TARGET_BIN.
#
# RESILIENT-211/RESILIENT-408 note: TARGET_BIN (CHUMP_RUNNER_BIN) is the
# install target this script *writes*. It is not necessarily the binary the
# fleet workers *execute* — workers resolve `chump` off PATH, and
# ~/.cargo/bin comes first there. Gating deploy success on TARGET_BIN alone
# let auto-deploy report success while the running worker kept executing a
# stale ~/.cargo/bin/chump (observed 2026-08-24, RESILIENT-408). Deploy
# success is therefore gated on the PATH-resolved binary, verified below.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CHUMP_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
# INFRA-8098: Rust-aware deploy helpers (rust_head_sha / binary_has_rust_head)
# shellcheck source=scripts/lib/rust-head.sh
[ -f "$REPO_ROOT/scripts/lib/rust-head.sh" ] && . "$REPO_ROOT/scripts/lib/rust-head.sh"
AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"
STATE_DIR="$REPO_ROOT/.chump-locks"
DEPLOYED_SHA_FILE="$STATE_DIR/auto-deploy-last-sha.txt"
LOG_DIR="$REPO_ROOT/.chump-locks/auto-deploy-logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/auto-deploy-$(date -u +%Y%m%dT%H%M%SZ).log"

# scanner-anchor: "kind":"binary_auto_deployed"
# scanner-anchor: "kind":"autodeploy_tool_smoke_passed"
# scanner-anchor: "kind":"autodeploy_tool_smoke_failed"
# scanner-anchor: "kind":"canary_rollout_failed"
emit_ambient() {
    local kind="$1" extra="${2:-}"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local line
    if [[ -n "$extra" ]]; then
        line="{\"ts\":\"$ts\",\"kind\":\"$kind\",$extra}"
    else
        line="{\"ts\":\"$ts\",\"kind\":\"$kind\"}"
    fi
    printf '%s\n' "$line" >> "$AMBIENT" 2>/dev/null || true
    printf '[%s] %s\n' "$ts" "$kind" >> "$LOG"
}

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG"; }

# resolve_worker_bin — RESILIENT-408. Returns the binary path the fleet
# workers' PATH will actually resolve `chump` to, which is NOT necessarily
# TARGET_BIN. Preference order mirrors a worker's own PATH resolution:
#   1. CHUMP_WORKER_BIN override (test hook)
#   2. ~/.cargo/bin/chump if present (first in worker PATH on Linux nodes)
#   3. whatever `chump` resolves to on this script's own PATH
#   4. TARGET_BIN as a last resort (keeps single-binary/dev hosts working)
resolve_worker_bin() {
    if [[ -n "${CHUMP_WORKER_BIN:-}" ]]; then
        printf '%s' "$CHUMP_WORKER_BIN"
        return 0
    fi
    if [[ -x "$HOME/.cargo/bin/chump" ]]; then
        printf '%s' "$HOME/.cargo/bin/chump"
        return 0
    fi
    local on_path
    on_path="$(command -v chump 2>/dev/null || true)"
    if [[ -n "$on_path" ]]; then
        printf '%s' "$on_path"
        return 0
    fi
    printf '%s' "$TARGET_BIN"
}

extract_build_sha() {
    "$1" --version 2>/dev/null | grep -oE '\(([a-f0-9]+) built' | head -1 | sed 's/[( ]//g;s/built//'
}

# run_canary_health_check — RESILIENT-211 gate. Runs AFTER this node's own
# rebuild+install has already succeeded; decides whether the second fleet
# node is allowed to receive the same binary. Exit 0 = healthy (propagate),
# non-zero = unhealthy (block).
#
# Deliberately narrow: only the two gates the operator named as acceptable
# (mission-scoreboard.sh, chump health --slo-check) are wired in. A gate
# that always exits 0 is worse than no gate — it manufactures false
# confidence — so this never swallows a nonzero exit into success.
run_canary_health_check() {
    if [[ -n "${CHUMP_HEALTHCHECK_CMD:-}" ]]; then
        log "canary health check: CHUMP_HEALTHCHECK_CMD override -> $CHUMP_HEALTHCHECK_CMD"
        bash -c "$CHUMP_HEALTHCHECK_CMD" >>"$LOG" 2>&1
        return $?
    fi
    local scoreboard="$REPO_ROOT/scripts/dev/mission-scoreboard.sh"
    if [[ -x "$scoreboard" ]]; then
        log "canary health check: mission-scoreboard.sh"
        bash "$scoreboard" >>"$LOG" 2>&1
        return $?
    fi
    log "canary health check: mission-scoreboard.sh unavailable — falling back to '$TARGET_BIN health --slo-check'"
    "$TARGET_BIN" health --slo-check >>"$LOG" 2>&1
    return $?
}

# deploy_second_node — RESILIENT-211. Only called after run_canary_health_check
# returns success. Triggers the second fleet node's own refresh
# (scripts/ops/node-refresh-chump.sh, per docs/process/ADD_A_FLEET_NODE.md)
# over ssh so the two-node rollout is sequential rather than both nodes
# independently free-running their own timers onto the same new SHA at once.
#
# No configured second node (CHUMP_SECOND_NODE_SSH unset) is a legitimate
# single-node context (dev checkouts, a node mid-bringup) — skip, don't fail.
deploy_second_node() {
    if [[ -n "${CHUMP_SECOND_NODE_DEPLOY_CMD:-}" ]]; then
        log "second-node deploy: CHUMP_SECOND_NODE_DEPLOY_CMD override"
        bash -c "$CHUMP_SECOND_NODE_DEPLOY_CMD" >>"$LOG" 2>&1
        return $?
    fi
    if [[ -z "${CHUMP_SECOND_NODE_SSH:-}" ]]; then
        log "SKIP second-node deploy: CHUMP_SECOND_NODE_SSH not set (single-node context)"
        return 0
    fi
    local remote_cmd="${CHUMP_SECOND_NODE_REFRESH_CMD:-bash ~/chump-host/scripts/ops/node-refresh-chump.sh || bash ~/Projects/Chump/scripts/ops/node-refresh-chump.sh}"
    log "second-node deploy: ssh -> $CHUMP_SECOND_NODE_SSH"
    ssh -o BatchMode=yes -o ConnectTimeout="${CHUMP_SECOND_NODE_SSH_TIMEOUT:-20}" \
        "$CHUMP_SECOND_NODE_SSH" "$remote_cmd" >>"$LOG" 2>&1
}

# Bypass
if [[ "${CHUMP_SKIP_AUTO_DEPLOY:-0}" == "1" ]]; then
    log "BYPASS: CHUMP_SKIP_AUTO_DEPLOY=1"
    exit 0
fi

REFRESH_SCRIPT="${CHUMP_REFRESH_RUNNER_SCRIPT:-$REPO_ROOT/scripts/setup/refresh-runner-binary.sh}"
if [[ ! -x "$REFRESH_SCRIPT" ]]; then
    log "FATAL: refresh script not executable: $REFRESH_SCRIPT"
    emit_ambient "binary_auto_deploy_failed" "\"reason\":\"no_refresh_script\",\"path\":\"$REFRESH_SCRIPT\""
    exit 1
fi

cd "$REPO_ROOT" || { log "FATAL: cannot cd to $REPO_ROOT"; exit 1; }

# (a) Fetch latest main
git fetch origin main --quiet 2>>"$LOG" || {
    log "WARN: git fetch failed (offline?); proceeding with local state"
}

# (b) Get origin/main HEAD SHA
MAIN_SHA="$(git rev-parse origin/main 2>/dev/null || git rev-parse HEAD)"
MAIN_SHA_SHORT="${MAIN_SHA:0:12}"
log "origin/main HEAD = $MAIN_SHA_SHORT"

# Load last-deployed SHA (empty = never deployed by auto-deploy)
LAST_SHA=""
if [[ -f "$DEPLOYED_SHA_FILE" ]]; then
    LAST_SHA="$(cat "$DEPLOYED_SHA_FILE" 2>/dev/null | tr -d '[:space:]')"
fi

if [[ -n "$LAST_SHA" && "$LAST_SHA" == "$MAIN_SHA" ]]; then
    log "SKIP: origin/main has not advanced since last auto-deploy (sha=$MAIN_SHA_SHORT)"
    emit_ambient "binary_auto_deploy_skipped" "\"reason\":\"already_current\",\"sha\":\"$MAIN_SHA_SHORT\""
    # Prune old logs (keep last 24)
    ls -t "$LOG_DIR"/auto-deploy-*.log 2>/dev/null | tail -n +25 | xargs -I{} rm -f {} 2>/dev/null || true
    exit 0
fi

# INFRA-8098: OS-aware default install target (Linux nodes → ~/.cargo/bin/chump;
# macOS → Homebrew prefix). Must be resolved before the Rust-aware skip below.
if [ -n "${CHUMP_RUNNER_BIN:-}" ]; then
    TARGET_BIN="$CHUMP_RUNNER_BIN"
elif [ "$(uname -s)" = "Darwin" ]; then
    TARGET_BIN="/opt/homebrew/bin/chump"
else
    TARGET_BIN="$HOME/.cargo/bin/chump"
fi

# (b2) Rust-aware skip (INFRA-8098). origin/main HEAD advancing is NOT a reason
# to rebuild — only a Rust-affecting commit changes the binary. Doc/script/yaml
# commits advance HEAD but compile to a byte-identical binary. Rebuilding the
# ~190k-LOC binary on every such commit burned cuphead's build cores and tripped
# the merged-not-running false alarm every ~20 min. If the installed binary
# already contains the last Rust-affecting commit, record the new HEAD (so the
# cheap HEAD-equality skip fires next cycle) and exit WITHOUT a rebuild.
if declare -F binary_has_rust_head >/dev/null 2>&1; then
    RUST_SHA="$(rust_head_sha "$REPO_ROOT" "origin/main")"
    INSTALLED_BUILD_SHA="$(extract_build_sha "$TARGET_BIN" 2>/dev/null || echo unknown)"
    if binary_has_rust_head "$RUST_SHA" "$INSTALLED_BUILD_SHA" "$REPO_ROOT"; then
        log "SKIP: HEAD advanced to $MAIN_SHA_SHORT but installed binary ($INSTALLED_BUILD_SHA) already contains the last Rust-affecting commit (${RUST_SHA:0:12}) — non-Rust lag, no rebuild"
        printf '%s\n' "$MAIN_SHA" > "$DEPLOYED_SHA_FILE"
        emit_ambient "binary_auto_deploy_skipped" \
            "\"reason\":\"no_rust_change\",\"sha\":\"$MAIN_SHA_SHORT\",\"rust_sha\":\"${RUST_SHA:0:12}\",\"binary_sha\":\"$INSTALLED_BUILD_SHA\""
        ls -t "$LOG_DIR"/auto-deploy-*.log 2>/dev/null | tail -n +25 | xargs -I{} rm -f {} 2>/dev/null || true
        exit 0
    fi
fi

log "DEPLOY: origin/main advanced (last_deployed=${LAST_SHA:-none}, current=$MAIN_SHA_SHORT)"

# (c) Delegate to refresh-runner-binary.sh (isolated worktree build)
# That script handles: create detached worktree → cargo build --release → hardcopy → teardown
PREV_SHA="$(extract_build_sha "$TARGET_BIN" || echo unknown)"
[[ -n "$PREV_SHA" ]] || PREV_SHA="unknown"

log "calling refresh-runner-binary.sh (prev_installed_sha=$PREV_SHA)"
if CHUMP_REPO_ROOT="$REPO_ROOT" bash "$REFRESH_SCRIPT" >>"$LOG" 2>&1; then
    NEW_SHA="$(extract_build_sha "$TARGET_BIN" || echo unknown)"
    [[ -n "$NEW_SHA" ]] || NEW_SHA="unknown"
    log "OK: rebuild complete — prev=$PREV_SHA new=$NEW_SHA main=$MAIN_SHA_SHORT"

    # (d) RESILIENT-408: verify the binary the fleet PATH actually resolves
    # `chump` to — NOT TARGET_BIN, which can be a different file/inode (the
    # merged-not-running disease: auto-deploy reports success while the
    # worker keeps executing a stale binary). Gate everything below
    # (sha-file write + binary_auto_deployed emission) on this check.
    WORKER_BIN="$(resolve_worker_bin)"
    WORKER_SHA="$(extract_build_sha "$WORKER_BIN" || echo unknown)"
    [[ -n "$WORKER_SHA" ]] || WORKER_SHA="unknown"
    if [[ -z "$WORKER_SHA" || "$WORKER_SHA" == "unknown" ]] \
        || { [[ "$WORKER_SHA" != "$MAIN_SHA_SHORT"* ]] && [[ "$MAIN_SHA_SHORT" != "$WORKER_SHA"* ]]; }; then
        log "FAIL: PATH-resolved worker binary ($WORKER_BIN, sha=$WORKER_SHA) does not match origin/main ($MAIN_SHA_SHORT) — merged-not-running"
        emit_ambient "binary_auto_deploy_failed" \
            "\"reason\":\"worker_binary_sha_mismatch\",\"worker_bin\":\"$WORKER_BIN\",\"worker_sha\":\"$WORKER_SHA\",\"main_sha\":\"$MAIN_SHA_SHORT\",\"target_bin\":\"$TARGET_BIN\",\"target_sha\":\"$NEW_SHA\""
        exit 1
    fi
    log "OK: PATH-resolved worker binary ($WORKER_BIN) verified at main sha $MAIN_SHA_SHORT"

    # (e) Record deployed SHA — only after worker-binary verification passes
    printf '%s\n' "$MAIN_SHA" > "$DEPLOYED_SHA_FILE"

    # (f) Emit binary_auto_deployed — only after worker-binary verification passes
    emit_ambient "binary_auto_deployed" \
        "\"prev_sha\":\"$PREV_SHA\",\"new_sha\":\"$NEW_SHA\",\"main_sha\":\"$MAIN_SHA_SHORT\",\"worker_bin\":\"$WORKER_BIN\",\"worker_sha\":\"$WORKER_SHA\""

    # (g) INFRA-3453: post-deploy tool-invocation smoke — the loop tests itself.
    # ADVISORY: never blocks or reverts the deploy. It drives the freshly-installed
    # agent through a real turn and confirms a critical tool is actually CALLABLE,
    # not merely present — catching the deploy->unreachable-tool class (the
    # 2026-07-28 comprehend_repo profile gap, which every structural check missed).
    # Opt-in: CHUMP_AUTODEPLOY_SMOKE (default 1; 0 skips). LLM-driven (~1-2 min); a
    # failure may also mean the model was unavailable, hence advisory-only.
    if [ "${CHUMP_AUTODEPLOY_SMOKE:-1}" != "0" ]; then
        SMOKE_SH="$REPO_ROOT/scripts/dev/agent-tool-smoke.sh"
        if [ -x "$SMOKE_SH" ]; then
            log "post-deploy tool-invocation smoke (advisory) …"
            if CHUMP_SMOKE_BIN="$TARGET_BIN" \
               CHUMP_SMOKE_TOOLS="${CHUMP_AUTODEPLOY_SMOKE_TOOLS:-comprehend_repo:$REPO_ROOT}" \
               timeout "${CHUMP_AUTODEPLOY_SMOKE_TIMEOUT:-220}" \
               bash "$SMOKE_SH" --bin "$TARGET_BIN" --repo "$REPO_ROOT" >>"$LOG" 2>&1; then
                log "OK: post-deploy smoke — critical tools are agent-invocable"
                emit_ambient "autodeploy_tool_smoke_passed" "\"new_sha\":\"$NEW_SHA\""
            else
                log "WARN: post-deploy smoke FAILED — a critical tool is NOT agent-invocable in $NEW_SHA (or the model was unavailable). Deploy stands; check profile/registration/gate."
                emit_ambient "autodeploy_tool_smoke_failed" \
                    "\"new_sha\":\"$NEW_SHA\",\"reason\":\"critical_tool_unreachable_or_model_unavailable\""
            fi
        else
            log "post-deploy smoke skipped — $SMOKE_SH not present yet (INFRA-3452 undeployed)"
        fi
    fi

    # (h) RESILIENT-211: canary rollout gate. This node's rebuild+install just
    # succeeded — it is the canary / first node of the two-node fleet. Only
    # propagate to the second node if the health-check gate actually passes;
    # a failed gate blocks propagation and is reported, never swallowed.
    if run_canary_health_check; then
        log "OK: canary health check passed on $(hostname) — clearing rollout to second node"
        deploy_second_node
    else
        log "FAIL: canary health check failed on $(hostname) (new_sha=$NEW_SHA) — BLOCKING rollout to second node"
        emit_ambient "canary_rollout_failed" \
            "\"new_sha\":\"$NEW_SHA\",\"main_sha\":\"$MAIN_SHA_SHORT\",\"canary_node\":\"$(hostname)\""
    fi
else
    log "FAIL: refresh-runner-binary.sh exited non-zero; binary may be stale"
    emit_ambient "binary_auto_deploy_failed" \
        "\"reason\":\"refresh_script_failed\",\"prev_sha\":\"$PREV_SHA\",\"main_sha\":\"$MAIN_SHA_SHORT\""
    exit 1
fi

# Prune old logs (keep last 24)
ls -t "$LOG_DIR"/auto-deploy-*.log 2>/dev/null | tail -n +25 | xargs -I{} rm -f {} 2>/dev/null || true

exit 0
