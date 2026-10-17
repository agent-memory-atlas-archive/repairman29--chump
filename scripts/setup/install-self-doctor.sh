#!/usr/bin/env bash
# install-self-doctor.sh — INFRA-1595
#
# Idempotent installer for the chump self-doctor launchd user agent.
# Copies com.chump.self-doctor.plist to ~/Library/LaunchAgents/ with
# CHUMP_BIN_PLACEHOLDER and CHUMP_LOG_DIR_PLACEHOLDER substituted for
# the actual chump binary and log directory paths.
#
# Wave 0b "outer loop": when paramedic dies or wasn't installed, when
# bootstrap missed a daemon, when a stuck PR escapes its SLO — this
# daemon catches the gap and dispatches. Default OFF; heal mode requires
# CHUMP_FLEET_SELF_DOCTOR_HEAL=true env to take any auto-fix action.
#
# Usage:
#   install-self-doctor.sh            — install (idempotent)
#   install-self-doctor.sh --uninstall — stop + remove plist
#   install-self-doctor.sh --status   — print launchctl status
#   install-self-doctor.sh --check    — exit 0 if installed+running, else 1

set -uo pipefail
# INFRA-8194 (R5 slice 2): __BREW_PREFIX__ in the plist template resolves
# through the host resolver (chump_brew_prefix, the shell mirror of
# chump_provision::brew_prefix) instead of a baked Apple Silicon path.
# shellcheck source=../lib/host-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/host-paths.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLIST_TEMPLATE="$SCRIPT_DIR/com.chump.self-doctor.plist"
LABEL="com.chump.self-doctor"
LAUNCH_AGENTS_DIR="${HOME}/Library/LaunchAgents"
INSTALLED_PLIST="${LAUNCH_AGENTS_DIR}/${LABEL}.plist"
LOG_DIR="${HOME}/Library/Logs/Chump"
UID_VAL="$(id -u)"

# ── resolve chump binary ──────────────────────────────────────────────────────
_find_chump() {
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
    launchctl bootstrap "$_lctl_domain" "$INSTALLED_PLIST" 2>&1 || true
    launchctl enable "$_lctl_svc" 2>&1 || true
    launchctl kickstart "$_lctl_svc" 2>&1 || true
}

_unload_plist() {
    launchctl bootout "$_lctl_svc" 2>&1 || true
}

# ── dispatch ──────────────────────────────────────────────────────────────────
case "${1:-install}" in
    --uninstall|uninstall)
        echo "[install-self-doctor] Uninstalling ${LABEL}..."
        if _is_loaded; then
            _unload_plist
        fi
        if [[ -f "$INSTALLED_PLIST" ]]; then
            rm -f "$INSTALLED_PLIST"
        fi
        echo "[install-self-doctor] Done."
        exit 0
        ;;

    --status|status)
        if _is_loaded; then
            echo "[install-self-doctor] ${LABEL}: LOADED"
            launchctl print "$_lctl_svc" 2>/dev/null | grep -E "state|pid|runs" || true
        else
            echo "[install-self-doctor] ${LABEL}: NOT LOADED"
        fi
        exit 0
        ;;

    --check|check)
        if [[ ! -f "$INSTALLED_PLIST" ]]; then
            echo "[install-self-doctor] FAIL: plist not installed at ${INSTALLED_PLIST}" >&2
            exit 1
        fi
        if ! _is_loaded; then
            echo "[install-self-doctor] FAIL: ${LABEL} not loaded in launchd" >&2
            exit 1
        fi
        echo "[install-self-doctor] OK: ${LABEL} installed and loaded"
        exit 0
        ;;

    install|--install|"")
        ;;

    *)
        echo "Usage: install-self-doctor.sh [--install|--uninstall|--status|--check]" >&2
        exit 1
        ;;
esac

# ── install ───────────────────────────────────────────────────────────────────
echo "[install-self-doctor] Installing ${LABEL}..."

CHUMP_BIN="$(_find_chump)" || {
    echo "[install-self-doctor] ERROR: chump binary not found." >&2
    echo "  Build first: cargo build --release" >&2
    echo "  Or set CHUMP_BIN=/path/to/chump" >&2
    exit 1
}
echo "[install-self-doctor]   chump binary: ${CHUMP_BIN}"

mkdir -p "$LAUNCH_AGENTS_DIR" "$LOG_DIR"

# Substitute placeholders in plist template.
sed \
    -e "s|__BREW_PREFIX__|$(chump_brew_prefix)|g" \
    -e "s|CHUMP_BIN_PLACEHOLDER|${CHUMP_BIN}|g" \
    -e "s|CHUMP_LOG_DIR_PLACEHOLDER|${LOG_DIR}|g" \
    "$PLIST_TEMPLATE" > "$INSTALLED_PLIST"

echo "[install-self-doctor]   plist: ${INSTALLED_PLIST}"
echo "[install-self-doctor]   logs:  ${LOG_DIR}/self-doctor.{out,err}.log"

if _is_loaded; then
    echo "[install-self-doctor]   already loaded — reloading..."
    _unload_plist
fi
_load_plist
echo "[install-self-doctor]   bootstrapped into ${_lctl_domain}"

if _is_loaded; then
    echo "[install-self-doctor] OK: ${LABEL} is running."
    echo
    echo "  Default mode is diagnose-only. To enable auto-healing:"
    echo "    launchctl setenv CHUMP_FLEET_SELF_DOCTOR_HEAL true"
    echo "    launchctl kickstart -k ${_lctl_svc}"
else
    echo "[install-self-doctor] WARN: bootstrap completed but service not yet visible." >&2
    echo "  Check: launchctl print ${_lctl_svc}" >&2
fi
