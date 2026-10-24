#!/usr/bin/env bash
# scripts/ops/backfill-shipped-gaps.sh — INFRA-2121 (CI-REVIEW Lever 5)
#
# One-time backfill: walk the last N days of MERGED PRs, extract the gap-ID
# from each PR title, and run `chump gap ship <ID> --closed-pr <#>` on every
# gap that's still status:open. Catches the 35+ silent-shipped backlog from
# the time before .github/workflows/auto-flip-on-merge.yml existed.
#
# Usage:
#   scripts/ops/backfill-shipped-gaps.sh [--days N] [--dry-run]
#
# Flags:
#   --days N    look back N days of merged PRs (default: 60)
#   --dry-run   print what WOULD be shipped; do not call chump gap ship
#   --apply     actually run chump gap ship (default mode is --dry-run for safety)
#
# Why dry-run is default:
#   The backfill rewrites docs/gaps/<ID>.yaml for every gap it flips. On a
#   60-day window we expect 35+ writes. Dry-run lets the operator preview the
#   set before committing.
#
# Exit codes:
#   0 — backfill ran cleanly (including dry-run preview)
#   1 — invocation error (bad flag)
#   2 — required tool missing (gh, chump)
#
# Event registry (INFRA-755 + scanner-anchor pattern):
#   scanner-anchor: "kind":"gap_backfill_flipped" emitted by this script (INFRA-2121)

set -euo pipefail

DAYS=60
MODE="dry-run"   # default to dry-run for safety

while [[ $# -gt 0 ]]; do
    case "$1" in
        --days)
            DAYS="$2"
            shift 2
            ;;
        --dry-run)
            MODE="dry-run"
            shift
            ;;
        --apply)
            MODE="apply"
            shift
            ;;
        -h|--help)
            sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "[backfill] ERROR: unknown flag: $1" >&2
            exit 1
            ;;
    esac
done

# Tool checks.
if ! command -v gh >/dev/null 2>&1; then
    echo "[backfill] ERROR: gh CLI not in PATH" >&2
    exit 2
fi
if ! command -v chump >/dev/null 2>&1; then
    echo "[backfill] ERROR: chump CLI not in PATH" >&2
    exit 2
fi

# Compute the since-date for gh search.
case "$(uname)" in
    Darwin) since_date=$(date -v "-${DAYS}d" +%Y-%m-%d) ;;
    *)      since_date=$(date -d "${DAYS} days ago" +%Y-%m-%d) ;;
esac

echo "[backfill] mode=$MODE  window=last $DAYS days (since $since_date)"

# CREDIBLE-1553 (Phase R R2): resolve the gap(s) each merged PR closes from
# the typed gap_prs FK (`chump gap gaps-for-pr <pr>`), NEVER from the PR title.
echo "[backfill] querying merged PRs since $since_date …"
merged_prs_json=$(
    gh pr list \
        --state merged \
        --limit 1000 \
        --json number,mergedAt \
    || { echo "[backfill] ERROR: gh pr list failed" >&2; exit 2; }
)
merged_prs_json=$(
    echo "$merged_prs_json" | python3 -c "
import json, sys
from datetime import datetime
prs = json.load(sys.stdin)
cutoff = datetime.fromisoformat('${since_date}T00:00:00+00:00')
keep = [pr for pr in prs if pr.get('mergedAt') and datetime.fromisoformat(pr['mergedAt'].replace('Z','+00:00')) >= cutoff]
print(json.dumps(keep))
"
)

total_prs=0
matched=0
already_done=0
to_ship=0
shipped=0
skipped_unknown=0

while IFS= read -r pr_number; do
    [[ -z "$pr_number" ]] && continue
    total_prs=$((total_prs + 1))
    gap_ids="$(chump gap gaps-for-pr "$pr_number" 2>/dev/null | sort -u || true)"
    [[ -z "$gap_ids" ]] && continue
    for gap_id in $gap_ids; do
        matched=$((matched + 1))
        if ! gap_status=$(chump gap show "$gap_id" 2>/dev/null | awk '/^  status:/ {print $2; exit}'); then
            skipped_unknown=$((skipped_unknown + 1))
            continue
        fi
        if [[ -z "$gap_status" ]]; then
            skipped_unknown=$((skipped_unknown + 1))
            continue
        fi

        case "$gap_status" in
            done|superseded)
                already_done=$((already_done + 1))
                ;;
            open|*)
                to_ship=$((to_ship + 1))
                if [[ "$MODE" == "dry-run" ]]; then
                    echo "[backfill] WOULD ship $gap_id (closed_pr=$pr_number)"
                else
                    if CHUMP_GAP_SHIP_SKIP_STALE_CHECK=1 \
                            chump gap ship "$gap_id" --closed-pr "$pr_number" --update-yaml >/dev/null 2>&1; then
                        echo "[backfill] ✓ shipped $gap_id (closed_pr=$pr_number)"
                        shipped=$((shipped + 1))
                        ambient_log="${CHUMP_AMBIENT_LOG:-${REPO_ROOT}/.chump-locks/ambient.jsonl}"
                        printf '{"ts":"%s","kind":"gap_backfill_flipped","gap":"%s","pr":%s,"source":"backfill-shipped-gaps"}\n' \
                            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$gap_id" "$pr_number" >> "$ambient_log" 2>/dev/null || true
                    else
                        echo "[backfill] ⚠ failed to ship $gap_id — left as-is"
                    fi
                fi
                ;;
        esac
    done
done < <(echo "$merged_prs_json" | python3 -c '
import json, sys
for pr in json.load(sys.stdin):
    print(pr["number"])
')

cat <<SUMMARY

[backfill] === summary ===
[backfill]   PRs scanned:           $total_prs
[backfill]   matched gap-ID prefix: $matched
[backfill]   already done:          $already_done
[backfill]   skipped (gap unknown): $skipped_unknown
[backfill]   to ship:               $to_ship
SUMMARY

if [[ "$MODE" == "dry-run" ]]; then
    cat <<NOTE
[backfill]
[backfill] DRY-RUN mode. Re-run with --apply to actually flip the $to_ship gaps to done.
NOTE
else
    cat <<NOTE
[backfill]   shipped this run:     $shipped
NOTE
fi
