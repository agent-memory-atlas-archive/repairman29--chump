#!/usr/bin/env bash
# scripts/coord/duplicate-pr-detector.sh — INFRA-1222
#
# Backstop. INFRA-1219 (pr-create dedup gate) catches the 80% case at PR
# open time; this scanner catches the residual: cases where two PRs for
# the same gap ID slipped past the gate (bypass used, race window beat
# the check, gap ID retitled after open, etc.).
#
# Strategy: group open PRs by gap ID; when 2+ PRs share a gap, keep the
# one with the most-recent green CI (or oldest if none have green CI yet)
# and close the others with an explanatory comment.
#
# Usage:
#   duplicate-pr-detector.sh             # dry-run
#   duplicate-pr-detector.sh --apply     # actually close losers
#   duplicate-pr-detector.sh --skip-fresh-mins 10
#     # don't act on PRs younger than N min (lets CI complete + arming finish)
#
# Cron-friendly. Emits kind=duplicate_pr_closed ambient events.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${CHUMP_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd -P)}"

APPLY=0
SKIP_FRESH_MINS=15
while [ $# -gt 0 ]; do
    case "$1" in
        --apply) APPLY=1; shift ;;
        --skip-fresh-mins) SKIP_FRESH_MINS="$2"; shift 2 ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "[dup-pr-detector] unknown arg: $1" >&2; exit 2 ;;
    esac
done

command -v gh >/dev/null 2>&1 || { echo "[dup-pr-detector] gh missing; skip" >&2; exit 0; }

repo="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)"
[ -z "$repo" ] && { echo "[dup-pr-detector] no repo nwo; skip" >&2; exit 1; }

# Pull all open PRs.
_PRS_TMP="$(mktemp)"
trap 'rm -f "$_PRS_TMP"' EXIT
gh api "repos/$repo/pulls?state=open&per_page=100" > "$_PRS_TMP" 2>/dev/null
[ ! -s "$_PRS_TMP" ] && { echo "[dup-pr-detector] empty PR list"; exit 0; }

# Group by gap ID (extracted from title). For each group ≥ 2, compute the
# "winner" PR: prefer most-recent green CI; else oldest (longest in queue
# is more likely to be the legitimate primary).
ambient="$REPO_ROOT/.chump-locks/ambient.jsonl"

# Decision JSON: [{gap_id, winner, losers: [...], close_losers: [...]}]
DECISIONS="$(python3 - "$_PRS_TMP" "$SKIP_FRESH_MINS" <<'PY'
import json, re, sys, time
from collections import defaultdict
from datetime import datetime
prs_file = sys.argv[1]
skip_fresh_mins = int(sys.argv[2])
data = json.load(open(prs_file))
# INFRA-8640: extract primary gap IDs from:
#   1) leading "GAP-ID: ..."
#   2) conventional commit scope "type(GAP-ID,...): ..."
#   3) trailing parenthesized gap list "... (GAP-ID, META-196)" (excluding "wedge" notes)
#   4) head branch ref "chump/<gap-id>-*", "fix/<GAP-ID>-*", "feat/<GAP-ID>-*", "claude/<gap-id>-*"
LEAD_RE = re.compile(r'^\s*([A-Z]+-\d+)\b')
CONV_RE = re.compile(r'^\s*[a-z]+\(([A-Z]+-\d+(?:,[A-Z]+-\d+)*)\):')
TRAIL_RE = re.compile(r'\(([A-Z]+-\d+(?:,\s*[A-Z]+-\d+)*)\)\s*(?:#\d+\s*)?$')
BRANCH_RE = re.compile(r'^(?:chump|fix|feat|claude)/([A-Za-z]+-\d+)\b')

groups = defaultdict(list)
for p in data:
    title = p.get('title', '') or ''
    if 'dup-detector-skip' in title.lower() or title.lower().startswith('fix(dedup)'):
        continue
    gids = []
    m = LEAD_RE.match(title)
    if m:
        gids.append(m.group(1))
    mc = CONV_RE.match(title)
    if mc:
        for tok in mc.group(1).split(','):
            tok = tok.strip()
            if tok and tok not in gids:
                gids.append(tok)
    mt = TRAIL_RE.search(title)
    if mt:
        for tok in mt.group(1).split(','):
            tok = tok.strip()
            if tok and tok not in gids:
                gids.append(tok)
    head_ref = ((p.get('head') or {}).get('ref') or p.get('headRefName') or '').strip()
    mb = BRANCH_RE.match(head_ref)
    if mb:
        btok = mb.group(1).upper()
        if btok not in gids:
            gids.append(btok)
    for gid in gids:
        groups[gid].append(p)

decisions = []
now = time.time()
for g, prs in groups.items():
    by_num = {p['number']: p for p in prs if 'number' in p}
    if len(by_num) < 2:
        continue
    prs_unique = list(by_num.values())
    def _too_fresh(p):
        created = datetime.fromisoformat(p['created_at'].replace('Z', '+00:00'))
        return (now - created.timestamp()) / 60 < skip_fresh_mins
    prs_sorted = sorted(prs_unique, key=lambda x: (x.get('created_at') or '', x.get('number') or 0))
    stable = [p for p in prs_sorted if not _too_fresh(p)]
    winner = (stable or prs_sorted)[0]
    # INFRA-8640 (AC2): flag and hold EVERY second/later open PR within one tick
    # (even inside skip_fresh_mins), while only auto-closing PRs older than skip_fresh_mins.
    hold_losers = [p for p in prs_sorted if p['number'] != winner['number']]
    close_losers = [p for p in hold_losers if not _too_fresh(p)]
    if not hold_losers:
        continue
    decisions.append({
        'gap_id': g,
        'winner': {'n': winner['number'], 'title': winner.get('title', '')},
        'losers': [{'n': l['number'], 'title': l.get('title', '')} for l in hold_losers],
        'close_losers': [{'n': l['number'], 'title': l.get('title', '')} for l in close_losers],
    })
print(json.dumps(decisions))
PY
)"

count=$(echo "$DECISIONS" | python3 -c "import json, sys; print(len(json.load(sys.stdin)))")
if [ "$count" = "0" ]; then
    echo "[dup-pr-detector] no duplicate groups eligible"
    exit 0
fi

echo "[dup-pr-detector] found $count duplicate group(s)"
echo "$DECISIONS" | python3 -c "
import json, sys
for d in json.load(sys.stdin):
    print(f\"  {d['gap_id']}: WINNER #{d['winner']['n']} -- {d['winner']['title'][:50]}\")
    for l in d['losers']:
        print(f\"    LOSER #{l['n']} -- {l['title'][:50]}\")
"

if [ "$APPLY" = "0" ]; then
    echo "[dup-pr-detector] (dry-run) re-run with --apply to hold/close losers"
    exit 0
fi

mkdir -p "$(dirname "$ambient")" 2>/dev/null || true
closed=0
echo "$DECISIONS" | python3 -c "
import json, sys
for d in json.load(sys.stdin):
    hold_csv = ','.join(str(l['n']) for l in d.get('losers', []))
    close_csv = ','.join(str(l['n']) for l in d.get('close_losers', []))
    print(f\"{d['gap_id']}|{d['winner']['n']}|{hold_csv}|{close_csv}\")
" | while IFS='|' read -r gap winner hold_losers close_losers; do
    # INFRA-8640 (AC2): hold every later duplicate PR within one tick
    # MUTANT_ANCHOR_DUP_PR_HOLD
    if true; then # MUTANT_ANCHOR_DUP_PR_HOLD
        for loser in $(echo "$hold_losers" | tr ',' ' '); do
            [ -z "$loser" ] && continue
            hold_msg="[dup-pr-detector] Holding duplicate PR #$loser (review-held): gap $gap already has earlier open PR #$winner (INFRA-8640)."
            gh api -X POST "repos/$repo/issues/$loser/labels" -f "labels[]=review-held" >/dev/null 2>&1 || true
            gh api -X POST "repos/$repo/issues/$loser/comments" -f body="$hold_msg" >/dev/null 2>&1 || true
            echo "  held #$loser ($gap -> primary #$winner)"
            # scanner-anchor: "kind":"duplicate_pr_held"
            printf '{"ts":"%s","kind":"duplicate_pr_held","gap":"%s","loser":%s,"winner":%s,"source":"duplicate-pr-detector"}\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$gap" "$loser" "$winner" \
                >> "$ambient" 2>/dev/null || true
        done
    fi
    for loser in $(echo "$close_losers" | tr ',' ' '); do
        [ -z "$loser" ] && continue
        msg="Auto-closing as duplicate: gap $gap also has open PR #$winner (older / primary).
Filed by INFRA-1222 duplicate-pr-detector. If this is wrong, reopen and add 'dup-detector-skip' to the title."
        if gh api -X POST "repos/$repo/issues/$loser/comments" -f body="$msg" >/dev/null 2>&1; then
            if gh api -X PATCH "repos/$repo/pulls/$loser" -f state=closed >/dev/null 2>&1; then
                echo "  closed #$loser ($gap -> kept #$winner)"
                printf '{"ts":"%s","kind":"duplicate_pr_closed","gap":"%s","loser":%s,"winner":%s,"source":"duplicate-pr-detector"}\n' \
                    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$gap" "$loser" "$winner" \
                    >> "$ambient" 2>/dev/null || true
                closed=$((closed + 1))
            fi
        fi
    done
done

echo "[dup-pr-detector] done"
exit 0
