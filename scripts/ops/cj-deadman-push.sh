#!/usr/bin/env bash
# cj-deadman-push.sh — RESILIENT-1247: CJ's outbound liveness beat.
#
# WHY THIS EXISTS. On 2026-09-16 CJ (the single fleet coordinator + worker) went
# dark for ~13h — its worker log dir vanished, every dispatch failed rc=1, and
# the fleet produced nothing — and NOTHING caught it, because CJ's own pager
# (duty-officer / discord-gateway) runs ON CJ: a CJ-wide failure has no off-node
# witness. CJ and the Oracle nodes are mutually network-isolated (no ssh either
# way, no reachable tailnet port), so an off-node watcher cannot PULL CJ's
# health. The only rendezvous both CJ and an off-node watcher can reach is the
# public internet (GitHub). So CJ PUSHES its liveness OUT to a secret GitHub
# gist every few minutes; an off-node watcher (offnode-deadman-watch.sh, on
# cuphead) grades the freshness and pages the operator CJ-independently if it
# goes stale. Absence of a push == CJ dark. This is a classic dead-man's switch.
#
# WHAT IT PUSHES. A tiny JSON payload with two timestamps:
#   pushed_epoch     — when THIS pusher last ran (catches full-node-dark: if CJ
#                      is down the pusher can't run, pushed_epoch freezes).
#   farmer_hb_epoch  — mtime/contents of CJ's farmer heartbeat (catches
#                      worker-wedge: if the worker loop dies but the box stays
#                      up, the pusher keeps beating but farmer_hb_epoch freezes).
# The watcher pages if EITHER goes stale, so both failure modes are covered.
#
# NO NEW CREDENTIAL. Uses CJ's existing `gh` auth (repairman29). The gist holds
# only a hostname + timestamps — zero secrets — so its id is non-sensitive.
#
# CONFIG (env, or ~/.chump/providers.env):
#   CHUMP_DEADMAN_GIST_ID   the rendezvous gist id (REQUIRED). Not committed to
#                           the repo — lives in providers.env on CJ + cuphead.
#   CHUMP_DEADMAN_GIST_FILE gist filename (default: deadman.json)
#   CHUMP_STATE_DIR         heartbeat dir (default: ~/.chump)
#   CHUMP_DEADMAN_DRY_RUN   1 = build payload + print it, do NOT touch the gist.
#
# INVARIANTS: fail-soft (a broken push must never break CJ), never prints the
# gist id's contents as a secret (it isn't one), self-contained (no repo build).
#
# Reversible: `systemctl --user disable --now chump-cj-deadman-push.timer`.
# shellcheck shell=bash
set -uo pipefail

STATE_DIR="${CHUMP_STATE_DIR:-$HOME/.chump}"
PROVIDERS_ENV="${CHUMP_PROVIDERS_ENV:-$HOME/.chump/providers.env}"
GIST_FILE="${CHUMP_DEADMAN_GIST_FILE:-deadman.json}"
NODE_ID="${CHUMP_NODE_ID:-$(hostname -s 2>/dev/null || hostname)}"

log() { printf '%s [cj-deadman-push] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }

# Pull config from providers.env if not already in the environment.
if [[ -z "${CHUMP_DEADMAN_GIST_ID:-}" && -f "$PROVIDERS_ENV" ]]; then
    CHUMP_DEADMAN_GIST_ID="$(grep -m1 '^CHUMP_DEADMAN_GIST_ID=' "$PROVIDERS_ENV" 2>/dev/null | cut -d= -f2- | tr -d '\042\047')"
fi
GIST_ID="${CHUMP_DEADMAN_GIST_ID:-}"

# --- farmer heartbeat freshness -------------------------------------------------
# The farmer stamps an ISO-8601 UTC line into these files every cycle. Prefer
# whichever is freshest; fall back to file mtime if the contents don't parse.
farmer_epoch=0
for hb in "$STATE_DIR/farmer-heartbeat" "$HOME/Projects/chump/.chump/farmer-heartbeat" "$HOME/chump/.chump/farmer-heartbeat"; do
    [[ -f "$hb" ]] || continue
    # Try to parse the ISO timestamp in the file; else use mtime.
    iso="$(head -1 "$hb" 2>/dev/null | tr -d '[:space:]')"
    e=0
    if [[ -n "$iso" ]]; then
        e="$(date -u -d "$iso" +%s 2>/dev/null || echo 0)"
    fi
    [[ "$e" -eq 0 ]] && e="$(stat -c %Y "$hb" 2>/dev/null || echo 0)"
    [[ "$e" -gt "$farmer_epoch" ]] && farmer_epoch="$e"
done

now_epoch="$(date +%s)"

# --- best-effort secondary: latest local origin/main commit epoch --------------
# No network fetch (that would be slow + noisy); just read the local ref if the
# checkout is present. Purely informational for the watcher; not load-bearing.
main_epoch=0
for repo in "$HOME/Projects/chump" "$HOME/chump"; do
    [[ -d "$repo/.git" ]] || continue
    e="$(git -C "$repo" log -1 --format=%ct origin/main 2>/dev/null || echo 0)"
    [[ "$e" -gt "$main_epoch" ]] && main_epoch="$e"
done

payload="$(printf '{"schema":"chump-deadman/1","node":"%s","farmer_hb_epoch":%s,"pushed_epoch":%s,"origin_main_epoch":%s,"pushed_iso":"%s"}' \
    "$NODE_ID" "$farmer_epoch" "$now_epoch" "$main_epoch" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"

if [[ "${CHUMP_DEADMAN_DRY_RUN:-0}" == "1" ]]; then
    printf '%s\n' "$payload"
    log "dry-run: farmer_hb_epoch=$farmer_epoch pushed_epoch=$now_epoch (gist untouched)"
    exit 0
fi

if [[ -z "$GIST_ID" ]]; then
    log "FATAL: CHUMP_DEADMAN_GIST_ID unset (env or $PROVIDERS_ENV) — nothing to push to"
    exit 1
fi

command -v gh >/dev/null 2>&1 || { log "FATAL: gh not on PATH"; exit 1; }

tmpd="$(mktemp -d)"
trap 'rm -rf "$tmpd"' EXIT
printf '%s\n' "$payload" > "$tmpd/$GIST_FILE"

# `gh gist edit <id> -a <file>` upserts the file whose basename matches. Bounded
# + fail-soft: a GitHub blip must not kill the pass (the watcher's staleness
# hysteresis absorbs a single missed push).
if timeout 45 gh gist edit "$GIST_ID" -a "$tmpd/$GIST_FILE" >/dev/null 2>&1; then
    log "pushed: farmer_hb_epoch=$farmer_epoch (age $((now_epoch-farmer_epoch))s) pushed_epoch=$now_epoch main_epoch=$main_epoch"
    exit 0
else
    log "WARN: gist push failed (network/gh) — will retry next cadence"
    exit 1
fi
