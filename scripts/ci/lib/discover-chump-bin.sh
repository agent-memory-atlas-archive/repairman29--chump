#!/usr/bin/env bash
# discover-chump-bin.sh — shared CI test helper, INFRA-1437 follow-up.
#
# Set $CHUMP_BIN to the path of a built chump binary. Resolution order:
#   1. an operator-supplied $CHUMP_BIN override
#   2. the canonical cargo target dir resolved via `cargo metadata`
#      (INFRA-3517: honors .cargo/config.toml [build] target-dir, which the
#      $CARGO_TARGET_DIR env-var checks below silently MISS — that gap made
#      preflight report "binary not found" on any host using a config.toml
#      shared target dir, e.g. ~/.cargo/chump-shared-target)
#   3. the $CARGO_TARGET_DIR shared-cache path (INFRA-1540 self-hosted runners)
#   4. the legacy repo-local target/ dirs
#
# Usage in a CI test script:
#   source "$(dirname "$0")/lib/discover-chump-bin.sh"
#
# Caller must have $REPO_ROOT defined. After sourcing, $CHUMP_BIN is set
# OR the script exits with a clear diagnostic + actionable build hint.
#
# Honors an existing $CHUMP_BIN env var if it points at an executable file —
# allows operators to override via `CHUMP_BIN=/path/to/chump bash test-foo.sh`.

# INFRA-3517: resolve the canonical target dir via cargo metadata (honors
# .cargo/config.toml [build] target-dir). resolve_cargo_target_dir also folds
# in $CARGO_TARGET_DIR and the $REPO_ROOT/target fallback, so its result is the
# most authoritative single source — checked ahead of the raw env-var tiers.
_dcb_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/lib/resolve-cargo-target-dir.sh
source "$_dcb_lib_dir/resolve-cargo-target-dir.sh"
_dcb_target="$(resolve_cargo_target_dir "${REPO_ROOT:-$PWD}")"

# If caller set CHUMP_BIN and it's executable, use it as-is.
if [[ -n "${CHUMP_BIN:-}" ]] && [[ -x "$CHUMP_BIN" ]]; then
    :  # keep as-is
elif [[ -n "${CHUMP_BIN:-}" ]] && [[ -x "${REPO_ROOT:-}/$CHUMP_BIN" ]]; then
    CHUMP_BIN="$REPO_ROOT/$CHUMP_BIN"
elif [[ -n "$_dcb_target" ]] && [[ -x "$_dcb_target/release/chump" ]]; then
    # INFRA-3517: cargo-metadata-resolved target (honors config.toml target-dir).
    CHUMP_BIN="$_dcb_target/release/chump"
elif [[ -n "$_dcb_target" ]] && [[ -x "$_dcb_target/debug/chump" ]]; then
    CHUMP_BIN="$_dcb_target/debug/chump"
elif [[ -n "${CARGO_TARGET_DIR:-}" ]] && [[ -x "$CARGO_TARGET_DIR/release/chump" ]]; then
    # Self-hosted runner with shared cache (INFRA-1540).
    CHUMP_BIN="$CARGO_TARGET_DIR/release/chump"
elif [[ -n "${CARGO_TARGET_DIR:-}" ]] && [[ -x "$CARGO_TARGET_DIR/debug/chump" ]]; then
    CHUMP_BIN="$CARGO_TARGET_DIR/debug/chump"
elif [[ -x "${REPO_ROOT:-}/target/release/chump" ]]; then
    CHUMP_BIN="$REPO_ROOT/target/release/chump"
elif [[ -x "${REPO_ROOT:-}/target/debug/chump" ]]; then
    CHUMP_BIN="$REPO_ROOT/target/debug/chump"
elif command -v chump >/dev/null 2>&1; then
    CHUMP_BIN="$(command -v chump)"
else
    # CREDIBLE-1528: never print SKIP and exit 0 when no chump binary is found
    # (especially under CI=true where a silent SKIP-exit-0 makes a green step
    # prove nothing). Exit non-zero with a clear diagnostic.
    echo "[discover-chump-bin] ERROR (CREDIBLE-1528, CI=${CI:-unset}): no chump binary found — refusing to SKIP-and-exit-0." >&2
    echo "  Tried cargo-metadata target dir=${_dcb_target:-<unresolved>}/{release,debug}/chump" >&2
    echo "  Tried CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-<unset>}/{release,debug}/chump" >&2
    echo "  Tried ${REPO_ROOT:-<unset>}/target/{release,debug}/chump and PATH" >&2
    echo "  Build with: cargo build --release   (or cargo build for debug)" >&2
    exit 1
fi

unset _dcb_lib_dir _dcb_target
export CHUMP_BIN

# INFRA-755 observability hook: emit ambient event recording which target dir
# resolved. Useful for diagnosing future CARGO_TARGET_DIR drift between runner
# lanes. Best-effort — failures must not block the test caller.
{
    _amb="${REPO_ROOT:-$PWD}/.chump-locks/ambient.jsonl"
    _ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
    _src=""
    case "$CHUMP_BIN" in
        "${CARGO_TARGET_DIR:-_unset_}"/*) _src=cargo_target_dir ;;
        "${REPO_ROOT:-_unset_}"/*)        _src=repo_root_target ;;
        *)                                _src=other ;;
    esac
    if [[ -d "$(dirname "$_amb")" ]]; then
        printf '{"ts":"%s","kind":"chump_bin_resolved","source":"%s","path":"%s"}\n' \
            "$_ts" "$_src" "$CHUMP_BIN" >> "$_amb" 2>/dev/null || true
    fi
    unset _amb _ts _src
} 2>/dev/null || true
