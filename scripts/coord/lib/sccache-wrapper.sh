#!/usr/bin/env bash
# scripts/coord/lib/sccache-wrapper.sh — RESILIENT-468
#
# Enables sccache as a rustc wrapper for local and node builds when available.
# Detects sccache binary, starts the daemon, configures RUSTC_WRAPPER, and
# tracks cache hit/miss statistics.
#
# Gracefully degrades to standard rustc if sccache is unavailable.
#
# Usage (source then call):
#   source "$(dirname "$0")/../coord/lib/sccache-wrapper.sh"
#   sccache_maybe_enable    # sets RUSTC_WRAPPER if sccache is available
#   # ... run cargo build/check ...
#   sccache_maybe_report    # prints cache stats if sccache was active
#
# Returns 0 when successful (either sccache enabled or graceful degradation).
# Never fails the caller — if sccache is missing, the build proceeds without it.

# Idempotent source guard.
if [ -n "${_SCCACHE_WRAPPER_LOADED:-}" ]; then
    return 0 2>/dev/null || true
fi
_SCCACHE_WRAPPER_LOADED=1

# Detect repo root + ambient log path.
_sccache_repo_root() {
    git rev-parse --show-toplevel 2>/dev/null || pwd
}

_sccache_ambient() {
    echo "${CHUMP_AMBIENT_LOG:-$(_sccache_repo_root)/.chump-locks/ambient.jsonl}"
}

# scanner-anchor (EVENT_REGISTRY coverage; kinds are passed via $1 below):
#   {"kind":"sccache_wrapper_enabled"} {"kind":"sccache_daemon_start_failed"} {"kind":"sccache_build_stats"}
# Emit a structured event to ambient (best-effort).
_sccache_emit() {
    local kind="$1"; shift
    local extra=""
    for kv in "$@"; do extra+=",${kv}"; done
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local amb
    amb="$(_sccache_ambient)"
    printf '{"ts":"%s","kind":"%s","source":"sccache_wrapper"%s}\n' \
        "$ts" "$kind" "$extra" >> "$amb" 2>/dev/null || true
}

# sccache_maybe_enable — detect sccache binary and configure RUSTC_WRAPPER.
# Sets environment variables:
#   RUSTC_WRAPPER=sccache (if available)
#   SCCACHE_CACHE_SIZE (if not already set)
#   SCCACHE_DIR (if not already set)
#
# Returns 0 (success or graceful degradation), non-zero only on fatal errors.
sccache_maybe_enable() {
    # sccache already enabled? skip detection.
    if [ "${RUSTC_WRAPPER:-}" = "sccache" ]; then
        return 0
    fi

    # Check if sccache binary is available on PATH.
    if ! command -v sccache >/dev/null 2>&1; then
        # Not available — degrade gracefully. No error, just no caching.
        return 0
    fi

    # sccache found. Try to start the daemon.
    local sccache_bin
    sccache_bin="$(command -v sccache)"

    # Start daemon (best-effort; if already running, this is a no-op).
    if ! "$sccache_bin" --start-server >/dev/null 2>&1; then
        # Daemon startup failed — still attempt to use RUSTC_WRAPPER
        # (some envs allow sccache to run without a background daemon).
        # Emit a warning but don't fail.
        _sccache_emit "sccache_daemon_start_failed" \
            "\"sccache_bin\":\"$sccache_bin\""
    fi

    # Configure RUSTC_WRAPPER + defaults for cache dir/size.
    export RUSTC_WRAPPER="$sccache_bin"
    export SCCACHE_DIR="${SCCACHE_DIR:-${HOME}/.cache/sccache}"
    export SCCACHE_CACHE_SIZE="${SCCACHE_CACHE_SIZE:-10G}"

    # Emit activation signal for ambient telemetry.
    _sccache_emit "sccache_wrapper_enabled" \
        "\"sccache_bin\":\"$sccache_bin\"" \
        "\"cache_dir\":\"$SCCACHE_DIR\"" \
        "\"cache_size\":\"$SCCACHE_CACHE_SIZE\""

    return 0
}

# sccache_maybe_report — print cache statistics if sccache was active.
# Returns 0 always (reporting is best-effort).
sccache_maybe_report() {
    if [ "${RUSTC_WRAPPER:-}" != "sccache" ]; then
        # sccache not active — nothing to report.
        return 0
    fi

    if ! command -v sccache >/dev/null 2>&1; then
        # This shouldn't happen if RUSTC_WRAPPER=sccache, but guard anyway.
        return 0
    fi

    # Query cache statistics.
    local stats_out
    stats_out="$(sccache --show-stats 2>/dev/null)" || return 0

    # Extract compile requests, cache hits, cache misses.
    local compile_reqs hits misses
    compile_reqs="$(printf '%s\n' "$stats_out" | grep -i 'compile requests' | awk '{print $NF}')"
    hits="$(printf '%s\n' "$stats_out" | grep -i 'cache hits' | awk '{print $NF}')"
    misses="$(printf '%s\n' "$stats_out" | grep -i 'cache misses' | awk '{print $NF}')"

    # Print to stdout for visibility.
    if [ -n "$compile_reqs" ] || [ -n "$hits" ] || [ -n "$misses" ]; then
        printf '=== sccache statistics ===\n' >&2
        [ -n "$compile_reqs" ] && printf '  Compile requests: %s\n' "$compile_reqs" >&2
        [ -n "$hits" ] && printf '  Cache hits: %s\n' "$hits" >&2
        [ -n "$misses" ] && printf '  Cache misses: %s\n' "$misses" >&2
    fi

    # Emit stats to ambient for trending.
    if [ -n "$compile_reqs" ] && [ -n "$hits" ]; then
        _sccache_emit "sccache_build_stats" \
            "\"compile_requests\":$compile_reqs" \
            "\"cache_hits\":$hits" \
            "\"cache_misses\":$misses"
    fi

    return 0
}

# sccache_is_enabled — query whether sccache is currently active.
# Returns 0 if RUSTC_WRAPPER=sccache, 1 otherwise.
sccache_is_enabled() {
    [ "${RUSTC_WRAPPER:-}" = "sccache" ]
}
