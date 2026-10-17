#!/usr/bin/env bash
# install-self-hosted-runners-all-local.sh — INFRA-1540 automation
#
# One-shot setup that discovers EVERY actions-runner installation on this
# machine, provisions the shared cargo target cache, injects the env vars
# into each runner's .env, restarts each launchd service, and verifies all
# 4 are back online with the new env in effect.
#
# Replaces the per-runner manual sequence:
#   1. bash install-self-hosted-runner-cache.sh        (per runner)
#   2. edit ~/Library/LaunchAgents/com.chump.*.plist   (per runner)
#   3. launchctl unload ... && launchctl load ...      (per runner)
#   4. gh api .../actions/runners | check status        (4x)
#
# Idempotent: re-running is a no-op if env already present.
#
# Usage:
#   bash scripts/setup/install-self-hosted-runners-all-local.sh
#   bash scripts/setup/install-self-hosted-runners-all-local.sh --dry-run
#   bash scripts/setup/install-self-hosted-runners-all-local.sh --no-restart
#
# Env:
#   CHUMP_RUNNER_CACHE_ROOT  cache dir (default: $HOME/.cache/chump-runner)
#   CHUMP_RUNNER_GH_REPO     gh api repo (default: repairman29/chump)

set -uo pipefail
# INFRA-8194 (R5 slice 2): the Homebrew prefix comes from the host resolver
# (chump_brew_prefix in scripts/lib/host-paths.sh, the shell mirror of
# chump_provision::brew_prefix; `chump node host --field brew-prefix`), not a
# baked Apple Silicon path.
# shellcheck source=../lib/host-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/host-paths.sh"
BREW_PREFIX="$(chump_brew_prefix)"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DRY_RUN=0
NO_RESTART=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --no-restart) NO_RESTART=1 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

CACHE_ROOT="${CHUMP_RUNNER_CACHE_ROOT:-$HOME/.cache/chump-runner}"
TARGET_DIR="$CACHE_ROOT/cargo-target"
ENV_FILE="$CACHE_ROOT/runner.env"
GH_REPO="${CHUMP_RUNNER_GH_REPO:-repairman29/chump}"

say() { echo "[runners-all] $*"; }
do_or_dry() {
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[runners-all][dry-run] $*"
    else
        eval "$@"
    fi
}

# ── Step 1: provision shared cache ───────────────────────────────────────────
say "step 1/5: provision shared cache at $CACHE_ROOT"
if [[ $DRY_RUN -eq 1 ]]; then
    say "[dry-run] would run: $SCRIPT_DIR/install-self-hosted-runner-cache.sh"
else
    if ! CHUMP_RUNNER_CACHE_ROOT="$CACHE_ROOT" bash "$SCRIPT_DIR/install-self-hosted-runner-cache.sh"; then
        say "FATAL: cache provisioning failed"
        exit 1
    fi
fi

# ── Step 2: discover runner installations ───────────────────────────────────
# macOS ships bash 3.2 — no mapfile. Use a portable while-read loop.
say "step 2/5: discover actions-runner installations under \$HOME"
RUNNER_DIRS=()
while IFS= read -r line; do
    [[ -n "$line" ]] && RUNNER_DIRS+=("$line")
done < <(find "$HOME" -maxdepth 3 -type f -name "config.sh" -path "*actions-runner*" 2>/dev/null \
          | xargs -n1 dirname 2>/dev/null \
          | sort -u)
if [[ ${#RUNNER_DIRS[@]} -eq 0 ]]; then
    say "FATAL: no actions-runner installations found under $HOME"
    exit 1
fi
say "found ${#RUNNER_DIRS[@]} runner(s):"
for d in "${RUNNER_DIRS[@]}"; do
    echo "    $d"
done

# ── Step 3: append env vars to each runner's .env (idempotent) ───────────────
say "step 3/5: inject env vars into each runner's .env"
ENV_MARKER="# INFRA-1540 cache env"
PATH_MARKER="# INFRA-1540 PATH (brew coreutils for timeout/jq/etc.)"
# Default PATH includes Homebrew + system. Override via CHUMP_RUNNER_PATH.
RUNNER_PATH="${CHUMP_RUNNER_PATH:-${BREW_PREFIX}/bin:${BREW_PREFIX}/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin}"
for rdir in "${RUNNER_DIRS[@]}"; do
    envfile="$rdir/.env"
    cache_done=0
    path_done=0
    if [[ -f "$envfile" ]] && grep -q "$ENV_MARKER" "$envfile" 2>/dev/null; then
        cache_done=1
    fi
    if [[ -f "$envfile" ]] && grep -q "INFRA-1540 PATH" "$envfile" 2>/dev/null; then
        path_done=1
    fi
    if [[ $cache_done -eq 1 && $path_done -eq 1 ]]; then
        say "  $rdir/.env  ALREADY HAS cache+PATH, skipping"
        continue
    fi
    # actions-runner reads .env as KEY=VALUE (NOT shell script). Append
    # bare KEY=VALUE lines (no `export`, no `source`).
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[dry-run] would append to $envfile:"
        [[ $cache_done -eq 0 ]] && {
            echo "    $ENV_MARKER"
            echo "    CARGO_TARGET_DIR=$TARGET_DIR"
            echo "    CHUMP_RUNNER_CACHE_ROOT=$CACHE_ROOT"
        }
        [[ $path_done -eq 0 ]] && {
            echo "    $PATH_MARKER"
            echo "    PATH=$RUNNER_PATH"
        }
    else
        if [[ $cache_done -eq 0 ]]; then
            {
                echo ""
                echo "$ENV_MARKER (do not edit — managed by install-self-hosted-runners-all-local.sh)"
                echo "CARGO_TARGET_DIR=$TARGET_DIR"
                echo "CHUMP_RUNNER_CACHE_ROOT=$CACHE_ROOT"
            } >> "$envfile"
        fi
        if [[ $path_done -eq 0 ]]; then
            # PATH is critical: without /opt/homebrew/bin, actions-runner jobs
            # can't find `timeout`, `gtimeout`, `jq` (if not in /usr/bin), etc.
            # Fixed an ACP smoke test failure 2026-05-16: test fell through to
            # sleep-kill branch because timeout wasn't on PATH; chump --acp got
            # killed before flushing stdout → empty TMPOUT → FAIL.
            {
                echo ""
                echo "$PATH_MARKER"
                echo "PATH=$RUNNER_PATH"
            } >> "$envfile"
        fi
        say "  $envfile  WROTE $([[ $cache_done -eq 0 ]] && echo cache) $([[ $path_done -eq 0 ]] && echo PATH)"
    fi
done

# ── Step 4: discover + restart each runner's launchd service ─────────────────
say "step 4/5: restart launchd services so .env changes take effect"
if [[ $NO_RESTART -eq 1 ]]; then
    say "  --no-restart: skipping restart phase"
else
    UID_=$(id -u)
    # Map each runner dir → launchd service name. The convention is
    # com.chump.actions-runner (first), -2, -3, -4 matching dir suffix.
    declare -a SERVICES=()
    for rdir in "${RUNNER_DIRS[@]}"; do
        name=$(basename "$rdir")
        case "$name" in
            actions-runner-chump)   svc="com.chump.actions-runner" ;;
            actions-runner-chump-*) suffix="${name#actions-runner-chump-}"; svc="com.chump.actions-runner-$suffix" ;;
            *) svc="com.chump.$(echo "$name" | tr '/' '-')" ;;
        esac
        if launchctl print "gui/$UID_/$svc" >/dev/null 2>&1; then
            SERVICES+=("$svc")
        else
            say "  WARN: no launchd service '$svc' found for $rdir; will need manual restart"
        fi
    done
    say "  found ${#SERVICES[@]} launchd service(s):"
    for s in "${SERVICES[@]}"; do echo "    gui/$UID_/$s"; done
    # Kickstart each (kill + restart, picks up .env).
    for s in "${SERVICES[@]}"; do
        if [[ $DRY_RUN -eq 1 ]]; then
            echo "[dry-run] would: launchctl kickstart -k gui/$UID_/$s"
        else
            launchctl kickstart -k "gui/$UID_/$s" 2>&1 | sed 's/^/    /'
            say "  kickstarted $s"
        fi
    done
    if [[ $DRY_RUN -eq 0 ]]; then
        say "  giving runners 8s to reconnect to GitHub..."
        sleep 8
    fi
fi

# ── Step 5: verify via gh api ────────────────────────────────────────────────
say "step 5/5: verify all runners are online again"
if ! command -v gh >/dev/null 2>&1; then
    say "  WARN: gh CLI not available; skipping verification"
    exit 0
fi
if [[ $DRY_RUN -eq 1 ]]; then
    say "[dry-run] would: gh api repos/$GH_REPO/actions/runners"
    exit 0
fi
gh api "repos/$GH_REPO/actions/runners" --jq '.runners[] | "\(.name)\t\(.status)\t\(.busy)\t\([.labels[].name] | join(","))"' 2>&1 | while IFS=$'\t' read -r name status busy labels; do
    if [[ "$status" == "online" ]]; then
        say "  ✓ $name  $status  busy=$busy  $labels"
    else
        say "  ✗ $name  $status  busy=$busy  $labels"
    fi
done

# Final sanity: tail one runner log for evidence the env took effect
if [[ -f "$HOME/Library/Logs/Chump/actions-runner.log" ]]; then
    say "recent log entries (runner 1):"
    tail -5 "$HOME/Library/Logs/Chump/actions-runner.log" 2>&1 | sed 's/^/    /'
fi

say "done. Cache dir: $TARGET_DIR"
say "Runners will use the shared cache on their NEXT job pickup."
