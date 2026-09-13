#!/usr/bin/env bash
# RESILIENT-283: headless-native worker runner. One worker.sh loop, no tmux
# dashboard. Systemd's minimal environment lacks HOME/PATH/USER, so derive the
# node context from the installed script rather than the historical root box.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="${CHUMP_REPO:-$DEFAULT_REPO_ROOT}"

if ! git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "[worker-run] ERROR: no Chump checkout at $REPO_ROOT (set CHUMP_REPO)" >&2
    exit 1
fi

if [[ -z "${HOME:-}" || ! -d "$HOME" ]]; then
    RUN_USER="${USER:-$(id -un 2>/dev/null || echo root)}"
    HOME="$(getent passwd "$RUN_USER" 2>/dev/null | cut -d: -f6 || true)"
    HOME="${HOME:-/tmp}"
fi
export HOME
export USER="${USER:-$(id -un 2>/dev/null || echo root)}"
export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$HOME/bin:/usr/local/bin:/usr/bin:/bin"

# A node install puts its verified binary at <node>/bin/chump while its checkout
# lives at <node>/repo. Prefer that exact binary so the worker and the refresh
# timer converge on one runtime rather than whichever stale copy happens to be
# earlier in a service's inherited PATH.
NODE_DIR="${CHUMP_NODE_DIR:-$(cd "$REPO_ROOT/.." && pwd)}"
NODE_BIN="${CHUMP_NODE_BIN:-$NODE_DIR/bin/chump}"
if [[ -x "$NODE_BIN" ]]; then
    export PATH="$(dirname "$NODE_BIN"):$PATH"
fi

if [[ -r "$HOME/.chump/providers.env" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$HOME/.chump/providers.env"
    set +a
fi

# Avoid a compile stampede when a node has several workers. An explicit
# operator value still wins; otherwise split available CPU capacity among the
# active worker loops and never drop below one job.
if [[ -z "${CARGO_BUILD_JOBS:-}" ]]; then
    _cores="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
    _cores="${_cores:-$(sysctl -n hw.ncpu 2>/dev/null || true)}"
    _cores="${_cores:-1}"
    _workers_up="$(pgrep -fc '[w]orker.sh' 2>/dev/null || true)"
    [[ "${_workers_up:-0}" -lt 1 ]] && _workers_up=1
    _auto_jobs=$(( _cores / _workers_up ))
    [[ "$_auto_jobs" -lt 1 ]] && _auto_jobs=1
    export CARGO_BUILD_JOBS="$_auto_jobs"
fi

export CHUMP_AUTH_MODE="${CHUMP_AUTH_MODE:-oauth}"
export CHUMP_REPO="$REPO_ROOT"
export IS_SANDBOX="${IS_SANDBOX:-1}"
export FLEET_MODEL="${FLEET_MODEL:-sonnet}"
export TERM="${TERM:-dumb}"
export AGENT_ID="${1:?need AGENT_ID}"
export FLEET_SESSION="${FLEET_SESSION:-ops}"

cd "$REPO_ROOT"
exec bash "$REPO_ROOT/scripts/dispatch/worker.sh"
