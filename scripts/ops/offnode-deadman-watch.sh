#!/usr/bin/env bash
# offnode-deadman-watch.sh — RESILIENT-1247: the off-CJ witness.
#
# WHY THIS EXISTS. See cj-deadman-push.sh. CJ is the single fleet coordinator +
# worker with no off-node watcher: when it went dark for ~13h on 2026-09-16
# nothing noticed, because its pager runs ON CJ. This script is that missing
# off-node witness. It runs on an always-on box that is NOT CJ (cuphead) and is
# network-isolated from CJ, so it cannot ssh/pull CJ. Instead it reads CJ's
# liveness from the shared rendezvous both boxes can reach — a secret GitHub
# gist that CJ beats into every ~5m — and pages the operator through THIS box's
# OWN Discord token (never through CJ's discord-gateway, which is dead if CJ is).
#
# DETECTION. Reads the gist payload {pushed_epoch, farmer_hb_epoch}:
#   * pushed_epoch stale > STALE  → CJ's pusher stopped: node dark / pusher dead.
#   * farmer_hb_epoch stale > STALE → CJ up but its worker loop wedged.
#   * gist unreadable → fall back to the last-good payload cached locally; only
#     page once THAT crosses STALE (so a transient GitHub/network blip on the
#     watcher side doesn't cry wolf). If we have never had a good read, page.
# Either stale condition → PAGE (halt-class, forces past the escalation registry).
#
# PAGE PATH — CJ-INDEPENDENT. Sources ~/.chump/providers.env and exports
# DISCORD_TOKEN + CHUMP_READY_DM_USER_ID into the environment, then calls the
# fleet's notify-operator.sh (which reads the process env first). The DM is sent
# by THIS box's bot token, so it lands on the operator's phone even with CJ
# entirely down. If notify-operator.sh is absent, a self-contained Discord DM
# mirror is used as a fallback.
#
# STALE MATH. STALE defaults to 20m (4x the 5m push cadence) — long enough to
# absorb a couple of missed pushes, far shorter than the 13h hole this closes.
#
# NON-COORDINATION. This is a pure read+page observer. It NEVER re-enables any
# coordination organ (board-cycle / duty-officer / merge-serializer / etc). It
# is safe to run on a CHUMP_NODE_ROLE=muscle node.
#
# CONFIG (env, or ~/.chump/providers.env):
#   CHUMP_DEADMAN_GIST_ID    rendezvous gist id (REQUIRED; not committed)
#   CHUMP_DEADMAN_GIST_FILE  gist filename (default: deadman.json)
#   CHUMP_DEADMAN_STALE_SECS staleness threshold (default: 1200 = 20m)
#   CHUMP_DEADMAN_STATE_DIR  cache/state dir (default: ~/.chump)
#   CHUMP_DEADMAN_PAGE_SINK  TEST hook: append page payloads here INSTEAD of DMing
#   CHUMP_DEADMAN_PAYLOAD_FILE TEST hook: read the payload from this file, not the gist
#   CHUMP_DEADMAN_NOW_EPOCH  TEST hook: override "now" for deterministic staleness
#
# Reversible: `systemctl --user disable --now chump-offnode-deadman-watch.timer`.
# shellcheck shell=bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${CHUMP_DEADMAN_STATE_DIR:-$HOME/.chump}"
PROVIDERS_ENV="${CHUMP_PROVIDERS_ENV:-$HOME/.chump/providers.env}"
GIST_FILE="${CHUMP_DEADMAN_GIST_FILE:-deadman.json}"
STALE_SECS="${CHUMP_DEADMAN_STALE_SECS:-1200}"
CACHE="$STATE_DIR/offnode-deadman.last-good.json"
WATCHER_NODE="${CHUMP_NODE_ID:-$(hostname -s 2>/dev/null || hostname)}"

log() { printf '%s [offnode-deadman-watch] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
now_epoch() { echo "${CHUMP_DEADMAN_NOW_EPOCH:-$(date +%s)}"; }

# Pull config from providers.env if not already in the environment.
if [[ -z "${CHUMP_DEADMAN_GIST_ID:-}" && -f "$PROVIDERS_ENV" ]]; then
    CHUMP_DEADMAN_GIST_ID="$(grep -m1 '^CHUMP_DEADMAN_GIST_ID=' "$PROVIDERS_ENV" 2>/dev/null | cut -d= -f2- | tr -d '\042\047')"
fi
GIST_ID="${CHUMP_DEADMAN_GIST_ID:-}"

mkdir -p "$STATE_DIR" 2>/dev/null || true

# --- json field extractor (no jq dependency) -----------------------------------
json_int() {  # payload, key
    printf '%s' "$1" | grep -oE "\"$2\"[[:space:]]*:[[:space:]]*[0-9]+" | head -1 | grep -oE '[0-9]+$' || echo 0
}
json_str() {  # payload, key
    printf '%s' "$1" | grep -oE "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/' || echo ""
}

# --- fetch the payload ----------------------------------------------------------
payload=""; source="unknown"
if [[ -n "${CHUMP_DEADMAN_PAYLOAD_FILE:-}" ]]; then
    payload="$(cat "$CHUMP_DEADMAN_PAYLOAD_FILE" 2>/dev/null || echo "")"; source="fixture"
elif [[ -n "$GIST_ID" ]] && command -v gh >/dev/null 2>&1; then
    payload="$(timeout 30 gh api "gists/$GIST_ID" --jq ".files[\"$GIST_FILE\"].content" 2>/dev/null || echo "")"; source="gist"
fi

read_ok=1
[[ -z "$payload" || "$payload" != *pushed_epoch* ]] && read_ok=0

if [[ "$read_ok" -eq 1 ]]; then
    # cache the good read for blip-tolerance
    printf '%s\n' "$payload" > "$CACHE" 2>/dev/null || true
else
    # fall back to last-good cache
    if [[ -f "$CACHE" ]]; then
        payload="$(cat "$CACHE" 2>/dev/null || echo "")"; source="cache"
        log "WARN: live read failed ($source) — grading last-good cache"
    fi
fi

# --- page helper ---------------------------------------------------------------
page() {  # kind, message
    local kind="$1" msg="$2"
    log "PAGE ($kind): $msg"
    # TEST sink: capture without DMing anyone.
    if [[ -n "${CHUMP_DEADMAN_PAGE_SINK:-}" ]]; then
        printf '%s\tPAGE\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$kind" "$msg" \
            >> "$CHUMP_DEADMAN_PAGE_SINK" 2>/dev/null || true
        return 0
    fi
    # Real page: reuse the fleet's notify-operator with THIS box's own token.
    # notify-operator reads DISCORD_TOKEN / CHUMP_READY_DM_USER_ID from the
    # process env first, so export them from providers.env before calling.
    [[ -f "$PROVIDERS_ENV" ]] && { set -a; . "$PROVIDERS_ENV"; set +a; }
    local notifier="$SCRIPT_DIR/../coord/lib/notify-operator.sh"
    if [[ -f "$notifier" ]] && [[ -n "${DISCORD_TOKEN:-}" ]]; then
        ( export DISCORD_TOKEN CHUMP_READY_DM_USER_ID
          CHUMP_NOTIFY_KIND="$kind" CHUMP_NOTIFY_SEVERITY=halt \
            bash "$notifier" "🛑 [deadman/$WATCHER_NODE] $msg" ) >/dev/null 2>&1 \
            && { log "paged via notify-operator"; return 0; }
    fi
    # Fallback: self-contained Discord DM mirror (open DM channel, post message).
    if [[ -n "${DISCORD_TOKEN:-}" && -n "${CHUMP_READY_DM_USER_ID:-}" ]]; then
        local chan
        chan="$(curl -s -m 10 -X POST "https://discord.com/api/v10/users/@me/channels" \
            -H "Authorization: Bot $DISCORD_TOKEN" -H "Content-Type: application/json" \
            -d "{\"recipient_id\":\"$CHUMP_READY_DM_USER_ID\"}" 2>/dev/null \
            | grep -oE '"id"[[:space:]]*:[[:space:]]*"[0-9]+"' | head -1 | grep -oE '[0-9]+')"
        if [[ -n "$chan" ]]; then
            curl -s -m 10 -o /dev/null -X POST "https://discord.com/api/v10/channels/$chan/messages" \
                -H "Authorization: Bot $DISCORD_TOKEN" -H "Content-Type: application/json" \
                -d "$(printf '{"content":%s}' "\"🛑 [deadman/$WATCHER_NODE] $msg\"")" 2>/dev/null \
                && { log "paged via fallback DM mirror"; return 0; }
        fi
    fi
    log "ERROR: no working page path (DISCORD_TOKEN unset?) — CJ-dark went unpaged"
    return 1
}

# --- grade ---------------------------------------------------------------------
NOW="$(now_epoch)"

if [[ -z "$payload" || "$payload" != *pushed_epoch* ]]; then
    page "cj_deadman_unreadable" "cannot read CJ liveness from rendezvous (gist $GIST_ID) and no cached beat — CJ health UNKNOWN"
    exit 0
fi

node="$(json_str "$payload" node)"; [[ -z "$node" ]] && node="closetjunky"
pushed="$(json_int "$payload" pushed_epoch)"
farmer="$(json_int "$payload" farmer_hb_epoch)"
push_age=$(( NOW - pushed ))
farmer_age=$(( NOW - farmer ))

dark=0
if [[ "$pushed" -eq 0 || "$push_age" -gt "$STALE_SECS" ]]; then
    dark=1
    page "cj_deadman_dark" "CJ ($node) has not beaten in ${push_age}s (> ${STALE_SECS}s) via $source — node dark or pusher dead. Fleet has NO coordinator/worker."
fi
if [[ "$dark" -eq 0 && ( "$farmer" -eq 0 || "$farmer_age" -gt "$STALE_SECS" ) ]]; then
    dark=1
    page "cj_deadman_worker_wedged" "CJ ($node) is beating but its WORKER heartbeat is stale ${farmer_age}s (> ${STALE_SECS}s) via $source — worker wedged, fleet producing nothing."
fi

if [[ "$dark" -eq 0 ]]; then
    log "OK: CJ ($node) alive — push_age=${push_age}s farmer_age=${farmer_age}s (stale>${STALE_SECS}s) source=$source"
fi
exit 0
