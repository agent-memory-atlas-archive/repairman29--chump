#!/usr/bin/env bash
# scripts/setup/install-node-refresh-systemd.sh — RESILIENT-200
#
# Install a systemd --user timer on a Linux fleet node that keeps the node's
# `chump` binary current with origin/main by running node-refresh-chump.sh on a
# cadence. This is the Linux equivalent of the macOS
# install-refresh-runner-binary-launchd.sh.
#
# PAUSE SAFETY: the timer runs binary-refresh ONLY. It does NOT enable, start,
# or reference any fleet-work unit (chumpd, mission loop, worker). A paused node
# (~/.chump/AUTONOMY_LEVEL=0) self-currents its binary and stays off.
#
# Cadence: 30 min (OnUnitActiveSec), first run 5 min after boot (OnBootSec).
#
# Linger: headless nodes need `loginctl enable-linger` so --user units run
# without an active login session. We attempt it and warn (not fail) if it needs
# privileges — an operator can run `sudo loginctl enable-linger $USER` once.
#
# Idempotent: re-running rewrites the units and re-enables the timer.
#
# RESILIENT-1685: the ExecStart is resolved to a STABLE checkout only (see
# _resolve_stable_script) — never a reaped-prone .claude/worktrees/ or /tmp
# path. Re-running this installer to re-render chump-node-refresh.service onto a
# live node (replacing a unit that was mis-installed from a worktree) is the
# operator-approved un-pause step (AC4); the installer does not apply itself to
# a running node on its own.
#
# Env:
#   CHUMP_NODE_REPO   passed through to the service (mirror to build from)
#   CHUMP_NODE_BIN    passed through to the service (install destination)
#   CADENCE_MIN       refresh cadence in minutes (default 30)

set -euo pipefail

# RESILIENT-1055: $USER is not exported in every invocation context (notably a
# `sudo -E env …` bring-up, where the environment carries HOME but not USER), so
# under `set -u` the linger step below (`loginctl enable-linger "$USER"`) aborted
# the whole installer with "USER: unbound variable" — leaving the refresh timer
# half-installed. Resolve it from the effective login name as a fallback.
USER="${USER:-$(id -un 2>/dev/null || echo root)}"

CADENCE_MIN="${CADENCE_MIN:-30}"
UNIT_DIR="$HOME/.config/systemd/user"

# --- canonical node checkout (INFRA-8597, PHASE-R R5) ------------------------
# The script paths baked into ExecStart MUST live in the node's canonical,
# durable checkout — never in a disposable `.claude/worktrees/*` linked worktree.
# When this installer was invoked from inside a claimed worktree, the old
# `$(dirname "$0")/..` candidate baked that worktree's path into
# chump-node-refresh.service; the worktree was later reaped, leaving
# ExecStart=.../.claude/worktrees/infra-8571/scripts/ops/node-refresh-chump.sh
# → exit 127 every cycle (cuphead, since ~2026-10-17). Resolve the canonical
# checkout explicitly: CHUMP_NODE_REPO, else the MAIN worktree of this git repo
# (git-common-dir's parent — a linked worktree's common dir points at the main
# repo's .git), else the well-known node checkouts. Anything under
# `.claude/worktrees/` is rejected so a doomed path can never be rendered.
is_worktree_path() { case "$1" in */.claude/worktrees/*) return 0;; *) return 1;; esac; }

resolve_canonical_checkout() {
    local cand
    # 1. explicit operator/unit override. A linked worktree's `.git` is a FILE,
    #    not a dir, so accept either. Worktree rejection is DELEGATED to
    #    assert_canonical_path below (where it is load-bearing + testable, so the
    #    INFRA-8597 M6 mutant dies): candidate 1 returns the CHUMP_NODE_REPO path
    #    verbatim and the assert FATALs on a `.claude/worktrees/` path — never a
    #    silent fall-through to candidate 2/3.
    if [[ -n "${CHUMP_NODE_REPO:-}" ]] && { [[ -d "${CHUMP_NODE_REPO}/.git" ]] || [[ -f "${CHUMP_NODE_REPO}/.git" ]]; }; then
        cand="$(cd "$CHUMP_NODE_REPO" && pwd)"
        printf '%s\n' "$cand"; return 0
    fi
    # 2. the MAIN worktree of whatever repo this installer runs from. From a
    #    linked worktree, git-common-dir resolves to <main>/.git, whose parent
    #    is the canonical checkout — so we hop out of the worktree automatically.
    local gcd here; here="$(cd "$(dirname "$0")" && pwd)"
    if gcd="$(git -C "$here" rev-parse --git-common-dir 2>/dev/null)"; then
        [[ "$gcd" != /* ]] && gcd="$here/$gcd"
        cand="$(cd "$(dirname "$gcd")" 2>/dev/null && pwd || true)"
        if [[ -n "$cand" ]] && ! is_worktree_path "$cand" && [[ -f "$cand/scripts/ops/node-refresh-chump.sh" ]]; then
            printf '%s\n' "$cand"; return 0
        fi
    fi
    # 3. well-known node checkouts (canonical, never a worktree).
    for cand in "$HOME/chump" "$HOME/chump-host" "$HOME/Projects/Chump"; do
        if [[ -f "$cand/scripts/ops/node-refresh-chump.sh" ]] && ! is_worktree_path "$cand"; then
            printf '%s\n' "$cand"; return 0
        fi
    done
    return 1
}

# Assert a resolved ExecStart path is durable before it is baked into a unit.
assert_canonical_path() {
    local p="$1" label="$2"
    if is_worktree_path "$p"; then
        echo "FATAL: refusing to render $label from a disposable worktree path: $p (INFRA-8597)" >&2
        exit 1
    fi
    if [[ ! -f "$p" ]]; then
        echo "FATAL: $label resolves to a non-existent path: $p (INFRA-8597)" >&2
        exit 1
    fi
}

# INFRA-8597 (blocking #1): a SET CHUMP_NODE_REPO must resolve to a durable
# checkout — NEVER a silent fall-through that then writes the caller's raw value
# into `Environment=`. A missing / no-.git value is FATAL here at top level (not
# inside the `$(resolve_canonical_checkout)` command substitution, whose `exit`
# only kills the subshell). A `.claude/worktrees/` value is rejected (also FATAL
# exit 1) by assert_canonical_path below, where the worktree guard is
# load-bearing and testable.
if [[ -n "${CHUMP_NODE_REPO:-}" ]]; then
    if [[ ! -d "${CHUMP_NODE_REPO}/.git" && ! -f "${CHUMP_NODE_REPO}/.git" ]]; then
        echo "FATAL: CHUMP_NODE_REPO=${CHUMP_NODE_REPO} is not a git checkout (missing or no .git); refusing (INFRA-8597)" >&2
        exit 1
    fi
fi

CANON_REPO="$(resolve_canonical_checkout || true)"
if [[ -z "$CANON_REPO" ]]; then
    echo "FATAL: cannot locate the canonical node checkout (set CHUMP_NODE_REPO)" >&2
    exit 1
fi
echo "canonical checkout: $CANON_REPO"

SCRIPT_SRC="$CANON_REPO/scripts/ops/node-refresh-chump.sh"
assert_canonical_path "$SCRIPT_SRC" "chump-node-refresh.service ExecStart"
chmod +x "$SCRIPT_SRC" 2>/dev/null || true
echo "refresh script: $SCRIPT_SRC"

# --- resolve the install destination (RESILIENT-378) -------------------------
# Bake CHUMP_NODE_BIN into the unit so the refresh installs where the FLEET's
# PATH actually resolves `chump`, not a fixed ~/.local/bin the PATH shadows
# (the RESILIENT-200 install-path bug that rotted closetjunky's fleet binary).
# Same precedence as node-refresh-chump.sh: explicit override → on-PATH chump
# (not the repo's own target build) → ~/.cargo/bin/chump → ~/.local/bin/chump.
if [[ -z "${CHUMP_NODE_BIN:-}" ]]; then
    _onpath="$(command -v chump 2>/dev/null || true)"
    if [[ -n "$_onpath" && "$_onpath" != *"/target/release/chump" && "$_onpath" != *"/target/debug/chump" ]]; then
        CHUMP_NODE_BIN="$_onpath"
    elif [[ -x "$HOME/.cargo/bin/chump" ]]; then
        CHUMP_NODE_BIN="$HOME/.cargo/bin/chump"
    else
        CHUMP_NODE_BIN="$HOME/.local/bin/chump"
    fi
fi
echo "install target: $CHUMP_NODE_BIN"

mkdir -p "$UNIT_DIR"

# --- service (oneshot) -------------------------------------------------------
{
    echo "[Unit]"
    echo "Description=chump node binary refresh (keep installed chump current with origin/main) — RESILIENT-200"
    echo "After=network-online.target"
    echo ""
    echo "[Service]"
    echo "Type=oneshot"
    # RESILIENT-523: without an explicit TimeoutStartSec, systemd falls back to
    # DefaultTimeoutStartSec (90s system-wide default) — far shorter than even
    # the 30min limit that proved fatal to the macOS auto-deploy path on a cold
    # cargo build of the 190k+ LOC chump binary. node-refresh-chump.sh tries the
    # INFRA-3677 prebuilt-artifact pull first (seconds), but the local-build
    # fallback still needs headroom for a genuinely cold build. 2700s (45min)
    # sits comfortably above worst-case cold-build time while still bounding
    # a truly wedged run (network hang, deadlocked cargo) instead of running
    # forever.
    echo "TimeoutStartSec=2700"
    # INFRA-8597 (blocking #1): write the RESOLVED canonical repo (CANON_REPO),
    # never the caller's raw CHUMP_NODE_REPO. A worktree/stale value here is the
    # exact failure install-helsinki-atc.sh recorded on 2026-08-11.
    echo "Environment=CHUMP_NODE_REPO=${CANON_REPO}"
    [[ -n "${CHUMP_NODE_BIN:-}" ]]  && echo "Environment=CHUMP_NODE_BIN=${CHUMP_NODE_BIN}"
    # INFRA-8597 (blocking #3, RESILIENT-1649 renderer half): do NOT bake any
    # secret into the unit. node-refresh-chump.sh reads GH_TOKEN from
    # ~/.chump/providers.env at runtime, so the timer's `gh` calls stay
    # authenticated without a plaintext GH_TOKEN= line in a world-readable unit.
    echo "ExecStart=/usr/bin/env bash ${SCRIPT_SRC}"
    echo "Nice=10"
} > "$UNIT_DIR/chump-node-refresh.service"

# --- timer -------------------------------------------------------------------
{
    echo "[Unit]"
    echo "Description=chump node binary refresh timer (every ${CADENCE_MIN}m) — RESILIENT-200"
    echo ""
    echo "[Timer]"
    echo "OnBootSec=5min"
    echo "OnUnitActiveSec=${CADENCE_MIN}min"
    echo "Persistent=true"
    echo ""
    echo "[Install]"
    echo "WantedBy=timers.target"
} > "$UNIT_DIR/chump-node-refresh.timer"

# --- RESILIENT-523: node-deploy-lag-watchdog (loud signal on stall/timeout) --
# Linux/systemd counterpart of merge-deploy-lag-watchdog.sh (macOS-only). Runs
# every 5 min — much tighter than the refresh cadence — so a stalled or
# timed-out refresh surfaces fast instead of silently leaving the node on a
# stale binary (AC #2).
WATCHDOG_SRC=""
if [[ -f "$CANON_REPO/scripts/coord/node-deploy-lag-watchdog.sh" ]]; then
    WATCHDOG_SRC="$CANON_REPO/scripts/coord/node-deploy-lag-watchdog.sh"
fi

if [[ -n "$WATCHDOG_SRC" ]]; then
    assert_canonical_path "$WATCHDOG_SRC" "chump-node-deploy-lag-watchdog.service ExecStart"
    chmod +x "$WATCHDOG_SRC" 2>/dev/null || true
    echo "watchdog script: $WATCHDOG_SRC"
    {
        echo "[Unit]"
        echo "Description=chump node deploy-lag watchdog (loud signal on stalled/timed-out refresh) — RESILIENT-523"
        echo "After=network-online.target"
        echo ""
        echo "[Service]"
        echo "Type=oneshot"
        # INFRA-8597 (blocking #1): resolved canonical repo, never the caller's raw value.
        echo "Environment=CHUMP_REPO_ROOT=${CANON_REPO}"
        [[ -n "${CHUMP_NODE_BIN:-}" ]]  && echo "Environment=CHUMP_NODE_BIN=${CHUMP_NODE_BIN}"
        echo "ExecStart=/usr/bin/env bash ${WATCHDOG_SRC}"
        echo "Nice=10"
    } > "$UNIT_DIR/chump-node-deploy-lag-watchdog.service"
    {
        echo "[Unit]"
        echo "Description=chump node deploy-lag watchdog timer (every 5m) — RESILIENT-523"
        echo ""
        echo "[Timer]"
        echo "OnBootSec=5min"
        echo "OnUnitActiveSec=5min"
        echo "Persistent=true"
        echo ""
        echo "[Install]"
        echo "WantedBy=timers.target"
    } > "$UNIT_DIR/chump-node-deploy-lag-watchdog.timer"
else
    echo "WARN: node-deploy-lag-watchdog.sh not found — skipping watchdog install" >&2
fi

# --- RESILIENT-1080: node-script-host-refresh (keep the worker's SCRIPT checkout
# current) ---------------------------------------------------------------------
# The binary-refresh timer above keeps the installed `chump` BINARY current, but
# a worker runs its shell/script organs (worker.sh, the gap pickers, dispatch/*)
# from a SCRIPT-HOST checkout — canonically ~/chump — that never advanced on its
# own. Merged shell/script fixes (e.g. the #4529 picker dedup) therefore stalled
# on the node, leaving the worker re-picking already-done gaps (mugman,
# 2026-09-08). This timer fast-forwards that checkout to origin/main on a cadence
# WITHOUT the destructive `reset --hard` node-main-sync.sh uses — preserving
# node-local tracked customizations (the muscle-node organ-manifest.txt stopgap)
# and untracked hand-deployed files, and refusing to touch a diverged checkout.
SCRIPTHOST_SRC=""
if [[ -f "$CANON_REPO/scripts/ops/node-script-host-refresh.sh" ]]; then
    SCRIPTHOST_SRC="$CANON_REPO/scripts/ops/node-script-host-refresh.sh"
fi

# Resolve the SCRIPT-HOST checkout the worker actually runs from (NOT the binary
# mirror). Precedence: explicit override → first of the canonical worker
# checkouts that is a git repo → ~/chump.
if [[ -z "${CHUMP_SCRIPT_HOST_REPO:-}" ]]; then
    for _shc in "$HOME/chump" "$HOME/Projects/Chump" "$HOME/chump-host"; do
        if [[ -e "$_shc/.git" ]]; then CHUMP_SCRIPT_HOST_REPO="$_shc"; break; fi
    done
    CHUMP_SCRIPT_HOST_REPO="${CHUMP_SCRIPT_HOST_REPO:-$HOME/chump}"
fi

if [[ -n "$SCRIPTHOST_SRC" ]]; then
    assert_canonical_path "$SCRIPTHOST_SRC" "chump-script-host-refresh.service ExecStart"
    chmod +x "$SCRIPTHOST_SRC" 2>/dev/null || true
    echo "script-host refresh script: $SCRIPTHOST_SRC"
    echo "script-host checkout:       $CHUMP_SCRIPT_HOST_REPO"
    {
        echo "[Unit]"
        echo "Description=chump node script-host refresh (keep the worker's ~/chump script checkout current with origin/main, worktree-safe) — RESILIENT-1080"
        echo "After=network-online.target"
        echo ""
        echo "[Service]"
        echo "Type=oneshot"
        # Fast-forward + a possible stash cycle only — seconds, not a build. Keep
        # a generous bound so a slow fetch on a 2-core node never wedges forever.
        echo "TimeoutStartSec=300"
        echo "Environment=CHUMP_SCRIPT_HOST_REPO=${CHUMP_SCRIPT_HOST_REPO}"
        # INFRA-8597 (blocking #3): no secret baked into the unit. Unlike the
        # binary-refresh service, node-script-host-refresh.sh does NOT read
        # GH_TOKEN / ~/.chump/providers.env — it runs a plain `git fetch origin
        # main`, which authenticates via the ~/chump checkout's own `origin`
        # remote credentials (an SSH key, or the git credential helper / a token
        # embedded in the remote URL), not an env token baked into the unit.
        echo "ExecStart=/usr/bin/env bash ${SCRIPTHOST_SRC}"
        echo "Nice=10"
    } > "$UNIT_DIR/chump-script-host-refresh.service"
    {
        echo "[Unit]"
        echo "Description=chump node script-host refresh timer (every ${CADENCE_MIN}m) — RESILIENT-1080"
        echo ""
        echo "[Timer]"
        # Offset the first run so it doesn't collide with the binary refresh.
        echo "OnBootSec=7min"
        echo "OnUnitActiveSec=${CADENCE_MIN}min"
        echo "Persistent=true"
        echo ""
        echo "[Install]"
        echo "WantedBy=timers.target"
    } > "$UNIT_DIR/chump-script-host-refresh.timer"
else
    echo "WARN: node-script-host-refresh.sh not found — skipping script-host refresh install" >&2
fi

echo "wrote:"
echo "  $UNIT_DIR/chump-node-refresh.service"
echo "  $UNIT_DIR/chump-node-refresh.timer"
[[ -n "$WATCHDOG_SRC" ]] && echo "  $UNIT_DIR/chump-node-deploy-lag-watchdog.service" && echo "  $UNIT_DIR/chump-node-deploy-lag-watchdog.timer"
[[ -n "$SCRIPTHOST_SRC" ]] && echo "  $UNIT_DIR/chump-script-host-refresh.service" && echo "  $UNIT_DIR/chump-script-host-refresh.timer"

# --- linger (best-effort) ----------------------------------------------------
if command -v loginctl >/dev/null 2>&1; then
    if loginctl enable-linger "$USER" 2>/dev/null; then
        echo "linger enabled for $USER (timer runs without an active session)"
    else
        echo "WARN: could not enable linger — run once as operator: sudo loginctl enable-linger $USER" >&2
    fi
fi

# --- enable + start ----------------------------------------------------------
systemctl --user daemon-reload
systemctl --user enable --now chump-node-refresh.timer
[[ -n "$WATCHDOG_SRC" ]] && systemctl --user enable --now chump-node-deploy-lag-watchdog.timer
[[ -n "$SCRIPTHOST_SRC" ]] && systemctl --user enable --now chump-script-host-refresh.timer
echo ""
echo "=== timer status ==="
systemctl --user list-timers chump-node-refresh.timer --no-pager 2>/dev/null || true
[[ -n "$WATCHDOG_SRC" ]] && systemctl --user list-timers chump-node-deploy-lag-watchdog.timer --no-pager 2>/dev/null || true
[[ -n "$SCRIPTHOST_SRC" ]] && systemctl --user list-timers chump-script-host-refresh.timer --no-pager 2>/dev/null || true
echo ""
echo "Manual run:   systemctl --user start chump-node-refresh.service"
echo "Logs:         journalctl --user -u chump-node-refresh.service -n 50 --no-pager"
echo "Watchdog run: systemctl --user start chump-node-deploy-lag-watchdog.service"
echo "Watchdog log: journalctl --user -u chump-node-deploy-lag-watchdog.service -n 50 --no-pager"
echo "Disable:      systemctl --user disable --now chump-node-refresh.timer"
