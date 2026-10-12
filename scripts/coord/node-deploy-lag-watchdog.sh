#!/usr/bin/env bash
# node-deploy-lag-watchdog.sh (RESILIENT-523) — Linux/systemd counterpart of
# scripts/coord/merge-deploy-lag-watchdog.sh (INFRA-3454, macOS/launchd only).
#
# WHY THIS EXISTS: on CJ (closetjunky, a Linux node), a merge to origin/main
# can silently fail to reach the running binary — a cold cargo build of the
# 190k+ LOC chump binary exceeded the systemd unit's TimeoutStartSec, the
# service was killed, and nothing paged anyone. The existing
# merge-deploy-lag-watchdog.sh only knows about launchctl/com.chump.auto-deploy
# (macOS) — it has no Linux/systemd equivalent, so a stalled chump-node-refresh
# timer on CJ had no alarm.
#
# Logic:
#   installed_sha == green-main sha  -> current, emit node_deploy_lag_ok, exit 0
#   behind, lag <= SLO                -> deploy pending, exit 0 (quiet)
#   behind, lag  > SLO                -> emit node_deploy_lag_exceeded +
#                                         restart chump-node-refresh.service (heal)
#   last run Result=timeout           -> emit node_deploy_timeout_detected (loud,
#                                         AC #2 — a timed-out deploy is never silent)
#
# lag = now - (author time of origin/main HEAD), i.e. how long the merge has
# been on main without reaching the binary.
#
# Env:
#   CHUMP_NODE_DEPLOY_LAG_SLO_SECS   default 1800 (30 min)
#   CHUMP_NODE_BIN                   installed binary to check (default: same
#                                     resolution order as node-refresh-chump.sh)
#   CHUMP_NODE_DEPLOY_LAG_NO_HEAL=1  alert only, don't restart the refresh unit
#   CHUMP_NODE_DEPLOY_LAG_UNIT       systemd --user unit to inspect/restart
#                                     (default chump-node-refresh.service)
#   CHUMP_NODE_DEPLOY_LAG_SYSTEMCTL_BIN  override `systemctl` (test stub)
#
# Meant to run on a tight systemd --user timer (e.g. every 5 min) — much
# tighter than the 30 min refresh cadence, so a stalled deploy surfaces fast.
# Installed by scripts/setup/install-node-refresh-systemd.sh.

set -uo pipefail

REPO_ROOT="${CHUMP_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
STATE_DIR="$REPO_ROOT/.chump-locks"
# INFRA-8098: Rust-aware helpers — a non-Rust commit advancing HEAD is not lag.
# shellcheck source=scripts/lib/rust-head.sh
[ -f "$REPO_ROOT/scripts/lib/rust-head.sh" ] && . "$REPO_ROOT/scripts/lib/rust-head.sh"
AMBIENT="${CHUMP_AMBIENT_LOG:-$STATE_DIR/ambient.jsonl}"
SLO="${CHUMP_NODE_DEPLOY_LAG_SLO_SECS:-1800}"
UNIT="${CHUMP_NODE_DEPLOY_LAG_UNIT:-chump-node-refresh.service}"
SYSTEMCTL_BIN="${CHUMP_NODE_DEPLOY_LAG_SYSTEMCTL_BIN:-systemctl}"

# scanner-anchor: "kind":"node_deploy_lag_ok"
# scanner-anchor: "kind":"node_deploy_lag_exceeded"
# scanner-anchor: "kind":"node_deploy_timeout_detected"
emit() {
    local kind="$1" extra="${2:-}"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","kind":"%s"%s}\n' "$ts" "$kind" "${extra:+,$extra}" >> "$AMBIENT" 2>/dev/null || true
}

# --- resolve the installed binary (mirrors node-refresh-chump.sh) -----------
_resolve_target_bin() {
    if [[ -n "${CHUMP_NODE_BIN:-}" ]]; then printf '%s' "$CHUMP_NODE_BIN"; return; fi
    local onpath; onpath="$(command -v chump 2>/dev/null || true)"
    if [[ -n "$onpath" && "$onpath" != *"/target/release/chump" && "$onpath" != *"/target/debug/chump" ]]; then
        printf '%s' "$onpath"; return
    fi
    if [[ -x "$HOME/.cargo/bin/chump" ]]; then printf '%s' "$HOME/.cargo/bin/chump"; return; fi
    printf '%s' "$HOME/.local/bin/chump"
}
TARGET_BIN="$(_resolve_target_bin)"

# 1. Loud, unconditional signal: did the LAST refresh run time out? This is
#    the direct RESILIENT-523 case — checked first and independent of SLO lag,
#    so a single timed-out run pages immediately rather than waiting for the
#    cumulative lag window to elapse.
RESULT="$("$SYSTEMCTL_BIN" --user show "$UNIT" -p Result --value 2>/dev/null || echo "")"
if [[ "$RESULT" == "timeout" ]]; then
    echo "[node-deploy-lag-watchdog] TIMEOUT DETECTED: $UNIT last run Result=timeout"
    emit "node_deploy_timeout_detected" "\"unit\":\"$UNIT\""
fi

# 2. Current main sha + its commit time (best-effort fetch; tolerate offline).
git -C "$REPO_ROOT" fetch origin main --quiet 2>/dev/null || true
MAIN_SHA="$(git -C "$REPO_ROOT" rev-parse origin/main 2>/dev/null)"
MAIN_TIME="$(git -C "$REPO_ROOT" show -s --format=%ct origin/main 2>/dev/null)"
if [[ -z "$MAIN_SHA" || -z "$MAIN_TIME" ]]; then
    echo "[node-deploy-lag-watchdog] cannot resolve origin/main (offline?) — no-op"
    exit 0
fi

# 3. Installed binary sha.
INSTALLED_SHA_SHORT="$("$TARGET_BIN" --version 2>/dev/null | grep -oE '\(([a-f0-9]+)' | head -1 | tr -d '(')"
MAIN_SHA_SHORT="${MAIN_SHA:0:${#INSTALLED_SHA_SHORT}}"
[[ -z "$INSTALLED_SHA_SHORT" ]] && INSTALLED_SHA_SHORT="unknown"

# 4. Compare.
# INFRA-8098: Rust-aware — the binary is current if it contains the last
# Rust-affecting commit, even when HEAD advanced past it on non-Rust commits.
if declare -F binary_has_rust_head >/dev/null 2>&1 && [[ "$INSTALLED_SHA_SHORT" != "unknown" ]]; then
    RUST_SHA="$(rust_head_sha "$REPO_ROOT" "origin/main")"
    if binary_has_rust_head "$RUST_SHA" "$INSTALLED_SHA_SHORT" "$REPO_ROOT"; then
        echo "[node-deploy-lag-watchdog] current (rust-aware): installed=$INSTALLED_SHA_SHORT contains last Rust commit ${RUST_SHA:0:12}; HEAD=$MAIN_SHA_SHORT is non-Rust ahead"
        emit "node_deploy_lag_ok" "\"sha\":\"$MAIN_SHA_SHORT\",\"reason\":\"rust_current\",\"rust_sha\":\"${RUST_SHA:0:12}\""
        exit 0
    fi
fi

if [[ "$INSTALLED_SHA_SHORT" == "$MAIN_SHA_SHORT" && "$INSTALLED_SHA_SHORT" != "unknown" ]]; then
    echo "[node-deploy-lag-watchdog] current: installed=$INSTALLED_SHA_SHORT == main=$MAIN_SHA_SHORT"
    emit "node_deploy_lag_ok" "\"sha\":\"$MAIN_SHA_SHORT\""
    exit 0
fi

NOW="$(date +%s)"
LAG=$(( NOW - MAIN_TIME ))
[[ "$LAG" -lt 0 ]] && LAG=0
LAG_MIN=$(( LAG / 60 ))

if [[ "$LAG" -le "$SLO" ]]; then
    echo "[node-deploy-lag-watchdog] behind but within SLO: installed=$INSTALLED_SHA_SHORT main=$MAIN_SHA_SHORT lag=${LAG_MIN}m (SLO=$(( SLO / 60 ))m) — deploy pending"
    exit 0
fi

# Past SLO: alert + self-heal.
echo "[node-deploy-lag-watchdog] LAG EXCEEDED: installed=$INSTALLED_SHA_SHORT main=$MAIN_SHA_SHORT lag=${LAG_MIN}m > SLO=$(( SLO / 60 ))m"
emit "node_deploy_lag_exceeded" \
    "\"installed_sha\":\"$INSTALLED_SHA_SHORT\",\"main_sha\":\"$MAIN_SHA_SHORT\",\"lag_secs\":$LAG,\"slo_secs\":$SLO,\"unit\":\"$UNIT\""

if [[ "${CHUMP_NODE_DEPLOY_LAG_NO_HEAL:-0}" != "1" ]]; then
    echo "[node-deploy-lag-watchdog] self-heal: restarting $UNIT"
    "$SYSTEMCTL_BIN" --user restart "$UNIT" 2>/dev/null \
        && echo "[node-deploy-lag-watchdog] restart issued" \
        || echo "[node-deploy-lag-watchdog] restart failed (unit not loaded?)"
fi
exit 0
