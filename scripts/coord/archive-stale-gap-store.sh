#!/usr/bin/env bash
# archive-stale-gap-store.sh — CREDIBLE-1602 (PHASE-R R4, one canonical store per node).
#
# Retire a stale/duplicate gap store (<dir>/.chump/state.db) WITHOUT deleting
# it: rename the db (and its -wal/-shm sidecars) aside with a timestamp suffix,
# and drop a CHUMP_STORE_ARCHIVED marker in the same .chump dir naming the date,
# the reason, and the canonical store that survives. The marker is the exact
# signal fleet-doctor-strict.sh's single-store check honors, so a retired store
# stops counting toward the ">1 live store" split-brain the moment it is marked.
#
# WHY RENAME, NEVER DELETE: a stale store may hold rows that were never
# reconciled onto the canonical store. Keeping the file lets an operator run
# `chump gap reconcile` / inspect it before it is finally removed by hand.
#
# WHY THIS EXISTS: cuphead 2026-10-21 ran three state.db on one node (the live
# 41MB store the architect+reconciler wrote, a stale ~/.chump Oct-19 store, and
# the node clone's stale Oct-10 store). The review organ resolved its store from
# the node-checkout cwd and shipped a gap against the wrong one. Converging to
# one store is the fix; this is the safe, repeatable retire step.
#
# Usage:
#   scripts/coord/archive-stale-gap-store.sh <store-path> --reason <why> --canonical <canonical-store-path> [--dry-run]
#
#   <store-path>        the stale store to retire, e.g. /home/ubuntu/.chump/state.db
#   --reason <why>      one line recorded in the marker (required)
#   --canonical <path>  the store that survives, recorded in the marker (required)
#   --dry-run           print what would happen; touch nothing
#
# NOT a hot path: a one-shot operator remediation. Exits non-zero on any error
# so a caller (or fleet-doctor remedy) can tell it failed.
set -uo pipefail

STORE="" REASON="" CANONICAL="" DRY=0
die() { printf 'archive-stale-gap-store: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --reason)    REASON="${2:-}"; shift 2 ;;
        --canonical) CANONICAL="${2:-}"; shift 2 ;;
        --dry-run)   DRY=1; shift ;;
        -h|--help)   sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)          die "unknown flag: $1" ;;
        *)           [[ -z "$STORE" ]] && { STORE="$1"; shift; } || die "unexpected argument: $1" ;;
    esac
done

[[ -n "$STORE" ]]     || die "missing <store-path> (the stale store to retire)"
[[ -n "$REASON" ]]    || die "missing --reason <why>"
[[ -n "$CANONICAL" ]] || die "missing --canonical <canonical-store-path>"
[[ -f "$STORE" ]]     || die "no such store file: $STORE"
# A symlink is a worktree pointer into the canonical store, not a real second
# store — refuse, so we never rename the canonical store out from under the fleet.
[[ -L "$STORE" ]]     && die "$STORE is a symlink (a worktree pointer, not a stale store) — refusing to archive it"

STORE_DIR="$(cd "$(dirname "$STORE")" && pwd -P)"
CANON_ABS="$CANONICAL"
[[ "$CANON_ABS" == /* ]] || CANON_ABS="$(cd "$(dirname "$CANONICAL")" 2>/dev/null && pwd -P)/$(basename "$CANONICAL")"
[[ "$STORE_DIR/$(basename "$STORE")" == "$CANON_ABS" ]] && die "refusing to archive the canonical store itself ($CANON_ABS)"

# Timestamp suffix — passed as data, computed once; no env seam.
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
MARKER="$STORE_DIR/CHUMP_STORE_ARCHIVED"

say() { printf 'archive-stale-gap-store: %s\n' "$*"; }
if [[ "$DRY" -eq 1 ]]; then
    say "DRY-RUN: would rename $STORE -> $STORE.archived-$STAMP (and any -wal/-shm sidecars)"
    say "DRY-RUN: would write marker $MARKER naming date=$STAMP reason='$REASON' canonical=$CANON_ABS"
    exit 0
fi

moved=0
for ext in "" "-wal" "-shm"; do
    src="$STORE$ext"
    [[ -f "$src" ]] || continue
    mv "$src" "$src.archived-$STAMP" || die "failed to rename $src aside"
    say "renamed $src -> $src.archived-$STAMP"
    moved=$((moved + 1))
done
[[ "$moved" -gt 0 ]] || die "nothing moved (store vanished mid-run?)"

{
    printf 'CHUMP_STORE_ARCHIVED\n'
    printf 'date: %s\n' "$STAMP"
    printf 'reason: %s\n' "$REASON"
    printf 'canonical_store: %s\n' "$CANON_ABS"
    printf 'archived_from: %s\n' "$STORE"
    printf 'tool: scripts/coord/archive-stale-gap-store.sh (CREDIBLE-1602)\n'
} > "$MARKER" || die "failed to write marker $MARKER"
say "wrote marker $MARKER"
say "done — $STORE retired; canonical store is $CANON_ABS. fleet-doctor single-store check now ignores this archive."
exit 0
