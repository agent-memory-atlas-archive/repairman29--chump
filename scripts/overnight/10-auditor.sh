#!/usr/bin/env bash
# scripts/overnight/10-auditor.sh — nightly repo failure-detection auditor
# (INFRA-087).
#
# Runs every check under scripts/audit/auditor-checks/, files findings via
# `chump gap reserve` (deduped against existing AUDITOR_KEY markers), then opens
# a single review PR with the docs/gaps.yaml diff. (INFRA-8193: .chump/state.sql
# is no longer tracked, so it is no longer regenerated or committed here.)
#
# Operates in a *throwaway worktree* under /tmp so the user's main checkout is
# never mutated. The state.db is shared across worktrees, so gaps file
# correctly into canonical storage regardless.
#
# To disable temporarily: rename to 10-auditor.sh.disabled.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { printf '[%s] auditor: %s\n' "$(ts)" "$*"; }

# Skip if explicitly disabled.
if [ -n "${CHUMP_AUDITOR_SKIP:-}" ]; then
    log "CHUMP_AUDITOR_SKIP set — exiting"; exit 0
fi

DATE="$(date -u +%Y%m%d)"
BRANCH="auditor/findings-${DATE}"
WORK_PARENT="$(mktemp -d)"
WORK="$WORK_PARENT/audit-worktree"
trap 'cd "$REPO" 2>/dev/null; git worktree remove --force "$WORK" 2>/dev/null || true; rm -rf "$WORK_PARENT" 2>/dev/null || true' EXIT

log "creating throwaway worktree at $WORK"
git fetch origin main --quiet 2>/dev/null || true

# Reuse the day's branch if it already exists on origin (idempotent within a day);
# otherwise create from origin/main.
if git ls-remote --heads origin "$BRANCH" 2>/dev/null | grep -q .; then
    git worktree add "$WORK" -B "$BRANCH" "origin/$BRANCH" 2>/dev/null || \
      git worktree add "$WORK" "$BRANCH"
else
    git worktree add "$WORK" -B "$BRANCH" origin/main
fi

cd "$WORK"

log "running auditor checks"
OUT_FILE="$(scripts/audit/run-auditor.sh)"
COUNT="$(wc -l <"$OUT_FILE" | awk '{print $1}')"
log "auditor emitted $COUNT raw findings"

if [ "$COUNT" -eq 0 ]; then
    log "no findings; exiting clean"
    exit 0
fi

log "filing findings (dedup against existing AUDITOR_KEY markers)"
scripts/audit/file-findings.sh --in "$OUT_FILE"

# Regenerate canonical mirrors after filings.
chump gap dump --out docs/gaps.yaml >/dev/null 2>&1 || true

if git diff --quiet -- docs/gaps.yaml; then
    log "no gap mirror changes — nothing to commit"
    exit 0
fi

log "committing changes on $BRANCH"
git config user.email 'auditor@chump.bot'
git config user.name 'Repo Auditor'
git add docs/gaps.yaml
git commit -m "chore(auditor): nightly findings $(date -u +%FT%TZ)

Filed by scripts/overnight/10-auditor.sh (INFRA-087). Each new gap row carries
an AUDITOR_KEY=<key> line in its description for dedup on subsequent runs.
Reviewer: skim, re-prioritise, merge or close.
"

log "pushing $BRANCH"
CHUMP_GAP_CHECK=0 git push origin "$BRANCH" 2>&1 | tail -5

if ! gh pr view "$BRANCH" >/dev/null 2>&1; then
    log "creating PR"
    gh pr create --base main --head "$BRANCH" \
      --title "chore(auditor): nightly findings ($(date -u +%Y-%m-%d))" \
      --body "Automated by \`scripts/overnight/10-auditor.sh\` (INFRA-087).

Each filed gap has \`AUDITOR_KEY=<key>\` in its description so subsequent runs
are idempotent. Findings hitting 5+ strikes auto-escalate from P2 to P1.

**Reviewer checklist:**
- Skim filed gaps; re-prioritise any that warrant P0/P1 immediately
- Close any false positives (will reappear if the underlying check still flags it)
- Merge to land the new gap rows

If you want to silence a finding permanently, edit the source check under
\`scripts/audit/auditor-checks/\` to exclude that case." 2>&1 | tail -2
    gh pr edit --add-label "auditor-findings" 2>/dev/null || true
fi

log "done"
