#!/usr/bin/env bash
# scripts/ops/node-refresh-fleet-server.sh — RESILIENT-1046
#
# Keep a fleet node's installed `chump-fleet-server` audit/dashboard binary
# current with green-main by PULLING the prebuilt per-SHA artifact that free
# GitHub-hosted CI already built (.github/workflows/build-fleet-binaries.yml →
# artifact chump-<target>-<sha>, which since RESILIENT-1046 contains BOTH the
# worker `chump` binary AND `chump-fleet-server`). On a change it installs the
# new binary atomically and restarts the long-running fleet-server --user
# service, so "merged" reaches "running" for the audit organ with no human step.
#
# WHY a pull, never a build (HARD CONSTRAINT): the Oracle nodes are 2-core
# aarch64 (cuphead/mugman). A local `cargo build` of this workspace starves the
# live fleet for tens of minutes (precedented 3h stall). This script therefore
# NEVER invokes cargo. Its only sources for a binary are, in order:
#   1. the prebuilt artifact for the newest successful build-fleet-binaries run
#      on main that is an ancestor of origin/main (the fast, correct path);
#   2. an already-present $REPO_ROOT/target/release/chump-fleet-server left by a
#      prior build (bootstrap only — used until the CI change has merged and
#      produced a fleet-server-containing artifact);
#   3. nothing → emit a loud halt-class signal and leave the running service on
#      whatever binary it already has (degrade, never cargo-build, never crash
#      a healthy server).
#
# Mirrors scripts/ops/node-refresh-chump.sh (RESILIENT-200/INFRA-3677) for the
# worker binary; installed by scripts/setup/install-fleet-server-node.sh under a
# systemd --user timer next to the long-running chump-fleet-server.service.
#
# Emits (to $NODE_AMBIENT if present, else logfile only):
#   fleet_server_refreshed          — installed a new binary + restarted service
#   fleet_server_refresh_skipped    — installed binary already current (no-op)
#   fleet_server_refresh_failed     — no pullable/local binary available
#
# Bypass: CHUMP_SKIP_FLEET_SERVER_REFRESH=1 short-circuits to exit 0.
#
# Env overrides:
#   CHUMP_NODE_REPO                 repo mirror (default: first of ~/chump-host,
#                                   ~/Projects/Chump, ~/chump that exists)
#   CHUMP_FLEET_SERVER_BIN          install destination (default ~/.local/bin/chump-fleet-server)
#   CHUMP_FLEET_SERVER_UNIT         --user service to restart (default chump-fleet-server.service)
#   CHUMP_NODE_ARTIFACT_WORKFLOW    workflow to query (default build-fleet-binaries.yml)
#   CHUMP_NODE_TARGET               force the rust target triple (default: uname -m mapping)
#   CHUMP_NODE_ARTIFACT_LOOKBACK    successful runs to scan (default 30)
#   NODE_AMBIENT                    ambient stream to append to
#   CHUMP_PROVIDERS_ENV             creds file for GH_TOKEN (default ~/.chump/providers.env)

set -uo pipefail

_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../coord/lib/github.sh
source "$_DIR/../coord/lib/github.sh" 2>/dev/null || true
# shellcheck source=../lib/halt-class-emit.sh
source "$_DIR/../lib/halt-class-emit.sh" 2>/dev/null || true

# --- gh auth: export GH_TOKEN from providers.env if not already in env --------
# A systemd --user timer starts with no interactive `gh auth login`; without a
# token every gh call silently returns empty and the pull degrades. Same
# fallback pattern as node-refresh-chump.sh (RESILIENT-1040).
CHUMP_PROVIDERS_ENV="${CHUMP_PROVIDERS_ENV:-$HOME/.chump/providers.env}"
if [[ -z "${GH_TOKEN:-}" && -z "${GITHUB_TOKEN:-}" && -f "$CHUMP_PROVIDERS_ENV" ]]; then
    _t="$(grep -E '^(export )?GH_TOKEN=' "$CHUMP_PROVIDERS_ENV" 2>/dev/null \
        | tail -1 | sed -E 's/^(export )?GH_TOKEN=//; s/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/')"
    [[ -n "$_t" ]] && export GH_TOKEN="$_t"
    unset _t
fi

# --- resolve mirror checkout + install destination ---------------------------
REPO_ROOT="${CHUMP_NODE_REPO:-}"
if [[ -z "$REPO_ROOT" ]]; then
    for c in "$HOME/chump-host" "$HOME/Projects/Chump" "$HOME/chump"; do
        git -C "$c" rev-parse --is-inside-work-tree >/dev/null 2>&1 && { REPO_ROOT="$c"; break; }
    done
fi
DEFAULT_TARGET_BIN="${CHUMP_NODE_DIR:+$CHUMP_NODE_DIR/bin/chump-fleet-server}"
DEFAULT_TARGET_BIN="${DEFAULT_TARGET_BIN:-$HOME/.local/bin/chump-fleet-server}"
TARGET_BIN="${CHUMP_FLEET_SERVER_BIN:-$DEFAULT_TARGET_BIN}"
FLEET_UNIT="${CHUMP_FLEET_SERVER_UNIT:-chump-fleet-server.service}"
NODE_AMBIENT="${NODE_AMBIENT:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
CHUMP_NODE_ARTIFACT_WORKFLOW="${CHUMP_NODE_ARTIFACT_WORKFLOW:-build-fleet-binaries.yml}"
CHUMP_NODE_ARTIFACT_LOOKBACK="${CHUMP_NODE_ARTIFACT_LOOKBACK:-30}"

LOG_DIR="${CHUMP_FLEET_SERVER_REFRESH_LOGDIR:-$HOME/.chump/fleet-server-refresh-logs}"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG="$LOG_DIR/refresh-$(date -u +%Y%m%dT%H%M%SZ).log"

emit() {
    local kind="$1" extra="${2:-}" ts line
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ -n "$extra" ]]; then line="{\"ts\":\"$ts\",\"kind\":\"$kind\",$extra}"
    else line="{\"ts\":\"$ts\",\"kind\":\"$kind\"}"; fi
    [[ -d "$(dirname "$NODE_AMBIENT")" ]] && printf '%s\n' "$line" >> "$NODE_AMBIENT" 2>/dev/null || true
    printf '[%s] %s\n' "$ts" "$kind" >> "$LOG"
}
log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG"; }

_halt() {
    local name="$1" reason="$2" detail="${3:-{}}" fc="permanent" er
    command -v halt_class_categorize >/dev/null 2>&1 && fc="$(halt_class_categorize "$reason")"
    er="$(printf '%s' "$reason" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    emit halt_class_emit "\"name\":\"$name\",\"status\":\"failure\",\"reason\":\"$er\",\"failure_class\":\"$fc\",\"detail\":$detail"
}

[[ "${CHUMP_SKIP_FLEET_SERVER_REFRESH:-0}" == "1" ]] && { log "BYPASS: CHUMP_SKIP_FLEET_SERVER_REFRESH=1"; exit 0; }

if [[ -z "$REPO_ROOT" ]] || ! git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log "FATAL: no chump mirror checkout found (set CHUMP_NODE_REPO)"
    emit fleet_server_refresh_failed "\"reason\":\"no_repo\""
    exit 1
fi
cd "$REPO_ROOT" || { log "FATAL: cannot cd $REPO_ROOT"; emit fleet_server_refresh_failed "\"reason\":\"cwd_failed\""; exit 1; }

_sha256() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
INSTALLED_SHA256=""
[[ -x "$TARGET_BIN" ]] && INSTALLED_SHA256="$(_sha256 "$TARGET_BIN")"

_resolve_rust_target() {
    if [[ -n "${CHUMP_NODE_TARGET:-}" ]]; then printf '%s' "$CHUMP_NODE_TARGET"; return; fi
    case "$(uname -m)" in
        x86_64|amd64)  printf 'x86_64-unknown-linux-gnu' ;;
        aarch64|arm64) printf 'aarch64-unknown-linux-gnu' ;;
        *)             printf '' ;;
    esac
}

# --- restart the long-running fleet-server unit (system OR --user) -----------
# The canonical organ on owned iron is a SYSTEM unit (User=<fleet user>), so a
# restart needs sudo; on a node that instead runs it as a --user unit we restart
# in the user manager. Try system-via-sudo first, fall back to --user, so ONE
# refresh script serves both shapes without a rival organ.
_restart_fleet_unit() {
    if sudo -n systemctl cat "$FLEET_UNIT" >/dev/null 2>&1; then
        # shellcheck disable=SC2024  # $LOG is user-owned; log as the user, not root (intended)
        if sudo -n systemctl restart "$FLEET_UNIT" >>"$LOG" 2>&1; then
            log "OK: restarted system unit $FLEET_UNIT (sudo)"; return 0
        fi
        log "WARN: sudo systemctl restart $FLEET_UNIT failed"
    fi
    if systemctl --user cat "$FLEET_UNIT" >/dev/null 2>&1; then
        if systemctl --user restart "$FLEET_UNIT" >>"$LOG" 2>&1; then
            log "OK: restarted --user unit $FLEET_UNIT"; return 0
        fi
        log "WARN: systemctl --user restart $FLEET_UNIT failed"
    fi
    log "WARN: could not restart $FLEET_UNIT (no matching system/user unit or no sudo) — binary updated but service NOT bounced"
    return 1
}

# --- install a candidate binary: verify runs, atomic swap, restart on change --
# $1 = path to candidate chump-fleet-server binary, $2 = provenance label.
# Returns 0 on installed-or-already-current, 1 on unusable candidate.
_install_candidate() {
    local src="$1" prov="$2" cand_sha256 ver
    [[ -f "$src" ]] || { log "candidate ($prov) missing: $src"; return 1; }
    chmod +x "$src" 2>/dev/null || true
    # A cross-arch or corrupt binary fails --version here → reject (never install).
    ver="$("$src" --version 2>/dev/null || echo unrunnable)"
    if [[ "$ver" != chump-fleet-server* ]]; then
        log "candidate ($prov) does not run on this host (--version: '$ver') — rejecting"
        return 1
    fi
    cand_sha256="$(_sha256 "$src")"
    if [[ -n "$INSTALLED_SHA256" && "$cand_sha256" == "$INSTALLED_SHA256" ]]; then
        log "SKIP: installed chump-fleet-server already current (sha256 $INSTALLED_SHA256, via $prov)"
        emit fleet_server_refresh_skipped "\"reason\":\"already_current\",\"sha256\":\"$INSTALLED_SHA256\",\"source\":\"$prov\""
        return 0
    fi
    mkdir -p "$(dirname "$TARGET_BIN")" 2>/dev/null || true
    cp -f "$src" "$TARGET_BIN.new" 2>>"$LOG" || { log "FATAL: cp to $TARGET_BIN.new failed"; return 1; }
    chmod +x "$TARGET_BIN.new"
    mv -f "$TARGET_BIN.new" "$TARGET_BIN" || { log "FATAL: mv into place failed"; return 1; }
    log "OK: installed chump-fleet-server → $TARGET_BIN ($ver, via $prov)"
    # Restart the long-running service so the new binary is actually serving.
    _restart_fleet_unit
    emit fleet_server_refreshed "\"prev_sha256\":\"${INSTALLED_SHA256:-none}\",\"new_sha256\":\"$cand_sha256\",\"source\":\"$prov\",\"unit\":\"$FLEET_UNIT\""
    return 0
}

# --- try the prebuilt-artifact pull (the correct, no-build path) --------------
_try_artifact_pull() {
    command -v gh >/dev/null 2>&1 || { log "artifact-pull: gh unavailable"; return 1; }
    local target; target="$(_resolve_rust_target)"
    [[ -z "$target" ]] && { log "artifact-pull: unknown arch $(uname -m)"; return 1; }

    git fetch origin main --quiet 2>>"$LOG" || log "WARN: git fetch failed (offline?)"
    local ref_sha; ref_sha="$(git rev-parse origin/main 2>/dev/null || git rev-parse HEAD)"

    local _gh="gh"; command -v chump_gh >/dev/null 2>&1 && _gh="chump_gh"
    # Newest successful build-fleet-binaries runs on main; pick the newest whose
    # head_sha is an ancestor of (or equal to) origin/main — its artifact tree
    # matches what this node should serve.
    local shas
    shas="$(CHUMP_GH_CALL_CRITICALITY=background "$_gh" api \
        "repos/{owner}/{repo}/actions/workflows/${CHUMP_NODE_ARTIFACT_WORKFLOW}/runs?branch=main&status=success&per_page=${CHUMP_NODE_ARTIFACT_LOOKBACK}" \
        --jq '.workflow_runs[] | "\(.id) \(.head_sha)"' 2>>"$LOG")"
    [[ -z "$shas" ]] && { log "artifact-pull: no successful $CHUMP_NODE_ARTIFACT_WORKFLOW runs found"; return 1; }

    local run_id full_sha chosen_run="" chosen_sha=""
    while IFS=' ' read -r run_id full_sha; do
        [[ -z "$run_id" || -z "$full_sha" ]] && continue
        if git merge-base --is-ancestor "$full_sha" "$ref_sha" 2>/dev/null; then
            chosen_run="$run_id"; chosen_sha="$full_sha"; break
        fi
    done <<< "$shas"
    if [[ -z "$chosen_run" ]]; then
        log "artifact-pull: no successful run is an ancestor of $ref_sha within lookback"
        return 1
    fi

    local dl aname pulled
    dl="$(mktemp -d)"
    aname="chump-${target}-${chosen_sha}"
    if ! CHUMP_GH_CALL_CRITICALITY=background "$_gh" run download "$chosen_run" -n "$aname" --dir "$dl" >>"$LOG" 2>&1; then
        log "artifact-pull: download $aname (run $chosen_run) failed"
        rm -rf "$dl"; return 1
    fi
    pulled="$dl/chump-fleet-server"
    if [[ ! -f "$pulled" ]]; then
        log "artifact-pull: $aname holds no chump-fleet-server (pre-RESILIENT-1046 artifact?) — falling back"
        rm -rf "$dl"; return 1
    fi
    # Integrity: verify sha256 if the artifact shipped one.
    if [[ -f "$dl/chump-fleet-server.sha256" ]] && command -v sha256sum >/dev/null 2>&1; then
        local want got
        want="$(awk '{print $1}' "$dl/chump-fleet-server.sha256" 2>/dev/null)"
        got="$(_sha256 "$pulled")"
        if [[ -n "$want" && "$want" != "$got" ]]; then
            log "artifact-pull: sha256 mismatch (want $want got $got) — rejecting"
            rm -rf "$dl"; return 1
        fi
    fi
    log "artifact-pull: got $aname (run $chosen_run) → installing"
    if _install_candidate "$pulled" "artifact_pull:${chosen_sha:0:12}"; then rm -rf "$dl"; return 0; fi
    rm -rf "$dl"; return 1
}

# --- main flow ---------------------------------------------------------------
if _try_artifact_pull; then
    ls -t "$LOG_DIR"/refresh-*.log 2>/dev/null | tail -n +25 | xargs -r rm -f 2>/dev/null || true
    exit 0
fi

# Bootstrap fallback: a binary a prior build already left in target/release.
# Used only until the CI change has merged and produced a fleet-server-bearing
# artifact. NEVER runs cargo.
LOCAL_BUILD="$REPO_ROOT/target/release/chump-fleet-server"
if [[ -x "$LOCAL_BUILD" ]]; then
    log "artifact-pull unavailable/missed — using existing local build $LOCAL_BUILD (bootstrap; no cargo invoked)"
    if _install_candidate "$LOCAL_BUILD" "local_target_release"; then
        ls -t "$LOG_DIR"/refresh-*.log 2>/dev/null | tail -n +25 | xargs -r rm -f 2>/dev/null || true
        exit 0
    fi
fi

# --- FAIL-SAFE tail (RESILIENT-1046 anti-Memento) ----------------------------
# No new artifact could be pulled and the bootstrap path had nothing to install.
# This is NOT a systemd failure: a refresh oneshot that exits non-zero here lands
# in `failed` state, which is exactly the silent-decay signal the anti-Memento
# work targets — a healthy "nothing new to pull, staying put" would masquerade as
# a broken organ. So we ALWAYS exit 0 and express health/decay through the
# ambient stream instead of the unit's exit code:
#
#   - a usable binary is already installed  -> genuinely healthy "staying put":
#     the running server is unaffected; emit a quiet skip, no alarm.
#   - NO usable binary anywhere (fresh node, nothing to serve) -> a real problem
#     worth paging on, but the alarm is the LOUD ambient halt-class signal, not a
#     wedged unit. The timer keeps retrying every cycle; the moment a good
#     artifact appears it gets pulled.
if [[ -x "$TARGET_BIN" ]] && "$TARGET_BIN" --version >/dev/null 2>&1; then
    log "OK: no new artifact to pull; staying on the installed binary ($TARGET_BIN) — healthy, no-op"
    emit fleet_server_refresh_skipped "\"reason\":\"no_new_artifact_staying_put\",\"target_bin\":\"$TARGET_BIN\""
    exit 0
fi

log "WARN: no pullable artifact, no bootstrap build, AND no usable installed binary — server cannot be (re)started until one appears"
_halt "fleet-server-refresh-no-binary" \
    "no chump-fleet-server prebuilt artifact was pullable, no target/release bootstrap build exists, and no usable binary is installed at $TARGET_BIN; refresh is a safe no-op (never cargo-build on a fleet node) and will retry each cycle" \
    "{\"node_repo\":\"$REPO_ROOT\",\"target_bin\":\"$TARGET_BIN\"}"
emit fleet_server_refresh_no_binary "\"reason\":\"no_binary_available\",\"target_bin\":\"$TARGET_BIN\""
# Exit 0 on purpose: fail-safe. The loud halt-class emit above is the alarm, not
# a `failed` systemd unit that would itself read as silent rot.
exit 0
