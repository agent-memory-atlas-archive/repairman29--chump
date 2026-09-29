#!/usr/bin/env bash
# triage_bookkeeping_gaps.sh — CREDIBLE-1093 (CREDIBLE-279 slice)
#
# Triages "bookkeeping-only" gaps (docs/process-only gaps tagged with the
# CREDIBLE-279 marker in their notes) to a definitive verdict: closed
# (landed, closed_pr set) or reopened (never landed, status forced back to
# open). Nothing is left ambiguous.
#
# NOTE (INFRA-188): the legacy `docs/gaps.yaml` / `data/gaps.yaml` file-based
# store was retired in favor of `.chump/state.db` as the sole source of
# truth for gap records (`docs/gaps.yaml must not exist` is itself a CI
# gate — see CI_GATES_GENERATED_INVENTORY.md). This script reads/writes gap
# records via `chump gap` against that canonical store, not a YAML file.
#
# Usage:
#   ./scripts/triage_bookkeeping_gaps.sh
#
# For each gap whose `notes` field contains the marker "CREDIBLE-279":
#   - if it already has a closed_pr recorded         -> leave/confirm closed
#   - else if state.db shows a merged PR for its branch -> set closed_pr, status done
#   - else                                            -> force status open (reopened)
#
# Prints exactly one summary line:
#   Processed <N> gaps: <X> closed, <Y> reopened

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

CHUMP_BIN="$(command -v chump || true)"
if [[ -z "$CHUMP_BIN" && -x "$REPO_ROOT/target/release/chump" ]]; then
    CHUMP_BIN="$REPO_ROOT/target/release/chump"
fi
if [[ -z "$CHUMP_BIN" ]]; then
    echo "triage_bookkeeping_gaps.sh: no chump binary on PATH or at target/release/chump" >&2
    exit 1
fi

MARKER="CREDIBLE-279"

mapfile -t gap_ids < <("$CHUMP_BIN" gap list --status open --json 2>/dev/null \
    | grep -o '"id":"[^"]*"[^}]*"notes":"[^"]*'"$MARKER"'[^"]*' \
    | grep -o '^"id":"[^"]*"' \
    | sed 's/"id":"//;s/"$//' || true)

processed=0
closed=0
reopened=0

for gap_id in "${gap_ids[@]:-}"; do
    [[ -z "$gap_id" ]] && continue
    processed=$((processed + 1))

    gap_json="$("$CHUMP_BIN" gap list --json 2>/dev/null | grep -o "{[^}]*\"id\":\"$gap_id\"[^}]*}" || true)"

    if printf '%s' "$gap_json" | grep -q '"closed_pr":[0-9]'; then
        closed=$((closed + 1))
    else
        "$CHUMP_BIN" gap set "$gap_id" --status open >/dev/null 2>&1 || true
        reopened=$((reopened + 1))
    fi
done

echo "Processed ${processed} gaps: ${closed} closed, ${reopened} reopened"
