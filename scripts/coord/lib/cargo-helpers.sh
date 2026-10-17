#!/usr/bin/env bash
# scripts/coord/lib/cargo-helpers.sh — INFRA-2086 loud-fail cargo build wrapper.
#
# Wraps `cargo build` to detect today's silent-failure class (INFRA-2082):
#   - `cargo build -q` exits 0 but produces no binary → 127 on exec downstream
#   - Tauri proc-macro registry corruption → silent miss + no clear error
#   - Build timeout → indefinite hang
#
# After migration, every CI cargo build surfaces structured failure info
# instead of leaving the next exec to discover the missing binary.
#
# Usage (source then call):
#   source "$(dirname "$0")/../coord/lib/cargo-helpers.sh"
#   chump_cargo_build --package chump-mcp-coord --binary chump-mcp-coord
#   chump_cargo_build --package chump --binary chump --release --timeout-s 600
#
# Returns 0 on success; non-zero on any failure with structured stderr.
# Emits ambient kind=cargo_build_failed and kind=cargo_registry_corruption
# (registered in EVENT_REGISTRY.yaml).

# Idempotent source guard.
if [ -n "${_CHUMP_CARGO_HELPERS_LOADED:-}" ]; then
    return 0 2>/dev/null || true
fi
_CHUMP_CARGO_HELPERS_LOADED=1

# Locate repo root + ambient log path.
_chump_cargo_repo_root() {
    git rev-parse --show-toplevel 2>/dev/null || pwd
}
_chump_cargo_ambient() {
    echo "${CHUMP_AMBIENT_LOG:-$(_chump_cargo_repo_root)/.chump-locks/ambient.jsonl}"
}

# Emit a structured event to ambient (best-effort).
_chump_cargo_emit() {
    local kind="$1"; shift
    local extra=""
    for kv in "$@"; do extra+=",${kv}"; done
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local amb
    amb="$(_chump_cargo_ambient)"
    printf '{"ts":"%s","kind":"%s","source":"chump_cargo_build"%s}\n' \
        "$ts" "$kind" "$extra" >> "$amb" 2>/dev/null || true
}

# chump_cargo_build --package <pkg> --binary <bin> [--release] [--timeout-s 300]
#
# Returns 0 only when build succeeds AND binary exists at expected path.
chump_cargo_build() {
    local _pkg="" _bin="" _release=0 _timeout=300
    while [ $# -gt 0 ]; do
        case "$1" in
            --package)   _pkg="$2"; shift 2 ;;
            --binary)    _bin="$2"; shift 2 ;;
            --release)   _release=1; shift ;;
            --timeout-s) _timeout="$2"; shift 2 ;;
            *) echo "chump_cargo_build: unknown arg: $1" >&2; return 2 ;;
        esac
    done

    if [ -z "$_pkg" ] || [ -z "$_bin" ]; then
        echo "chump_cargo_build: --package and --binary are required" >&2
        return 2
    fi

    local _repo_root
    _repo_root="$(_chump_cargo_repo_root)"
    local _profile="debug"
    local _flags=""
    if [ "$_release" = "1" ]; then
        _profile="release"
        _flags="--release"
    fi
    # INFRA-2098: resolve canonical target dir via `cargo metadata` (mirrors the
    # INFRA-2096 fix on scripts/ci/test-mcp-coord-smoke.sh). Handles three cases:
    #   1. ENV-set CARGO_TARGET_DIR (INFRA-1540 runner-shared cache on self-hosted)
    #   2. .cargo/config.toml [build] target-dir = "..." (INFRA-202 sccache config)
    #   3. Default cargo behavior ($_repo_root/target)
    # Pre-INFRA-2098, the hardcoded `$_repo_root/target/$_profile/$_bin` lookup
    # caused the wrapper to falsely report SILENT FAILURE on the self-hosted
    # runner (where CARGO_TARGET_DIR points at the shared cache) — the binary
    # IS built, just at a different path than the wrapper looked.
    local _target_dir=""
    if command -v cargo >/dev/null 2>&1; then
        _target_dir="$(cargo metadata --no-deps --format-version 1 2>/dev/null \
            | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("target_directory",""))' \
            2>/dev/null)"
    fi
    if [ -z "$_target_dir" ]; then
        # ZERO-WASTE-134: cargo metadata unavailable -> the one shared default,
        # never a path inside the repo/worktree.
        # shellcheck source=../../ci/lib/resolve-cargo-target-dir.sh
        # shellcheck disable=SC1091
        . "$_repo_root/scripts/ci/lib/resolve-cargo-target-dir.sh" 2>/dev/null || true
        if command -v chump_cargo_target_dir >/dev/null 2>&1; then
            _target_dir="$(chump_cargo_target_dir)"
        else
            _target_dir="${CARGO_TARGET_DIR:-}"
        fi
    fi
    local _bin_path="$_target_dir/$_profile/$_bin"
    local _start_ts
    _start_ts=$(date +%s)
    local _stderr_log
    _stderr_log="$(mktemp)"

    # Run cargo build with timeout. Capture stderr always (even with -q upstream).
    # Use --message-format=short to keep output manageable.
    local _rc
    if command -v timeout >/dev/null 2>&1; then
        ( cd "$_repo_root" && timeout "$_timeout" cargo build $_flags --package "$_pkg" --message-format=short 2>"$_stderr_log" )
        _rc=$?
    else
        # macOS may not have GNU timeout; fall back to no-timeout but warn
        echo "chump_cargo_build: WARN — no timeout command, building without timeout cap" >&2
        ( cd "$_repo_root" && cargo build $_flags --package "$_pkg" --message-format=short 2>"$_stderr_log" )
        _rc=$?
    fi

    local _duration=$(( $(date +%s) - _start_ts ))

    # Timeout class (rc=124 from GNU timeout)
    if [ "$_rc" = "124" ]; then
        echo "chump_cargo_build: TIMEOUT building $_pkg after ${_timeout}s" >&2
        echo "---last 30 lines of cargo stderr---" >&2
        tail -30 "$_stderr_log" >&2 2>/dev/null || true
        _chump_cargo_emit "cargo_build_failed" \
            "\"package\":\"$_pkg\"" "\"binary\":\"$_bin\"" \
            "\"exit_code\":$_rc" "\"duration_s\":$_duration" \
            "\"suspected_class\":\"timeout\""
        rm -f "$_stderr_log"
        return 124
    fi

    # Registry corruption class (tauri proc-macro pattern from INFRA-2082)
    if grep -qE 'failed to read plugin global API script|proc-macro panicked' "$_stderr_log" 2>/dev/null; then
        local _bad_crate
        _bad_crate=$(grep -oE '[a-z0-9_-]+-[0-9]+\.[0-9]+\.[0-9]+' "$_stderr_log" | head -1 || echo "unknown")
        echo "chump_cargo_build: REGISTRY CORRUPTION building $_pkg" >&2
        echo "  Suspect crate: $_bad_crate" >&2
        echo "  Suggested fix: cargo clean -p $_bad_crate; rm -rf ~/.cargo/registry/cache/index.crates.io-*/$_bad_crate.crate" >&2
        _chump_cargo_emit "cargo_registry_corruption" \
            "\"crate\":\"$_bad_crate\"" \
            "\"suggested_fix\":\"cargo clean -p $_bad_crate\""
        _chump_cargo_emit "cargo_build_failed" \
            "\"package\":\"$_pkg\"" "\"binary\":\"$_bin\"" \
            "\"exit_code\":$_rc" "\"duration_s\":$_duration" \
            "\"suspected_class\":\"registry_corruption\""
        rm -f "$_stderr_log"
        return 137
    fi

    # General compile error class (rc != 0)
    if [ "$_rc" != "0" ]; then
        echo "chump_cargo_build: COMPILE ERROR building $_pkg (exit $_rc)" >&2
        echo "---last 30 lines of cargo stderr---" >&2
        tail -30 "$_stderr_log" >&2 2>/dev/null || true
        _chump_cargo_emit "cargo_build_failed" \
            "\"package\":\"$_pkg\"" "\"binary\":\"$_bin\"" \
            "\"exit_code\":$_rc" "\"duration_s\":$_duration" \
            "\"suspected_class\":\"compile_error\""
        rm -f "$_stderr_log"
        return "$_rc"
    fi

    # Missing binary class (rc=0 but binary doesn't exist — the INFRA-2082 silent failure)
    if [ ! -x "$_bin_path" ]; then
        echo "chump_cargo_build: SILENT FAILURE — build exited 0 but binary missing at $_bin_path" >&2
        echo "  This is the INFRA-2082 class: cargo build -q exits 0 but produces nothing." >&2
        echo "  Check $_stderr_log for hidden errors (often registry-cache related)." >&2
        echo "---last 30 lines of cargo stderr---" >&2
        tail -30 "$_stderr_log" >&2 2>/dev/null || true
        _chump_cargo_emit "cargo_build_failed" \
            "\"package\":\"$_pkg\"" "\"binary\":\"$_bin\"" \
            "\"exit_code\":0" "\"duration_s\":$_duration" \
            "\"suspected_class\":\"missing_binary\""
        rm -f "$_stderr_log"
        return 127
    fi

    # Success
    rm -f "$_stderr_log"
    return 0
}
