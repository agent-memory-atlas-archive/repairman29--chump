#!/usr/bin/env bash
# scripts/lib/orchestrator-log.sh — INFRA-6128 (INFRA-1966 slice): shared
# execution logging for orchestration scripts (bot-merge, queue-driver,
# pr-rescue, pr-auto-rearm, pr-auto-rebase, worker.sh).
#
# Usage (source, then call):
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib/orchestrator-log.sh"
#   orch_log_start "bot-merge.sh" "$@"
#   trap 'orch_log_end "bot-merge.sh" "$?"' EXIT
#   orch_log_step "rebasing onto main"
#
# Destination: $CHUMP_ORCH_LOG_FILE if set, else /var/log/infra-orchestrator.log
# if writable (root/production hosts), else ~/.chump/logs/infra-orchestrator.log
# as a non-root dev fallback. Never fails the caller — worst case logs to /dev/null.

_orch_log_pick_file() {
    local candidate dir
    for candidate in \
        "${CHUMP_ORCH_LOG_FILE:-}" \
        "/var/log/infra-orchestrator.log" \
        "${HOME}/.chump/logs/infra-orchestrator.log"
    do
        [ -z "$candidate" ] && continue
        dir="$(dirname "$candidate")"
        if mkdir -p "$dir" 2>/dev/null && touch "$candidate" 2>/dev/null; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    printf '/dev/null\n'
}

ORCH_LOG_FILE="$(_orch_log_pick_file)"

orch_log() {
    printf '[%s] [%s] %s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "${ORCH_LOG_SCRIPT_NAME:-orchestrator}" \
        "$*" >> "$ORCH_LOG_FILE" 2>/dev/null
}

orch_log_start() {
    ORCH_LOG_SCRIPT_NAME="$1"
    shift
    orch_log "START pid=$$ args=[$*]"
}

orch_log_step() {
    orch_log "STEP $*"
}

orch_log_end() {
    local name="$1" code="${2:-0}"
    ORCH_LOG_SCRIPT_NAME="$name"
    orch_log "END exit_code=$code"
}
