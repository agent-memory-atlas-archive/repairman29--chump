#!/usr/bin/env bash
# load-aware-deadman.sh — RESILIENT-1611: node-level dead-man for load/memory thrash.
#
# When a node enters memory/CPU thrash (load > 3x nproc, or MemAvailable < 5%),
# this daemon proactively kills the newest claude -p and cargo processes before
# sshd becomes unresponsive.
#
# NO AUTOMATIC REBOOT (CREDIBLE-1568/1570): earlier versions of this header
# claimed that 15 minutes of unresponsive sshd would trigger a systemd-watchdog
# or kernel-softdog reboot. NO fleet node actually configures that watchdog
# (there is no RuntimeWatchdogSec / softdog on any node), so the reboot never
# happened — a documented capability that did not exist. The SSH-unresponsive
# path below therefore only LOGS and emits an ambient signal; it does not reboot.
# Configuring a real watchdog is tracked as item (c) of the CJ hardening umbrella.
#
# THRESHOLDS:
#   - Load spike: 1m load > 3x nproc for 10 consecutive minutes → kill newest claude -p/cargo
#   - Memory pressure: MemAvailable < 5% of MemTotal for 5 consecutive minutes → kill newest claude -p/cargo
#   - SSH unresponsive: 15 minutes without an ssh command returning immediately → log + emit a critical ambient signal (no reboot; see NO AUTOMATIC REBOOT above)
#
# CONFIG (env, or ~/.chump/providers.env):
#   CHUMP_DEADMAN_LOAD_ENABLED        set to 0 to disable (default: 1)
#   CHUMP_DEADMAN_LOAD_THRESHOLD      load multiple of nproc (default: 3)
#   CHUMP_DEADMAN_LOAD_DURATION_SECS  duration before killing (default: 600 = 10 min)
#   CHUMP_DEADMAN_MEM_ENABLED         set to 0 to disable (default: 1)
#   CHUMP_DEADMAN_MEM_THRESHOLD_PCT   MemAvailable % of MemTotal (default: 5)
#   CHUMP_DEADMAN_MEM_DURATION_SECS   duration before killing (default: 300 = 5 min)
#   CHUMP_DEADMAN_SSH_TIMEOUT_SECS    ssh responsiveness timeout (default: 3)
#   CHUMP_DEADMAN_SSH_UNRESPONSIVE_DUR_SECS  time before reboot (default: 900 = 15 min)
#   CHUMP_DEADMAN_STATE_DIR           state dir for tracking (default: ~/.chump)
#   CHUMP_DEADMAN_DRY_RUN             set to 1 to identify but not kill
#
# Exit codes:
#   0  normal (whether or not anything was killed)
#   1  internal error
#
# Reversible: `systemctl --user disable --now chump-load-aware-deadman.service`.
# shellcheck shell=bash
set -uo pipefail

STATE_DIR="${CHUMP_DEADMAN_STATE_DIR:-$HOME/.chump}"
PROVIDERS_ENV="${CHUMP_PROVIDERS_ENV:-$HOME/.chump/providers.env}"

# Load config from environment or providers.env
# shellcheck source=/dev/null
[[ -f "$PROVIDERS_ENV" ]] && { set -a; . "$PROVIDERS_ENV"; set +a; }

# Defaults
LOAD_ENABLED="${CHUMP_DEADMAN_LOAD_ENABLED:-1}"
LOAD_THRESHOLD="${CHUMP_DEADMAN_LOAD_THRESHOLD:-3}"
LOAD_DURATION_SECS="${CHUMP_DEADMAN_LOAD_DURATION_SECS:-600}"
MEM_ENABLED="${CHUMP_DEADMAN_MEM_ENABLED:-1}"
MEM_THRESHOLD_PCT="${CHUMP_DEADMAN_MEM_THRESHOLD_PCT:-5}"
MEM_DURATION_SECS="${CHUMP_DEADMAN_MEM_DURATION_SECS:-300}"
SSH_TIMEOUT_SECS="${CHUMP_DEADMAN_SSH_TIMEOUT_SECS:-3}"
SSH_UNRESPONSIVE_DUR_SECS="${CHUMP_DEADMAN_SSH_UNRESPONSIVE_DUR_SECS:-900}"
DRY_RUN="${CHUMP_DEADMAN_DRY_RUN:-0}"

LOAD_STATE="$STATE_DIR/deadman-load.state"
MEM_STATE="$STATE_DIR/deadman-mem.state"
SSH_STATE="$STATE_DIR/deadman-ssh.state"
# Canonical node ambient log (CREDIBLE-1570, AC3): this organ is installed to
# ~/.local/bin, so it CANNOT self-locate the repo the way in-repo organs do
# ($SCRIPT_DIR/../.. would be $HOME). It must default to the SAME canonical node
# log that fleet-doctor's check_load_aware_deadman reads, or every healthy node
# false-REDs. That canonical log is $HOME/chump/.chump-locks/ambient.jsonl — the
# repo-root log every other organ heartbeat lands in — derived from $HOME (not a
# CHUMP_* path env default, per the standing safety-input rule) so a sandbox-HOME
# test exercises the real default. The old $STATE_DIR/../.chump-locks default
# resolved to $HOME/.chump-locks — a DIFFERENT directory the check never reads.
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$HOME/chump/.chump-locks/ambient.jsonl}"

log() {
    printf '%s [load-aware-deadman] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

emit_ambient() {
    local kind="$1" msg="$2"
    mkdir -p "$(dirname "$AMBIENT_LOG")" 2>/dev/null || true
    local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local msg_esc; msg_esc="${msg//\\/\\\\}"
    msg_esc="${msg_esc//\"/\\\"}"
    printf '{"ts":"%s","kind":"%s","message":"%s"}\n' "$ts" "$kind" "$msg_esc" >> "$AMBIENT_LOG" 2>/dev/null || true
}

now_secs() {
    date +%s
}

get_nproc() {
    nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 4
}

get_load() {
    awk '{print $1}' /proc/loadavg 2>/dev/null || echo "0"
}

get_mem_pressure() {
    local mem_available mem_total
    mem_available=$(grep ^MemAvailable: /proc/meminfo 2>/dev/null | awk '{print $2}')
    mem_total=$(grep ^MemTotal: /proc/meminfo 2>/dev/null | awk '{print $2}')
    if [[ -z "$mem_available" || -z "$mem_total" ]] || [[ "$mem_total" -eq 0 ]]; then
        echo "0"
        return
    fi
    local pct; pct=$(( (mem_available * 100) / mem_total ))
    echo "$pct"
}

check_ssh_responsive() {
    timeout "$SSH_TIMEOUT_SECS" sh -c 'exit 0' >/dev/null 2>&1 && return 0
    return 1
}

kill_newest_process() {
    local pattern="$1" reason="$2"
    local newest_pid newest_cmd
    # shellcheck disable=SC2009  # comm= match keeps pgrep-free portability (macOS + Linux)
    newest_pid=$(ps -Ao pid=,comm= 2>/dev/null | grep "$pattern" | tail -1 | awk '{print $1}')
    if [[ -z "$newest_pid" ]]; then
        log "INFO: no process matching '$pattern' found"
        return 0
    fi
    newest_cmd=$(ps -o cmd= -p "$newest_pid" 2>/dev/null || echo "unknown")
    if [[ "$DRY_RUN" == "1" ]]; then
        log "DRY-RUN: would kill PID $newest_pid ($newest_cmd) — $reason"
        # scanner-anchor: "kind":"deadman_process_kill_dry_run"
        emit_ambient "deadman_process_kill_dry_run" "killed_pid=$newest_pid pattern=$pattern reason=$reason"
        return 0
    fi
    log "KILLING PID $newest_pid ($newest_cmd) — $reason"
    # scanner-anchor: "kind":"deadman_process_killed"
    emit_ambient "deadman_process_killed" "killed_pid=$newest_pid pattern=$pattern reason=$reason"
    kill -9 "$newest_pid" 2>/dev/null || true
}

mkdir -p "$STATE_DIR" 2>/dev/null || true

# ── Per-run liveness heartbeat (CREDIBLE-1568/1570) ───────────────────────────
# RESILIENT-1611's dead-man was SILENT when healthy — a run that killed nothing
# emitted nothing, so there was no way to prove the organ was alive on a node.
# Emit one heartbeat EVERY run (even a fully-healthy one), so fleet-doctor can
# read the last deadman_tick and RED a node whose dead-man has gone dark.
# scanner-anchor: "kind":"deadman_tick"
emit_ambient "deadman_tick" "load-aware dead-man liveness tick (nproc=$(get_nproc) load=$(get_load) mem_avail_pct=$(get_mem_pressure))"

# ── Load check ───────────────────────────────────────────────────────────────
if [[ "$LOAD_ENABLED" == "1" ]]; then
    load=$(get_load)
    nproc=$(get_nproc)
    threshold=$(( nproc * LOAD_THRESHOLD ))
    load_int=${load%.*}

    if (( load_int > threshold )); then
        now=$(now_secs)
        if [[ -f "$LOAD_STATE" ]]; then
            first_spike=$(cat "$LOAD_STATE")
            duration=$(( now - first_spike ))
            if [[ "$duration" -ge "$LOAD_DURATION_SECS" ]]; then
                log "ALERT: load=$load (> threshold=$threshold) for ${duration}s — killing newest claude -p"
                kill_newest_process "claude" "load thrash: load=$load > ${nproc}x threshold"
                rm -f "$LOAD_STATE" 2>/dev/null || true
            fi
        else
            echo "$now" > "$LOAD_STATE"
            log "WARN: load spike detected ($load > ${nproc}x threshold) — monitoring..."
        fi
    else
        rm -f "$LOAD_STATE" 2>/dev/null || true
    fi
fi

# ── Memory check ─────────────────────────────────────────────────────────────
if [[ "$MEM_ENABLED" == "1" ]]; then
    mem_pct=$(get_mem_pressure)
    if [[ "$mem_pct" -lt "$MEM_THRESHOLD_PCT" ]]; then
        now=$(now_secs)
        if [[ -f "$MEM_STATE" ]]; then
            first_pressure=$(cat "$MEM_STATE")
            duration=$(( now - first_pressure ))
            if [[ "$duration" -ge "$MEM_DURATION_SECS" ]]; then
                log "ALERT: MemAvailable=${mem_pct}% (< ${MEM_THRESHOLD_PCT}% threshold) for ${duration}s — killing newest cargo"
                kill_newest_process "cargo" "memory pressure: MemAvailable=${mem_pct}%"
                rm -f "$MEM_STATE" 2>/dev/null || true
            fi
        else
            echo "$now" > "$MEM_STATE"
            log "WARN: memory pressure detected (${mem_pct}% < ${MEM_THRESHOLD_PCT}% threshold) — monitoring..."
        fi
    else
        rm -f "$MEM_STATE" 2>/dev/null || true
    fi
fi

# ── SSH responsiveness check (for systemd watchdog integration) ──────────────
if check_ssh_responsive; then
    rm -f "$SSH_STATE" 2>/dev/null || true
else
    now=$(now_secs)
    if [[ -f "$SSH_STATE" ]]; then
        first_unresponsive=$(cat "$SSH_STATE")
        duration=$(( now - first_unresponsive ))
        if [[ "$duration" -ge "$SSH_UNRESPONSIVE_DUR_SECS" ]]; then
            log "CRITICAL: SSH unresponsive for ${duration}s — logging + signalling (no node configures a watchdog reboot; see header)"
            # scanner-anchor: "kind":"deadman_ssh_unresponsive_critical"
            emit_ambient "deadman_ssh_unresponsive_critical" "duration_secs=$duration"
            # Best-effort watchdog notify IF a node ever configures one. No node
            # currently does (no RuntimeWatchdogSec/softdog), so this is a no-op
            # today — it does NOT itself reboot anything.
            if command -v systemd-notify >/dev/null 2>&1; then
                systemd-notify --ready 2>/dev/null || true
            fi
        fi
    else
        echo "$now" > "$SSH_STATE"
        log "WARN: SSH unresponsive — monitoring..."
        # scanner-anchor: "kind":"deadman_ssh_unresponsive_detected"
        emit_ambient "deadman_ssh_unresponsive_detected" "duration_secs=0"
    fi
fi

exit 0
