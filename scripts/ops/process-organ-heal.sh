#!/usr/bin/env bash
# process-organ-heal.sh — INFRA-3650 (PEER-HEAL-03, MISSION-010).
#
# WHY THIS EXISTS. scripts/ops/organ-watchdog.sh + organ-reconcile.sh already
# self-heal chump-*.service/.timer SYSTEMD units (INFRA-3595, RESILIENT-305/
# 347). Nothing revives a raw background bash process that isn't wrapped as a
# systemd unit at all — an "unsupervised bash proc" started by hand (or by an
# installer that never wired in real supervision) just dies silently, and
# systemd's own Restart=always doesn't apply because the process was never a
# unit in the first place. scripts/ops/almanac-vision-keeper.sh (the "eyes")
# is the first concrete instance of this: a standing loop, not a systemd
# unit. This heal loop is the muscle that revives it (and anything else
# declared in process-organ-registry.txt) — one pgrep + respawn pass per
# invocation, install-time-wired so it lands on every owned node via
# chump-node-install.sh instead of being a hand-op.
#
# DEPTH (wiring/liveness tier, per this gap's AC5):
#   - WIRING tier: this script + almanac-vision-keeper.sh + the registry +
#     chump-node-install.sh ORGANS wiring + the reaper-heartbeat-watchdog.sh
#     TARGETS entry are all shipped and locally CI-tested
#     (scripts/ci/test-process-organ-heal.sh) in this PR.
#   - LIVE tier (pgrep on closetjunky itself, ambient.jsonl tail on CJ):
#     CONFIRMED 2026-08-22 — this session's worktree turned out to be running
#     ON closetjunky itself (hostname check), so scripts/ops/
#     check-process-organ-heal-live.sh could run directly: systemd timer
#     active, organ_watchdog_tick fresh, almanac-vision-keeper running.
#     Earlier sessions (and this one, before checking hostname) found no
#     credential path to CJ from a *remote* Claude Code session — ssh,
#     `tailscale ssh`, and a `tailscale nc` ProxyCommand all hit publickey
#     Permission denied, and no self-hosted runner is registered on CJ — so
#     that path stays valid for any future session that is NOT itself CJ.
#     Full findings + the live-check's own discovery-path bug (also fixed in
#     this PR): docs/process/PROCEDURES/verify-process-organ-heal-live.md.
#
# Usage:
#   scripts/ops/process-organ-heal.sh              # scan + heal, real spawn
#   scripts/ops/process-organ-heal.sh --dry-run     # report only, no spawn
#   scripts/ops/process-organ-heal.sh --check       # health report only, no
#                                                    # spawn, no ambient writes
#                                                    # (INFRA-7588) — see below
#   scripts/ops/process-organ-heal.sh --registry PATH   # override registry
#
# --check mode (INFRA-7588, process-organ health reporting):
#   Runs each registered organ's pgrep detector and prints one line per organ:
#     DETECTED-ALIVE <name>   pgrep found a matching process
#     DETECTED-DEAD  <name>   pgrep ran cleanly and found nothing (and no
#                              fresh optional heartbeat file covers for it —
#                              see CHUMP_PROCESS_ORGAN_HEARTBEAT_MAX_AGE_S)
#     UNKNOWN        <name>   pgrep itself errored (rc>=2) — can't tell
#   Never spawns anything and never touches ambient.jsonl — this is a pure
#   read-only report, deliberately separate from the heal path above so a
#   monitoring cron can run --check on a tight cadence without side effects.
#   Detection is solely pgrep + the optional heartbeat file — NEVER systemctl
#   (this repo runs on nodes that are not always systemd-supervised).
#   Exit codes: 0 all organs DETECTED-ALIVE or UNKNOWN; 1 one or more
#   DETECTED-DEAD; 2 registry unreadable.
#
# Env:
#   CHUMP_PROCESS_ORGAN_REGISTRY  — override registry path
#   CHUMP_PROCESS_ORGAN_PGREP_BIN — override `pgrep` binary (test hook)
#   CHUMP_AMBIENT_LOG             — override ambient.jsonl path
#   CHUMP_PROCESS_ORGAN_HEARTBEAT_MAX_AGE_S — --check only: an organ whose
#     pgrep detector reports dead is still DETECTED-ALIVE if
#     process-organ-logs/<name>.heartbeat exists and was touched within this
#     many seconds (default 300). Organs opt in by touching that file
#     themselves; most won't have one, which is fine — pgrep is authoritative.
#   REPO_ROOT / CHUMP_REPO_ROOT   — repo checkout organs are relative to
#
# Exit codes:
#   0  normal (whether or not any organ needed reviving)
#   2  registry unreadable
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-${CHUMP_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
REGISTRY="${CHUMP_PROCESS_ORGAN_REGISTRY:-$REPO_ROOT/scripts/ops/process-organ-registry.txt}"
PGREP_BIN="${CHUMP_PROCESS_ORGAN_PGREP_BIN:-pgrep}"
LOG_DIR="$(dirname "$AMBIENT_LOG")/process-organ-logs"

DRY_RUN=0
CHECK=0
HEARTBEAT_MAX_AGE_S="${CHUMP_PROCESS_ORGAN_HEARTBEAT_MAX_AGE_S:-300}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --check) CHECK=1; shift ;;
        --registry) REGISTRY="$2"; shift 2 ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

mkdir -p "$(dirname "$AMBIENT_LOG")" "$LOG_DIR" 2>/dev/null || true

emit() {  # kind, extra-json (no leading/trailing comma)
    local kind="$1" extra="${2:-}"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local line
    if [[ -n "$extra" ]]; then line="{\"ts\":\"$ts\",\"kind\":\"$kind\",$extra}"
    else line="{\"ts\":\"$ts\",\"kind\":\"$kind\"}"; fi
    printf '%s\n' "$line" >> "$AMBIENT_LOG" 2>/dev/null || true
}

if [[ ! -f "$REGISTRY" ]]; then
    echo "[process-organ-heal] ERROR: registry not found: $REGISTRY" >&2
    exit 2
fi

if [[ "$CHECK" == "1" ]]; then
    if ! command -v "$PGREP_BIN" >/dev/null 2>&1; then
        echo "[process-organ-heal] UNKNOWN: $PGREP_BIN unavailable — cannot determine liveness for any organ" >&2
    fi

    any_dead=0
    checked=0
    while IFS='|' read -r name relpath args; do
        [[ -z "$name" ]] && continue
        [[ "$name" =~ ^[[:space:]]*# ]] && continue
        name="$(echo "$name" | xargs)"
        relpath="$(echo "$relpath" | xargs)"
        [[ -z "$name" || -z "$relpath" ]] && continue

        checked=$((checked + 1))
        status="UNKNOWN"

        if command -v "$PGREP_BIN" >/dev/null 2>&1; then
            "$PGREP_BIN" -f "$relpath" >/dev/null 2>&1
            rc=$?
            if [[ "$rc" -eq 0 ]]; then
                status="DETECTED-ALIVE"
            elif [[ "$rc" -eq 1 ]]; then
                status="DETECTED-DEAD"
                # Optional heartbeat file fallback: an organ that touches its
                # own process-organ-logs/<name>.heartbeat within the freshness
                # window counts as alive even if pgrep's -f substring match
                # missed it (e.g. mid-restart). Still no systemctl anywhere.
                heartbeat="$LOG_DIR/${name}.heartbeat"
                if [[ -f "$heartbeat" ]]; then
                    hb_epoch=$(stat -c %Y "$heartbeat" 2>/dev/null || stat -f %m "$heartbeat" 2>/dev/null || echo 0)
                    now_epoch=$(date -u +%s)
                    if [[ "$hb_epoch" -gt 0 ]] && [[ "$((now_epoch - hb_epoch))" -le "$HEARTBEAT_MAX_AGE_S" ]]; then
                        status="DETECTED-ALIVE"
                    fi
                fi
            fi
        fi

        [[ "$status" == "DETECTED-DEAD" ]] && any_dead=1
        printf '[process-organ-heal] %s: %s (%s)\n' "$status" "$name" "$relpath"
    done < "$REGISTRY"

    echo "[process-organ-heal] --check complete: checked=$checked any_dead=$any_dead"
    [[ "$any_dead" == "1" ]] && exit 1
    exit 0
fi

if ! command -v "$PGREP_BIN" >/dev/null 2>&1; then
    echo "[process-organ-heal] WARN: $PGREP_BIN unavailable — cannot check process liveness, skipping this cycle" >&2
    emit organ_watchdog_tick "\"source\":\"process-organ-heal\",\"healed\":0,\"checked\":0,\"dry_run\":$DRY_RUN,\"skip_reason\":\"pgrep_unavailable\""
    exit 0
fi

healed=0
checked=0

while IFS='|' read -r name relpath args; do
    # skip blank lines and comments
    [[ -z "$name" ]] && continue
    [[ "$name" =~ ^[[:space:]]*# ]] && continue
    name="$(echo "$name" | xargs)"
    relpath="$(echo "$relpath" | xargs)"
    args="$(echo "${args:-}" | xargs)"
    [[ -z "$name" || -z "$relpath" ]] && continue

    checked=$((checked + 1))

    if "$PGREP_BIN" -f "$relpath" >/dev/null 2>&1; then
        echo "[process-organ-heal] UP: $name ($relpath)"
        continue
    fi

    echo "[process-organ-heal] DOWN: $name ($relpath)"
    if [[ "$DRY_RUN" == "1" ]]; then
        echo "[process-organ-heal]   (dry-run) would respawn $name"
        # scanner-anchor: "kind":"process_organ_revived"
        emit process_organ_revived "\"name\":\"$name\",\"path\":\"$relpath\",\"dry_run\":1"
        continue
    fi

    full_path="$REPO_ROOT/$relpath"
    if [[ ! -f "$full_path" ]]; then
        echo "[process-organ-heal]   ERROR: script not found at $full_path — cannot respawn $name" >&2
        continue
    fi

    log_file="$LOG_DIR/${name}.log"
    # shellcheck disable=SC2086  # args is deliberately word-split (space-separated flags)
    nohup bash "$full_path" $args >>"$log_file" 2>&1 &
    disown 2>/dev/null || true
    echo "[process-organ-heal]   revived $name (pid $!, log $log_file)"
    # scanner-anchor: "kind":"process_organ_revived"  (INFRA-3650; fires when
    # the heal loop respawns a registered process-organ found missing via
    # pgrep — the observable proof a dead unsupervised bash proc, e.g.
    # almanac-vision-keeper, was revived with no human step)
    emit process_organ_revived "\"name\":\"$name\",\"path\":\"$relpath\",\"dry_run\":0"
    healed=$((healed + 1))
done < "$REGISTRY"

# Heartbeat — reuses organ-watchdog.sh's established kind so consumers don't
# need a second event to watch (AC2). Distinguished by "source" for anyone
# who cares which heal loop emitted it.
# scanner-anchor: "kind":"organ_watchdog_tick"  (already registered by
# scripts/ops/organ-watchdog.sh, INFRA-3595; process-organ-heal.sh reuses it
# per this gap's AC2 rather than inventing a parallel tick kind)
emit organ_watchdog_tick "\"source\":\"process-organ-heal\",\"healed\":$healed,\"checked\":$checked,\"dry_run\":$DRY_RUN"

echo "[process-organ-heal] cycle complete: checked=$checked healed=$healed dry_run=$DRY_RUN"

# Self-registration (AC2): stamp the standard reaper heartbeat so a dead heal
# loop is itself caught by reaper-heartbeat-watchdog.sh's existing
# cadence-grading pattern (see its "process-organ-heal" TARGETS entry) —
# without this, the healer could die unnoticed the same way organ-watchdog.sh
# almost did before RESILIENT-356.
# shellcheck source=../lib/reaper-instrumentation.sh
source "$SCRIPT_DIR/../lib/reaper-instrumentation.sh" 2>/dev/null && {
    reaper_setup process-organ-heal
    reaper_emit_run process-organ-heal ok "{\"checked\":$checked,\"healed\":$healed}"
}

exit 0
