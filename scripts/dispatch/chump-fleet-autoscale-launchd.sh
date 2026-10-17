#!/usr/bin/env bash
# scripts/dispatch/chump-fleet-autoscale-launchd.sh — INFRA-2198 (META-128/C7)
#
# Installs the com.chump.fleet-autoscale launchd user agent.
# Fires `chump fleet auto-scale --apply` every 5 minutes.
#
# Usage:
#   bash scripts/dispatch/chump-fleet-autoscale-launchd.sh           # install + load
#   bash scripts/dispatch/chump-fleet-autoscale-launchd.sh --uninstall  # stop + remove
#   bash scripts/dispatch/chump-fleet-autoscale-launchd.sh --status   # show launchctl state
#   bash scripts/dispatch/chump-fleet-autoscale-launchd.sh --check    # exit 0 if running, else 1
#
# Thresholds (override via env before install or in launchd EnvironmentVariables):
#   CHUMP_FLEET_SCALE_LOW_GB   — disk free below which we scale down 1 (default 20)
#   CHUMP_FLEET_SCALE_HIGH_GB  — disk free above which we scale up 1   (default 60)
#
# Idempotent. Safe to re-run; unloads old plist before loading new.
# Requires: chump binary on PATH or target/release/chump in repo root.
# Cross-references: INFRA-2193 (disk daemon), INFRA-2196 (chump disk CLI), META-128.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# INFRA-8194 (R5 slice 2): the Homebrew prefix comes from the host resolver
# (chump_brew_prefix, the shell mirror of chump_provision::brew_prefix).
# shellcheck source=scripts/lib/host-paths.sh
source "$SCRIPT_DIR/../lib/host-paths.sh"
BREW_PREFIX="$(chump_brew_prefix)"

# INFRA-451: resolve to main worktree so the plist absolute path survives
# worktree reaping.  Fall back to two-levels-up if the helper is absent.
if [[ -f "$SCRIPT_DIR/../lib/resolve-main-worktree.sh" ]]; then
    # shellcheck source=scripts/lib/resolve-main-worktree.sh
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
    REPO_ROOT="$(resolve_main_worktree "$0")"
else
    REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi

LABEL="com.chump.fleet-autoscale"
PLIST_DIR="${HOME}/Library/LaunchAgents"
PLIST="${PLIST_DIR}/${LABEL}.plist"
LOG_DIR="${HOME}/.chump/logs"
UID_VAL="$(id -u)"
DOMAIN="gui/${UID_VAL}"

# ── resolve chump binary ─────────────────────────────────────────────────────
_find_chump() {
    for candidate in \
        "${REPO_ROOT}/target/release/chump" \
        "${REPO_ROOT}/target/debug/chump" \
        "${HOME}/.cargo/bin/chump"
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
    echo "ERROR: chump binary not found; build with 'cargo build --release' first" >&2
    exit 2
}
CHUMP_BIN="$(_find_chump)"

# ── launchctl helpers ────────────────────────────────────────────────────────
_is_loaded() {
    launchctl print "${DOMAIN}/${LABEL}" &>/dev/null
}

_unload() {
    if _is_loaded; then
        launchctl bootout "${DOMAIN}" "${PLIST}" 2>/dev/null || true
    fi
}

# ── dispatch table ───────────────────────────────────────────────────────────
MODE="${1:-install}"

case "$MODE" in
    --uninstall)
        _unload
        rm -f "$PLIST"
        echo "[fleet-autoscale] uninstalled (plist removed)"
        exit 0
        ;;
    --status)
        launchctl print "${DOMAIN}/${LABEL}" 2>&1 || echo "(not loaded)"
        exit 0
        ;;
    --check)
        _is_loaded && exit 0 || exit 1
        ;;
    install|--install|"")
        : # fall through to install
        ;;
    *)
        echo "Usage: $0 [--install|--uninstall|--status|--check]" >&2
        exit 2
        ;;
esac

# ── install ──────────────────────────────────────────────────────────────────
mkdir -p "$PLIST_DIR" "$LOG_DIR"

LOW_GB="${CHUMP_FLEET_SCALE_LOW_GB:-20}"
HIGH_GB="${CHUMP_FLEET_SCALE_HIGH_GB:-60}"

cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${CHUMP_BIN}</string>
        <string>fleet</string>
        <string>auto-scale</string>
        <string>--apply</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${REPO_ROOT}</string>
    <!-- Fire every 5 minutes (300 seconds). -->
    <key>StartInterval</key>
    <integer>300</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/fleet-autoscale.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/fleet-autoscale.err.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>${HOME}</string>
        <key>PATH</key>
        <string>/usr/local/bin:${BREW_PREFIX}/bin:${HOME}/.cargo/bin:/usr/bin:/bin</string>
        <key>CHUMP_FLEET_SCALE_LOW_GB</key>
        <string>${LOW_GB}</string>
        <key>CHUMP_FLEET_SCALE_HIGH_GB</key>
        <string>${HIGH_GB}</string>
    </dict>
</dict>
</plist>
PLIST_EOF

# Reload (idempotent).
_unload
launchctl bootstrap "$DOMAIN" "$PLIST"

echo "[fleet-autoscale] installed: ${PLIST}"
echo "[fleet-autoscale] cadence  : every 5 minutes (StartInterval=300)"
echo "[fleet-autoscale] chump    : ${CHUMP_BIN}"
echo "[fleet-autoscale] repo     : ${REPO_ROOT}"
echo "[fleet-autoscale] low_gb   : ${LOW_GB}  (scale down below this free)"
echo "[fleet-autoscale] high_gb  : ${HIGH_GB}  (scale up above this free, if ship-rate > 0)"
echo "[fleet-autoscale] logs     : ${LOG_DIR}/fleet-autoscale.log"
echo "[fleet-autoscale] inspect  : launchctl print ${DOMAIN}/${LABEL}"
echo "[fleet-autoscale] disable  : $0 --uninstall"
