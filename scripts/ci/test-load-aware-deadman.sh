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

# ── CREDIBLE-1568/1570 ────────────────────────────────────────────────────────

# Test 11: units' Documentation= URL names repairman29/chump (not anthropics).
for unit in "$SERVICE_FILE" "$TIMER_FILE"; do
    if grep -q '^Documentation=.*github.com/repairman29/chump' "$unit"; then
        log "OK: $(basename "$unit") Documentation= names repairman29/chump"
    else
        fail "$(basename "$unit") Documentation= does not name repairman29/chump (AC4)"
        ((FAILED++))
    fi
    if grep -q '^Documentation=.*github.com/anthropics/chump' "$unit"; then
        fail "$(basename "$unit") still points Documentation= at the wrong anthropics/chump repo (AC4)"
        ((FAILED++))
    fi
done

# Test 12: script header no longer CLAIMS a reboot no node configures (AC4).
# The header must carry the NO-AUTOMATIC-REBOOT disclaimer and must not assert
# that the watchdog/softdog "reboots the node" as a live capability.
if grep -q 'NO AUTOMATIC REBOOT' "$DEADMAN_SCRIPT"; then
    log "OK: header carries the NO-AUTOMATIC-REBOOT disclaimer"
else
    fail "header missing the NO-AUTOMATIC-REBOOT disclaimer (AC4: stop claiming an unconfigured reboot)"
    ((FAILED++))
fi
if grep -qE 'watchdog or kernel softdog reboots the node' "$DEADMAN_SCRIPT"; then
    fail "header still claims 'watchdog or kernel softdog reboots the node' — no node configures it (AC4)"
    ((FAILED++))
fi

# Test 13: a run emits kind=deadman_tick EVERY time, even when healthy (AC2).
TMP_TICK="$(mktemp -d)"
trap 'rm -rf "$TMP_TICK"' EXIT
TICK_AMBIENT="$TMP_TICK/ambient.jsonl"
mkdir -p "$TMP_TICK/.chump-locks"
# DRY_RUN=1 so nothing is ever killed on the CI box; the heartbeat still fires.
CHUMP_DEADMAN_DRY_RUN=1 \
CHUMP_DEADMAN_STATE_DIR="$TMP_TICK/state" \
CHUMP_AMBIENT_LOG="$TICK_AMBIENT" \
    bash "$DEADMAN_SCRIPT" >/dev/null 2>&1 || true
if grep -q '"kind":"deadman_tick"' "$TICK_AMBIENT" 2>/dev/null; then
    log "OK: a healthy run emitted kind=deadman_tick (liveness heartbeat)"
else
    fail "script did not emit kind=deadman_tick on a healthy run (AC2) — the dead-man stays unprovable"
    ((FAILED++))
fi

# Test 14: fleet-doctor's check_load_aware_deadman goes RED when the timer is
# missing/inactive OR the last deadman_tick is older than 5 minutes, and PASSes
# when the timer is active with a fresh tick — stubbed systemctl + ambient (AC3).
DOCTOR="$REPO_ROOT/scripts/coord/fleet-doctor-strict.sh"
if [[ ! -f "$DOCTOR" ]]; then
    fail "fleet-doctor-strict.sh missing — cannot verify the deadman check (AC3)"
    ((FAILED++))
else
    FD_TMP="$(mktemp -d)"
    STUBDIR="$FD_TMP/bin"; mkdir -p "$STUBDIR"
    # Stub systemctl: `is-active` honors $STUB_DEADMAN_ACTIVE; everything else ok.
    cat > "$STUBDIR/systemctl" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do
    if [[ "$a" == "is-active" ]]; then
        [[ "${STUB_DEADMAN_ACTIVE:-0}" == "1" ]] && exit 0 || exit 3
    fi
done
exit 0
STUB
    chmod +x "$STUBDIR/systemctl"
    FD_AMBIENT="$FD_TMP/ambient.jsonl"
    iso_at() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }

    # Isolated subshell (own `set`) so the sourced doctor can't trip this file's
    # `set -euo pipefail`. Prints "<status>\t<detail>" of the registered check.
    run_fd_deadman() {   # $1=active(0|1)  $2=ambient-file
        STUB_DEADMAN_ACTIVE="$1" PATH="$STUBDIR:$PATH" CHUMP_AMBIENT_LOG="$2" DOCTOR="$DOCTOR" \
        bash -c '
            set -uo pipefail
            export FLEET_DOCTOR_SOURCED=1
            # shellcheck disable=SC1090
            source "$DOCTOR"
            CHECKS=(); STATUSES=(); DETAILS=(); REMEDIES=(); PASS_COUNT=0; FAIL_COUNT=0
            check_load_aware_deadman
            printf "%s\t%s\n" "${STATUSES[-1]:-}" "${DETAILS[-1]:-}"
        '
    }

    NOW="$(date -u +%s)"

    # Case A: timer active + fresh tick (60s ago) → pass.
    printf '{"ts":"%s","kind":"deadman_tick","message":"x"}\n' "$(iso_at $(( NOW - 60 )))" > "$FD_AMBIENT"
    RES="$(run_fd_deadman 1 "$FD_AMBIENT")"
    if [[ "${RES%%$'\t'*}" == "pass" ]]; then
        log "OK: active timer + fresh deadman_tick → pass"
    else
        fail "expected pass for active+fresh, got: $RES (AC3)"
        ((FAILED++))
    fi

    # Case B: timer active + STALE tick (600s ago > 5min) → fail.
    printf '{"ts":"%s","kind":"deadman_tick","message":"x"}\n' "$(iso_at $(( NOW - 600 )))" > "$FD_AMBIENT"
    RES="$(run_fd_deadman 1 "$FD_AMBIENT")"
    if [[ "${RES%%$'\t'*}" == "fail" ]]; then
        log "OK: active timer + deadman_tick older than 5 min → RED"
    else
        fail "expected fail for active+stale heartbeat, got: $RES (AC3)"
        ((FAILED++))
    fi

    # Case C: timer missing/inactive → fail (shipped != installed).
    printf '{"ts":"%s","kind":"deadman_tick","message":"x"}\n' "$(iso_at $(( NOW - 60 )))" > "$FD_AMBIENT"
    RES="$(run_fd_deadman 0 "$FD_AMBIENT")"
    if [[ "${RES%%$'\t'*}" == "fail" ]]; then
        log "OK: timer missing/inactive → RED (even with a fresh tick)"
    else
        fail "expected fail when timer inactive, got: $RES (AC3)"
        ((FAILED++))
    fi

    # Case D: timer active but no deadman_tick ever → fail (can't prove alive).
    : > "$FD_AMBIENT"
    RES="$(run_fd_deadman 1 "$FD_AMBIENT")"
    if [[ "${RES%%$'\t'*}" == "fail" ]]; then
        log "OK: active timer but no deadman_tick heartbeat → RED"
    else
        fail "expected fail when no deadman_tick present, got: $RES (AC3)"
        ((FAILED++))
    fi

    # Mutant guard: the check must be wired into the runner, not just defined.
    # A mutant that SKIPS the check (drops it from the run list) must fail here.
    if grep -qE '^check_load_aware_deadman$' "$DOCTOR"; then
        log "OK: check_load_aware_deadman is wired into the fleet-doctor runner"
    else
        fail "check_load_aware_deadman defined but NOT invoked in the runner — the check is skipped (AC3)"
        ((FAILED++))
    fi

    # Test 15 (CREDIBLE-1570, AC3 default-path reconciliation): with
    # CHUMP_AMBIENT_LOG UNSET, the dead-man's write path and fleet-doctor's read
    # path must resolve to the SAME canonical node log. Cases A-D above stub both
    # sides onto one CHUMP_AMBIENT_LOG file — they prove the freshness logic but
    # NOT the default wiring. This case exercises the real default end-to-end
    # under a sandbox HOME (the standing safety-input test-seam: real code,
    # sandbox HOME, no env override of the path): the dead-man writes its tick,
    # then the check reads the SAME default path and goes GREEN. A regression that
    # diverges the two defaults (the original bug: writer $HOME/.chump-locks vs
    # reader $REPO_ROOT/.chump-locks) fails here even though Cases A-D stay green.
    SANDBOX_HOME="$(mktemp -d)"
    CANON_AMBIENT="$SANDBOX_HOME/chump/.chump-locks/ambient.jsonl"
    mkdir -p "$SANDBOX_HOME/chump/.chump-locks"

    # Writer: real dead-man under sandbox HOME, DRY_RUN=1 (kill-switch class —
    # can only make it safer, never kills on the CI box), CHUMP_AMBIENT_LOG unset
    # → it must default to $HOME/chump/.chump-locks/ambient.jsonl.
    env -u CHUMP_AMBIENT_LOG HOME="$SANDBOX_HOME" CHUMP_DEADMAN_DRY_RUN=1 \
        bash "$DEADMAN_SCRIPT" >/dev/null 2>&1 || true
    if grep -q '"kind":"deadman_tick"' "$CANON_AMBIENT" 2>/dev/null; then
        log "OK: dead-man default write path is \$HOME/chump/.chump-locks/ambient.jsonl (CHUMP_AMBIENT_LOG unset)"
    else
        fail "dead-man did not write deadman_tick to the canonical node log \$HOME/chump/.chump-locks/ambient.jsonl with CHUMP_AMBIENT_LOG unset (AC3 default write path)"
        ((FAILED++))
    fi

    # Reader: real fleet-doctor check under the SAME sandbox HOME, stub systemctl
    # active, CHUMP_AMBIENT_LOG unset → it must resolve the SAME canonical log and
    # see the writer's tick (→ pass). Proves write/read defaults reconcile.
    RES="$(STUB_DEADMAN_ACTIVE=1 PATH="$STUBDIR:$PATH" HOME="$SANDBOX_HOME" DOCTOR="$DOCTOR" \
        env -u CHUMP_AMBIENT_LOG bash -c '
            set -uo pipefail
            export FLEET_DOCTOR_SOURCED=1
            # shellcheck disable=SC1090
            source "$DOCTOR"
            CHECKS=(); STATUSES=(); DETAILS=(); REMEDIES=(); PASS_COUNT=0; FAIL_COUNT=0
            check_load_aware_deadman
            printf "%s\t%s\n" "${STATUSES[-1]:-}" "${DETAILS[-1]:-}"
        ')"
    if [[ "${RES%%$'\t'*}" == "pass" ]]; then
        log "OK: fleet-doctor default read path matches the dead-man default write path (AC3 reconciled end-to-end)"
    else
        fail "fleet-doctor check did not see the dead-man's deadman_tick on the default (unset-env) path — write/read defaults diverge (AC3), got: $RES"
        ((FAILED++))
    fi
    rm -rf "$SANDBOX_HOME"

    rm -rf "$FD_TMP"
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
