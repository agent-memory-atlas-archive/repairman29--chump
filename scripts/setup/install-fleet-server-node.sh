#!/usr/bin/env bash
# scripts/setup/install-fleet-server-node.sh — RESILIENT-1046
#
# Make the chump-fleet-server audit/dashboard API a DURABLE, PULL-DRIVEN organ
# on a Linux fleet node — the "see everything out" / audit-OUT half of the
# operating covenant (dispatch-IN via POST /api/gap already works). The fleet's
# state becomes queryable over HTTP instead of by SSH-ing the boxes.
#
# THE GAP THIS CLOSES (verified live on cuphead 2026-09-07): a long-running
# chump-fleet-server unit already existed, but it ran the binary straight out of
# the working tree's `target/release/` — i.e. it depended on a LOCAL cargo build
# existing, with nothing keeping that binary current with green-main. That is the
# recurring "merged but running a stale hand-build" disease. On a 2-core Oracle
# node a local rebuild is forbidden (it starves the live fleet), so the binary
# just went stale silently. This installer makes the organ pull-driven instead:
#
#   1. installs the prebuilt chump-fleet-server binary to a STABLE path
#      (~/.local/bin/chump-fleet-server) via the refresh script's artifact pull —
#      never a local build;
#   2. points the long-running unit at that stable path (so it no longer depends
#      on target/release), adapting to whatever unit shape the node already has:
#        - existing SYSTEM unit  -> rewrite its ExecStart in place (sudo);
#        - existing --user unit  -> rewrite its ExecStart in place;
#        - NO unit at all        -> install a --user unit (fresh-node path,
#          no sudo needed, survives reboot via linger);
#      it never spins up a rival organ next to an existing one;
#   3. installs a --user refresh timer that re-pulls on a cadence and restarts
#      the unit on change — mirroring the node-refresh-chump / node-refresh timer
#      pair (RESILIENT-200/INFRA-3677) that already self-sustains the worker bin.
#
# Linux/owned-iron counterpart of the macOS-only, cargo-building
# scripts/setup/install-fleet-server.sh.
#
# Usage:
#   scripts/setup/install-fleet-server-node.sh              # install + start
#   scripts/setup/install-fleet-server-node.sh --uninstall  # remove the refresh
#                                                             # timer + any --user
#                                                             # unit THIS script made
#
# Env:
#   CHUMP_NODE_REPO            repo checkout the server reads (.chump/, .chump-locks/)
#   CHUMP_FLEET_SERVER_BIN     stable install path (default ~/.local/bin/chump-fleet-server)
#   CHUMP_FLEET_SERVER_UNIT    long-running unit name (default chump-fleet-server.service)
#   CHUMP_FLEET_SERVER_PORT    bind port (default 7070)
#   CHUMP_FLEET_SERVER_BIND    bind address (default 127.0.0.1). Read endpoints
#                              are unauthenticated, so tailnet exposure is an
#                              explicit operator choice: set this to the node's
#                              Tailscale IPv4 address after verifying the host.
#   CHUMP_PROVIDERS_ENV        creds sourced by the service (default ~/.chump/providers.env)
#   CADENCE_MIN                refresh cadence in minutes (default 30)

set -euo pipefail

# RESILIENT-1055: $USER isn't exported under a `sudo -E env …` bring-up, so under
# `set -u` the linger step (`loginctl enable-linger "$USER"`) aborted this whole
# installer with "USER: unbound variable" — leaving the /healthz organ
# half-installed. Resolve it from the effective login name as a fallback (same
# fix as install-node-refresh-systemd.sh).
USER="${USER:-$(id -un 2>/dev/null || echo root)}"

UNIT_DIR="$HOME/.config/systemd/user"
CADENCE_MIN="${CADENCE_MIN:-30}"
FLEET_UNIT="${CHUMP_FLEET_SERVER_UNIT:-chump-fleet-server.service}"
REFRESH_UNIT="chump-fleet-server-refresh"

# --- locate the refresh script (source of truth) -----------------------------
REFRESH_SRC=""
for c in \
    "${CHUMP_NODE_REPO:-}/scripts/ops/node-refresh-fleet-server.sh" \
    "$HOME/chump-host/scripts/ops/node-refresh-fleet-server.sh" \
    "$HOME/Projects/Chump/scripts/ops/node-refresh-fleet-server.sh" \
    "$HOME/chump/scripts/ops/node-refresh-fleet-server.sh" \
    "$(dirname "$0")/../ops/node-refresh-fleet-server.sh"; do
    [[ -n "$c" && -f "$c" ]] && { REFRESH_SRC="$(cd "$(dirname "$c")" && pwd)/$(basename "$c")"; break; }
done

# --- resolve the repo checkout the server reads ------------------------------
REPO_ROOT="${CHUMP_NODE_REPO:-}"
if [[ -z "$REPO_ROOT" ]]; then
    for c in "$HOME/chump-host" "$HOME/Projects/Chump" "$HOME/chump"; do
        git -C "$c" rev-parse --is-inside-work-tree >/dev/null 2>&1 && { REPO_ROOT="$c"; break; }
    done
fi

DEFAULT_TARGET_BIN="${CHUMP_NODE_DIR:+$CHUMP_NODE_DIR/bin/chump-fleet-server}"
DEFAULT_TARGET_BIN="${DEFAULT_TARGET_BIN:-$HOME/.local/bin/chump-fleet-server}"
TARGET_BIN="${CHUMP_FLEET_SERVER_BIN:-$DEFAULT_TARGET_BIN}"
PORT="${CHUMP_FLEET_SERVER_PORT:-7070}"
BIND="${CHUMP_FLEET_SERVER_BIND:-127.0.0.1}"
PROVIDERS_ENV="${CHUMP_PROVIDERS_ENV:-$HOME/.chump/providers.env}"

SYS_UNIT_PATH="/etc/systemd/system/$FLEET_UNIT"
USER_UNIT_PATH="$UNIT_DIR/$FLEET_UNIT"

_have_sudo() { sudo -n true >/dev/null 2>&1; }
_system_unit_loaded() { sudo -n systemctl cat "$FLEET_UNIT" >/dev/null 2>&1 || systemctl cat "$FLEET_UNIT" >/dev/null 2>&1; }
_user_unit_loaded()   { systemctl --user cat "$FLEET_UNIT" >/dev/null 2>&1; }

# --- uninstall ---------------------------------------------------------------
if [[ "${1:-}" == "--uninstall" ]]; then
    echo "[install-fleet-server-node] removing refresh timer …"
    systemctl --user disable --now "$REFRESH_UNIT.timer" 2>/dev/null || true
    rm -f "$UNIT_DIR/$REFRESH_UNIT.service" "$UNIT_DIR/$REFRESH_UNIT.timer"
    # Only remove a long-running unit if THIS script created it as a --user unit.
    if [[ -f "$USER_UNIT_PATH" ]] && grep -q "install-fleet-server-node" "$USER_UNIT_PATH" 2>/dev/null; then
        echo "[install-fleet-server-node] removing --user $FLEET_UNIT (created by this script) …"
        systemctl --user disable --now "$FLEET_UNIT" 2>/dev/null || true
        rm -f "$USER_UNIT_PATH"
    fi
    systemctl --user daemon-reload
    echo "[install-fleet-server-node] uninstalled (an existing SYSTEM unit is left untouched)."
    exit 0
fi

[[ -n "$REPO_ROOT" ]] && git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || { echo "FATAL: no chump checkout found (set CHUMP_NODE_REPO)" >&2; exit 1; }
[[ -n "$REFRESH_SRC" ]] || { echo "FATAL: cannot locate node-refresh-fleet-server.sh (set CHUMP_NODE_REPO)" >&2; exit 1; }
chmod +x "$REFRESH_SRC" 2>/dev/null || true

echo "[install-fleet-server-node] repo:      $REPO_ROOT"
echo "[install-fleet-server-node] binary:    $TARGET_BIN"
echo "[install-fleet-server-node] unit:      $FLEET_UNIT"
echo "[install-fleet-server-node] refresh:   $REFRESH_SRC"
echo "[install-fleet-server-node] bind:      $BIND:$PORT"

mkdir -p "$UNIT_DIR"

# --- 1. ensure the long-running unit runs the STABLE installed binary --------
_point_execstart_to_stable_bin() {
    # $1 = unit path, $2 = "sudo" to edit as root else ""
    local path="$1" pfx="${2:-}"
    # Replace the exec'd .../chump-fleet-server path (target/release or other)
    # with the stable installed path, leaving the `set -a; source …; exec` shell
    # wrapper intact. Both our unit shapes exec the binary, so one rule covers
    # them. Idempotent: a no-op once it already points at $TARGET_BIN.
    ${pfx} sed -i -E "s#(exec )\"?[^\" ]*/chump-fleet-server\"?#\1\"$TARGET_BIN\"#g" "$path"
}

UNIT_MODE=""
if _system_unit_loaded; then
    UNIT_MODE="system"
    echo "[install-fleet-server-node] found existing SYSTEM unit $FLEET_UNIT — pointing it at $TARGET_BIN"
    if [[ -f "$SYS_UNIT_PATH" ]]; then
        _have_sudo || { echo "FATAL: existing system unit but no passwordless sudo to repoint it" >&2; exit 1; }
        _point_execstart_to_stable_bin "$SYS_UNIT_PATH" "sudo -n"
        sudo -n systemctl daemon-reload
    else
        echo "WARN: system unit is loaded but $SYS_UNIT_PATH not found (drop-in?); leaving ExecStart as-is" >&2
    fi
elif _user_unit_loaded; then
    UNIT_MODE="user-existing"
    echo "[install-fleet-server-node] found existing --user unit $FLEET_UNIT — pointing it at $TARGET_BIN"
    _point_execstart_to_stable_bin "$USER_UNIT_PATH" ""
    systemctl --user daemon-reload
else
    UNIT_MODE="user-new"
    echo "[install-fleet-server-node] no existing $FLEET_UNIT — installing a --user long-running unit"
    {
        echo "# installed by scripts/setup/install-fleet-server-node.sh — RESILIENT-1046"
        echo "[Unit]"
        echo "Description=Chump fleet-server — audit/dashboard API + bat-phone intake (RESILIENT-1046)"
        echo "After=network-online.target"
        echo "Wants=network-online.target"
        echo ""
        echo "[Service]"
        echo "Type=simple"
        echo "WorkingDirectory=$REPO_ROOT"
        echo "Environment=CHUMP_REPO_ROOT=$REPO_ROOT"
        echo "Environment=CHUMP_FLEET_SERVER_PORT=$PORT"
        echo "Environment=CHUMP_FLEET_SERVER_BIND=$BIND"
        echo "Environment=RUST_LOG=info"
        echo "ExecStart=/bin/bash -c 'set -a; source \"$PROVIDERS_ENV\" 2>/dev/null; set +a; exec \"$TARGET_BIN\"'"
        echo "Restart=always"
        echo "RestartSec=10"
        echo "Nice=5"
        echo ""
        echo "[Install]"
        echo "WantedBy=default.target"
    } > "$USER_UNIT_PATH"
    systemctl --user daemon-reload
    systemctl --user enable "$FLEET_UNIT" >/dev/null 2>&1 || true
fi

# --- 2. refresh oneshot + timer (pull-driven currency) -----------------------
{
    echo "[Unit]"
    echo "Description=Chump fleet-server binary refresh (pull prebuilt, install, restart) — RESILIENT-1046"
    echo "After=network-online.target"
    echo ""
    echo "[Service]"
    echo "Type=oneshot"
    # Pull is seconds; bootstrap copy is instant; never a cargo build. Ceiling
    # bounds a wedged gh/network call.
    echo "TimeoutStartSec=600"
    echo "Environment=CHUMP_NODE_REPO=$REPO_ROOT"
    echo "Environment=CHUMP_FLEET_SERVER_BIN=$TARGET_BIN"
    echo "Environment=CHUMP_FLEET_SERVER_UNIT=$FLEET_UNIT"
    [[ -n "${GH_TOKEN:-}" ]] && echo "Environment=GH_TOKEN=${GH_TOKEN}"
    echo "ExecStart=/usr/bin/env bash $REFRESH_SRC"
    echo "Nice=10"
} > "$UNIT_DIR/$REFRESH_UNIT.service"
{
    echo "[Unit]"
    echo "Description=Chump fleet-server refresh timer (every ${CADENCE_MIN}m) — RESILIENT-1046"
    echo ""
    echo "[Timer]"
    echo "OnBootSec=5min"
    echo "OnUnitActiveSec=${CADENCE_MIN}min"
    echo "Persistent=true"
    echo ""
    echo "[Install]"
    echo "WantedBy=timers.target"
} > "$UNIT_DIR/$REFRESH_UNIT.timer"
echo "wrote refresh units: $UNIT_DIR/$REFRESH_UNIT.{service,timer} (unit mode: $UNIT_MODE)"

# --- linger (headless nodes need --user units to run without a login) --------
if command -v loginctl >/dev/null 2>&1; then
    loginctl enable-linger "$USER" 2>/dev/null \
        && echo "linger enabled for $USER" \
        || echo "WARN: could not enable linger — run once: sudo loginctl enable-linger $USER" >&2
fi

systemctl --user daemon-reload

# --- 3. first refresh: install the binary (pull or bootstrap), restart unit ---
echo "[install-fleet-server-node] running first refresh (pull prebuilt or bootstrap) …"
CHUMP_NODE_REPO="$REPO_ROOT" CHUMP_FLEET_SERVER_BIN="$TARGET_BIN" CHUMP_FLEET_SERVER_UNIT="$FLEET_UNIT" \
    bash "$REFRESH_SRC" || {
        # A known executable may have been staged by the node installer or a
        # prior successful artifact pull. It is still a real, verifiable
        # control-plane binary even if today's network refresh is unavailable;
        # only an absent binary makes this install incomplete.
        if [[ -x "$TARGET_BIN" ]]; then
            echo "WARN: first fleet-server refresh failed; retaining the existing verified binary at $TARGET_BIN" >&2
        else
            echo "FATAL: first fleet-server refresh failed and no executable cockpit binary exists" >&2
            exit 1
        fi
    }

# --- 4. ensure the server is actually up (refresh only bounces on a CHANGE) ---
if [[ ! -x "$TARGET_BIN" ]]; then
    echo "FATAL: $TARGET_BIN not present after refresh — cockpit is not installed" >&2
    exit 1
fi
case "$UNIT_MODE" in
    system)
        sudo -n systemctl restart "$FLEET_UNIT" 2>/dev/null \
            || sudo -n systemctl start "$FLEET_UNIT" 2>/dev/null \
            || { echo "FATAL: could not start system unit $FLEET_UNIT" >&2; exit 1; }
        sudo -n systemctl is-active --quiet "$FLEET_UNIT" \
            || { echo "FATAL: system unit $FLEET_UNIT is not active" >&2; exit 1; }
        ;;
    *)
        systemctl --user restart "$FLEET_UNIT" 2>/dev/null \
            || systemctl --user start "$FLEET_UNIT" 2>/dev/null \
            || { echo "FATAL: could not start --user unit $FLEET_UNIT" >&2; exit 1; }
        systemctl --user is-active --quiet "$FLEET_UNIT" \
            || { echo "FATAL: --user unit $FLEET_UNIT is not active" >&2; exit 1; }
        ;;
esac
systemctl --user enable --now "$REFRESH_UNIT.timer" \
    || { echo "FATAL: could not enable refresh timer $REFRESH_UNIT.timer" >&2; exit 1; }

echo ""
echo "=== status ==="
if [[ "$UNIT_MODE" == "system" ]]; then sudo -n systemctl is-active "$FLEET_UNIT" 2>/dev/null || true
else systemctl --user is-active "$FLEET_UNIT" 2>/dev/null || true; fi
systemctl --user list-timers "$REFRESH_UNIT.timer" --no-pager 2>/dev/null | head -3 || true
echo ""
echo "Verify:  curl -s http://$BIND:$PORT/healthz && echo"
echo "Audit:   curl -s http://$BIND:$PORT/api/dashboard-summary"
echo "Refresh: systemctl --user start $REFRESH_UNIT.service"
