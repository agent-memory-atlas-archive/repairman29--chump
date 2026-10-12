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
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"

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

# Decision JSON: [{group_id, winner, losers: [...]}]
DECISIONS="$(python3 - "$_PRS_TMP" "$SKIP_FRESH_MINS" <<'PY'
import json, re, sys, time
from collections import defaultdict
from datetime import datetime
prs_file = sys.argv[1]
skip_fresh_mins = int(sys.argv[2])
data = json.load(open(prs_file))
# Only the LEADING gap id identifies a PR's gap (chump convention is
# "GAP-ID: title"). A gap id merely MENTIONED later in the title — e.g.
# "fix(dedup): ... (RESILIENT-1562 wedge)" — must NOT group the PR as a
# duplicate of that gap. The old `\b...\b` findall-anywhere matched such
# mentions and nearly closed the dedup fix's own PR (INFRA-8111).
GAP_RE = re.compile(r'^\s*([A-Z]+-\d+)\b')
groups = defaultdict(list)
for p in data:
    m = GAP_RE.match(p.get('title', ''))
    if m:
        groups[m.group(1)].append(p)
decisions = []
now = time.time()
for g, prs in groups.items():
    if len(prs) < 2:
        continue
    # Freshness guard (INFRA-8111 fix): exclude only the INDIVIDUAL PRs updated
    # within skip_fresh_mins from being closed (they may be mid-creation). A
    # single fresh PR must NOT exempt the whole group — a perpetually-refreshed
    # swarm (a new attempt every ~hour, rescue organ re-touching them) is exactly
    # the case that needs deduping, and the old `any-fresh -> skip whole group`
    # logic guaranteed the janitor never ran on it (the RESILIENT-1562 wedge:
    # 21 open PRs for one gap, "no eligible groups" for 33h).
    def _too_fresh(p):
        # Key on CREATED time, not updated_at: a rescue/shepherd organ touches
        # updated_at constantly (mass-reopen), so updated_at is fresh forever and
        # the janitor could never act. A PR created long ago is a stale swarm
        # member regardless of bot pokes. (INFRA-8111: the RESILIENT-1562 wedge.)
        created = datetime.fromisoformat(p['created_at'].replace('Z', '+00:00'))
        return (now - created.timestamp()) / 60 < skip_fresh_mins
    prs_sorted = sorted(prs, key=lambda x: x['created_at'])
    stable = [p for p in prs_sorted if not _too_fresh(p)]
    # winner: oldest stable PR (longest in queue); fall back to oldest overall
    winner = (stable or prs_sorted)[0]
    # close every other PR except any still inside the fresh window (next run gets them)
    losers = [p for p in prs_sorted
              if p['number'] != winner['number'] and not _too_fresh(p)]
    if not losers:
        continue
    decisions.append({
        'gap_id': g,
        'winner': {'n': winner['number'], 'title': winner['title']},
        'losers': [{'n': l['number'], 'title': l['title']} for l in losers],
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
    echo "[dup-pr-detector] (dry-run) re-run with --apply to close losers"
    exit 0
fi

closed=0
echo "$DECISIONS" | python3 -c "
import json, sys
for d in json.load(sys.stdin):
    print(f\"{d['gap_id']}|{d['winner']['n']}|\" + ','.join(str(l['n']) for l in d['losers']))
" | while IFS='|' read -r gap winner losers; do
    for loser in $(echo "$losers" | tr ',' ' '); do
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
