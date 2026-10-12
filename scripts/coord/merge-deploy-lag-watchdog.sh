#!/usr/bin/env bash
# merge-deploy-lag-watchdog.sh (INFRA-3454) — the timing receipt for the
# merge -> deployed-binary chain.
#
# auto-deploy.sh keeps the installed binary current with origin/main, but it's a
# 20-min timer with NO alarm if it stalls (dead daemon, failing build, etc.).
# On 2026-07-28 the installed binary lagged main and needed a manual
# `launchctl kickstart` — nothing would have noticed. This watchdog measures
# the merge->deploy lag and, past an SLO, ALERTS and SELF-HEALS.
#
# Logic:
#   installed_sha == main_sha        -> current, emit merge_deploy_lag_ok, exit 0
#   installed behind, lag <= SLO     -> deploy pending, exit 0 (quiet)
#   installed behind, lag  > SLO     -> emit merge_deploy_lag_exceeded +
#                                        kickstart com.chump.auto-deploy (heal)
#
# lag = now - (author time of origin/main HEAD), i.e. how long the merge has
# been on main without reaching the binary.
#
# Env:
#   CHUMP_DEPLOY_LAG_SLO_SECS   default 1800 (30 min)
#   CHUMP_RUNNER_BIN            default /opt/homebrew/bin/chump
#   CHUMP_DEPLOY_LAG_NO_HEAL=1  alert only, don't kickstart auto-deploy
#
# Meant to run on a short launchd timer (e.g. every 5 min) — much tighter than
# the 20-min deploy cadence, so a stalled deploy surfaces fast.

set -uo pipefail

REPO_ROOT="${CHUMP_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
STATE_DIR="$REPO_ROOT/.chump-locks"
AMBIENT="${CHUMP_AMBIENT_LOG:-$STATE_DIR/ambient.jsonl}"
TARGET_BIN="${CHUMP_RUNNER_BIN:-/opt/homebrew/bin/chump}"
SLO="${CHUMP_DEPLOY_LAG_SLO_SECS:-1800}"

# scanner-anchor: "kind":"merge_deploy_lag_ok"
# scanner-anchor: "kind":"merge_deploy_lag_exceeded"
emit() {
    local kind="$1" extra="${2:-}"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","kind":"%s"%s}\n' "$ts" "$kind" "${extra:+,$extra}" >> "$AMBIENT" 2>/dev/null || true
}

# INFRA-8098: Rust-aware helpers — a non-Rust commit advancing HEAD is not lag.
# shellcheck source=scripts/lib/rust-head.sh
[ -f "$REPO_ROOT/scripts/lib/rust-head.sh" ] && . "$REPO_ROOT/scripts/lib/rust-head.sh"

# 1. Current main sha + its commit time (best-effort fetch; tolerate offline).
git -C "$REPO_ROOT" fetch origin main --quiet 2>/dev/null || true
MAIN_SHA="$(git -C "$REPO_ROOT" rev-parse origin/main 2>/dev/null)"
MAIN_TIME="$(git -C "$REPO_ROOT" show -s --format=%ct origin/main 2>/dev/null)"
if [ -z "$MAIN_SHA" ] || [ -z "$MAIN_TIME" ]; then
    echo "[lag-watchdog] cannot resolve origin/main (offline?) — no-op"
    exit 0
fi

# 2. Installed binary sha.
INSTALLED_SHA_SHORT="$("$TARGET_BIN" --version 2>/dev/null \
    | grep -oE '\(([a-f0-9]+)' | head -1 | tr -d '(' )"
MAIN_SHA_SHORT="${MAIN_SHA:0:${#INSTALLED_SHA_SHORT}}"
[ -z "$INSTALLED_SHA_SHORT" ] && INSTALLED_SHA_SHORT="unknown"

# 3. Compare.
# INFRA-8098: Rust-aware — the binary is current if it contains the last
# Rust-affecting commit, even when HEAD has advanced past it on doc/script/yaml
# commits (which compile to a byte-identical binary). This is checked BEFORE the
# exact-HEAD match so non-Rust lag never trips a false merge_deploy_lag_exceeded.
if declare -F binary_has_rust_head >/dev/null 2>&1 && [ "$INSTALLED_SHA_SHORT" != "unknown" ]; then
    RUST_SHA="$(rust_head_sha "$REPO_ROOT" "origin/main")"
    if binary_has_rust_head "$RUST_SHA" "$INSTALLED_SHA_SHORT" "$REPO_ROOT"; then
        echo "[lag-watchdog] current (rust-aware): installed=$INSTALLED_SHA_SHORT contains last Rust commit ${RUST_SHA:0:12}; HEAD=$MAIN_SHA_SHORT is non-Rust ahead"
        emit "merge_deploy_lag_ok" "\"sha\":\"$MAIN_SHA_SHORT\",\"reason\":\"rust_current\",\"rust_sha\":\"${RUST_SHA:0:12}\""
        exit 0
    fi
fi

if [ "$INSTALLED_SHA_SHORT" = "$MAIN_SHA_SHORT" ] && [ "$INSTALLED_SHA_SHORT" != "unknown" ]; then
    echo "[lag-watchdog] current: installed=$INSTALLED_SHA_SHORT == main=$MAIN_SHA_SHORT"
    emit "merge_deploy_lag_ok" "\"sha\":\"$MAIN_SHA_SHORT\""
    exit 0
fi

NOW="$(date +%s)"
LAG=$(( NOW - MAIN_TIME ))
[ "$LAG" -lt 0 ] && LAG=0
LAG_MIN=$(( LAG / 60 ))

if [ "$LAG" -le "$SLO" ]; then
    echo "[lag-watchdog] behind but within SLO: installed=$INSTALLED_SHA_SHORT main=$MAIN_SHA_SHORT lag=${LAG_MIN}m (SLO=$(( SLO / 60 ))m) — deploy pending"
    exit 0
fi

# Past SLO: alert + self-heal.
echo "[lag-watchdog] LAG EXCEEDED: installed=$INSTALLED_SHA_SHORT main=$MAIN_SHA_SHORT lag=${LAG_MIN}m > SLO=$(( SLO / 60 ))m"
emit "merge_deploy_lag_exceeded" \
    "\"installed_sha\":\"$INSTALLED_SHA_SHORT\",\"main_sha\":\"$MAIN_SHA_SHORT\",\"lag_secs\":$LAG,\"slo_secs\":$SLO"

if [ "${CHUMP_DEPLOY_LAG_NO_HEAL:-0}" != "1" ]; then
    echo "[lag-watchdog] self-heal: kickstarting com.chump.auto-deploy"
    launchctl kickstart -k "gui/$(id -u)/com.chump.auto-deploy" 2>/dev/null \
        && echo "[lag-watchdog] kickstart issued" \
        || echo "[lag-watchdog] kickstart failed (daemon not loaded?)"
fi
exit 0
