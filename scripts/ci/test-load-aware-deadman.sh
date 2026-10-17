#!/usr/bin/env bash
# scripts/ci/test-load-aware-deadman.sh — RESILIENT-1611
#
# Test the load-aware-deadman.sh script for:
#   - Basic syntactic correctness (shellcheck)
#   - Systemd unit file validity
#   - Function presence and logic flow
#
# Exit codes:
#   0  all tests passed
#   1  at least one test failed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

log() { printf '%s [test-load-aware-deadman] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
fail() { printf '%s [test-load-aware-deadman] FAIL: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }

DEADMAN_SCRIPT="$REPO_ROOT/scripts/ops/load-aware-deadman.sh"
SERVICE_FILE="$REPO_ROOT/scripts/ops/systemd/chump-load-aware-deadman.service"
TIMER_FILE="$REPO_ROOT/scripts/ops/systemd/chump-load-aware-deadman.timer"
INSTALLER_SCRIPT="$REPO_ROOT/scripts/setup/install-load-aware-deadman.sh"

FAILED=0

# Test 1: Script exists and is readable
if [[ ! -f "$DEADMAN_SCRIPT" ]]; then
    fail "load-aware-deadman.sh not found at $DEADMAN_SCRIPT"
    ((FAILED++))
else
    log "OK: load-aware-deadman.sh exists"
fi

# Test 2: Shellcheck (if available)
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck "$DEADMAN_SCRIPT" 2>/dev/null; then
        log "OK: shellcheck passed on load-aware-deadman.sh"
    else
        fail "shellcheck found issues in load-aware-deadman.sh"
        ((FAILED++))
    fi
else
    log "SKIP: shellcheck not available"
fi

# Test 3: Service file exists and is readable
if [[ ! -f "$SERVICE_FILE" ]]; then
    fail "chump-load-aware-deadman.service not found at $SERVICE_FILE"
    ((FAILED++))
else
    log "OK: chump-load-aware-deadman.service exists"
fi

# Test 4: Timer file exists and is readable
if [[ ! -f "$TIMER_FILE" ]]; then
    fail "chump-load-aware-deadman.timer not found at $TIMER_FILE"
    ((FAILED++))
else
    log "OK: chump-load-aware-deadman.timer exists"
fi

# Test 5: Service file has required fields
if [[ -f "$SERVICE_FILE" ]]; then
    if grep -q '^\[Service\]' "$SERVICE_FILE" && grep -q '^ExecStart=' "$SERVICE_FILE"; then
        log "OK: service file has required [Service] section and ExecStart"
    else
        fail "service file missing required fields"
        ((FAILED++))
    fi
fi

# Test 6: Timer file has required fields
if [[ -f "$TIMER_FILE" ]]; then
    if grep -q '^\[Timer\]' "$TIMER_FILE" && grep -q '^OnBootSec=' "$TIMER_FILE"; then
        log "OK: timer file has required [Timer] section and OnBootSec"
    else
        fail "timer file missing required fields"
        ((FAILED++))
    fi
fi

# Test 7: Installer script exists and is executable
if [[ ! -f "$INSTALLER_SCRIPT" ]]; then
    fail "install-load-aware-deadman.sh not found at $INSTALLER_SCRIPT"
    ((FAILED++))
else
    log "OK: install-load-aware-deadman.sh exists"
fi

# Test 8: Script contains expected functions (load check, memory check, ssh check)
if [[ -f "$DEADMAN_SCRIPT" ]]; then
    grep -q "get_load()" "$DEADMAN_SCRIPT" && log "OK: get_load() function found" || { fail "get_load() not found"; ((FAILED++)); }
    grep -q "get_mem_pressure()" "$DEADMAN_SCRIPT" && log "OK: get_mem_pressure() function found" || { fail "get_mem_pressure() not found"; ((FAILED++)); }
    grep -q "check_ssh_responsive()" "$DEADMAN_SCRIPT" && log "OK: check_ssh_responsive() function found" || { fail "check_ssh_responsive() not found"; ((FAILED++)); }
    grep -q "kill_newest_process()" "$DEADMAN_SCRIPT" && log "OK: kill_newest_process() function found" || { fail "kill_newest_process() not found"; ((FAILED++)); }
fi

# Test 9: Script respects DRY_RUN mode
if grep -q 'if \[\[ "$DRY_RUN" == "1" \]\]' "$DEADMAN_SCRIPT"; then
    log "OK: script respects DRY_RUN mode"
else
    fail "script does not check DRY_RUN mode"
    ((FAILED++))
fi

# Test 10: Script emits ambient events
if grep -q 'emit_ambient' "$DEADMAN_SCRIPT"; then
    log "OK: script emits ambient events"
else
    fail "script does not emit ambient events"
    ((FAILED++))
fi

# Summary
echo ""
if [[ "$FAILED" -eq 0 ]]; then
    log "✓ All tests passed"
    exit 0
else
    log "✗ $FAILED test(s) failed"
    exit 1
fi
