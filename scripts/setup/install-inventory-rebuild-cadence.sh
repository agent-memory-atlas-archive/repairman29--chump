#!/usr/bin/env bash
# install-inventory-rebuild-cadence.sh — RESILIENT-220
#
# Installs the inventory-rebuild-cadence as a launchd agent (macOS) or cron
# job (Linux). Runs `chump inventory rebuild` weekly so META-271's 9
# tech-debt/dead-code detector classes don't sit unused indefinitely --
# discovered they'd gone silently un-run for ~2 months with zero findings.
# Mirrors install-intervention-watchdog.sh (RESILIENT-214).

set -euo pipefail
# INFRA-8194 (R5 slice 2): the tracked plist is a placeholder template
# (__REPO_ROOT__ __HOME__ __BIN_DIR__ __BREW_PREFIX__), rendered for THIS host by
# chump_render_template (typed `chump node render-unit`, sed mirror fallback).
# shellcheck source=../lib/host-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/host-paths.sh"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
PLIST_SRC="$REPO_ROOT/launchd/com.chump.inventory-rebuild-cadence.plist"
PLIST_DEST="$HOME/Library/LaunchAgents/com.chump.inventory-rebuild-cadence.plist"

command -v chump >/dev/null 2>&1 || { echo "ERROR: chump not on PATH — run 'cargo install --path .' first"; exit 1; }

if [[ "$(uname)" == "Darwin" ]]; then
    if [[ ! -f "$PLIST_SRC" ]]; then
        echo "ERROR: $PLIST_SRC not found — run from repo root after this PR merges"; exit 1
    fi
    mkdir -p "$HOME/Library/LaunchAgents"
    chump_render_template "$PLIST_SRC" "$PLIST_DEST" "$REPO_ROOT"
    launchctl unload "$PLIST_DEST" 2>/dev/null || true
    launchctl load -w "$PLIST_DEST"
    echo "[install-inventory-rebuild-cadence] launchd agent loaded: com.chump.inventory-rebuild-cadence"
else
    CRON_LINE="0 6 * * 1 cd $REPO_ROOT && bash scripts/coord/inventory-rebuild-cadence.sh >> $REPO_ROOT/.chump-locks/inventory-rebuild-cadence.log 2>&1"
    ( crontab -l 2>/dev/null | grep -v 'inventory-rebuild-cadence'; echo "$CRON_LINE" ) | crontab -
    echo "[install-inventory-rebuild-cadence] cron job installed (weekly, Monday 06:00)"
fi
