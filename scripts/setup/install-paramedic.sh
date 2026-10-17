#!/usr/bin/env bash
# install-paramedic.sh — INFRA-1397
#
# Idempotent installer for the chump paramedic launchd user agent.
# Copies com.chump.paramedic.plist to ~/Library/LaunchAgents/ with
# CHUMP_BIN_PLACEHOLDER and CHUMP_LOG_DIR_PLACEHOLDER substituted for
# the actual chump binary and log directory paths.
#
# Usage:
#   install-paramedic.sh            — install (idempotent)
#   install-paramedic.sh --uninstall — stop + remove plist
#   install-paramedic.sh --status   — print launchctl status
#   install-paramedic.sh --check    — exit 0 if installed+running, else 1
#
# AC §2: idempotent installer; AC §3: chump-fleet-bootstrap.sh integration.

set -euo pipefail
# INFRA-8194 (R5 slice 2): __BREW_PREFIX__ in the plist template resolves
# through the host resolver (chump_brew_prefix, the shell mirror of
# chump_provision::brew_prefix) instead of a baked Apple Silicon path.
# shellcheck source=../lib/host-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/host-paths.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLIST_TEMPLATE="$SCRIPT_DIR/com.chump.paramedic.plist"
LABEL="com.chump.paramedic"
LAUNCH_AGENTS_DIR="${HOME}/Library/LaunchAgents"
INSTALLED_PLIST="${LAUNCH_AGENTS_DIR}/${LABEL}.plist"
LOG_DIR="${HOME}/Library/Logs/Chump"
UID_VAL="$(id -u)"

# ── resolve chump binary ──────────────────────────────────────────────────────
_find_chump() {
    # Priority: $CHUMP_BIN env → repo target/release → target/debug → PATH
    if [[ -n "${CHUMP_BIN:-}" ]] && [[ -x "$CHUMP_BIN" ]]; then
        printf '%s' "$CHUMP_BIN"
        return 0
    fi
    for candidate in \
        "$REPO_ROOT/target/release/chump" \
        "$REPO_ROOT/target/debug/chump"
    do
        if [[ -x "$candidate" ]]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    if command -v chump &>/dev/null; then
        command -v chump
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
        echo "[install-paramedic] Uninstalling ${LABEL}..."
        _unload_plist
        if [[ -f "$INSTALLED_PLIST" ]]; then
            rm -f "$INSTALLED_PLIST"
            echo "[install-paramedic] Removed ${INSTALLED_PLIST}"
        fi
        echo "[install-paramedic] Done."
        exit 0
        ;;

    --status|status)
        if _is_loaded; then
            echo "[install-paramedic] ${LABEL}: LOADED"
            launchctl print "$_lctl_svc" 2>/dev/null | grep -E "state|pid|runs" || true
        else
            echo "[install-paramedic] ${LABEL}: NOT LOADED"
        fi
        exit 0
        ;;

    --check|check)
        # AC §3: exit 0 if installed+plist present; else exit 1.
        # (Heartbeat freshness checked by chump-fleet-bootstrap.sh --check.)
        if [[ ! -f "$INSTALLED_PLIST" ]]; then
            echo "[install-paramedic] FAIL: plist not installed at ${INSTALLED_PLIST}" >&2
            exit 1
        fi
        if ! _is_loaded; then
            echo "[install-paramedic] FAIL: ${LABEL} not loaded in launchd" >&2
            exit 1
        fi
        echo "[install-paramedic] OK: ${LABEL} installed and loaded"
        exit 0
        ;;

    install|--install|"")
        # Fall through to install logic below.
        ;;

    *)
        echo "Usage: install-paramedic.sh [--install|--uninstall|--status|--check]" >&2
        exit 1
        ;;
esac

# ── install ───────────────────────────────────────────────────────────────────
echo "[install-paramedic] Installing ${LABEL}..."

CHUMP_BIN="$(_find_chump)" || {
    echo "[install-paramedic] ERROR: chump binary not found." >&2
    echo "  Build first: cargo build --release" >&2
    echo "  Or set CHUMP_BIN=/path/to/chump" >&2
    exit 1
}
echo "[install-paramedic]   chump binary: ${CHUMP_BIN}"

mkdir -p "$LAUNCH_AGENTS_DIR" "$LOG_DIR"

# Substitute placeholders in plist template.
sed \
    -e "s|__BREW_PREFIX__|$(chump_brew_prefix)|g" \
    -e "s|CHUMP_BIN_PLACEHOLDER|${CHUMP_BIN}|g" \
    -e "s|CHUMP_LOG_DIR_PLACEHOLDER|${LOG_DIR}|g" \
    "$PLIST_TEMPLATE" > "$INSTALLED_PLIST"

echo "[install-paramedic]   plist: ${INSTALLED_PLIST}"
echo "[install-paramedic]   logs:  ${LOG_DIR}/paramedic.{out,err}.log"

# Reload if already running (idempotent).
if _is_loaded; then
    echo "[install-paramedic]   already loaded — reloading..."
    _unload_plist
fi
_load_plist
echo "[install-paramedic]   bootstrapped into ${_lctl_domain}"

# Verify load succeeded.
if _is_loaded; then
    echo "[install-paramedic] OK: ${LABEL} is running."
else
    echo "[install-paramedic] WARN: bootstrap completed but service not yet visible." >&2
    echo "  Check: launchctl print ${_lctl_svc}" >&2
fi
