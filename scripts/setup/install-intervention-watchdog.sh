#!/usr/bin/env bash
# install-intervention-watchdog.sh — RESILIENT-214 (wires INFRA-3489/COTG-2.1)
#
# Installs the intervention-watchdog as a launchd agent (macOS) or cron job
# (Linux). It runs `chump intervention-watchdog --apply` every 30 min so every
# human touch is logged as an autonomy_defect + deduped self-heal gap, keeping
# the downstream consumers (fleet-brief, ops-audit) fed. Idempotent: safe to
# re-run. Mirrors install-bot-merge-watchdog.sh (INFRA-1006).

set -euo pipefail
# INFRA-8194 (R5 slice 2): the tracked plist is a placeholder template
# (__REPO_ROOT__ __HOME__ __BIN_DIR__ __BREW_PREFIX__), rendered for THIS host by
# chump_render_template (typed `chump node render-unit`, sed mirror fallback).
# shellcheck source=../lib/host-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/host-paths.sh"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
PLIST_SRC="$REPO_ROOT/launchd/com.chump.intervention-watchdog.plist"
PLIST_DEST="$HOME/Library/LaunchAgents/com.chump.intervention-watchdog.plist"

command -v chump >/dev/null 2>&1 || { echo "ERROR: chump not on PATH — run 'cargo install --path .' first"; exit 1; }

if [[ "$(uname)" == "Darwin" ]]; then
    if [[ ! -f "$PLIST_SRC" ]]; then
        echo "ERROR: $PLIST_SRC not found — run from repo root after this PR merges"; exit 1
    fi
    mkdir -p "$HOME/Library/LaunchAgents"
    # Patch plist to use absolute repo path.
    chump_render_template "$PLIST_SRC" "$PLIST_DEST" "$REPO_ROOT"
    launchctl unload "$PLIST_DEST" 2>/dev/null || true
    launchctl load -w "$PLIST_DEST"
    echo "[install-intervention-watchdog] launchd agent loaded: com.chump.intervention-watchdog"
else
    # Linux: cron every 30 min.
    CRON_LINE="*/30 * * * * cd $REPO_ROOT && chump intervention-watchdog --apply >> $REPO_ROOT/.chump-locks/intervention-watchdog.log 2>&1"
    ( crontab -l 2>/dev/null | grep -v 'intervention-watchdog'; echo "$CRON_LINE" ) | crontab -
    echo "[install-intervention-watchdog] cron job installed (every 30 min)"
fi
