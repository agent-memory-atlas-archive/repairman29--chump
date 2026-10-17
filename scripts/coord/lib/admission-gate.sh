#!/usr/bin/env bash
# admission-gate.sh — RESILIENT-1604 / INFRA-8219: node-wide admission ceiling.
#
# This is now a THIN WRAPPER around the Rust verb `chump admit` (src/admit.rs).
# The invariant — "how many `claude -p` / cargo+rustc jobs may run on this node
# at once" — is owned by Rust per the PHASE-R R6 architecture rule; this shell
# only exists so existing spawn-site callers can keep sourcing the same two
# functions:
#
#   source "$(dirname "$0")/../coord/lib/admission-gate.sh"   # from scripts/dispatch/*
#   chump_admission_wait_claude    # block (bounded, fail-open) for a claude slot
#   chump_admission_wait_cargo     # block (bounded, fail-open) for a cargo slot
#
# Ceiling + bound config live entirely in the Rust verb (env > ~/.chump/node.env
# > nproc default):
#   CHUMP_MAX_CONCURRENT_CLAUDE       default max(1, nproc/2)
#   CHUMP_MAX_CONCURRENT_CARGO_JOBS   default max(1, nproc/2)
#   CHUMP_ADMISSION_WAIT_TIMEOUT_S    default 300  (total bounded wait)
#   CHUMP_ADMISSION_POLL_INTERVAL_S   default 5    (inter-check interval)
#
# `chump admit` exits 0 when a slot is free and 75 when deferred, and emits
# kind=admission_deferred itself. These wrappers are FAIL-OPEN: a deferred
# (exit 75) result is logged but we still return 0 so the caller proceeds — a
# stuck admission gate is worse than a temporarily-busy node.

if [ -n "${_CHUMP_ADMISSION_GATE_LOADED:-}" ]; then
    return 0 2>/dev/null || true
fi
_CHUMP_ADMISSION_GATE_LOADED=1

_chump_admission_bin() {
    if [ -n "${CHUMP_BIN:-}" ] && [ -x "${CHUMP_BIN}" ]; then
        echo "$CHUMP_BIN"
        return 0
    fi
    if command -v chump >/dev/null 2>&1; then
        command -v chump
        return 0
    fi
    local root
    root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    if [ -x "$root/target/release/chump" ]; then
        echo "$root/target/release/chump"
    elif [ -x "$root/target/debug/chump" ]; then
        echo "$root/target/debug/chump"
    else
        return 1
    fi
}

# _chump_admission_wait <resource>
# Delegates to `chump admit <resource> --wait-s <timeout>`; fail-open (returns 0
# regardless). If the binary can't be found, degrade to a no-op so a missing
# build never wedges a spawn site.
_chump_admission_wait() {
    local resource="$1"
    local timeout_s="${CHUMP_ADMISSION_WAIT_TIMEOUT_S:-300}"
    local bin
    if ! bin="$(_chump_admission_bin)"; then
        echo "[admission-gate] chump binary not found — skipping ${resource} admission gate" >&2
        return 0
    fi
    "$bin" admit "$resource" --wait-s "$timeout_s" >/dev/null 2>&1 || true
    return 0
}

# Call before spawning a `claude -p` subprocess.
chump_admission_wait_claude() {
    _chump_admission_wait claude
}

# Call before spawning a cargo/rustc build job.
chump_admission_wait_cargo() {
    _chump_admission_wait cargo
}
