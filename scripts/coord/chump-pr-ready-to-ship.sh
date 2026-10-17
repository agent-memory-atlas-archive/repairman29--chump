#!/usr/bin/env bash
# scripts/coord/chump-pr-ready-to-ship.sh — INFRA-2309
#
# Lists all open PRs with mergeStateStatus=CLEAN (passed QA, no merge conflicts,
# CI green) so the operator can see exactly what's ready to ship at a glance.
#
# Usage:
#   bash scripts/coord/chump-pr-ready-to-ship.sh          # table view
#   bash scripts/coord/chump-pr-ready-to-ship.sh --json   # raw JSON
#   bash scripts/coord/chump-pr-ready-to-ship.sh --arm    # arm auto-merge on all CLEAN PRs
#
# Env:
#   CHUMP_READY_TO_SHIP_LIMIT   max PRs to scan (default 200)

set -euo pipefail

# RESILIENT-1613: one arm policy — honor `no-auto-merge` / `Auto-merge: hold`.
# shellcheck source=scripts/coord/lib/arm-policy.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/arm-policy.sh"

LIMIT="${CHUMP_READY_TO_SHIP_LIMIT:-200}"
MODE="${1:-}"

_fetch_prs() {
  gh pr list --state open --limit "$LIMIT" \
    --json number,title,mergeStateStatus,autoMergeRequest,createdAt,author,headRefName \
    2>/dev/null
}

_print_table() {
  local prs_json="$1"
  printf "%-6s  %-10s  %-10s  %-11s  %s\n" "PR" "OPENED" "FIX-CLASS" "AUTO-MERGE" "TITLE"
  printf "%-6s  %-10s  %-10s  %-11s  %s\n" "------" "----------" "----------" "-----------" "--------------------------------------------------------------"

  python3 - <<PYEOF
import json, sys
from datetime import datetime, timezone

prs = json.loads("""$prs_json""")
clean = [p for p in prs if p.get('mergeStateStatus') == 'CLEAN']

if not clean:
    print("  (no CLEAN PRs found)")
    sys.exit(0)

for p in clean:
    pr_num   = p['number']
    title    = p.get('title', '')
    created  = p.get('createdAt', '')[:10]  # YYYY-MM-DD
    fix_cls  = title.split('(')[0] if '(' in title else title[:10]
    auto_mg  = 'armed' if p.get('autoMergeRequest') is not None else 'off'
    trunc    = title[:62] + ('...' if len(title) > 62 else '')
    print(f"#{pr_num:<5}  {created:<10}  {fix_cls:<10}  {auto_mg:<11}  {trunc}")
PYEOF
}

_print_json() {
  local prs_json="$1"
  python3 - <<PYEOF
import json, sys
prs = json.loads("""$prs_json""")
clean = [p for p in prs if p.get('mergeStateStatus') == 'CLEAN']
print(json.dumps(clean, indent=2))
PYEOF
}

_arm_all() {
  local prs_json="$1"
  local armed=0 already=0 failed=0

  while IFS=$'\t' read -r pr title auto_merge; do
    [[ -z "$pr" ]] && continue
    if [[ "$auto_merge" != "null" && -n "$auto_merge" ]]; then
      echo "  PR #${pr} already armed — skipping: ${title}" >&2
      already=$((already + 1))
      continue
    fi
    if ! arm_policy_allows "$pr" "chump-pr-ready-to-ship.sh"; then
      echo "  PR #${pr} held (no-auto-merge / Auto-merge: hold) — skipping: ${title}" >&2
      continue
    fi
    if gh pr merge "$pr" --auto --squash >/dev/null 2>&1; then
      echo "  armed PR #${pr}: ${title}" >&2
      armed=$((armed + 1))
    else
      echo "  WARN: failed to arm PR #${pr}: ${title}" >&2
      failed=$((failed + 1))
    fi
  done < <(python3 - <<PYEOF
import json, sys
prs = json.loads("""$prs_json""")
for p in prs:
    if p.get('mergeStateStatus') != 'CLEAN':
        continue
    auto_mg = str(p.get('autoMergeRequest') or 'null')
    title_safe = p.get('title','').replace('\t',' ')
    print(f"{p['number']}\t{title_safe}\t{auto_mg}")
PYEOF
)

  echo ""
  echo "Result: armed=${armed} already-armed=${already} failed=${failed}" >&2
}

prs_json=$(_fetch_prs)

if [[ -z "$prs_json" || "$prs_json" = "[]" ]]; then
  echo "No open PRs found." >&2
  exit 0
fi

case "$MODE" in
  --json)
    _print_json "$prs_json"
    ;;
  --arm)
    echo "Arming auto-merge on all CLEAN PRs..."
    _arm_all "$prs_json"
    ;;
  *)
    _print_table "$prs_json"
    ;;
esac
