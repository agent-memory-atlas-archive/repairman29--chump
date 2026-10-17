#!/usr/bin/env bash
# scripts/setup/install-curator-supervisor.sh — INFRA-2239
#
# Install (or uninstall) the com.chump.curator-supervisor launchd user agent.
# Modeled on install-fleet-server.sh (INFRA-2175).
#
# Usage:
#   bash scripts/setup/install-curator-supervisor.sh             # install
#   bash scripts/setup/install-curator-supervisor.sh --check     # exit 0 if loaded, 1 if not
#   bash scripts/setup/install-curator-supervisor.sh --uninstall # remove plist + unload

set -euo pipefail
# INFRA-8194 (R5 slice 2): __BREW_PREFIX__ in the plist template resolves
# through the host resolver (chump_brew_prefix, the shell mirror of
# chump_provision::brew_prefix) instead of a baked Apple Silicon path.
# shellcheck source=../lib/host-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/host-paths.sh"

LABEL="com.chump.curator-supervisor"
REPO_ROOT="${CHUMP_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo /Users/jeffadkins/Projects/Chump)}"
LOG_DIR="$HOME/Library/Logs/Chump"
PLIST_TEMPLATE="$REPO_ROOT/scripts/setup/launchd/${LABEL}.plist"
PLIST_DEST="$HOME/Library/LaunchAgents/${LABEL}.plist"
BIN_PATH="$HOME/.cargo/bin/chump-curator-supervisor"

# Fallback: check common cargo output dirs.
if [[ ! -f "$BIN_PATH" ]]; then
    CANDIDATE="$REPO_ROOT/target/release/chump-curator-supervisor"
    if [[ -f "$CANDIDATE" ]]; then
        BIN_PATH="$CANDIDATE"
    fi
fi

log() { printf '[install-curator-supervisor] %s\n' "$*"; }

is_loaded() {
    launchctl list 2>/dev/null | grep -qE "^[0-9-]+[[:space:]]+[0-9-]+[[:space:]]+${LABEL}$"
}

# RESILIENT-246: last_exit_status LABEL — the second column of `launchctl list`.
# is_loaded() alone is NOT health: a job stuck at exit 78 is still "loaded" and
# still listed. For twelve days `--check` would have said LOADED while the job
# had not run once. Anything non-zero here means the last invocation failed.
last_exit_status() {
    launchctl list 2>/dev/null \
        | awk -v l="$LABEL" '$3 == l {print $2; found=1} END {if (!found) print "absent"}'
}

# Human-readable meaning for the exit codes launchd actually reports here.
explain_exit() {
    case "$1" in
        0)      echo "ok" ;;
        78)     echo "EX_CONFIG — launchd could not spawn ProgramArguments[0] (missing/non-executable binary). NOTE: no log output is produced in this state" ;;
        127)    echo "command not found" ;;
        -15)    echo "SIGTERM" ;;
        absent) echo "not loaded" ;;
        *)      echo "non-zero exit" ;;
    esac
}

# ── --check ────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--check" ]]; then
    _st="$(last_exit_status)"
    if [[ "$_st" == "absent" ]]; then
        log "NOT LOADED — $LABEL is not loaded"
        exit 1
    elif [[ "$_st" == "0" ]]; then
        log "HEALTHY — $LABEL loaded, last exit 0"
        exit 0
    else
        # RESILIENT-246: loaded-but-failing is a FAILURE, not a pass.
        log "FAILING — $LABEL loaded but last exit status is $_st ($(explain_exit "$_st"))"
        exit 1
    fi
fi

# ── --uninstall ────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--uninstall" ]]; then
    if is_loaded; then
        launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || \
            launchctl unload "$PLIST_DEST" 2>/dev/null || true
        log "unloaded $LABEL"
    fi
    rm -f "$PLIST_DEST"
    log "removed $PLIST_DEST"
    exit 0
fi

# ── install ────────────────────────────────────────────────────────────────
mkdir -p "$LOG_DIR"
mkdir -p "$HOME/Library/LaunchAgents"

if [[ ! -f "$PLIST_TEMPLATE" ]]; then
    log "ERROR: plist template not found at $PLIST_TEMPLATE"
    exit 1
fi

# ── RESILIENT-246: the binary MUST live at a stable path ───────────────────
# The twelve-day outage happened because this script fell back to
# $REPO_ROOT/target/release/chump-curator-supervisor and baked that path into
# the plist. target/release is disposable (cargo clean, cargo-target-reaper,
# disk-pressure reaps). When it was reclaimed, launchd could not spawn the job
# and returned 78 (EX_CONFIG) forever — writing NOTHING to either log, because
# the failure happens before the process exists.
#
# Two defenses now:
#   1. The plist no longer references the binary at all (it runs /bin/bash +
#      scripts/ops/curator-supervisor-run.sh, which is version-controlled).
#   2. We still install the binary into ~/.cargo/bin — the stable location
#      where the fleet's other six daemons live and which nothing reaps — so
#      the runner's first-choice path is durable.
STABLE_BIN="$HOME/.cargo/bin/chump-curator-supervisor"
BUILT_BIN="$REPO_ROOT/target/release/chump-curator-supervisor"

if [[ ! -x "$BUILT_BIN" && ! -x "$STABLE_BIN" ]]; then
    log "Binary not found — building chump-curator-supervisor (release)..."
    (cd "$REPO_ROOT" && PATH="$HOME/.cargo/bin:$PATH" cargo build --release -p chump-curator-supervisor)
fi

# Copy the freshest build into the stable path. `install` is atomic enough for
# our purposes and preserves the exec bit.
if [[ -x "$BUILT_BIN" ]]; then
    mkdir -p "$HOME/.cargo/bin"
    if [[ ! -x "$STABLE_BIN" || "$BUILT_BIN" -nt "$STABLE_BIN" ]]; then
        install -m 755 "$BUILT_BIN" "$STABLE_BIN" \
            && log "installed binary → $STABLE_BIN"
    fi
fi

if [[ -x "$STABLE_BIN" ]]; then
    BIN_PATH="$STABLE_BIN"
elif [[ -x "$BUILT_BIN" ]]; then
    BIN_PATH="$BUILT_BIN"
    log "WARNING: only a disposable build path is available ($BUILT_BIN)."
    log "WARNING: this is the RESILIENT-246 fragility — install into ~/.cargo/bin when you can."
else
    log "ERROR: no chump-curator-supervisor binary could be found or built"
    exit 1
fi
log "supervisor binary: $BIN_PATH"

# Substitute placeholders.
sed \
    -e "s|__BREW_PREFIX__|$(chump_brew_prefix)|g" \
    -e "s|CHUMP_REPO_ROOT_PLACEHOLDER|${REPO_ROOT}|g" \
    -e "s|CHUMP_LOG_DIR_PLACEHOLDER|${LOG_DIR}|g" \
    -e "s|CHUMP_HOME_PLACEHOLDER|${HOME}|g" \
    "$PLIST_TEMPLATE" > "$PLIST_DEST"

# RESILIENT-246 regression guard: never ship a plist whose ProgramArguments
# point into a build-output directory. That is the exact config that produced
# exit 78. Fail the install rather than re-create the outage.
if python3 - "$PLIST_DEST" <<'PY'
import sys, plistlib
with open(sys.argv[1], 'rb') as f:
    d = plistlib.load(f)
args = d.get('ProgramArguments', [])
sys.exit(0 if any('/target/release/' in a or '/target/debug/' in a for a in args) else 1)
PY
then
    log "ERROR: generated plist points ProgramArguments at a target/ build artifact."
    log "ERROR: that is the RESILIENT-246 exit-78 config. Refusing to install."
    rm -f "$PLIST_DEST"
    exit 1
fi

log "wrote $PLIST_DEST"

# Unload first if already loaded (idempotent re-install).
if is_loaded; then
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || \
        launchctl unload "$PLIST_DEST" 2>/dev/null || true
    sleep 1
fi

launchctl bootstrap "gui/$(id -u)" "$PLIST_DEST" 2>/dev/null || \
    launchctl load "$PLIST_DEST"

# RESILIENT-246: verify the job actually SPAWNED. RunAtLoad is true, so give
# the first invocation a moment and then read the real exit status. "Loaded"
# was never proof of anything — exit 78 is loaded too.
sleep 3
_st="$(last_exit_status)"
case "$_st" in
    absent)
        log "WARNING — load attempted but launchctl list does not show $LABEL yet"
        ;;
    0)
        log "SUCCESS — $LABEL loaded and last exit status 0"
        ;;
    *)
        log "FAILURE — $LABEL loaded but last exit status is $_st ($(explain_exit "$_st"))"
        log "         run: bash scripts/ops/curator-supervisor-run.sh   # to see the real error"
        exit 1
        ;;
esac
