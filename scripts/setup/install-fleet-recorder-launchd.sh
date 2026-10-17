#!/usr/bin/env bash
# install-fleet-recorder-launchd.sh — INFRA-2174
#
# Idempotent installer for the chump-fleet-recorder launchd user agent.
# Installs com.chump.fleet-recorder.plist into ~/Library/LaunchAgents/
# with binary path, repo root, HOME, and log dir substituted.
#
# Usage:
#   install-fleet-recorder-launchd.sh            — install (idempotent)
#   install-fleet-recorder-launchd.sh --uninstall — stop + remove plist
#   install-fleet-recorder-launchd.sh --status    — print launchctl status
#   install-fleet-recorder-launchd.sh --check     — exit 0 if installed+running, else 1

set -euo pipefail
# INFRA-8194 (R5 slice 2): __BREW_PREFIX__ in the plist template resolves
# through the host resolver (chump_brew_prefix, the shell mirror of
# chump_provision::brew_prefix) instead of a baked Apple Silicon path.
# shellcheck source=../lib/host-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/host-paths.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLIST_TEMPLATE="$SCRIPT_DIR/com.chump.fleet-recorder.plist"
LABEL="com.chump.fleet-recorder"
LAUNCH_AGENTS_DIR="${HOME}/Library/LaunchAgents"
INSTALLED_PLIST="${LAUNCH_AGENTS_DIR}/${LABEL}.plist"
LOG_DIR="${HOME}/Library/Logs/Chump"
UID_VAL="$(id -u)"
CARGO_BIN="${HOME}/.cargo/bin"

# ── resolve chump-fleet-recorder binary ──────────────────────────────────────
_find_recorder() {
    if [[ -n "${CHUMP_FLEET_RECORDER_BIN:-}" ]] && [[ -x "$CHUMP_FLEET_RECORDER_BIN" ]]; then
        printf '%s' "$CHUMP_FLEET_RECORDER_BIN"
        return 0
    fi
    for candidate in \
        "$REPO_ROOT/target/release/chump-fleet-recorder" \
        "$REPO_ROOT/target/debug/chump-fleet-recorder" \
        "$CARGO_BIN/chump-fleet-recorder"
    do
        if [[ -x "$candidate" ]]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    if command -v chump-fleet-recorder &>/dev/null; then
        command -v chump-fleet-recorder
        return 0
    fi
    return 1
}

# ── launchctl helpers ─────────────────────────────────────────────────────────
_lctl_domain="gui/${UID_VAL}"
_lctl_svc="${_lctl_domain}/${LABEL}"

_is_loaded() {
    launchctl print "$_lctl_svc" &>/dev/null
}

_load_plist() {
    launchctl bootstrap "$_lctl_domain" "$INSTALLED_PLIST" 2>/dev/null || true
}

_unload_plist() {
    if _is_loaded; then
        launchctl bootout "$_lctl_domain" "$INSTALLED_PLIST" 2>/dev/null || \
            launchctl remove "$LABEL" 2>/dev/null || true
    fi
}

# ── subcommands ───────────────────────────────────────────────────────────────
cmd="${1:-install}"

case "$cmd" in
    --uninstall|uninstall)
        echo "[install-fleet-recorder] Uninstalling ${LABEL}..."
        _unload_plist
        if [[ -f "$INSTALLED_PLIST" ]]; then
            rm -f "$INSTALLED_PLIST"
            echo "[install-fleet-recorder] Removed ${INSTALLED_PLIST}"
        fi
        echo "[install-fleet-recorder] Done."
        exit 0
        ;;

    --status|status)
        if _is_loaded; then
            echo "[install-fleet-recorder] ${LABEL}: LOADED"
            launchctl print "$_lctl_svc" 2>/dev/null | grep -E "state|pid|runs" || true
        else
            echo "[install-fleet-recorder] ${LABEL}: NOT LOADED"
        fi
        exit 0
        ;;

    --check|check)
        if [[ ! -f "$INSTALLED_PLIST" ]]; then
            echo "[install-fleet-recorder] FAIL: plist not installed at ${INSTALLED_PLIST}" >&2
            exit 1
        fi
        if ! _is_loaded; then
            echo "[install-fleet-recorder] FAIL: ${LABEL} not loaded in launchd" >&2
            exit 1
        fi
        echo "[install-fleet-recorder] OK: ${LABEL} installed and loaded"
        exit 0
        ;;

    install|--install|"")
        # Fall through to install logic below.
        ;;

    *)
        echo "Usage: install-fleet-recorder-launchd.sh [--install|--uninstall|--status|--check]" >&2
        exit 1
        ;;
esac

# ── install ───────────────────────────────────────────────────────────────────
echo "[install-fleet-recorder] Installing ${LABEL}..."

RECORDER_BIN="$(_find_recorder)" || {
    echo "[install-fleet-recorder] ERROR: chump-fleet-recorder binary not found." >&2
    echo "  Build first: cargo build --release --package chump-fleet-recorder" >&2
    echo "  Or: cargo install --path crates/chump-fleet-recorder" >&2
    echo "  Or set CHUMP_FLEET_RECORDER_BIN=/path/to/binary" >&2
    exit 1
}
echo "[install-fleet-recorder]   binary:    ${RECORDER_BIN}"
echo "[install-fleet-recorder]   repo root: ${REPO_ROOT}"
echo "[install-fleet-recorder]   logs:      ${LOG_DIR}/fleet-recorder.{out,err}.log"

mkdir -p "$LAUNCH_AGENTS_DIR" "$LOG_DIR"

# Substitute placeholders in the plist template.
sed \
    -e "s|__BREW_PREFIX__|$(chump_brew_prefix)|g" \
    -e "s|RECORDER_BIN_PLACEHOLDER|${RECORDER_BIN}|g" \
    -e "s|REPO_ROOT_PLACEHOLDER|${REPO_ROOT}|g" \
    -e "s|CARGO_BIN_PLACEHOLDER|${CARGO_BIN}|g" \
    -e "s|HOME_PLACEHOLDER|${HOME}|g" \
    -e "s|LOG_DIR_PLACEHOLDER|${LOG_DIR}|g" \
    "$PLIST_TEMPLATE" > "$INSTALLED_PLIST"

echo "[install-fleet-recorder]   plist:     ${INSTALLED_PLIST}"

# Reload if already running (idempotent).
if _is_loaded; then
    echo "[install-fleet-recorder]   already loaded — reloading..."
    _unload_plist
fi
_load_plist
echo "[install-fleet-recorder]   bootstrapped into ${_lctl_domain}"

if _is_loaded; then
    echo "[install-fleet-recorder] OK: ${LABEL} is running."
else
    echo "[install-fleet-recorder] WARN: bootstrap completed but service not yet visible." >&2
    echo "  Check: launchctl print ${_lctl_svc}" >&2
fi
