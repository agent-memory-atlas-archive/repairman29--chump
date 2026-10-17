#!/usr/bin/env bash
# install-merge-drivers.sh — INFRA-310 / INFRA-367
#
# Register chump's custom git merge drivers in the local git config.
# Idempotent — safe to re-run.
#
# Wiring is split between:
#   - .gitattributes (committed) — declares which paths use which driver
#   - .git/config (NOT committed) — registers the driver command
#
# Without the .git/config registration, .gitattributes references drivers
# that git can't find, and merges fall back to default 3-way (which produces
# conflict markers — same as no driver at all). So this installer is required
# once per checkout / per linked worktree.
#
# Auto-installed by scripts/setup/install-hooks.sh (which agents run via
# `bot-merge.sh` and `post-checkout` hook), so most operators never need to
# run it directly. Manual invocation:
#
#   bash scripts/setup/install-merge-drivers.sh
#
# Verify all drivers:
#   git config --get-regexp '^merge\.' | grep -E 'driver|name'
#
# Drivers registered (INFRA-310):
#   (chump-state-sql-regen retired by INFRA-8193 — .chump/state.sql left git)
#   ci-yml-add-row: merges .github/workflows/ci.yml step additions
#   pre-commit-add-guard: merges scripts/git-hooks/pre-commit guard additions
#   gap-yaml-add-line: resolves docs/gaps/*.yaml conflicts by using ours (newest state)

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$REPO_ROOT" ]]; then
    echo "[install-merge-drivers] not in a git repo — nothing to do" >&2
    exit 1
fi
cd "$REPO_ROOT"

# ── INFRA-8193: retire the state.sql regeneration driver ─────────────────────
# .chump/state.sql is no longer tracked (state.db is the only truth), so the
# chump-state-sql-regen driver has nothing to merge. Drop a stale registration
# left in .git/config by older installs (idempotent; absent section is fine).
if git config --get "merge.chump-state-sql-regen.driver" >/dev/null 2>&1; then
    git config --remove-section "merge.chump-state-sql-regen" 2>/dev/null || true
    echo "[install-merge-drivers] OK: retired chump-state-sql-regen (INFRA-8193)"
fi

# ── Register CI YAML add-row driver ──────────────────────────────────────────
DRIVER_SCRIPT_REL="scripts/git/merge-driver-ci-yml-add-row.sh"
DRIVER_NAME="ci-yml-add-row"

if [[ -x "$DRIVER_SCRIPT_REL" ]]; then
    git config "merge.${DRIVER_NAME}.name" "Union .github/workflows/ci.yml step additions (INFRA-310)"
    git config "merge.${DRIVER_NAME}.driver" "${DRIVER_SCRIPT_REL} %O %A %B %L"
    echo "[install-merge-drivers] OK: ${DRIVER_NAME} registered"
else
    echo "[install-merge-drivers] SKIP: ${DRIVER_SCRIPT_REL} not found" >&2
fi

# ── Register pre-commit add-guard driver ─────────────────────────────────────
DRIVER_SCRIPT_REL="scripts/git/merge-driver-pre-commit-add-guard.sh"
DRIVER_NAME="pre-commit-add-guard"

if [[ -x "$DRIVER_SCRIPT_REL" ]]; then
    git config "merge.${DRIVER_NAME}.name" "Append scripts/git-hooks/pre-commit guard blocks (INFRA-310)"
    git config "merge.${DRIVER_NAME}.driver" "${DRIVER_SCRIPT_REL} %O %A %B %L"
    echo "[install-merge-drivers] OK: ${DRIVER_NAME} registered"
else
    echo "[install-merge-drivers] SKIP: ${DRIVER_SCRIPT_REL} not found" >&2
fi

# ── Register gap-yaml add-line driver ────────────────────────────────────
DRIVER_SCRIPT_REL="scripts/git/merge-driver-gap-yaml-add-line.sh"
DRIVER_NAME="gap-yaml-add-line"

if [[ -x "$DRIVER_SCRIPT_REL" ]]; then
    git config "merge.${DRIVER_NAME}.name" "Resolve docs/gaps/*.yaml conflicts by using ours (INFRA-310)"
    git config "merge.${DRIVER_NAME}.driver" "${DRIVER_SCRIPT_REL} %O %A %B %L"
    echo "[install-merge-drivers] OK: ${DRIVER_NAME} registered"
else
    echo "[install-merge-drivers] SKIP: ${DRIVER_SCRIPT_REL} not found" >&2
fi

# ── INFRA-1389: Register generic append-only driver for 3 new hot files ──────
# Single driver script, three named aliases pointing at it.
APPEND_DRIVER_SCRIPT_REL="scripts/git/merge-driver-append-only.sh"

for alias_name in cargo-toml-append js-append rust-main-append; do
  case "$alias_name" in
    cargo-toml-append) desc="Append-only merge for Cargo.toml dep/bin entries (INFRA-1389)" ;;
    js-append)         desc="Append-only merge for web/v2/app.js component/VIEWS additions (INFRA-1389)" ;;
    rust-main-append)  desc="Append-only merge for src/main.rs route/arm additions (INFRA-1389)" ;;
  esac
  if [[ -x "$APPEND_DRIVER_SCRIPT_REL" ]]; then
    git config "merge.${alias_name}.name" "$desc"
    git config "merge.${alias_name}.driver" "${APPEND_DRIVER_SCRIPT_REL} %O %A %B %L"
    echo "[install-merge-drivers] OK: ${alias_name} registered"
  else
    echo "[install-merge-drivers] SKIP: ${APPEND_DRIVER_SCRIPT_REL} not found (run from repo root)" >&2
  fi
done

# ── Register generic 'union' driver (INFRA-1419, rewritten INFRA-8223) ────────
# `merge=union` in .gitattributes resolves to THIS registration, not git's
# built-in (a config entry named `union` shadows the built-in). The original
# INFRA-1419 command was `git merge-file -p ... %A %O %B > %A`: the shell
# truncated %A before git read it and -p wrote conflict markers instead of a
# union, so every rebase of EVENT_REGISTRY.yaml / env-vars-internal.txt came out
# wrapped in LEFT/RIGHT markers with the upstream side gone (PRs #5536 #5529
# #5527, 2026-10-17). The script reads %O %A %B into temp files first and moves
# the result into place; it is list-item aware for EVENT_REGISTRY.yaml.
DRIVER_NAME="union"
UNION_DRIVER_SCRIPT_REL="scripts/git/merge-driver-union.sh"
git config "merge.${DRIVER_NAME}.name" "Union merge: both sides kept, no in-place truncation (INFRA-1419/INFRA-8223)"
git config "merge.${DRIVER_NAME}.driver" "${UNION_DRIVER_SCRIPT_REL} %O %A %B %L %P"
echo "[install-merge-drivers] OK: ${DRIVER_NAME} registered"

# Verify .gitattributes wiring
if [[ -f .gitattributes ]]; then
    echo "[install-merge-drivers] .gitattributes wiring check:"
    for pattern in ".github/workflows/ci.yml" "scripts/git-hooks/pre-commit" \
                   "Cargo.toml" "web/v2/app.js" "src/main.rs"; do
        if grep -qF "$pattern" .gitattributes 2>/dev/null; then
            echo "[install-merge-drivers]   ✓ $pattern configured"
        else
            echo "[install-merge-drivers]   ⚠ $pattern not found in .gitattributes" >&2
        fi
    done
fi
