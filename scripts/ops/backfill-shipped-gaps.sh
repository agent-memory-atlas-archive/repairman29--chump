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

# Gap-ID regex — a bare "<GAP-ID>: …" title prefix means "this PR SHIPS this gap"
# and is the only form that closes a gap. A conventional-commit scope like
# "fix(INFRA-8112): …" REFERENCES the gap without closing it (see
# check-gap-status-flip.sh §convention + INFRA-066) — e.g. a PR that unblocks a
# gap's ship but does not implement it. This regex MUST require the bare
# "<DOMAIN>-<NUM>:" prefix so it matches check-gap-status-flip.sh:34 and
# gap-doctor-reconcile.py:576 exactly. The old permissive form
# ^([a-z]+\()?(DOMAIN)-([0-9]+) stripped the "fix(" and false-closed any gap
# merely named in a fix(X:) title — it closed INFRA-8112 off PR #5317, a
# clippy-classifier fix that never implemented the toolkit.
GAP_ID_REGEX='^(INFRA|EFFECTIVE|RESILIENT|DOC|META|MISSION|CREDIBLE)-([0-9]+):'

# Query the merged PRs via `gh pr list --state merged`.
# gh search prs lacks `mergedAt`; gh pr list returns it cleanly. --limit 1000
# covers >90d of typical merge volume. Post-process to drop PRs older than
# since_date (gh pr list sorts newest-first by default).
echo "[backfill] querying merged PRs since $since_date …"
merged_prs_json=$(
    gh pr list \
        --state merged \
        --limit 1000 \
        --json number,title,mergedAt \
    || { echo "[backfill] ERROR: gh pr list failed" >&2; exit 2; }
)
# Filter to since_date in Python (date arithmetic in bash is fragile).
merged_prs_json=$(
    echo "$merged_prs_json" | python3 -c "
import json, sys
from datetime import datetime, timezone
prs = json.load(sys.stdin)
cutoff = datetime.fromisoformat('${since_date}T00:00:00+00:00')
keep = [pr for pr in prs if pr.get('mergedAt') and datetime.fromisoformat(pr['mergedAt'].replace('Z','+00:00')) >= cutoff]
print(json.dumps(keep))
"
)

# Iterate. For each PR, extract gap-ID. If extraction succeeds AND the gap
# is currently status:open, schedule the ship.
total_prs=0
matched=0
already_done=0
to_ship=0
shipped=0
skipped_unknown=0

# Process substitution avoids the pipefail-into-while subshell bug
# (CLAUDE_GOTCHAS — INFRA-1658 / RESILIENT-031 pattern).
while IFS=$'\t' read -r pr_number pr_title; do
    total_prs=$((total_prs + 1))
    # Bash regex: build inside the [[ ]] guard.
    # Only a bare "<GAP-ID>: …" prefix closes (ships) the gap; "fix(X:) …" is a
    # reference, not a close (see GAP_ID_REGEX note above). This prevents the
    # false-close of a gap merely named in an enabler PR's scope.
    if [[ "$pr_title" =~ ^(INFRA|EFFECTIVE|RESILIENT|DOC|META|MISSION|CREDIBLE)-([0-9]+): ]]; then
        domain="${BASH_REMATCH[1]}"
        num="${BASH_REMATCH[2]}"
        gap_id="${domain}-${num}"
        matched=$((matched + 1))

        # Check current status. `chump gap show` exits non-zero if the gap
        # does not exist; we count that as "skipped-unknown" rather than
        # failing the backfill.
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
                    echo "[backfill] WOULD ship $gap_id (closed_pr=$pr_number)  title='${pr_title:0:60}'"
                else
                    if CHUMP_GAP_SHIP_SKIP_STALE_CHECK=1 \
                            chump gap ship "$gap_id" --closed-pr "$pr_number" --update-yaml >/dev/null 2>&1; then
                        echo "[backfill] ✓ shipped $gap_id (closed_pr=$pr_number)"
                        shipped=$((shipped + 1))
                        # INFRA-755: structured ambient emit so the operator
                        # can audit which gaps were backfill-flipped.
                        ambient_log="${CHUMP_AMBIENT_LOG:-${REPO_ROOT}/.chump-locks/ambient.jsonl}"
                        printf '{"ts":"%s","kind":"gap_backfill_flipped","gap":"%s","pr":%s,"source":"backfill-shipped-gaps"}\n' \
                            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$gap_id" "$pr_number" >> "$ambient_log" 2>/dev/null || true
                    else
                        echo "[backfill] ⚠ failed to ship $gap_id — left as-is"
                    fi
                fi
                ;;
        esac
    fi
done < <(echo "$merged_prs_json" | python3 -c '
import json, sys
prs = json.load(sys.stdin)
for pr in prs:
    n = pr["number"]
    t = pr["title"]
    print(str(n) + "\t" + t)
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
