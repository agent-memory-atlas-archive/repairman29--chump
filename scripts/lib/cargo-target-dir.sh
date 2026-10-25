#!/usr/bin/env bash
# scripts/lib/cargo-target-dir.sh — INFRA-8154 / ZERO-WASTE-134
# Shared warm cargo target directory resolver for pre-push and scripts.
# Delegates to the canonical resolver in scripts/ci/lib/resolve-cargo-target-dir.sh.

_CTD_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CTD_CI_RESOLVER="${_CTD_SELF_DIR}/../ci/lib/resolve-cargo-target-dir.sh"

if [[ -f "$_CTD_CI_RESOLVER" ]]; then
    # shellcheck source=../ci/lib/resolve-cargo-target-dir.sh
    source "$_CTD_CI_RESOLVER"
else
    chump_cargo_target_dir() {
        if [[ -n "${CARGO_TARGET_DIR:-}" ]]; then
            printf '%s\n' "$CARGO_TARGET_DIR"
        elif [[ -n "${CHUMP_CARGO_TARGET:-}" ]]; then
            printf '%s\n' "$CHUMP_CARGO_TARGET"
        elif [[ -n "${CHUMP_SHARED_CARGO_TARGET:-}" ]]; then
            printf '%s\n' "$CHUMP_SHARED_CARGO_TARGET"
        else
            printf '%s\n' "${HOME:-/tmp}/.cargo/chump-shared-target"
        fi
    }
    chump_export_cargo_target_dir() {
        local _d
        _d="$(chump_cargo_target_dir)"
        export CARGO_TARGET_DIR="$_d"
        mkdir -p "$_d" 2>/dev/null || true
    }
    resolve_cargo_target_dir() {
        chump_cargo_target_dir
    }
fi
unset _CTD_SELF_DIR _CTD_CI_RESOLVER
