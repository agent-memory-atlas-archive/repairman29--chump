#!/usr/bin/env bash
# scripts/ops/refresh-chump-binary.sh — INFRA-1065
#
# Auto-rebuild ~/.cargo/bin/chump when origin/main has gap-store-affecting
# commits ahead of the installed binary's baked SHA. Removes the daily
# friction of needing CHUMP_ALLOW_STALE_DESTRUCTIVE=1 on every `chump gap ship
# --update-yaml` call (observed 8+ times today during fleet activity).
#
# Logic mirrors src/version.rs INFRA-825 staleness check:
#   - Read the binary's baked SHA (chump --version-json prints CHUMP_BUILD_SHA)
#   - git log <baked>..origin/main -- src/main.rs crates/chump-gap-store/src/lib.rs
#   - If non-empty, rebuild via `cargo install --path . --bin chump --force`
#
# Designed for launchd (com.chump.binary-refresh.plist, hourly) and on-demand
# operator use. Idempotent — exits 0 + emits no event if binary is fresh.
#
# Usage:
#   scripts/ops/refresh-chump-binary.sh           # apply if stale (default)
#   scripts/ops/refresh-chump-binary.sh --check   # report only, don't rebuild
#   scripts/ops/refresh-chump-binary.sh --force   # rebuild unconditionally
#
# Ambient emits:
#   kind=chump_binary_refreshed   on successful rebuild
#   kind=chump_binary_refresh_failed   on cargo install failure

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/resolve-main-worktree.sh
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
REPO="$(resolve_main_worktree "$0")"
LOCK_DIR="$REPO/.chump-locks"
AMB="$LOCK_DIR/ambient.jsonl"

MODE="apply"
case "${1:-}" in
    --check) MODE="check" ;;
    --force) MODE="force" ;;
    "") ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
esac

cd "$REPO" || { echo "cannot cd to $REPO" >&2; exit 1; }

# PRODUCT-169: this cron previously left CARGO_TARGET_DIR unset, so it built
# into whatever .cargo/config.toml's [build] target-dir happened to resolve
# to (typically $REPO/target) while fleet workers (scripts/dispatch/worker.sh,
# INFRA-1933) build into the shared ~/.cargo/chump-shared-target. Two
# directories meant every crate compiled twice into every cache. Mirror
# worker.sh's resolution so the cron and interactive sessions share one
# build cache.
if [[ -z "${CARGO_TARGET_DIR:-}" ]]; then
    # ZERO-WASTE-134: the one shared resolver.
    # shellcheck source=../ci/lib/resolve-cargo-target-dir.sh
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/../ci/lib/resolve-cargo-target-dir.sh"
    export CARGO_TARGET_DIR="$(chump_cargo_target_dir)"
    mkdir -p "$CARGO_TARGET_DIR" 2>/dev/null || true
    printf '{"ts":"%s","kind":"cargo_target_dir_shared","source":"refresh-chump-binary.sh","target_dir":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$CARGO_TARGET_DIR" \
        >> "$AMB" 2>/dev/null || true
fi

# Pull latest so the staleness check sees committed-but-unfetched commits too.
git fetch origin main --quiet 2>/dev/null || true

# Resolve binary path. Prefer the installed cargo bin so we refresh THAT one
# (not whatever's in PATH from a target/debug/chump that doesn't match).
CHUMP_BIN="${CHUMP_BIN:-$HOME/.cargo/bin/chump}"
if [[ ! -x "$CHUMP_BIN" ]]; then
    echo "refresh-chump-binary: no binary at $CHUMP_BIN — first-time install"
    if [[ "$MODE" == "check" ]]; then
        echo "  (--check mode: would install)"
        exit 0
    fi
    cd "$REPO" && cargo install --path . --bin chump --force
    exit $?
fi

# Read the binary's baked SHA from --version output. Format:
#   "chump 0.1.1 (78339bcfc450 built 2026-05-13)"
# Extract the 8-12 hex chars inside the first parenthesis.
BAKED_SHA="$("$CHUMP_BIN" --version 2>/dev/null \
    | python3 -c '
import re, sys
m = re.search(r"\(([0-9a-f]+)\b", sys.stdin.read())
print(m.group(1) if m else "unknown")
')"

if [[ "$BAKED_SHA" == "unknown" || -z "$BAKED_SHA" ]]; then
    echo "refresh-chump-binary: baked SHA unknown — skipping staleness check"
    [[ "$MODE" == "force" ]] || exit 0
    BAKED_SHA="HEAD~999"
fi

# Count commits touching gap-store-affecting files since baked SHA.
COMMITS_AHEAD=$(git log --oneline "$BAKED_SHA..origin/main" -- src/main.rs src/gap_store.rs crates/chump-gap-store/src/lib.rs 2>/dev/null | wc -l | tr -d ' ')

if [[ "$MODE" == "force" ]]; then
    REBUILD=1
elif [[ "${COMMITS_AHEAD:-0}" -gt 0 ]]; then
    REBUILD=1
else
    REBUILD=0
fi

if [[ "$REBUILD" -eq 0 ]]; then
    echo "refresh-chump-binary: fresh (baked=$BAKED_SHA, 0 gap-store commits ahead)"
    exit 0
fi

if [[ "$MODE" == "check" ]]; then
    echo "refresh-chump-binary: STALE (baked=$BAKED_SHA, $COMMITS_AHEAD commits ahead). Run without --check to rebuild."
    exit 3
fi

echo "refresh-chump-binary: rebuilding (baked=$BAKED_SHA, $COMMITS_AHEAD gap-store commits ahead)…"
TS_START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
START_EPOCH="$(date +%s)"
set +e
cargo install --path . --bin chump --force --quiet 2>&1
RC=$?
set -e
ELAPSED=$(( $(date +%s) - START_EPOCH ))
TS_END="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

mkdir -p "$LOCK_DIR" 2>/dev/null || true
if [[ "$RC" -eq 0 ]]; then
    echo "refresh-chump-binary: rebuilt in ${ELAPSED}s"
    printf '{"ts":"%s","kind":"chump_binary_refreshed","baked_sha_before":"%s","commits_ahead":%s,"elapsed_s":%d}\n' \
        "$TS_END" "$BAKED_SHA" "$COMMITS_AHEAD" "$ELAPSED" \
        >> "$AMB" 2>/dev/null || true
    exit 0
else
    echo "refresh-chump-binary: cargo install FAILED (rc=$RC)" >&2
    printf '{"ts":"%s","kind":"chump_binary_refresh_failed","baked_sha":"%s","commits_ahead":%s,"elapsed_s":%d,"rc":%d}\n' \
        "$TS_END" "$BAKED_SHA" "$COMMITS_AHEAD" "$ELAPSED" "$RC" \
        >> "$AMB" 2>/dev/null || true
    exit "$RC"
fi
