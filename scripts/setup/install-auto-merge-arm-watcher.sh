#!/usr/bin/env bash
# install-auto-merge-arm-watcher.sh — INFRA-2289
#
# Install the auto-merge ARM-drop watcher as a launchd user agent (macOS).
# The watcher polls every CHUMP_AM_WATCHER_INTERVAL_S (default 600s) for
# OPEN PRs whose autoMergeRequest was silently cleared after an auto-rebase
# conflict, then re-arms them.
#
# Usage:
#   bash scripts/setup/install-auto-merge-arm-watcher.sh            # install + load
#   bash scripts/setup/install-auto-merge-arm-watcher.sh --uninstall
#   bash scripts/setup/install-auto-merge-arm-watcher.sh --status
#   bash scripts/setup/install-auto-merge-arm-watcher.sh --check    # exit 0 if running
#
# Env knobs (read at install time):
#   CHUMP_AM_WATCHER_INTERVAL_S — poll interval in seconds (default 600)
#
# Mirrors the META-118 daemon install pattern (see install-self-doctor.sh,
# install-paramedic-launchd.sh for prior art).
#
# DO NOT call launchctl unload on the plist directly without --uninstall;
# use the script so logs/state stay consistent.

set -uo pipefail
# INFRA-8194 (R5 slice 2): the Homebrew prefix comes from the host resolver
# (chump_brew_prefix in scripts/lib/host-paths.sh, the shell mirror of
# chump_provision::brew_prefix; `chump node host --field brew-prefix`), not a
# baked Apple Silicon path.
# shellcheck source=../lib/host-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/host-paths.sh"
BREW_PREFIX="$(chump_brew_prefix)"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

LABEL="com.chump.auto-merge-arm-watcher"
LAUNCH_AGENTS_DIR="${HOME}/Library/LaunchAgents"
INSTALLED_PLIST="${LAUNCH_AGENTS_DIR}/${LABEL}.plist"
WATCHER_SCRIPT="${REPO_ROOT}/scripts/coord/auto-merge-arm-watcher.sh"
LOG_OUT="/tmp/chump-auto-merge-arm-watcher.out.log"
LOG_ERR="/tmp/chump-auto-merge-arm-watcher.err.log"

INTERVAL_S="${CHUMP_AM_WATCHER_INTERVAL_S:-600}"

UID_VAL="$(id -u)"
_lctl_domain="gui/${UID_VAL}"
_lctl_svc="${_lctl_domain}/${LABEL}"

_is_loaded() {
    launchctl print "${_lctl_svc}" &>/dev/null
}

_load_plist() {
    launchctl bootstrap "${_lctl_domain}" "${INSTALLED_PLIST}" 2>&1 || true
    launchctl enable "${_lctl_svc}" 2>&1 || true
    launchctl kickstart "${_lctl_svc}" 2>&1 || true
}

_unload_plist() {
    launchctl bootout "${_lctl_svc}" 2>&1 || true
}

# ── dispatch ──────────────────────────────────────────────────────────────────
case "${1:-install}" in
    --uninstall|uninstall)
        echo "[install-auto-merge-arm-watcher] Uninstalling ${LABEL}..."
        if _is_loaded; then
            _unload_plist
        fi
        if [[ -f "${INSTALLED_PLIST}" ]]; then
            rm -f "${INSTALLED_PLIST}"
            echo "[install-auto-merge-arm-watcher] Removed plist."
        else
            echo "[install-auto-merge-arm-watcher] Plist not found — nothing to remove."
        fi
        echo "[install-auto-merge-arm-watcher] Done."
        exit 0
        ;;

    --status|status)
        if _is_loaded; then
            echo "[install-auto-merge-arm-watcher] ${LABEL}: LOADED"
            launchctl print "${_lctl_svc}" 2>/dev/null | grep -E "state|pid|runs" || true
        else
            echo "[install-auto-merge-arm-watcher] ${LABEL}: NOT LOADED"
        fi
        exit 0
        ;;

    --check|check)
        if [[ ! -f "${INSTALLED_PLIST}" ]]; then
            echo "[install-auto-merge-arm-watcher] FAIL: plist not installed at ${INSTALLED_PLIST}" >&2
            exit 1
        fi
        if ! _is_loaded; then
            echo "[install-auto-merge-arm-watcher] FAIL: ${LABEL} not loaded in launchd" >&2
            exit 1
        fi
        echo "[install-auto-merge-arm-watcher] OK: ${LABEL} installed and loaded."
        exit 0
        ;;

    install|--install|"")
        ;;

    *)
        echo "Usage: install-auto-merge-arm-watcher.sh [--install|--uninstall|--status|--check]" >&2
        exit 1
        ;;
esac

# ── install ───────────────────────────────────────────────────────────────────
echo "[install-auto-merge-arm-watcher] Installing ${LABEL}..."

if [[ ! -f "${WATCHER_SCRIPT}" ]]; then
    echo "[install-auto-merge-arm-watcher] ERROR: ${WATCHER_SCRIPT} not found." >&2
    echo "  INFRA-2289 must land before installing the launchd agent." >&2
    exit 1
fi
if [[ ! -x "${WATCHER_SCRIPT}" ]]; then
    chmod +x "${WATCHER_SCRIPT}"
fi

mkdir -p "${LAUNCH_AGENTS_DIR}"

cat > "${INSTALLED_PLIST}" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${WATCHER_SCRIPT}</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${REPO_ROOT}</string>
    <!-- StartInterval=600s (10 min) — matches CHUMP_AM_WATCHER_INTERVAL_S default.
         The watcher itself loops internally; launchd restarts it if it exits.
         Set CHUMP_AM_WATCHER_ONE_SHOT=1 to run once per launchd tick instead. -->
    <key>StartInterval</key>
    <integer>${INTERVAL_S}</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_OUT}</string>
    <key>StandardErrorPath</key>
    <string>${LOG_ERR}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>${HOME}</string>
        <key>PATH</key>
        <string>${BREW_PREFIX}/bin:/usr/local/bin:/usr/bin:/bin</string>
        <key>CHUMP_REPO_ROOT</key>
        <string>${REPO_ROOT}</string>
        <!-- One-shot per launchd tick: watcher polls once then exits.
             launchd re-launches after StartInterval. This is simpler than
             keeping a long-running process alive across macOS sleep cycles. -->
        <key>CHUMP_AM_WATCHER_ONE_SHOT</key>
        <string>1</string>
    </dict>
</dict>
</plist>
PLISTEOF

echo "[install-auto-merge-arm-watcher]   plist:   ${INSTALLED_PLIST}"
echo "[install-auto-merge-arm-watcher]   watcher: ${WATCHER_SCRIPT}"
echo "[install-auto-merge-arm-watcher]   stdout:  ${LOG_OUT}"
echo "[install-auto-merge-arm-watcher]   stderr:  ${LOG_ERR}"

if _is_loaded; then
    echo "[install-auto-merge-arm-watcher]   already loaded — reloading..."
    _unload_plist
fi
_load_plist

if _is_loaded; then
    echo "[install-auto-merge-arm-watcher] OK: ${LABEL} is running."
    echo
    echo "  Cadence: StartInterval=${INTERVAL_S}s (one-shot per tick)"
    echo "  Logs:    ${LOG_OUT}"
    echo "  Verify:  launchctl list | grep ${LABEL}"
    echo "  Disable: launchctl bootout ${_lctl_svc}"
else
    echo "[install-auto-merge-arm-watcher] WARN: bootstrap completed but service not yet visible." >&2
    echo "  Check: launchctl print ${_lctl_svc}" >&2
fi
