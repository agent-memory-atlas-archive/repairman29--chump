#!/usr/bin/env bash
# worker-timeout.sh — RESILIENT-135
#
# Pure, unit-testable effort-based timeout scaling for the fleet worker loop.
# Extracted from scripts/dispatch/worker.sh so the scaling can be exercised by
# a real behavioural test (scripts/ci/test-worker-timeout-scale.sh) instead of
# a hand-copied replica.
#
# THE BUG THIS GUARDS (RESILIENT-135): the original inline scaler wrote the
# scaled value back into the *global* base timeout each cycle, so consecutive
# xs gaps (x0.5) compounded the multiplier and collapsed the per-cycle
# claude -p budget toward 0s (observed live: 1800 -> ... -> 14 -> 7 -> 3 -> 1 -> 0).
# Every spawn was then killed (rc=124) before it could implement anything, which
# is why autonomous worker completion was ~0. The fix is twofold and both halves
# live here so they cannot drift apart:
#   1. derive ONLY from the immutable base the caller passes in (never from the
#      previous result), and
#   2. a hard floor so the budget can never collapse below a workable minimum.
#
# Usage:
#   compute_scaled_timeout BASE_S EFFORT [MAX_S] [MIN_S]   -> echoes scaled seconds
#     EFFORT multipliers: xs=0.5  s=1.0  m=1.5  l=2.0  xl=3.0  (unknown -> 1.0)
#     MAX_S default: $CHUMP_WORKER_TIMEOUT_MAX_S or 7200
#     MIN_S default: $CHUMP_WORKER_TIMEOUT_MIN_S or 120

compute_scaled_timeout() {
    local base="${1:?compute_scaled_timeout: BASE_S required}"
    local effort="${2:-s}"
    local max="${3:-${CHUMP_WORKER_TIMEOUT_MAX_S:-7200}}"
    local min="${4:-${CHUMP_WORKER_TIMEOUT_MIN_S:-120}}"
    local n d out

    case "$effort" in
        xs) n=5  d=10 ;;  # 0.5x
        s)  n=10 d=10 ;;  # 1.0x
        m)  n=15 d=10 ;;  # 1.5x
        l)  n=20 d=10 ;;  # 2.0x
        xl) n=30 d=10 ;;  # 3.0x
        *)  n=10 d=10 ;;  # 1.0x fallback for unknown/empty effort
    esac

    out=$(( base * n / d ))
    # Cap, then floor. Floor wins last so the budget can NEVER collapse to ~0
    # (the death-spiral guard) even if a caller passes a tiny/zero base.
    if [ "$out" -gt "$max" ]; then out="$max"; fi
    if [ "$out" -lt "$min" ]; then out="$min"; fi

    printf '%s' "$out"
}

# RESILIENT-1569: plain `timeout Ns` only sends TERM; a hung claude that
# ignores/blocks TERM outlived the 1800s budget (41min wedge). Add -k so
# the process is SIGKILLed KILL_AFTER seconds after the TERM.
# Usage: build_timeout_prefix SECONDS  -> echoes e.g. "timeout -k 30s 1800s" (empty if no timeout binary)
build_timeout_prefix() {
    local secs="${1:?build_timeout_prefix: SECONDS required}"
    local ka="${CHUMP_TIMEOUT_KILL_AFTER_S:-30}"
    local bin=""
    if command -v timeout >/dev/null 2>&1; then bin=timeout
    elif command -v gtimeout >/dev/null 2>&1; then bin=gtimeout
    fi
    [ -n "$bin" ] || return 0
    printf '%s -k %ss %ss' "$bin" "$ka" "$secs"
}
