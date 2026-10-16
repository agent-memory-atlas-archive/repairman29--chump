#!/usr/bin/env bash
# scripts/coord/farmer.sh — RESILIENT-068
#
# dev.chump.farmer — un-killable control-plane tender.
#
# DESIGN AXIOM: no shared failure mode with the layer it revives.
#   - Pure /bin/bash + coreutils (launchctl/sqlite3/pgrep/test/rm/date)
#   - NEVER calls cargo-installed binaries on the recovery hot path
#   - NEVER reads GitHub cache / smee / NATS / GraphQL
#   - NEVER obeys .chump/fleet-paused — reads it as DATA to act on
#
# Launchd: KeepAlive=true + StartInterval=60 (install via
#   scripts/setup/install-farmer-launchd.sh)
#
# Six failure modes it auto-recovers (see FARMER_2026-06-03.md):
#   1. pause-deadlock  — slo passes → rm sentinel + kickstart exit-78 daemons
#   2. crash-no-restart — daemon in exit-127 → restore binary + kick;
#                         else kick; escalate after 3 kicks/10min (RESILIENT-058)
#   3. auth-death      — oauth token stale → operator_recall AUTH_DEAD
#   4. silent-worker   — stale lease + no ambient heartbeat → release + kick choir
#   5. stale-sentinel  — sentinel >15min AND slo-check passes → rm
#   6. dead-supervisor — supervisor not loaded → kickstart it
#
# Revive order (OTP rest_for_one):
#   substrate → supervisors → choir → workers
#
# Event kinds (registered in docs/observability/EVENT_REGISTRY.yaml):
# scanner-anchor: "kind":"farmer_heartbeat"
# scanner-anchor: "kind":"farmer_pause_lifted"
# scanner-anchor: "kind":"farmer_daemon_kicked"
# scanner-anchor: "kind":"farmer_auth_dead"
# scanner-anchor: "kind":"farmer_auth_halt"
# scanner-anchor: "kind":"farmer_silent_worker"
# scanner-anchor: "kind":"farmer_escalated"
# scanner-anchor: "kind":"dispatch_orphan_reaped"
#
# Usage:
#   bash scripts/coord/farmer.sh         # run one tick (launchd calls this)
#   FARMER_DRY_RUN=1 bash scripts/coord/farmer.sh   # dry-run (no launchctl/rm)
#
# Env:
#   CHUMP_REPO_ROOT               — override repo root detection
#   FARMER_DRY_RUN=1              — dry-run mode: log actions, don't take them
#   FARMER_OAUTH_MAX_AGE_S=3600   — max oauth token age before AUTH_DEAD (default 3600)
#   FARMER_SENTINEL_MAX_AGE_S=900 — max sentinel age for stale-sentinel check (default 900)
#   FARMER_SILENT_WORKER_S=1800   — lease mtime age before considered silent (default 1800)
#   FARMER_KICK_ESCALATE_N=3      — kicks before escalating per daemon (default 3)
#   FARMER_KICK_WINDOW_S=600      — window for kick count (default 600)

set -uo pipefail

# ── Resolve repo root (NO git call — pure path arithmetic, can't fail) ────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
REPO_ROOT="${CHUMP_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." 2>/dev/null && pwd)}"
LOCK_DIR="$REPO_ROOT/.chump-locks"
CHUMP_DIR="$REPO_ROOT/.chump"
mkdir -p "$LOCK_DIR" "$CHUMP_DIR"

# INFRA-8198: reap_dispatch_orphans — see scripts/coord/lib/dispatch-orphan-reaper.sh.
# shellcheck source=scripts/coord/lib/dispatch-orphan-reaper.sh
source "$SCRIPT_DIR/lib/dispatch-orphan-reaper.sh"

# ── Knobs ─────────────────────────────────────────────────────────────────────
DRY_RUN="${FARMER_DRY_RUN:-0}"
OAUTH_MAX_AGE_S="${FARMER_OAUTH_MAX_AGE_S:-3600}"
SENTINEL_MAX_AGE_S="${FARMER_SENTINEL_MAX_AGE_S:-900}"
SILENT_WORKER_S="${FARMER_SILENT_WORKER_S:-1800}"
KICK_ESCALATE_N="${FARMER_KICK_ESCALATE_N:-3}"
KICK_WINDOW_S="${FARMER_KICK_WINDOW_S:-600}"

AMBIENT="$LOCK_DIR/ambient.jsonl"
SENTINEL="$CHUMP_DIR/fleet-paused"
KICK_STATE="$CHUMP_DIR/farmer-kick-state.json"
HEARTBEAT_FILE="$CHUMP_DIR/farmer-heartbeat"

# RESILIENT-331: per-tick outcome counters (I-did-X, not just I-ran). Reset at
# the top of each tick, folded into the closing farmer_heartbeat's `counts` so
# chairman-pulse.sh can tell a tick that healed something from one that just
# turned over.
TICK_KICKED_N=0
TICK_SILENT_N=0
TICK_ESCALATED_N=0

# ── Core helpers (zero chump dependencies) ────────────────────────────────────
_ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
_now() { date +%s; }

log() { printf '[farmer %s] %s\n' "$(_ts)" "$*"; }

# Append one JSON line to ambient.jsonl (no flock dep — plain append is
# atomic enough for single-line writes on local fs).
emit() {
    local kind="$1"
    shift
    local extra="${1:-}"
    local line
    if [[ -n "$extra" ]]; then
        line="{\"ts\":\"$(_ts)\",\"kind\":\"${kind}\",${extra}}"
    else
        line="{\"ts\":\"$(_ts)\",\"kind\":\"${kind}\"}"
    fi
    printf '%s\n' "$line" >> "$AMBIENT" 2>/dev/null || \
        log "WARN: ambient write failed for kind=$kind"
}

# ── Portable file mtime (epoch seconds), ALWAYS a clean integer ───────────────
# RESILIENT-313: the old inline `stat -f %m F || stat -c %Y F` is a macOS-first
# ordering that is TOXIC on GNU/Linux. On Linux `stat -f` means --file-system and
# `%m` is parsed as a SECOND path arg → stat prints a multi-line filesystem block
# to stdout AND exits non-zero, so the `||` fallback output gets CONCATENATED with
# that garbage. The result (`  File: "...\n ID: ..."`) then flows into `$(( now -
# mtime ))`, where under `set -u` the token `File` is an unbound variable and the
# whole tick dies BEFORE write_heartbeat — the farmer's one job. Any present/stale
# claim-*.json lease was enough to trip it. This helper is GNU-first, BSD-second,
# and sanitizes to digits so a non-numeric result can never crash arithmetic.
_mtime() {
    local f="$1" m
    m="$(stat -c %Y "$f" 2>/dev/null)" || m="$(stat -f %m "$f" 2>/dev/null)" || m=0
    [[ "$m" =~ ^[0-9]+$ ]] || m=0
    printf '%s' "$m"
}

# Write/update the heartbeat file (local only, no network).
# RESILIENT-313: dual-write — the in-repo path (what the worker binary's
# farmer-gate reads, src/farmer_status.rs) PLUS a durable out-of-repo copy under
# $HOME/.chump that survives the fleet's `git reset --hard` / `git clean` of the
# repo checkout. The 30s chump-farmer.timer rewrites both every tick, so even a
# reset that deletes the in-repo copy leaves it stale for <30s — well under the
# 120s freshness threshold.
write_heartbeat() {
    local ts; ts="$(_ts)"
    printf '%s\n' "$ts" > "$HEARTBEAT_FILE" 2>/dev/null || true
    local durable="${HOME:-/root}/.chump/farmer-heartbeat"
    if [[ "$durable" != "$HEARTBEAT_FILE" ]]; then
        mkdir -p "${HOME:-/root}/.chump" 2>/dev/null || true
        printf '%s\n' "$ts" > "$durable" 2>/dev/null || true
    fi
}

# ── Dry-run wrapper ───────────────────────────────────────────────────────────
run_cmd() {
    if [[ "$DRY_RUN" == "1" ]]; then
        log "[dry-run] would run: $*"
    else
        "$@" 2>/dev/null || true
    fi
}

# ── slo_check (read-only, no chump binary) ────────────────────────────────────
# Replicates the ghost-gap SLO: open gaps where closed_pr is set → ghost count.
# Threshold mirrors INFRA-1607 (L2-SLO-5 = 2).
# Uses sqlite3 only — if db is absent, treat SLO as passing (safe default).
slo_check_passes() {
    local db="$CHUMP_DIR/state.db"
    [[ -f "$db" ]] || { log "state.db absent — treating SLO as pass"; return 0; }
    local ghost_count
    ghost_count=$(sqlite3 "$db" \
        "SELECT COUNT(*) FROM gaps WHERE status='open' AND closed_pr IS NOT NULL AND closed_pr != '';" \
        2>/dev/null || echo "0")
    # Also check waste rate proxy: open gaps with closed_pr / total open
    local total_open
    total_open=$(sqlite3 "$db" \
        "SELECT COUNT(*) FROM gaps WHERE status='open';" \
        2>/dev/null || echo "0")
    log "slo_check: ghost_count=$ghost_count total_open=$total_open"
    if [[ "$ghost_count" -le 2 ]]; then
        return 0
    fi
    return 1
}

# ── Daemon helpers ────────────────────────────────────────────────────────────
# All known control-plane daemon labels (supervisors + choir).
# These are loaded by launchd; we monitor + revive them.
CONTROL_PLANE_LABELS=(
    "com.chump.bot-merge-watchdog"
    "com.chump.main-health-watchdog"
    "com.chump.reap-stale-leases"
    "com.chump.stale-process-watchdog"
    "com.chump.heartbeat-watcher"
    "com.chump.ci-health-gate"
    "com.chump.queue-health-monitor"
    "dev.chump.premature-closure-watch"
    "dev.chump.system-invariants-monitor"
    "com.chump.integrator-daemon"
)

# RESILIENT-132 AC#5: labels whose ProgramArguments binary path is baked in
# at install time by a dedicated installer (not a static repo script path).
# exit=127 for these means the baked path is stale/missing — a bare
# `launchctl kickstart` re-runs the SAME broken command and just loops. The
# fix is to re-run the installer (idempotent, re-resolves the binary and
# rewrites the plist) before kickstarting.
declare -A LABEL_REPAIR_INSTALLER=(
    ["com.chump.integrator-daemon"]="scripts/setup/install-integrator-daemon.sh"
)

# _repair_daemon_binary LABEL — re-run the label's installer (if any) to
# rebake a stale ProgramArguments binary path. No-op for labels without a
# registered installer.
_repair_daemon_binary() {
    local label="$1"
    local installer="${LABEL_REPAIR_INSTALLER[$label]:-}"
    [[ -z "$installer" ]] && return 0
    local installer_path="$REPO_ROOT/$installer"
    if [[ -x "$installer_path" ]]; then
        log "$label exit=127 — re-running installer to rebake binary path: $installer"
        run_cmd bash "$installer_path"
        emit "farmer_daemon_binary_repaired" "\"label\":\"$label\",\"installer\":\"$installer\""
    else
        log "$label exit=127 — no installer found at $installer_path, skipping rebake"
    fi
}

# label_is_loaded LABEL — returns 0 if launchd has the label loaded
label_is_loaded() {
    launchctl list 2>/dev/null | grep -qF "$1"
}

# label_last_exit LABEL — get last exit status from launchctl list output
label_last_exit() {
    launchctl list 2>/dev/null | awk -v lbl="$1" '$0 ~ lbl {print $2}' | head -1
}

# kick_daemon LABEL — launchctl kickstart (respects DRY_RUN)
kick_daemon() {
    local label="$1"
    log "kicking $label"
    run_cmd launchctl kickstart -k "gui/$(id -u)/$label"
    emit "farmer_daemon_kicked" "\"label\":\"$label\""
    TICK_KICKED_N=$(( TICK_KICKED_N + 1 ))
}

# ── Kick-escalation tracker ───────────────────────────────────────────────────
# State file: JSON {"label": {"kicks": [ts,...], "escalated": bool}}
kick_count_in_window() {
    local label="$1"
    local now; now="$(_now)"
    local window_start=$(( now - KICK_WINDOW_S ))
    [[ -f "$KICK_STATE" ]] || { echo 0; return; }
    python3 -c "
import json, sys
try:
    d = json.load(open('$KICK_STATE'))
    kicks = d.get('$label', {}).get('kicks', [])
    print(sum(1 for t in kicks if t >= $window_start))
except Exception:
    print(0)
" 2>/dev/null || echo 0
}

record_kick() {
    local label="$1"
    local now; now="$(_now)"
    local window_start=$(( now - KICK_WINDOW_S ))
    local state="{}"
    [[ -f "$KICK_STATE" ]] && state="$(cat "$KICK_STATE" 2>/dev/null || echo '{}')"
    python3 -c "
import json, sys, os
try:
    d = json.loads('$state') if '$state'.strip() else {}
    entry = d.get('$label', {'kicks': [], 'escalated': False})
    entry['kicks'] = [t for t in entry['kicks'] if t >= $window_start] + [$now]
    d['$label'] = entry
    with open('$KICK_STATE', 'w') as f:
        json.dump(d, f)
except Exception as e:
    sys.stderr.write(str(e)+'\n')
" 2>/dev/null || true
}

should_escalate() {
    local label="$1"
    local count; count="$(kick_count_in_window "$label")"
    [[ "$count" -ge "$KICK_ESCALATE_N" ]] && return 0
    return 1
}

mark_escalated() {
    local label="$1"
    [[ -f "$KICK_STATE" ]] || return
    python3 -c "
import json
try:
    d = json.load(open('$KICK_STATE'))
    d.setdefault('$label', {})['escalated'] = True
    json.dump(d, open('$KICK_STATE','w'))
except Exception: pass
" 2>/dev/null || true
}

already_escalated() {
    local label="$1"
    [[ -f "$KICK_STATE" ]] || { echo 0; return; }
    python3 -c "
import json
try:
    d = json.load(open('$KICK_STATE'))
    print(1 if d.get('$label',{}).get('escalated') else 0)
except Exception:
    print(0)
" 2>/dev/null || echo 0
}

# ── operator_recall shim (pure bash, no chump binary) ─────────────────────────
# Writes a HALT-class recall to ambient.jsonl so the watchdog (RESILIENT-071)
# pages the operator. Does NOT call scripts/dispatch/operator-recall.sh which
# may itself be blocked.
# CREDIBLE-090 enforcement: POSITIVE proof of fleet life. A merge to origin/main
# in the last hour is the canonical "is the fleet alive" instrument (CLAUDE.md:
# the recent-merge ground truth is the only proof of life). Cheap, local-ref, no
# network, no chump binary. Overridable in tests.
_fleet_shipped_recently() {
    local _r
    _r="$(git -C "$REPO_ROOT" log origin/main --since='1 hour ago' --oneline 2>/dev/null | head -1 || true)"
    [[ -n "$_r" ]]
}

operator_page() {
    local reason="$1"
    local detail="${2:-}"
    # CREDIBLE-090 — CHECK THE INSTRUMENT BEFORE PULLING THE ALARM. For
    # fleet/auth aliveness halt-classes, a recent merge proves the fleet is
    # alive, so the belief ("X is dead/broken/starved") is refuted — suppress
    # the cry-wolf page instead of waking the operator. Detectors firing
    # halt-class recalls without verifying outcomes are why the operator got
    # paged ~6x/min on a false AUTH_DEAD (INFRA-2031). Fail-open: any error in
    # the check leaves _r empty -> falls through to paging (never suppress a
    # real outage on error).
    case "$reason" in
        AUTH_DEAD|CI_BROKEN|FLEET_DEAD|QUEUE_STARVE|NOTHING_SHIPPING)
            if _fleet_shipped_recently; then
                log "operator_page SUPPRESSED ($reason): origin/main shipped in last 1h — fleet provably alive, halt-class belief refuted"
                emit "operator_recall_suppressed" "\"reason\":\"$reason\",\"suppressed_because\":\"recent_merge_proves_fleet_alive\",\"detail\":\"$detail\""
                return
            fi
            ;;
    esac
    log "OPERATOR PAGE: $reason $detail"
    emit "operator_recall" "\"reason\":\"$reason\",\"detail\":\"$detail\",\"class\":\"halt\""
}

# ── Mode 3: auth-death ─────────────────────────────────────────────────────────
# RESILIENT-113 (durable-fix per docs/process/DURABLE_FIX_DOCTRINE.md):
# Previously this checked only ~/.chump/oauth-token.json age. Shallow — never
# validated whether the OPERATOR's auth path (api-key / oauth / auto per
# CLAUDE.md §Auth modes) was actually working. Empirical 2026-06-05: operator
# on CHUMP_AUTH_MODE=auto with ANTHROPIC_API_KEY in .env → fleet shipping
# 8 PRs / 6 sibling claims / gh pr list responding → AUTH WAS FINE →
# AUTH_DEAD fired ~1.1/min anyway (274 false positives in 4h). The durable
# fix is to validate the chosen auth mode FIRST, only paging when there's
# NO working auth path.
check_auth() {
    # ── Layer 1: API-key path (per CLAUDE.md §Auth modes) ────────────────
    # Read ANTHROPIC_API_KEY from $REPO_ROOT/.env if not in env (launchd
    # context doesn't auto-source .env). Safe-parse: grep+cut+sed, no eval.
    local api_key="${ANTHROPIC_API_KEY:-}"
    if [[ -z "$api_key" && -f "$REPO_ROOT/.env" ]]; then
        api_key="$(grep -E '^ANTHROPIC_API_KEY=' "$REPO_ROOT/.env" 2>/dev/null \
                  | head -1 | cut -d= -f2- \
                  | sed 's/^"//;s/"$//;s/^'"'"'//;s/'"'"'$//')"
    fi
    local auth_mode="${CHUMP_AUTH_MODE:-auto}"

    # scanner-anchor: "kind":"farmer_auth_ok"
    # api-key mode + key present → AUTH OK, skip OAuth entirely.
    if [[ "$auth_mode" == "api-key" && -n "$api_key" ]]; then
        emit "farmer_auth_ok" "\"path\":\"api_key\",\"mode\":\"api-key\""
        return
    fi
    # auto mode + key present → api-key is the preferred fallback; OAuth dormant.
    if [[ "$auth_mode" == "auto" && -n "$api_key" ]]; then
        emit "farmer_auth_ok" "\"path\":\"api_key\",\"mode\":\"auto\""
        return
    fi
    # api-key mode + NO key → genuine misconfig; page (this IS halt-class).
    if [[ "$auth_mode" == "api-key" && -z "$api_key" ]]; then
        operator_page "AUTH_DEAD" "CHUMP_AUTH_MODE=api-key but ANTHROPIC_API_KEY unset"
        emit "farmer_auth_dead" "\"reason\":\"api_key_mode_no_key\""
        return
    fi

    # ── Layer 2: OAuth path (CHUMP_AUTH_MODE=oauth, or auto+no-api-key) ──
    # INFRA-2031 durable fix — CHECK THE INSTRUMENT BEFORE PULLING THE ALARM.
    # The fleet falls back to ANTHROPIC_API_KEY on any OAuth 401 (CLAUDE.md
    # §Auth modes), so a stale/absent OAuth token is NOT auth-death when an
    # api-key floor exists. The prior code paged AUTH_DEAD here claiming "no
    # ANTHROPIC_API_KEY fallback" without ever reading $api_key — a halt-class
    # cry-wolf (274 false positives in 4h; then 6×/min in oauth mode). AUTH_DEAD
    # may fire ONLY when there is genuinely NO working auth path.
    if [[ -n "$api_key" ]]; then
        emit "farmer_auth_ok" "\"path\":\"api_key_fallback\",\"mode\":\"${auth_mode}\",\"note\":\"oauth stale/absent but api-key floor present\""
        return
    fi

    # RESILIENT-147: VALIDITY over AGE. A long-lived token (e.g. `claude
    # setup-token`, ~1yr) is valid regardless of file mtime; the legacy
    # age>OAUTH_MAX_AGE_S heuristic below false-paged AUTH_DEAD on it — the
    # fleet shipped fine on a 23h-old-but-valid token while the farmer cried
    # AUTH_DEAD purely off file age (the 2026-06-15 multi-day false-outage).
    # Prefer the auth-status.sh validity probe — "can the fleet actually
    # transact?" — and fall back to the age heuristic only when the probe
    # script isn't present on this checkout (backward compatible).
    local probe="$REPO_ROOT/scripts/coord/auth-status.sh"
    if [[ -x "$probe" ]]; then
        if "$probe" --quiet >/dev/null 2>&1; then
            emit "farmer_auth_ok" "\"path\":\"oauth\",\"mode\":\"${auth_mode}\",\"via\":\"validity_probe\""
        else
            # CREDIBLE-136: signal != outcome (CREDIBLE-090) — a single BROKEN
            # verdict can be a transient probe failure (network blip, one-off
            # claude -p timeout), not a genuine outage. Force ONE fresh re-probe
            # (--probe bypasses auth-status.sh's own cache) before paging
            # halt-class AUTH_DEAD; if the re-probe comes back OK, the first
            # failure was transient and must not be replayed as an outage.
            if "$probe" --probe --quiet >/dev/null 2>&1; then
                emit "farmer_auth_ok" "\"path\":\"oauth\",\"mode\":\"${auth_mode}\",\"via\":\"validity_probe_reprobe_ok\",\"note\":\"first probe was BROKEN, re-probe OK — transient\""
            else
                operator_page "AUTH_DEAD" "auth-status.sh validity probe reports BROKEN (oauth path, mode=${auth_mode}) on TWO consecutive probes"
                emit "farmer_auth_dead" "\"reason\":\"validity_probe_broken\",\"mode\":\"${auth_mode}\",\"via\":\"validity_probe\",\"reprobed\":true"
                # RESILIENT-1566: green-heartbeat-but-no-auth is silent death — HALT
                # workers (fleet-paused sentinel) and say so loudly, same tick.
                if [[ "$DRY_RUN" != "1" ]]; then
                    printf 'AUTH_DEAD: live probe BROKEN x2 at %s\n' "$(_ts)" > "$SENTINEL" 2>/dev/null || true
                fi
                emit "farmer_auth_halt" "\"reason\":\"live_probe_broken\",\"sentinel\":\"${SENTINEL}\""
                printf '\n*** FARMER RED: AUTH BROKEN (live probe x2) — workers HALTED via %s ***\n\n' "$SENTINEL" >&2
            fi
        fi
        return
    fi
    local token_file="$HOME/.chump/oauth-token.json"
    [[ -f "$token_file" ]] || {
        operator_page "AUTH_DEAD" "oauth-token.json absent AND no ANTHROPIC_API_KEY fallback"
        emit "farmer_auth_dead" "\"reason\":\"token_file_absent_no_apikey\",\"mode\":\"${auth_mode}\""
        return
    }
    local mtime now age
    mtime=$(_mtime "$token_file")   # RESILIENT-313: portable, always-integer
    now="$(_now)"
    age=$(( now - mtime ))
    if [[ "$age" -gt "$OAUTH_MAX_AGE_S" ]]; then
        log "oauth token is ${age}s old (max ${OAUTH_MAX_AGE_S}s) AND no api-key fallback — paging"
        operator_page "AUTH_DEAD" "oauth token ${age}s old AND no ANTHROPIC_API_KEY fallback"
        emit "farmer_auth_dead" "\"token_age_s\":$age,\"mode\":\"${auth_mode}\",\"reason\":\"oauth_stale_no_apikey\""
    fi
}

# ── Mode 4: silent-worker ──────────────────────────────────────────────────────
check_silent_workers() {
    local now; now="$(_now)"
    # Find leases that have a heartbeat file older than SILENT_WORKER_S
    # and no recent ambient event from that session.
    for lease_file in "$LOCK_DIR"/claim-*.json; do
        [[ -f "$lease_file" ]] || continue
        local mtime
        mtime=$(_mtime "$lease_file")   # RESILIENT-313: was the crash site (macOS stat -f on Linux)
        local age=$(( now - mtime ))
        [[ "$age" -lt "$SILENT_WORKER_S" ]] && continue
        # Stale lease — check if session has recent ambient activity
        local session_id
        session_id=$(python3 -c "
import json
try:
    d = json.load(open('$lease_file'))
    print(d.get('session_id','unknown'))
except Exception:
    print('unknown')
" 2>/dev/null || echo "unknown")
        local recent
        recent=$(grep "\"session\":\"${session_id}\"" "$AMBIENT" 2>/dev/null | tail -1 | \
            python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read().strip())
    import datetime
    ts = d.get('ts','')
    if ts:
        from datetime import timezone
        dt = datetime.datetime.fromisoformat(ts.replace('Z','+00:00'))
        age = (datetime.datetime.now(timezone.utc) - dt).total_seconds()
        print(int(age))
    else:
        print(99999)
except Exception:
    print(99999)
" 2>/dev/null || echo 99999)
        # RESILIENT-313: sanitize to a single integer. `set -o pipefail` + a
        # grep-miss on $AMBIENT makes the pipeline exit non-zero even though
        # python already printed a value, so the `|| echo 99999` fallback
        # APPENDS a second line ("99999\n99999"). A multi-line $recent then made
        # `[[ -gt ]]` throw a "syntax error in expression" — silently disabling
        # Mode-4 silent-worker detection. Keep only the last numeric line.
        recent="$(printf '%s\n' "$recent" | grep -E '^[0-9]+$' | tail -1)"
        [[ "$recent" =~ ^[0-9]+$ ]] || recent=99999
        if [[ "$recent" -gt "$SILENT_WORKER_S" ]]; then
            log "silent worker detected: session=$session_id lease_age=${age}s ambient_age=${recent}s"
            emit "farmer_silent_worker" "\"session\":\"$session_id\",\"lease_age_s\":$age,\"ambient_age_s\":$recent"
            TICK_SILENT_N=$(( TICK_SILENT_N + 1 ))
            # Kick the stale-lease-reaper (Mode 4 response — don't rm the lease ourselves)
            if label_is_loaded "com.chump.reap-stale-leases"; then
                run_cmd launchctl kickstart -k "gui/$(id -u)/com.chump.reap-stale-leases"
            fi
        fi
    done
}

# ── Mode 1+5: pause-deadlock / stale-sentinel ─────────────────────────────────
handle_sentinel() {
    [[ -f "$SENTINEL" ]] || return 0
    local now; now="$(_now)"
    local mtime
    mtime=$(_mtime "$SENTINEL")   # RESILIENT-313: portable, always-integer
    local age=$(( now - mtime ))
    log "sentinel present, age=${age}s"

    # Mode 5: stale sentinel (>15min) — check SLO, lift if passing
    if [[ "$age" -gt "$SENTINEL_MAX_AGE_S" ]]; then
        if slo_check_passes; then
            log "stale sentinel + slo passing → lifting pause"
            run_cmd rm -f "$SENTINEL"
            emit "farmer_pause_lifted" "\"reason\":\"stale_sentinel_slo_pass\",\"age_s\":$age"
            # Now revive the choir (Mode 1 revive order)
            revive_control_plane
        else
            log "stale sentinel but slo still failing — kicking ghost-gap-reaper"
            kick_ghost_gap_reaper
        fi
        return
    fi

    # Mode 1: fresh sentinel — just check if SLO recovered
    if slo_check_passes; then
        log "sentinel present but slo has recovered → lifting pause"
        run_cmd rm -f "$SENTINEL"
        emit "farmer_pause_lifted" "\"reason\":\"slo_recovered\",\"age_s\":$age"
        revive_control_plane
    else
        log "sentinel present and slo still failing — leaving in place"
    fi
}

# Kick the ghost-gap-reaper — uses launchd kickstart, not chump binary
kick_ghost_gap_reaper() {
    local label="com.chump.reap-stale-leases"  # best proxy available via launchd
    # Also try to run ghost-gap-reaper.sh directly if available
    local reaper="$REPO_ROOT/scripts/coord/ghost-gap-reaper.sh"
    if [[ -x "$reaper" ]]; then
        log "running ghost-gap-reaper directly"
        run_cmd bash "$reaper"
    fi
}

# Mode 6 + Mode 1 revive: ensure all control-plane daemons are loaded + running
revive_control_plane() {
    log "reviving control plane (revive order: supervisors → choir)"
    for label in "${CONTROL_PLANE_LABELS[@]}"; do
        label_is_loaded "$label" || {
            log "$label not loaded — skipping (not installed on this host)"
            continue
        }
        local exit_code
        exit_code="$(label_last_exit "$label")"
        if [[ "$exit_code" == "78" || "$exit_code" == "127" ]]; then
            log "$label exited $exit_code — kicking"
            record_kick "$label"
            if should_escalate "$label" && [[ "$(already_escalated "$label")" == "0" ]]; then
                mark_escalated "$label"
                operator_page "DAEMON_CRASH_LOOP" "label=$label exit_code=$exit_code kicks>=$KICK_ESCALATE_N in ${KICK_WINDOW_S}s"
                emit "farmer_escalated" "\"label\":\"$label\",\"exit_code\":$exit_code"
                TICK_ESCALATED_N=$(( TICK_ESCALATED_N + 1 ))
            else
                [[ "$exit_code" == "127" ]] && _repair_daemon_binary "$label"
                kick_daemon "$label"
            fi
        fi
    done
}

# ── Mode 6: dead-supervisor sweep (runs every tick, not only on revive) ────────
check_dead_supervisors() {
    for label in "${CONTROL_PLANE_LABELS[@]}"; do
        label_is_loaded "$label" || continue  # not installed, skip
        local exit_code
        exit_code="$(label_last_exit "$label")"
        # exit_code="" means currently running (PID column non-null)
        [[ -z "$exit_code" || "$exit_code" == "-" ]] && continue
        # 0 = clean exit (scheduled job), non-zero might be crash
        [[ "$exit_code" == "0" ]] && continue
        log "daemon $label has exit_code=$exit_code — kicking"
        record_kick "$label"
        if should_escalate "$label" && [[ "$(already_escalated "$label")" == "0" ]]; then
            mark_escalated "$label"
            operator_page "DAEMON_CRASH_LOOP" "label=$label exit_code=$exit_code"
            emit "farmer_escalated" "\"label\":\"$label\",\"exit_code\":$exit_code"
                TICK_ESCALATED_N=$(( TICK_ESCALATED_N + 1 ))
        else
            [[ "$exit_code" == "127" ]] && _repair_daemon_binary "$label"
            kick_daemon "$label"
        fi
    done
}

# ── Crash guard (RESILIENT-313) ───────────────────────────────────────────────
# The farmer's ONE job is to keep the heartbeat fresh so the worker-gate stays
# GREEN. A tick that dies mid-way (unbound var, bad arithmetic, a future edit)
# used to leave NO heartbeat → the worker binary's farmer-gate reads it stale →
# every worker on the host hard-blocks new claims → silent fleet-wide outage.
# This EXIT trap guarantees the heartbeat is written even on an abnormal exit,
# so a single bad tick can never dark-out the fleet again. It stays LOUD (logs a
# WARN) so the crash is still visible rather than masked. Normal ticks set
# _HEARTBEAT_WRITTEN=1 and the trap is a no-op for them.
_HEARTBEAT_WRITTEN=0
_farmer_exit_guard() {
    local rc=$?
    if [[ "$rc" -ne 0 && "${_HEARTBEAT_WRITTEN}" != "1" ]]; then
        log "WARN: tick exiting abnormally (rc=$rc) before heartbeat — writing it anyway so the worker-gate does not dark-out the fleet (RESILIENT-313)"
        write_heartbeat || true
    fi
}
trap _farmer_exit_guard EXIT

# ── Main tick ─────────────────────────────────────────────────────────────────
log "farmer tick start (dry_run=$DRY_RUN)"

# Mode 3: auth check (independent of everything else)
check_auth

# Mode 1+5: sentinel / pause-deadlock
handle_sentinel

# Mode 4: silent workers
check_silent_workers

# Mode 6: dead supervisors (always run, not only during revive)
check_dead_supervisors

# INFRA-8198: reap `claude -p` dispatch children whose `chump dispatch`
# parent is gone (the exact orphan class this gap closes). One sweep per
# tick; see scripts/coord/lib/dispatch-orphan-reaper.sh.
reap_dispatch_orphans

# Heartbeat — written AFTER all checks on the normal path. A crash BEFORE here is
# now caught by the EXIT trap above (RESILIENT-313) so the fleet never darks out.
write_heartbeat
_HEARTBEAT_WRITTEN=1
emit "farmer_heartbeat" "\"dry_run\":${DRY_RUN},\"counts\":{\"kicked\":${TICK_KICKED_N},\"silent_detected\":${TICK_SILENT_N},\"escalated\":${TICK_ESCALATED_N}}"

log "farmer tick done"
