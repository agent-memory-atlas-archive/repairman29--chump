#!/usr/bin/env bash
# scripts/ops/apex-watchdog.sh — RESILIENT-1098
#
# WHY THIS EXISTS. Post-incident reconstruction of a tonight-fleet-down event:
# the FIRST thing to notice the fleet was down was a human message. On the
# node that wedged, chump-organ-watchdog.timer (the healer that
# reset-failed+restarts dead organs) had no unit installed, and its own
# supervisor (chump-organ-reconcile) only re-enables what IS already
# installed — it cannot notice "the entire node's systemd/reconcile loop is
# gone". Every self-heal layer we have (organ-watchdog, organ-reconcile) lives
# ON the node it heals. A whole-node wedge, or the box going unreachable, has
# no in-band healer: nothing OFF the node was watching.
#
# This is the apex layer ABOVE organ-reconcile/organ-watchdog: a cross-node
# peer heartbeat check (ALT (b) in the gap notes). It is designed to be
# installed on every fleet node via scripts/dispatch/chump-apex-watchdog.timer
# (a plain systemd timer, NOT the operator session, NOT a curator loop) so
# each node watches its PEERS rather than itself. If node A wedges entirely
# — organ-watchdog dead, organ-reconcile dead, systemd itself hosed — node B
# (and C, ...) still notice within one cycle and page, because B's watchdog
# process is running on B's OS, independent of whatever broke on A.
#
# Algorithm, every cycle:
#   1. Read docs/fleet/nodes/*.json (the node registry — RESILIENT-291's
#      node-describe.sh output) to get the peer list: every node_id != self,
#      with its tailnet_ip.
#   2. For each peer, probe liveness: `curl -sf -m <timeout> http://<ip>:<port>/health`
#      (the fleet-server health endpoint every node already runs).
#   3. Track consecutive-miss count per peer in a small state file
#      (.chump-locks/apex-watchdog-state/<peer>.count) so one blip doesn't
#      page — only CHUMP_APEX_WATCHDOG_MISS_THRESHOLD (default 3) consecutive
#      misses trips node_unreachable. This state file IS the cross-cycle
#      memory; it is local to the watching node, not the watched one, so it
#      survives the peer being unreachable.
#   4. On threshold crossed: emit kind=node_unreachable (self-healer-visible
#      escalation — the fleet-wide equivalent of organ_self_heal_failed) and
#      attempt a best-effort remote revive over ssh (reset-failed + restart
#      the peer's own organ-watchdog unit) — the same "no human step" bar as
#      organ-watchdog. Remote heal is now ON BY DEFAULT (RESILIENT-1112):
#      DESIGN_GAPS_SELF_RUNNING.md Gap 2 observed that every control loop,
#      including this one, previously bottomed out in a human noticing the
#      ambient event by hand — remote heal was opt-in (default 0) and nothing
#      auto-escalated on repeated heal failure, so the apex layer's own catch
#      WAS the operator scrolling logs. Set CHUMP_APEX_WATCHDOG_REMOTE_HEAL=0
#      to restore the old opt-out behavior.
#   5. On a peer recovering after prior misses: emit kind=node_reachable_again
#      and reset the counter (including the heal-failure counter below).
#   6. Self-heal escalation ladder (RESILIENT-1112): each cycle the peer stays
#      unreachable, a remote heal attempt is made and tracked per-peer in
#      <peer>.healfail. Only after CHUMP_APEX_WATCHDOG_HEAL_ESCALATE (default
#      2) *consecutive* failed heal attempts does the watchdog call
#      operator-recall.sh --condition NODE_UNREACHABLE_UNHEALED itself — an
#      automated page, not a human stumbling on the ambient line. A human is
#      still the ultimate responder to the page (this cannot page itself out
#      of existence), but the escalation trigger and the self-heal attempts
#      preceding it are now fully automated: the loop tries to fix itself
#      first, and pages only once self-heal is proven exhausted.
#   7. Emit kind=apex_watchdog_tick every cycle (heartbeat) — mirrors
#      organ-watchdog's own organ_watchdog_tick pattern, because the apex
#      watchdog must itself be observable: a dead watchdog-of-the-watchdog is
#      exactly the SPOF this gap exists to cure.
#
# Usage:
#   scripts/ops/apex-watchdog.sh              # scan peers + heal, real curl/ssh
#   scripts/ops/apex-watchdog.sh --dry-run     # report only, no remote heal
#
# Test hooks (used by scripts/ci/test-apex-watchdog.sh):
#   CHUMP_APEX_WATCHDOG_NODES_DIR      — override docs/fleet/nodes directory
#   CHUMP_APEX_WATCHDOG_SELF           — override self node_id (default: hostname)
#   CHUMP_APEX_WATCHDOG_CURL_BIN       — path to a stubbed `curl`
#   CHUMP_APEX_WATCHDOG_SSH_BIN        — path to a stubbed `ssh`
#   CHUMP_APEX_WATCHDOG_STATE_DIR      — override the per-peer miss-count dir
#   CHUMP_APEX_WATCHDOG_MISS_THRESHOLD — consecutive misses before paging (default 3)
#   CHUMP_APEX_WATCHDOG_HEALTH_PORT    — fleet-server health port (default 8080)
#   CHUMP_APEX_WATCHDOG_TIMEOUT_S      — per-peer curl timeout seconds (default 5)
#   CHUMP_APEX_WATCHDOG_REMOTE_HEAL    — 1 = attempt ssh remote revive on threshold trip (default 1, RESILIENT-1112)
#   CHUMP_APEX_WATCHDOG_HEAL_ESCALATE  — consecutive failed heal attempts before auto-paging the operator (default 2, RESILIENT-1112)
#   CHUMP_APEX_WATCHDOG_RECALL_SCRIPT  — path to operator-recall.sh (override for tests)
#   CHUMP_AMBIENT_LOG                  — override ambient.jsonl path
#
# Exit codes:
#   0  normal (whether or not any peer needed paging)
#   1  node registry directory missing/empty — nothing to watch, not fatal
#      to the caller but worth surfacing in logs

set -euo pipefail

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CHUMP_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

NODES_DIR="${CHUMP_APEX_WATCHDOG_NODES_DIR:-$REPO_ROOT/docs/fleet/nodes}"
SELF_NODE="${CHUMP_APEX_WATCHDOG_SELF:-$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)}"
CURL_BIN="${CHUMP_APEX_WATCHDOG_CURL_BIN:-curl}"
SSH_BIN="${CHUMP_APEX_WATCHDOG_SSH_BIN:-ssh}"
STATE_DIR="${CHUMP_APEX_WATCHDOG_STATE_DIR:-$REPO_ROOT/.chump-locks/apex-watchdog-state}"
MISS_THRESHOLD="${CHUMP_APEX_WATCHDOG_MISS_THRESHOLD:-3}"
HEALTH_PORT="${CHUMP_APEX_WATCHDOG_HEALTH_PORT:-8080}"
TIMEOUT_S="${CHUMP_APEX_WATCHDOG_TIMEOUT_S:-5}"
REMOTE_HEAL="${CHUMP_APEX_WATCHDOG_REMOTE_HEAL:-1}"
HEAL_ESCALATE="${CHUMP_APEX_WATCHDOG_HEAL_ESCALATE:-2}"
RECALL_SCRIPT="${CHUMP_APEX_WATCHDOG_RECALL_SCRIPT:-$REPO_ROOT/scripts/dispatch/operator-recall.sh}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

LIB_AMBIENT="$REPO_ROOT/scripts/coord/lib/ambient-write.sh"
# shellcheck source=/dev/null
[[ -f "$LIB_AMBIENT" ]] && source "$LIB_AMBIENT"

mkdir -p "$STATE_DIR" 2>/dev/null || true
mkdir -p "$(dirname "$AMBIENT_LOG")" 2>/dev/null || true

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

emit() {  # kind, key=value ...
    local kind="$1"; shift
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local extra=""
    local kv k v
    for kv in "$@"; do
        k="${kv%%=*}"
        v="${kv#*=}"
        extra+=",\"${k}\":\"$(json_escape "$v")\""
    done
    local line="{\"ts\":\"$ts\",\"kind\":\"$kind\",\"emitter\":\"apex-watchdog\"${extra}}"
    if command -v _ambient_write >/dev/null 2>&1; then
        _ambient_write "$AMBIENT_LOG" "$line"
    else
        printf '%s\n' "$line" >> "$AMBIENT_LOG" 2>/dev/null || true
    fi
}

# ── extract a top-level string field from a node registry JSON file ─────────
node_field() {
    local file="$1" field="$2"
    grep -o "\"${field}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$file" 2>/dev/null \
        | head -1 \
        | sed -E "s/\"${field}\"[[:space:]]*:[[:space:]]*\"([^\"]*)\"/\1/"
}

if [[ ! -d "$NODES_DIR" ]]; then
    echo "[apex-watchdog] node registry dir missing: $NODES_DIR — nothing to watch" >&2
    exit 1
fi

shopt -s nullglob
NODE_FILES=("$NODES_DIR"/*.json)
shopt -u nullglob

if [[ ${#NODE_FILES[@]} -eq 0 ]]; then
    echo "[apex-watchdog] no node registry files in $NODES_DIR — nothing to watch" >&2
    exit 1
fi

PEERS_CHECKED=0
PEERS_PAGED=0

for f in "${NODE_FILES[@]}"; do
    node_id="$(node_field "$f" node_id)"
    [[ -z "$node_id" ]] && node_id="$(basename "$f" .json)"
    [[ "$node_id" == "$SELF_NODE" ]] && continue

    tailnet_ip="$(node_field "$f" tailnet_ip)"
    if [[ -z "$tailnet_ip" ]]; then
        continue
    fi

    PEERS_CHECKED=$((PEERS_CHECKED + 1))
    count_file="$STATE_DIR/${node_id}.count"
    prev_misses=0
    [[ -f "$count_file" ]] && prev_misses="$(cat "$count_file" 2>/dev/null || echo 0)"
    [[ "$prev_misses" =~ ^[0-9]+$ ]] || prev_misses=0

    healfail_file="$STATE_DIR/${node_id}.healfail"

    if "$CURL_BIN" -sf -m "$TIMEOUT_S" "http://${tailnet_ip}:${HEALTH_PORT}/health" >/dev/null 2>&1; then
        # ── peer reachable ──────────────────────────────────────────────
        if [[ "$prev_misses" -ge "$MISS_THRESHOLD" ]]; then
            # scanner-anchor: "kind":"node_reachable_again"  (RESILIENT-1098;
            # fires when a peer that had crossed the miss threshold answers
            # its health probe again)
            emit node_reachable_again "peer=$node_id" "tailnet_ip=$tailnet_ip" "prior_misses=$prev_misses"
        fi
        echo 0 > "$count_file" 2>/dev/null || true
        rm -f "$healfail_file" 2>/dev/null || true
        continue
    fi

    # ── peer unreachable this cycle ─────────────────────────────────────
    new_misses=$((prev_misses + 1))
    echo "$new_misses" > "$count_file" 2>/dev/null || true

    if [[ "$new_misses" -lt "$MISS_THRESHOLD" ]]; then
        continue
    fi

    PEERS_PAGED=$((PEERS_PAGED + 1))
    # scanner-anchor: "kind":"node_unreachable"  (RESILIENT-1098; fires when a
    # peer fails its health probe for MISS_THRESHOLD consecutive cycles — the
    # apex escalation for a whole-node wedge no in-node healer can self-report)
    emit node_unreachable "peer=$node_id" "tailnet_ip=$tailnet_ip" \
        "consecutive_misses=$new_misses" "dry_run=$DRY_RUN"

    if [[ "$REMOTE_HEAL" == "1" && "$DRY_RUN" == "0" ]]; then
        if "$SSH_BIN" -o ConnectTimeout="$TIMEOUT_S" -o BatchMode=yes "$tailnet_ip" \
            "systemctl reset-failed chump-organ-watchdog.service 2>/dev/null; systemctl restart chump-organ-watchdog.service" \
            >/dev/null 2>&1; then
            # scanner-anchor: "kind":"node_remote_heal_attempted"  (RESILIENT-1098; success case)
            emit node_remote_heal_attempted "peer=$node_id" "tailnet_ip=$tailnet_ip" "result=success"
            rm -f "$healfail_file" 2>/dev/null || true
        else
            # scanner-anchor: "kind":"node_remote_heal_attempted"  (RESILIENT-1098; failure case)
            emit node_remote_heal_attempted "peer=$node_id" "tailnet_ip=$tailnet_ip" "result=failed"

            new_healfails=1
            prev_healfails=0
            [[ -f "$healfail_file" ]] && prev_healfails="$(cat "$healfail_file" 2>/dev/null || echo 0)"
            [[ "$prev_healfails" =~ ^[0-9]+$ ]] || prev_healfails=0
            new_healfails=$((prev_healfails + 1))
            echo "$new_healfails" > "$healfail_file" 2>/dev/null || true

            if [[ "$new_healfails" -ge "$HEAL_ESCALATE" && -x "$RECALL_SCRIPT" ]]; then
                # RESILIENT-1112: self-heal is exhausted (HEAL_ESCALATE
                # consecutive failed remote-heal attempts) — page the
                # operator automatically instead of relying on a human to
                # notice node_unreachable in the ambient stream. This is the
                # apex-human catch removed: the loop tries to fix itself
                # first (above) and only reaches for the human once that is
                # proven to have failed, and it reaches for the human itself
                # rather than waiting to be noticed.
                CHUMP_AMBIENT_LOG="$AMBIENT_LOG" "$RECALL_SCRIPT" --condition NODE_UNREACHABLE_UNHEALED \
                    --reason "peer=$node_id ($tailnet_ip) unreachable for ${new_misses} cycles; remote self-heal failed ${new_healfails} consecutive times (>= ${HEAL_ESCALATE})" \
                    >/dev/null 2>&1 || echo "[apex-watchdog]   WARN: operator-recall.sh NODE_UNREACHABLE_UNHEALED call failed" >&2
                # scanner-anchor: "kind":"node_heal_exhausted_recall"  (RESILIENT-1112;
                # fires when consecutive remote-heal failures cross HEAL_ESCALATE —
                # proves the escalation to operator-recall happened automatically)
                emit node_heal_exhausted_recall "peer=$node_id" "tailnet_ip=$tailnet_ip" \
                    "consecutive_heal_failures=$new_healfails" "heal_escalate_threshold=$HEAL_ESCALATE"
            fi
        fi
    fi
done

# scanner-anchor: "kind":"apex_watchdog_tick"  (RESILIENT-1098; emitted every
# cycle, success or no-op — heartbeat proving the apex watchdog is alive)
emit apex_watchdog_tick "self=$SELF_NODE" "peers_checked=$PEERS_CHECKED" \
    "peers_paged=$PEERS_PAGED" "dry_run=$DRY_RUN"

exit 0
