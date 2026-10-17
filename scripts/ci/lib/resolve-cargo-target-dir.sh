#!/usr/bin/env bash
# INFRA-2099: shared helper for scripts/ci/test-*.sh to resolve the canonical
# cargo target dir without hardcoding $ROOT/target.
#
# Prefer `cargo metadata --no-deps --format-version 1` which honors BOTH:
#   - $CARGO_TARGET_DIR env var (INFRA-1540 shared runner cache)
#   - .cargo/config.toml `[build] target-dir =` (INFRA-202 sccache fleet)
# Falls back to ${CARGO_TARGET_DIR:-$REPO_ROOT/target} when cargo is absent
# (callers handle the missing-cargo path themselves via SKIP guards).
#
# Usage:
#   source "$(dirname "$0")/lib/resolve-cargo-target-dir.sh"
#   TARGET_DIR="$(resolve_cargo_target_dir "$REPO_ROOT")"
#   BIN="$TARGET_DIR/debug/chump"
#
# ZERO-WASTE-134: ONE default cargo target dir for every script, hook and
# commit helper that has to pick a build dir when the caller did not.
#   chump_cargo_target_dir          -> prints the chosen dir (pure shell, no cargo)
#   chump_export_cargo_target_dir   -> exports CARGO_TARGET_DIR, mkdir -p, and
#                                      prints ONE line to stderr per process tree
# Resolution order (first hit wins, never a path inside a worktree):
#   1. $CARGO_TARGET_DIR          caller / CI runner / agent shell already chose
#   2. $CHUMP_CARGO_TARGET        per-user override of the shared default
#   3. $CHUMP_SHARED_CARGO_TARGET legacy alias (worker.sh / run-fleet.sh era)
#   4. $HOME/.cargo/chump-shared-target   per-user, shared by every worktree
# Receipt (2026-10-17): chump-commit.sh and the hooks defaulted to
# <worktree>/.cargo-build-target, so four worktrees carried private 2.4-3 GB
# build dirs (10 GiB) even though every agent exported a shared dir.
# Guard: scripts/ci/test-cargo-target-no-worktree-default.sh

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
    if [[ -z "${CHUMP_CARGO_TARGET_ANNOUNCED:-}" ]]; then
        export CHUMP_CARGO_TARGET_ANNOUNCED=1
        echo "[cargo-target] CARGO_TARGET_DIR=$_d (shared; override: CHUMP_CARGO_TARGET)" >&2
    fi
}

resolve_cargo_target_dir() {
    local repo_root="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
    local resolved=""

    if command -v cargo >/dev/null 2>&1; then
        resolved="$(cd "$repo_root" && cargo metadata --no-deps --format-version 1 2>/dev/null \
            | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("target_directory",""))' \
            2>/dev/null)"
    fi

    if [[ -n "$resolved" ]]; then
        echo "$resolved"
        return 0
    fi

    # Fall back to the one shared default (ZERO-WASTE-134) — never a path
    # inside the worktree/repo root.
    chump_cargo_target_dir
}
