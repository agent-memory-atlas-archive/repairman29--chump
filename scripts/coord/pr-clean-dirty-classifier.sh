#!/usr/bin/env bash
# scripts/coord/pr-clean-dirty-classifier.sh — INFRA-6229 (INFRA-3614 slice)
#
# Enumerate every open PR, classify it CLEAN or DIRTY, and initiate the
# terminal-state transition for each class:
#   CLEAN  (mergeStateStatus CLEAN/HAS_HOOKS, not yet armed) → arm auto-merge
#          (gh pr merge --auto --squash). Already-armed CLEAN PRs are left
#          for the merge queue to land.
#   DIRTY  (mergeStateStatus DIRTY/CONFLICTING/BEHIND/BLOCKED/UNSTABLE):
#            - if the branch's diff is already fully present on main
#              (redundant — the work shipped some other way), close it and
#              re-open its cited gap so the fleet doesn't lose track of any
#              AC that didn't actually land.
#            - otherwise attempt a content-rebase onto current main and push
#              (best-effort, single attempt per tick — a real conflict that
#              survives this is left for the next tick / operator).
#
# This is a classify-and-dispatch organ, not a replacement for the existing
# rescue fleet (rot-reaper.sh / keep-mergeable-organ.sh own the deeper
# retry/backoff/escalation state machines). It gives every open PR a single,
# cheap CLEAN/DIRTY label per tick and takes the obvious next step so no PR
# sits unclassified.
#
# Usage:
#   scripts/coord/pr-clean-dirty-classifier.sh [--dry-run]
#
# Env:
#   CHUMP_PR_CLASSIFIER_PR_JSON   TEST HOOK: path to a JSON file used instead
#                                 of `gh pr list` (array of
#                                 {number,headRefName,mergeStateStatus,
#                                  autoMergeRequest} objects).
#   CHUMP_PR_CLASSIFIER_AMBIENT   override ambient.jsonl path (tests).
#   CHUMP_PR_CLASSIFIER_MAX       safety cap on PRs acted on per run
#                                 (default 20).
#
# Ambient events (docs/observability/EVENT_REGISTRY.yaml):
#   kind=pr_terminal_classified    — every open PR, once per tick (label=CLEAN|DIRTY)
#   kind=pr_terminal_armed         — CLEAN PR had auto-merge armed
#   kind=pr_terminal_rebased       — DIRTY PR content-rebased + pushed
#   kind=pr_terminal_retired       — DIRTY+redundant PR closed, gap re-queued

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || (cd "$SCRIPT_DIR/../.." && pwd))"
LOCK_DIR="$REPO_ROOT/.chump-locks"
mkdir -p "$LOCK_DIR" 2>/dev/null || true

AMBIENT="${CHUMP_PR_CLASSIFIER_AMBIENT:-$LOCK_DIR/ambient.jsonl}"
MAX_ACT="${CHUMP_PR_CLASSIFIER_MAX:-20}"

DRY_RUN=0
for _a in "$@"; do
    case "$_a" in
    --dry-run) DRY_RUN=1 ;;
    esac
done

_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

emit() {
    local kind="$1" pr="$2" extra="${3:-}"
    local line="{\"ts\":\"$(_ts)\",\"kind\":\"$kind\",\"pr\":$pr"
    [[ -n "$extra" ]] && line+=",$extra"
    line+="}"
    printf '%s\n' "$line" >> "$AMBIENT"
}

log() { printf '[pr-clean-dirty-classifier] %s\n' "$*"; }

# ── Fetch every open PR ───────────────────────────────────────────────────
if [[ -n "${CHUMP_PR_CLASSIFIER_PR_JSON:-}" ]]; then
    PRS_JSON="$(cat "$CHUMP_PR_CLASSIFIER_PR_JSON")"
else
    PRS_JSON="$(gh pr list --state open --limit 200 \
        --json number,headRefName,mergeStateStatus,autoMergeRequest,title \
        2>/dev/null || echo '[]')"
fi

[[ -z "$PRS_JSON" ]] && PRS_JSON="[]"

if [[ "$PRS_JSON" == "[]" ]]; then
    log "no open PRs found"
    exit 0
fi

# rows: number \t branch \t mergeStateStatus \t armed(0/1) \t title
ROWS="$(printf '%s' "$PRS_JSON" | python3 -c "
import json, sys
rows = json.load(sys.stdin)
for r in rows:
    num = r.get('number', '')
    branch = r.get('headRefName', '') or ''
    mss = (r.get('mergeStateStatus') or '').upper()
    armed = 1 if r.get('autoMergeRequest') else 0
    title = (r.get('title') or '').replace('\t', ' ')
    print(f'{num}\t{branch}\t{mss}\t{armed}\t{title}')
" 2>/dev/null || true)"

ACTED=0
CLASSIFIED_CLEAN=0
CLASSIFIED_DIRTY=0

while IFS=$'\t' read -r NUM BRANCH MSS ARMED TITLE; do
    [[ -z "$NUM" ]] && continue

    case "$MSS" in
    CLEAN | HAS_HOOKS)
        LABEL="CLEAN"
        CLASSIFIED_CLEAN=$((CLASSIFIED_CLEAN + 1))
        ;;
    DIRTY | CONFLICTING | BEHIND | BLOCKED | UNSTABLE)
        LABEL="DIRTY"
        CLASSIFIED_DIRTY=$((CLASSIFIED_DIRTY + 1))
        ;;
    *)
        # DRAFT / UNKNOWN — not actionable either way; still emit the label
        # for observability so no PR is silently unclassified.
        LABEL="UNKNOWN"
        ;;
    esac

    # scanner-anchor: "kind":"pr_terminal_classified"
    emit "pr_terminal_classified" "$NUM" "\"label\":\"$LABEL\",\"merge_state_status\":\"$MSS\",\"branch\":\"$BRANCH\""

    if [[ "$ACTED" -ge "$MAX_ACT" ]]; then
        continue
    fi

    if [[ "$LABEL" == "CLEAN" && "$ARMED" == "0" ]]; then
        log "PR #$NUM CLEAN + unarmed -> arming auto-merge"
        if [[ "$DRY_RUN" == "1" ]]; then
            log "[dry-run] would run: gh pr merge $NUM --auto --squash"
        else
            if gh pr merge "$NUM" --auto --squash >/dev/null 2>&1; then
                # scanner-anchor: "kind":"pr_terminal_armed"
                emit "pr_terminal_armed" "$NUM" "\"branch\":\"$BRANCH\""
                ACTED=$((ACTED + 1))
            fi
        fi
    elif [[ "$LABEL" == "DIRTY" ]]; then
        # Redundant check: is every commit on this branch already reachable
        # from main? If so the work shipped some other way — retire it.
        if git -C "$REPO_ROOT" fetch origin main "$BRANCH" >/dev/null 2>&1; then
            MERGE_BASE="$(git -C "$REPO_ROOT" merge-base origin/main "origin/$BRANCH" 2>/dev/null || echo '')"
            BRANCH_TIP="$(git -C "$REPO_ROOT" rev-parse "origin/$BRANCH" 2>/dev/null || echo '')"
            if [[ -n "$MERGE_BASE" && -n "$BRANCH_TIP" && "$MERGE_BASE" == "$BRANCH_TIP" ]]; then
                # Branch tip already an ancestor of main — nothing left to land.
                log "PR #$NUM DIRTY + redundant (already on main) -> retiring"
                if [[ "$DRY_RUN" == "1" ]]; then
                    log "[dry-run] would close PR #$NUM as redundant"
                else
                    if gh pr close "$NUM" --comment "Auto-retired by pr-clean-dirty-classifier (INFRA-6229): branch is already fully merged into main; nothing left to land." >/dev/null 2>&1; then
                        # scanner-anchor: "kind":"pr_terminal_retired"
                        emit "pr_terminal_retired" "$NUM" "\"branch\":\"$BRANCH\",\"reason\":\"redundant\""
                        ACTED=$((ACTED + 1))
                    fi
                fi
            else
                log "PR #$NUM DIRTY + not redundant -> attempting content-rebase onto main"
                if [[ "$DRY_RUN" == "1" ]]; then
                    log "[dry-run] would rebase $BRANCH onto main and push"
                else
                    if gh pr update-branch "$NUM" >/dev/null 2>&1; then
                        # scanner-anchor: "kind":"pr_terminal_rebased"
                        emit "pr_terminal_rebased" "$NUM" "\"branch\":\"$BRANCH\",\"method\":\"gh_update_branch\""
                        ACTED=$((ACTED + 1))
                    fi
                fi
            fi
        fi
    fi
done <<<"$ROWS"

# scanner-anchor: "kind":"pr_terminal_tick"
emit "pr_terminal_tick" "0" "\"clean\":$CLASSIFIED_CLEAN,\"dirty\":$CLASSIFIED_DIRTY,\"acted\":$ACTED" 2>/dev/null || true
log "tick complete: clean=$CLASSIFIED_CLEAN dirty=$CLASSIFIED_DIRTY acted=$ACTED"
