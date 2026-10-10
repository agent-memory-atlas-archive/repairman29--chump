#!/usr/bin/env bash
# chump-pr-triage.sh — INFRA-1409
#
# Prints a table of open PRs with the next mechanical action per row.
# Reads from the local SQLite cache (INFRA-1081) for speed; falls back
# to direct gh api on cache miss.
#
# Usage
#   scripts/coord/chump-pr-triage.sh [--mine] [--all] [--json]
#   scripts/coord/chump-pr-triage.sh --apply <pr> <action>
#
# Options
#   --mine        Filter to PRs authored by current GitHub user (default)
#   --all         Include all open PRs (no author filter)
#   --json        Emit newline-delimited JSON instead of table
#   --apply <pr> <action>
#                 Execute the recommended action for a PR.
#                 Actions: rebase | re-arm | ship-gap | close
#
# Recommended actions
#   rebase          PR is BEHIND main — call chump-rebase-and-push.sh
#   re-arm          Auto-merge not armed — re-run gh pr merge --auto
#   wait-ci         CI running — wait; armed PRs merge automatically
#   fix-ci          CI failed on this PR only — needs local investigation
#   wait-sibling    Same CI failure as a sibling gap in-flight — wait
#   ship-gap        PR merged — run chump gap ship <ID>
#   unknown         Cannot determine state without further gh calls
#
# Bypass: CHUMP_PR_TRIAGE=0 exits 0 immediately (useful in scripts).
#
# Rust-First-Bypass: read-only diagnostic glue over gh+cache+jq; no state
#   mutation; called on demand, not in hot path. Shell is appropriate.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
CACHE_LIB="$REPO_ROOT/scripts/coord/lib/github_cache.sh"
REBASE_SCRIPT="$REPO_ROOT/scripts/coord/chump-rebase-and-push.sh"

# ── Config ────────────────────────────────────────────────────────────────────
MINE=1          # default: filter to operator's PRs
OUTPUT="table"  # or "json"
APPLY_PR=""
APPLY_ACTION=""

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mine)  MINE=1; shift ;;
        --all)   MINE=0; shift ;;
        --json)  OUTPUT="json"; shift ;;
        --apply)
            APPLY_PR="$2"
            APPLY_ACTION="$3"
            shift 3
            ;;
        -h|--help)
            sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown flag: $1  (use --help)" >&2
            exit 2
            ;;
    esac
done

if [[ "${CHUMP_PR_TRIAGE:-1}" == "0" ]]; then
    exit 0
fi

# ── Helpers ───────────────────────────────────────────────────────────────────

# Determine GitHub login for --mine filtering.
OPERATOR_LOGIN=""
if [[ "$MINE" -eq 1 ]]; then
    OPERATOR_LOGIN="$(gh api user --jq '.login' 2>/dev/null || true)"
fi

# Load cache helpers if available (INFRA-1081).
if [[ -f "$CACHE_LIB" ]]; then
    # shellcheck source=/dev/null
    source "$CACHE_LIB" 2>/dev/null || true
fi

# Fetch open PRs. Returns tab-separated: number <TAB> title <TAB> head_ref <TAB> author
fetch_open_prs() {
    local author_filter=""
    [[ -n "$OPERATOR_LOGIN" ]] && author_filter="author:$OPERATOR_LOGIN"

    gh pr list \
        --repo repairman29/chump \
        --state open \
        ${author_filter:+--search "$author_filter"} \
        --json number,title,headRefName,author,mergeable,mergeStateStatus,autoMergeRequest \
        --limit 100 \
        2>/dev/null \
    | python3 -c "
import sys, json
prs = json.load(sys.stdin)
for p in prs:
    author = p.get('author', {}).get('login', '')
    armed  = '1' if p.get('autoMergeRequest') else '0'
    mss    = p.get('mergeStateStatus', 'UNKNOWN')
    print('\t'.join([str(p['number']), p.get('title',''), p.get('headRefName',''), author, mss, armed]))
"
}

# Extract gap ID from PR title (e.g. "INFRA-1403" or "PRODUCT-128").
extract_gap_id() {
    local title="$1"
    echo "$title" | grep -oE '[A-Z]+-[0-9]+' | head -1 || true
}

# Determine the sibling-gap that is working on the same topic (INFRA-1409 AC4).
# Cross-references .chump-locks/*.json against a failing check name.
sibling_for_check() {
    local check_name="$1"
    for lock in "$REPO_ROOT"/.chump-locks/claim-*.json; do
        [[ -f "$lock" ]] || continue
        gap_id="$(python3 -c "import sys,json; d=json.load(open('$lock')); print(d.get('gap_id',''))" 2>/dev/null || true)"
        [[ -z "$gap_id" ]] && continue
        # Rough heuristic: check if the gap title mentions the test name.
        title="$(chump gap show "$gap_id" 2>/dev/null | grep 'title:' | head -1 || true)"
        if echo "$title $gap_id" | grep -qiF "$check_name"; then
            echo "$gap_id"
            return
        fi
    done
}

# Map mergeStateStatus + armed flag to recommended action.
recommended_action() {
    local mss="$1" armed="$2"
    case "$mss" in
        BEHIND|DIRTY)
            # BEHIND = branch is behind base; DIRTY = GitHub's stale-merge-commit state
            echo "rebase"
            ;;
        BLOCKED)
            if [[ "$armed" == "0" ]]; then
                echo "re-arm"
            else
                echo "fix-ci"  # will refine below with check inspection
            fi
            ;;
        CLEAN)
            if [[ "$armed" == "0" ]]; then
                echo "re-arm"
            else
                echo "wait-ci"
            fi
            ;;
        UNKNOWN)
            echo "unknown"
            ;;
        *)
            echo "unknown ($mss)"
            ;;
    esac
}

# Remediation command string for the --apply dispatcher.
remediation_cmd() {
    local pr="$1" action="$2" gap_id="$3"
    case "$action" in
        rebase)
            if [[ -x "$REBASE_SCRIPT" ]]; then
                echo "bash $REBASE_SCRIPT --pr $pr"
            else
                echo "bash scripts/coord/lib/pr_rebase.sh $pr repairman29/chump main"
            fi
            ;;
        re-arm)
            echo "gh pr merge $pr --repo repairman29/chump --auto --squash"
            ;;
        ship-gap)
            if [[ -n "$gap_id" ]]; then
                echo "chump gap ship $gap_id"
            else
                echo "chump gap ship <gap-from-title>"
            fi
            ;;
        close)
            echo "gh pr close $pr --repo repairman29/chump"
            ;;
        wait-ci|fix-ci|unknown|*)
            echo "(no mechanical action — investigate manually)"
            ;;
    esac
}

# ── --apply mode ──────────────────────────────────────────────────────────────
if [[ -n "$APPLY_PR" && -n "$APPLY_ACTION" ]]; then
    gap_id="$(gh pr view "$APPLY_PR" --repo repairman29/chump --json title --jq '.title' 2>/dev/null \
        | { read -r t; extract_gap_id "$t"; })"
    cmd="$(remediation_cmd "$APPLY_PR" "$APPLY_ACTION" "$gap_id")"
    if [[ "$cmd" == "(no mechanical action"* ]]; then
        echo "[pr-triage] No mechanical action available for PR #$APPLY_PR action=$APPLY_ACTION." >&2
        echo "[pr-triage] Investigate CI output manually." >&2
        exit 1
    fi
    echo "[pr-triage] Applying: $cmd" >&2
    eval "$cmd"
    exit $?
fi

# ── Collect PR data ───────────────────────────────────────────────────────────
PR_DATA="$(fetch_open_prs)"

if [[ -z "$PR_DATA" ]]; then
    echo "[pr-triage] No open PRs found."
    exit 0
fi

# ── Build table / JSON ────────────────────────────────────────────────────────
# Column widths for table output.
COL_PR=5
COL_MSS=8
COL_ARMED=5
COL_ACTION=22
COL_TITLE=50

print_header() {
    printf "%-${COL_PR}s  %-${COL_MSS}s  %-${COL_ARMED}s  %-${COL_ACTION}s  %-${COL_TITLE}s\n" \
        "PR#" "STATE" "ARMED" "NEXT ACTION" "TITLE"
    printf '%s\n' "$(printf '─%.0s' {1..140})"
}

[[ "$OUTPUT" == "table" ]] && print_header

# shellcheck disable=SC2034  # head_ref and author read for future --apply context
while IFS=$'\t' read -r pr title head_ref author mss armed; do
    [[ -z "$pr" ]] && continue

    action="$(recommended_action "$mss" "$armed")"
    gap_id="$(extract_gap_id "$title")"

    # Refine fix-ci: check if a sibling is fixing the same thing.
    if [[ "$action" == "fix-ci" ]]; then
        # Quick check without gh pr checks (expensive) — use gap_id hint.
        if [[ -n "$gap_id" ]]; then
            sibling="$(sibling_for_check "$gap_id" 2>/dev/null || true)"
            if [[ -n "$sibling" ]]; then
                action="wait-sibling ($sibling)"
            fi
        fi
    fi

    cmd="$(remediation_cmd "$pr" "$action" "$gap_id")"
    short_title="${title:0:$COL_TITLE}"

    if [[ "$OUTPUT" == "json" ]]; then
        python3 -c "import json; print(json.dumps({'pr': $pr, 'title': $(python3 -c "import json; print(json.dumps('$title'))"), 'gap_id': '$gap_id', 'mss': '$mss', 'auto_merge_armed': $armed, 'action': '$action', 'remediation_cmd': '$cmd'}))"
    else
        printf "%-${COL_PR}s  %-${COL_MSS}s  %-${COL_ARMED}s  %-${COL_ACTION}s  %-${COL_TITLE}s\n" \
            "#$pr" "$mss" "$armed" "$action" "$short_title"
        if [[ "$cmd" != "(no mechanical action"* && "$action" != "wait-ci" ]]; then
            printf "%s  ↳ %s\n" "$(printf ' %.0s' {1..7})" "$cmd"
        fi
    fi
done <<< "$PR_DATA"

if [[ "$OUTPUT" == "table" ]]; then
    echo
    echo "Legend: STATE=mergeStateStatus  ARMED=1=auto-merge-enabled"
    echo "        Actions: rebase | re-arm | wait-ci | fix-ci | wait-sibling | unknown"
    echo "Run with --all for fleet-wide PRs (default: --mine)"
    echo "Apply:  $(basename "$0") --apply <PR#> <action>"
fi

# Emit ambient telemetry so fleet-brief + kpi-report can track triage calls (INFRA-755).
# kind=pr_triage_run — registered in docs/observability/EVENT_REGISTRY.yaml.
PR_COUNT="$(echo "$PR_DATA" | wc -l | tr -d ' ')"
_SCOPE="$([ "$MINE" -eq 1 ] && echo mine || echo all)"
_AMBIENT_EMIT="$REPO_ROOT/scripts/dev/ambient-emit.sh"
if [[ -x "$_AMBIENT_EMIT" ]]; then
    bash "$_AMBIENT_EMIT" pr_triage_run \
        scope="$_SCOPE" pr_count="$PR_COUNT" output="$OUTPUT" \
        2>/dev/null || true
fi
