#!/usr/bin/env bash
# install-coord-assign-launchd.sh — RESILIENT-271 (FLEET-034 / INFRA-2476)
#
# Idempotent installer for the `chump-coord assign` push-routing daemon as a
# launchd user agent. Installs com.chump.coord-assign.plist into
# ~/Library/LaunchAgents/ with binary path, repo root, HOME, and log dir
# substituted.
#
# Without this daemon running, chump-coord assign is built code-on-disk but
# never executes: state.db gaps with `preferred_machine` set are never
# published to chump.work.<priority>.<class>.<machine>, so host-targeted
# push dispatch stays dormant and the fleet falls back to pull-only.
#
# Usage:
#   install-coord-assign-launchd.sh            — install (idempotent)
#   install-coord-assign-launchd.sh --uninstall — stop + remove plist
#   install-coord-assign-launchd.sh --status    — print launchctl status
#   install-coord-assign-launchd.sh --check     — exit 0 if installed+running, else 1

set -euo pipefail
# INFRA-8194 (R5 slice 2): __BREW_PREFIX__ in the plist template resolves
# through the host resolver (chump_brew_prefix, the shell mirror of
# chump_provision::brew_prefix) instead of a baked Apple Silicon path.
# shellcheck source=../lib/host-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/host-paths.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLIST_TEMPLATE="$SCRIPT_DIR/com.chump.coord-assign.plist"
LABEL="com.chump.coord-assign"
LAUNCH_AGENTS_DIR="${HOME}/Library/LaunchAgents"
INSTALLED_PLIST="${LAUNCH_AGENTS_DIR}/${LABEL}.plist"
LOG_DIR="${HOME}/Library/Logs/Chump"
UID_VAL="$(id -u)"
CARGO_BIN="${HOME}/.cargo/bin"

# ── resolve chump-coord binary ───────────────────────────────────────────────
_find_coord_bin() {
    if [[ -n "${CHUMP_COORD_BIN:-}" ]] && [[ -x "$CHUMP_COORD_BIN" ]]; then
        printf '%s' "$CHUMP_COORD_BIN"
        return 0
    fi
    for candidate in \
        "$REPO_ROOT/target/release/chump-coord" \
        "$REPO_ROOT/target/debug/chump-coord" \
        "$HOME/.local/bin/chump-coord" \
        "$CARGO_BIN/chump-coord"
    do
        if [[ -x "$candidate" ]]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    if command -v chump-coord &>/dev/null; then
        command -v chump-coord
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
        echo "[install-coord-assign] Uninstalling ${LABEL}..."
        _unload_plist
        if [[ -f "$INSTALLED_PLIST" ]]; then
            rm -f "$INSTALLED_PLIST"
            echo "[install-coord-assign] Removed ${INSTALLED_PLIST}"
        fi
        echo "[install-coord-assign] Done."
        exit 0
        ;;

    --status|status)
        if _is_loaded; then
            echo "[install-coord-assign] ${LABEL}: LOADED"
            launchctl print "$_lctl_svc" 2>/dev/null | grep -E "state|pid|runs" || true
        else
            echo "[install-coord-assign] ${LABEL}: NOT LOADED"
        fi
        exit 0
        ;;

    --check|check)
        if [[ ! -f "$INSTALLED_PLIST" ]]; then
            echo "[install-coord-assign] FAIL: plist not installed at ${INSTALLED_PLIST}" >&2
            exit 1
        fi
        if ! _is_loaded; then
            echo "[install-coord-assign] FAIL: ${LABEL} not loaded in launchd" >&2
            exit 1
        fi
        echo "[install-coord-assign] OK: ${LABEL} installed and loaded"
        exit 0
        ;;

    install|--install|"")
        # Fall through to install logic below.
        ;;

    *)
        echo "Usage: install-coord-assign-launchd.sh [--install|--uninstall|--status|--check]" >&2
        exit 1
        ;;
esac

# ── install ───────────────────────────────────────────────────────────────────
echo "[install-coord-assign] Installing ${LABEL}..."

COORD_BIN="$(_find_coord_bin)" || {
    echo "[install-coord-assign] ERROR: chump-coord binary not found." >&2
    echo "  Build first: cargo build --release --package chump-coord" >&2
    echo "  Or: cargo install --path crates/chump-coord" >&2
    echo "  Or set CHUMP_COORD_BIN=/path/to/binary" >&2
    exit 1
}
echo "[install-coord-assign]   binary:    ${COORD_BIN}"
echo "[install-coord-assign]   repo root: ${REPO_ROOT}"
echo "[install-coord-assign]   logs:      ${LOG_DIR}/coord-assign.{out,err}.log"

mkdir -p "$LAUNCH_AGENTS_DIR" "$LOG_DIR"

# Substitute placeholders in the plist template.
sed \
    -e "s|__BREW_PREFIX__|$(chump_brew_prefix)|g" \
    -e "s|COORD_BIN_PLACEHOLDER|${COORD_BIN}|g" \
    -e "s|REPO_ROOT_PLACEHOLDER|${REPO_ROOT}|g" \
    -e "s|CARGO_BIN_PLACEHOLDER|${CARGO_BIN}|g" \
    -e "s|HOME_PLACEHOLDER|${HOME}|g" \
    -e "s|LOG_DIR_PLACEHOLDER|${LOG_DIR}|g" \
    "$PLIST_TEMPLATE" > "$INSTALLED_PLIST"

echo "[install-coord-assign]   plist:     ${INSTALLED_PLIST}"

# Reload if already running (idempotent).
if _is_loaded; then
    echo "[install-coord-assign]   already loaded — reloading..."
    _unload_plist
fi
_load_plist
echo "[install-coord-assign]   bootstrapped into ${_lctl_domain}"

if _is_loaded; then
    echo "[install-coord-assign] OK: ${LABEL} is running."
else
    echo "[install-coord-assign] WARN: bootstrap completed but service not yet visible." >&2
    echo "  Check: launchctl print ${_lctl_svc}" >&2
fi
