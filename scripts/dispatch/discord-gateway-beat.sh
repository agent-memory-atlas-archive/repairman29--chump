#!/usr/bin/env bash
# discord-gateway-beat.sh — RESILIENT-370: host-agnostic entrypoint for the
# serenity-free Discord RECEIVE gateway (scripts/ops/discord-gateway.py).
#
# WHY A BEAT WRAPPER, AND WHY IT LIVES HERE. RESILIENT-266 shipped the gateway
# and a manifest `enabled chump-discord-gateway.service` line, but the only unit
# file lived in scripts/ops/ and the only installer was a Mac launchd script.
# The ATC roster (install-helsinki-atc.sh, TREK-18) derives what to deploy from
# organ-manifest.txt INTERSECTED with the unit files under scripts/dispatch/ —
# so a manifest line with no scripts/dispatch/ unit is declared-but-never-
# installed on every Linux node. helsinki's decommission left the two-way
# operator channel dark with nothing to revive it. This wrapper + its sibling
# unit put the organ where the machinery actually looks.
#
# The wrapper is host-agnostic ON PURPOSE: it self-locates the repo, fixes HOME
# from the run-user, re-resolves creds, and DEGRADES GRACEFULLY (idle, never
# crash-loop) when the token/intent is not available on this node.
set -uo pipefail

# ── Host-agnostic HOME ───────────────────────────────────────────────────────
# systemd may hand us HOME=/root even on a run-user node: install-helsinki-atc
# rewrites `/root/` paths but NOT a bare `Environment=HOME=/root`, because its
# sed only matches `/root/` WITH a trailing slash. Derive HOME from the user we
# actually run as so ~/.chump resolves on every host (Mac, root Linux, CJ).
_run_user="$(id -un 2>/dev/null || echo root)"
_run_home="$(getent passwd "$_run_user" 2>/dev/null | cut -d: -f6)"
[[ -n "${_run_home:-}" && -d "$_run_home" ]] && export HOME="$_run_home"

# ── Self-locate the repo from this script's path ─────────────────────────────
# Works in any checkout/worktree, on any node, regardless of how the unit's
# paths were rewritten.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export CHUMP_REPO="${CHUMP_REPO:-$REPO_ROOT}"
cd "$REPO_ROOT" || exit 1

log() { echo "[discord-gateway-beat] $*" >&2; }

# Best-effort ambient breadcrumb — same sink the python gateway and the fleet's
# board/duty-officer read (.chump-locks/ambient.jsonl).
emit() {
  local kind="$1" extra="${2:-}"
  local sink="$REPO_ROOT/.chump-locks/ambient.jsonl"
  mkdir -p "$REPO_ROOT/.chump-locks" 2>/dev/null || return 0
  printf '{"ts":"%s","kind":"%s"%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$kind" "${extra:+,$extra}" \
    >> "$sink" 2>/dev/null || true
}

# ── Single-instance guard ────────────────────────────────────────────────────
# run-discord.sh warns duplicate instances cause duplicate replies to EVERY
# message. systemd already gives us one; a manual debug run alongside is the
# easy accident. Verify the PID is actually alive (a stale pidfile is exactly
# what made operator-recall look healthy while dead).
PIDFILE="$HOME/.chump/discord-gateway.pid"
mkdir -p "$HOME/.chump" 2>/dev/null || true
if [[ -f "$PIDFILE" ]]; then
  old="$(cat "$PIDFILE" 2>/dev/null || echo '')"
  if [[ "$old" =~ ^[0-9]+$ ]] && kill -0 "$old" 2>/dev/null; then
    log "refusing to start: PID $old already running"; exit 0
  fi
  rm -f "$PIDFILE"
fi
echo $$ > "$PIDFILE"

# ── Resolve creds (reuse notify-operator.sh's config) ────────────────────────
# The unit already sources ~/.chump/providers.env, but re-resolve here so the
# beat also works when creds live in the repo .env (notify-operator.sh's
# convention) or when run by hand. Never echo the values.
if [[ -z "${DISCORD_TOKEN:-}" || -z "${CHUMP_READY_DM_USER_ID:-}" ]]; then
  [[ -f "$REPO_ROOT/scripts/dispatch/lib/load-provider-auth.env" ]] && source "$REPO_ROOT/scripts/dispatch/lib/load-provider-auth.env" "$HOME/.chump/providers.env" 2>/dev/null || true
fi
if [[ -z "${DISCORD_TOKEN:-}" || -z "${CHUMP_READY_DM_USER_ID:-}" ]]; then
  if [[ -f "$REPO_ROOT/scripts/coord/lib/resolve-env.sh" ]]; then
    # shellcheck disable=SC1091
    source "$REPO_ROOT/scripts/coord/lib/resolve-env.sh" 2>/dev/null && chump_env_load 2>/dev/null || true
  fi
fi

# ── GRACEFUL DEGRADATION ─────────────────────────────────────────────────────
# If creds are absent on this node, do NOT crash-loop under Restart=always.
# Stay active-and-idle, emit one ambient breadcrumb, and sleep — an operator
# adding creds + `systemctl restart` picks it up. is-active stays green so the
# organ reads as installed, not failed.
if [[ -z "${DISCORD_TOKEN:-}" || -z "${CHUMP_READY_DM_USER_ID:-}" ]]; then
  log "awaiting DISCORD token/intent — DISCORD_TOKEN/CHUMP_READY_DM_USER_ID not set on $(hostname); idling (add creds to ~/.chump/providers.env then: systemctl restart chump-discord-gateway)"
  emit discord_gateway_awaiting_creds "\"node\":\"$(hostname)\""
  exec sleep infinity
fi

# ── MESSAGE CONTENT intent note ──────────────────────────────────────────────
# Default is DIRECT_MESSAGES only (1<<12 = 4096), which is NOT privileged and
# never gets the gateway disconnected. Free-text DM commands additionally need
# the privileged MESSAGE CONTENT intent enabled in the Discord dev portal AND
# CHUMP_DISCORD_GW_INTENTS=36864 (4096|32768) in providers.env. We do NOT force
# 36864: requesting a privileged intent the portal has not granted makes Discord
# close the connection with 4014 (Disallowed intent), which WOULD crash-loop.
# Buttons + `status`/`ping`/`help` work at 4096; a free-text DM gets a one-line
# nudge to enable the intent. This is graceful-degrade for the intent, matching
# the token degrade above.
log "starting serenity-free gateway (python3 scripts/ops/discord-gateway.py) HOME=$HOME repo=$REPO_ROOT intents=${CHUMP_DISCORD_GW_INTENTS:-4096}"
emit discord_gateway_starting "\"node\":\"$(hostname)\""
exec /usr/bin/python3 "$REPO_ROOT/scripts/ops/discord-gateway.py"
