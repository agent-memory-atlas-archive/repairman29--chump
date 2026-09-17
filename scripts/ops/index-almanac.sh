#!/usr/bin/env bash
# scripts/ops/index-almanac.sh — RESILIENT-404 (RESILIENT-367 slice)
#
# WHY THIS EXISTS. scripts/setup/refresh-almanac-binary.sh (INFRA-3639) and
# scripts/ops/almanac-liveness-refresh.sh (INFRA-3643) both watch almanac's
# health and self-heal a MISSING binary or a STALE/EMPTY index — but neither
# one is the thing that keeps the fleet's index fresh under normal
# operation. Per docs/design/FLEET_LOAD_MAP.md and docs/CHUMPOS_FIRST_BOOT.md
# the almanac index has historically been stranded on the Mac and gone
# stale for days with nothing driving a routine reindex. This script is that
# routine driver: it walks every fleet repo checkout, reindexes each one
# through almanac's local ollama nomic-embed-text backend, and logs a clear
# success/failure summary — the thing scripts/setup/install-index-almanac-timer.sh
# wires to run hourly (plus on new-repo discovery) on the factory node.
#
# Usage:
#   scripts/ops/index-almanac.sh                  # discover + reindex all fleet repos
#   scripts/ops/index-almanac.sh --dry-run         # print what would run, don't call almanac
#
# Env overrides:
#   ALMANAC_BIN           almanac CLI (default: $HOME/Projects/almanac/target/release/almanac)
#   ALMANAC_FLEET_ROOTS   colon-separated roots to scan for fleet repos
#                         (default: $HOME/Projects)
#   ALMANAC_INDEX_DIR     designated index storage location
#                         (default: $HOME/.almanac/indexes)
#   ALMANAC_INDEX_CMD     override the per-repo index command; {repo} is
#                         substituted with the repo's absolute path, {name}
#                         with its basename
#                         (default: "$ALMANAC_BIN" index {repo} --json).
#                         NOTE: almanac index takes NO --embed-backend/--embed-model/
#                         --index-dir flags -- embeddings are a separate almanac
#                         embed/summarize pass. Passing them errored every repo
#                         (0/N) until RESILIENT-1340.)
#   ALMANAC_INDEX_MARKER  path to the "last full fleet index" marker file
#                         (default: $HOME/.almanac/fleet-index.last)
#   ALMANAC_INDEX_LOG     path to the human-readable run log
#                         (default: $HOME/.almanac/fleet-index.log)
#   CHUMP_REPO_ROOT       chump checkout whose ambient.jsonl to emit to
#
# Emits ambient kinds:
#   almanac_fleet_index_started    — a reindex sweep began (repo count known)
#   almanac_fleet_index_repo_failed — one repo's index command exited non-zero
#   almanac_fleet_index_completed  — sweep finished (success/fail counts + marker written)
#   almanac_fleet_index_no_binary  — almanac CLI absent, sweep skipped entirely
#
# Exit codes:
#   0  sweep ran to completion (individual repo failures are logged and
#      counted, not fatal — one broken repo must not blind the rest of the fleet)
#   1  almanac CLI absent, or zero fleet repos discovered

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CHUMP_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"
mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true

ALMANAC_REPO_DEFAULT="$HOME/Projects/almanac"
ALMANAC_BIN="${ALMANAC_BIN:-$ALMANAC_REPO_DEFAULT/target/release/almanac}"
ALMANAC_FLEET_ROOTS="${ALMANAC_FLEET_ROOTS:-$HOME/Projects}"
ALMANAC_INDEX_DIR="${ALMANAC_INDEX_DIR:-$HOME/.almanac/indexes}"
ALMANAC_INDEX_MARKER="${ALMANAC_INDEX_MARKER:-$HOME/.almanac/fleet-index.last}"
ALMANAC_INDEX_LOG="${ALMANAC_INDEX_LOG:-$HOME/.almanac/fleet-index.log}"

DRY_RUN=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done

mkdir -p "$ALMANAC_INDEX_DIR" "$(dirname "$ALMANAC_INDEX_MARKER")" "$(dirname "$ALMANAC_INDEX_LOG")" 2>/dev/null || true

emit() {  # kind extra_json
    local kind="$1" extra="${2:-}"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local line
    if [ -n "$extra" ]; then line="{\"ts\":\"$ts\",\"kind\":\"$kind\",$extra}"
    else line="{\"ts\":\"$ts\",\"kind\":\"$kind\"}"; fi
    printf '%s\n' "$line" >> "$AMBIENT" 2>/dev/null || true
}

log() {  # mirror to stdout and the run log (AC4: "logs success")
    local msg="[index-almanac] $*"
    echo "$msg"
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$msg" >> "$ALMANAC_INDEX_LOG" 2>/dev/null || true
}

if [ ! -x "$ALMANAC_BIN" ]; then
    log "FAIL: almanac binary not found/executable at $ALMANAC_BIN"
    # scanner-anchor: "kind":"almanac_fleet_index_no_binary"  (RESILIENT-404;
    # fires when the almanac CLI is absent — sweep skipped entirely instead
    # of silently no-op'ing)
    emit almanac_fleet_index_no_binary "\"bin\":\"$ALMANAC_BIN\""
    exit 1
fi

# ---------- discover fleet repos (git checkouts under the scan roots) ----------
canon() { (cd "$1" 2>/dev/null && pwd -P) || printf '%s\n' "$1"; }

declare -a REPOS=()
IFS=':' read -ra ROOTS <<< "$ALMANAC_FLEET_ROOTS"
for root in "${ROOTS[@]}"; do
    [ -d "$root" ] || continue
    for repo in "$root"/*; do
        [ -e "$repo/.git" ] || continue
        REPOS+=("$(canon "$repo")")
    done
done

REPO_COUNT="${#REPOS[@]}"
if [ "$REPO_COUNT" -eq 0 ]; then
    log "FAIL: no fleet repos discovered under roots: $ALMANAC_FLEET_ROOTS"
    exit 1
fi

log "discovered $REPO_COUNT fleet repo(s) under: $ALMANAC_FLEET_ROOTS"
# scanner-anchor: "kind":"almanac_fleet_index_started"  (RESILIENT-404;
# fires at the start of every fleet-wide reindex sweep)
emit almanac_fleet_index_started "\"repo_count\":$REPO_COUNT,\"dry_run\":$DRY_RUN"

# ---------- reindex each repo (AST symbol index; no inference -- embeddings are a separate almanac embed/summarize pass) ----------
OK_COUNT=0
FAIL_COUNT=0
for repo in "${REPOS[@]}"; do
    name="$(basename "$repo")"
    cmd="${ALMANAC_INDEX_CMD:-\"$ALMANAC_BIN\" index \"$repo\" --json}"
    cmd="${cmd//\{repo\}/$repo}"
    cmd="${cmd//\{name\}/$name}"

    if [ "$DRY_RUN" = 1 ]; then
        log "DRY: $cmd"
        continue
    fi

    if ( eval "$cmd" ) >>"$ALMANAC_INDEX_LOG" 2>&1; then
        OK_COUNT=$((OK_COUNT + 1))
        log "OK: indexed $name ($repo)"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        log "FAIL: indexing $name ($repo) — see $ALMANAC_INDEX_LOG"
        # scanner-anchor: "kind":"almanac_fleet_index_repo_failed"
        # (RESILIENT-404; fires when one repo's index command exits
        # non-zero during a sweep — logged and counted, not fatal)
        emit almanac_fleet_index_repo_failed "\"repo\":\"$name\",\"path\":\"$repo\""
    fi
done

if [ "$DRY_RUN" = 1 ]; then
    log "dry-run complete: $REPO_COUNT repo(s) would be indexed"
    exit 0
fi

date -u +%Y-%m-%dT%H:%M:%SZ > "$ALMANAC_INDEX_MARKER" 2>/dev/null || true

log "sweep complete: $OK_COUNT/$REPO_COUNT indexed OK, $FAIL_COUNT failed — marker: $ALMANAC_INDEX_MARKER"

# RESILIENT-1340: fleet-doctor-strict.sh check_almanac_freshness (INFRA-3586) watches
# $ALMANAC_HOME/refresh.log as the canonical "routine reindex loop is alive" latch.
# This sweep IS that routine driver on the factory node, but it historically only wrote
# fleet-index.log -- so the latch read a missing refresh.log, defaulted age to 999h, and
# FAILed "refresh loop stale" even when the index was fresh. Stamp refresh.log on every
# completed (non-dry-run) sweep so the latch reflects real loop liveness.
ALMANAC_HOME_DIR="${ALMANAC_HOME:-$(dirname "$ALMANAC_INDEX_LOG")}"
printf '%s [index-almanac] sweep complete: %s/%s indexed OK, %s failed\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$OK_COUNT" "$REPO_COUNT" "$FAIL_COUNT" \
    >> "$ALMANAC_HOME_DIR/refresh.log" 2>/dev/null || true
# scanner-anchor: "kind":"almanac_fleet_index_completed"  (RESILIENT-404;
# fires once per sweep with the final ok/fail tally and marker write)
emit almanac_fleet_index_completed "\"repo_count\":$REPO_COUNT,\"ok_count\":$OK_COUNT,\"fail_count\":$FAIL_COUNT,\"index_dir\":\"$ALMANAC_INDEX_DIR\""

exit 0
