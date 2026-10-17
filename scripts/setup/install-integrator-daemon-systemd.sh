#!/usr/bin/env bash
# install-integrator-daemon-systemd.sh — RESILIENT-318 / INFRA-2130 SCALE-A
#
# Linux/systemd installer for the chump-integrator-daemon (the Batched Merge
# Train). This is the port of the macOS-launchd install-integrator-daemon.sh to
# a fresh Linux ChumpOS node — same organ, same DRY-RUN-by-default safety, but
# as a root-owned systemd service + timer instead of a launchd user agent.
#
# It installs the repo-tracked units from scripts/dispatch/:
#   chump-integrator.service  (oneshot: one --once cycle, DRY-RUN)
#   chump-integrator.timer    (every 15 min, matching the launchd StartInterval)
#
# The Batched Merge Train batches up to CHUMP_INTEGRATOR_BATCH_MAX ready_to_ship
# gaps through a preflight gate into ONE integration branch so CI runs once per
# batch instead of once per gap (docs/process/SCALING.md).
#
# DEFAULT INSTALL IS DRY-RUN (CHUMP_INTEGRATOR_LIVE=0 baked into the tracked
# unit). To enable LIVE mode the operator runs `--live`, which drops in an
# override setting CHUMP_INTEGRATOR_LIVE=1. Flip LIVE ONLY after trunk is
# confirmed GREEN and the fleet is unpaused — see docs/process/SCALING.md.
#
# Usage:
#   sudo bash install-integrator-daemon-systemd.sh            — install (dry-run), enable+start timer
#   sudo bash install-integrator-daemon-systemd.sh --live     — flip to LIVE (drop-in CHUMP_INTEGRATOR_LIVE=1)
#   sudo bash install-integrator-daemon-systemd.sh --dry-run  — remove the LIVE drop-in (back to dry-run)
#   sudo bash install-integrator-daemon-systemd.sh --uninstall — stop + remove units
#   bash install-integrator-daemon-systemd.sh --status        — print timer + mode
#   bash install-integrator-daemon-systemd.sh --check         — exit 0 iff timer active

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$REPO_ROOT/.." && pwd)"

SERVICE_UNIT="chump-integrator.service"
TIMER_UNIT="chump-integrator.timer"
UNIT_DIR="/etc/systemd/system"
DROPIN_DIR="${UNIT_DIR}/${SERVICE_UNIT}.d"
LIVE_DROPIN="${DROPIN_DIR}/live.conf"
# INFRA-8194 (R5 slice 2): the tracked units are placeholder templates
# (__HOME__ / __REPO_ROOT__, no User=); render them for this host through the
# shared shell mirror (organ_unit_host_rewrite, the same placer
# install-helsinki-atc.sh uses) instead of copying them verbatim, which would
# install a unit full of unresolved placeholders. The run identity is the
# checkout's owner (or CHUMP_RUN_USER), so paths follow that user's home, not a
# baked root home.
# shellcheck source=../ops/lib/organ-unit-install-lib.sh
source "$REPO_ROOT/scripts/ops/lib/organ-unit-install-lib.sh"
RUN_USER="${CHUMP_RUN_USER:-$(stat -c %U "$REPO_ROOT" 2>/dev/null || id -un)}"
RUN_HOME="$(getent passwd "$RUN_USER" 2>/dev/null | cut -d: -f6 || true)"
[[ -z "$RUN_HOME" ]] && RUN_HOME="$HOME"
CARGO_BIN="${CARGO_BIN:-${RUN_HOME%/}/.cargo/bin}"
LOG_DIR="${RUN_HOME%/}/.chump/logs"

_need_root() {
    if [[ "$(id -u)" != "0" ]]; then
        echo "ERROR: system units require root (sudo bash $0 $*)" >&2
        exit 1
    fi
}

# ── resolve/install the chump-integrator binary ───────────────────────────────
_ensure_binary() {
    if [[ -x "${CARGO_BIN}/chump-integrator" ]]; then
        echo "[install-integrator-systemd] binary present: ${CARGO_BIN}/chump-integrator"
        return 0
    fi
    for candidate in \
        "$REPO_ROOT/target/release/chump-integrator" \
        "$REPO_ROOT/target/debug/chump-integrator"; do
        if [[ -x "$candidate" ]]; then
            install -m 0755 "$candidate" "${CARGO_BIN}/chump-integrator"
            echo "[install-integrator-systemd] installed binary from $candidate -> ${CARGO_BIN}/chump-integrator"
            return 0
        fi
    done
    echo "[install-integrator-systemd] WARNING: chump-integrator binary not found." >&2
    echo "[install-integrator-systemd]   Build it: cargo build --release -p chump-integrator --bin chump-integrator" >&2
    echo "[install-integrator-systemd]   then re-run this installer (or copy target/release/chump-integrator to ${CARGO_BIN}/)." >&2
    return 1
}

cmd="install"
for arg in "$@"; do
    case "$arg" in
        --live)      cmd="live" ;;
        --dry-run)   cmd="dryrun" ;;
        --uninstall) cmd="uninstall" ;;
        --status)    cmd="status" ;;
        --check)     cmd="check" ;;
        install)     cmd="install" ;;
        *) echo "[install-integrator-systemd] unknown argument: $arg" >&2; exit 1 ;;
    esac
done

case "$cmd" in
    check)
        if systemctl is-active --quiet "$TIMER_UNIT" 2>/dev/null; then
            echo "ok: $TIMER_UNIT active"; exit 0
        fi
        echo "MISSING: $TIMER_UNIT not active"; exit 1
        ;;
    status)
        echo "== timer =="; systemctl status "$TIMER_UNIT" --no-pager 2>/dev/null || true
        echo "== mode =="
        if [[ -f "$LIVE_DROPIN" ]]; then echo "LIVE drop-in present: $LIVE_DROPIN"; else echo "DRY-RUN (no LIVE drop-in)"; fi
        systemctl show "$SERVICE_UNIT" -p Environment --no-pager 2>/dev/null | tr ' ' '\n' | grep CHUMP_INTEGRATOR_LIVE || true
        exit 0
        ;;
    uninstall)
        _need_root "$@"
        echo "[install-integrator-systemd] Uninstalling..."
        systemctl disable --now "$TIMER_UNIT" 2>/dev/null || true
        systemctl stop "$SERVICE_UNIT" 2>/dev/null || true
        rm -f "${UNIT_DIR}/${SERVICE_UNIT}" "${UNIT_DIR}/${TIMER_UNIT}"
        rm -f "$LIVE_DROPIN"; rmdir "$DROPIN_DIR" 2>/dev/null || true
        systemctl daemon-reload
        echo "[install-integrator-systemd] Done."
        exit 0
        ;;
    live)
        _need_root "$@"
        echo "[install-integrator-systemd] Enabling LIVE mode (CHUMP_INTEGRATOR_LIVE=1)."
        echo "[install-integrator-systemd] WARNING: the daemon will PUSH branches and OPEN PRs."
        echo "[install-integrator-systemd] Precondition (docs/process/SCALING.md): trunk must be GREEN, fleet unpaused."
        mkdir -p "$DROPIN_DIR"
        cat > "$LIVE_DROPIN" <<'EOF'
# LIVE-mode drop-in for the Batched Merge Train. Installed by
# install-integrator-daemon-systemd.sh --live. Remove with --dry-run.
# Precondition: trunk GREEN + fleet unpaused (docs/process/SCALING.md).
[Service]
Environment=CHUMP_INTEGRATOR_LIVE=1
EOF
        systemctl daemon-reload
        echo "[install-integrator-systemd] LIVE drop-in written: $LIVE_DROPIN"
        echo "[install-integrator-systemd] Revert to dry-run: sudo bash $0 --dry-run"
        exit 0
        ;;
    dryrun)
        _need_root "$@"
        rm -f "$LIVE_DROPIN"; rmdir "$DROPIN_DIR" 2>/dev/null || true
        systemctl daemon-reload
        echo "[install-integrator-systemd] LIVE drop-in removed — back to DRY-RUN."
        exit 0
        ;;
    install)
        _need_root "$@"
        ;;
esac

# ── install (dry-run, safe default) ───────────────────────────────────────────
for u in "$SERVICE_UNIT" "$TIMER_UNIT"; do
    src="$REPO_ROOT/scripts/dispatch/$u"
    if [[ ! -f "$src" ]]; then
        echo "ERROR: tracked unit not found: $src" >&2
        exit 1
    fi
    organ_unit_host_rewrite "$src" "${UNIT_DIR}/$u" "$RUN_USER" "$RUN_HOME" 0 "$REPO_ROOT" \
        || { echo "ERROR: could not render $src" >&2; exit 1; }
    echo "[install-integrator-systemd] rendered ${UNIT_DIR}/$u (run user $RUN_USER)"
done

mkdir -p "$LOG_DIR"
_ensure_binary || echo "[install-integrator-systemd] (units installed; timer will fail until the binary is built)"

systemctl daemon-reload
systemctl enable --now "$TIMER_UNIT"

echo ""
echo "[install-integrator-systemd] Mode: DRY-RUN (CHUMP_INTEGRATOR_LIVE=0, safe default)"
echo "[install-integrator-systemd] Cadence: every 15 minutes (chump-integrator.timer)"
echo "[install-integrator-systemd] Logs: ${LOG_DIR}/integrator-daemon.{out,err} (or journalctl -u ${SERVICE_UNIT})"
echo "[install-integrator-systemd] Run one cycle now: systemctl start ${SERVICE_UNIT}"
echo "[install-integrator-systemd] Status: bash $0 --status"
echo "[install-integrator-systemd] Flip LIVE later (trunk GREEN + fleet unpaused first): sudo bash $0 --live"
echo "[install-integrator-systemd] Done."
