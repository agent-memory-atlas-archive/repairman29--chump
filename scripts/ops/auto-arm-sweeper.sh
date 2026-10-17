#!/usr/bin/env bash
# scripts/ops/auto-arm-sweeper.sh — INFRA-374
#
# Arm auto-merge on any OPEN PR that lost (or never got) its auto-merge
# state. Caught all night 2026-05-02/03: bot-merge.sh's INFRA-154
# auto-close step occasionally fails between gh pr create and the arm
# step, leaving PRs OPEN-but-unarmed. They sit until manually noticed
# and someone runs `gh pr merge <N> --auto --squash`.
#
# This sweeper finds them and arms them automatically. Safety guards:
#   - Only arms PRs authored by the current user (gh auth user)
#   - Only arms NON-DRAFT PRs
#   - Only arms PRs whose title doesn't contain WIP/wip/[skip]/[hold]
#   - Skips PRs that are MERGEABLE=CONFLICTING (DIRTY) — those need rebase
#     first, not arming
#   - INFRA-8047: skips PRs labelled `hold` or `do-not-merge` (the one
#     documented way to hold a PR — see docs/process/OPERATOR_RUNBOOK.md)
#   - INFRA-8047: respects a human disarm. The sweeper remembers each PR it
#     saw armed (PR number + head SHA). If that PR later shows up unarmed on
#     the same head SHA, someone disabled auto-merge: record who, and do not
#     re-arm until the head SHA changes (a new push = a new green event) and
#     no hold label is present.
#   - INFRA-8178: a disarm is only treated as human if the timeline actor is
#     NOT the automation login AND the disarm didn't land within
#     CHUMP_AUTOARM_DISARM_WINDOW_S seconds of a failed required check on
#     the same head — GitHub attributes auto_merge_disabled to whoever
#     ENABLED auto-merge (almost always the automation login) whenever a
#     required check fails after arming, which the sweeper was previously
#     misreading as a permanent human hold (see scripts/ops/lib/
#     disarm-classify.sh). A gate-triggered disarm re-arms once green.
#   - Logs every arm action so it's auditable
#
# Recommended cron: every 10 min via launchd. Idempotent — already-armed
# PRs are skipped.
#
# Usage:
#   bash scripts/ops/auto-arm-sweeper.sh             # apply
#   bash scripts/ops/auto-arm-sweeper.sh --dry-run   # report only
#
# Bypass: CHUMP_AUTOARM_SKIP=1 (cron-side global off-switch).

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# INFRA-1081/INFRA-1274: route gh reads through the throttled cache-first
# wrapper rather than calling the gh CLI raw in a hot path. Falls back to a
# bare passthrough if the lib can't be sourced.
# shellcheck source=/dev/null
source "${REPO_ROOT}/scripts/coord/lib/github.sh" 2>/dev/null || true
command -v chump_gh >/dev/null 2>&1 || chump_gh() { gh "$@"; }

# INFRA-8178: pure human-vs-gate disarm classification (unit-tested
# separately in scripts/ci/test-auto-arm-sweeper.sh).
# shellcheck source=lib/disarm-classify.sh
source "${REPO_ROOT}/scripts/ops/lib/disarm-classify.sh"

DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1
[[ "${CHUMP_AUTOARM_SKIP:-0}" == "1" ]] && { echo "[auto-arm] CHUMP_AUTOARM_SKIP=1 — exit"; exit 0; }

command -v gh >/dev/null 2>&1 || { echo "ERROR: gh CLI required" >&2; exit 2; }

# Whoami — only arm our own PRs (so this script is safe to deploy on
# shared infra without trampling sibling-author intent).
ME="$(gh api user --jq '.login' 2>/dev/null || echo '')"
[[ -n "$ME" ]] || { echo "ERROR: gh api user returned empty (not logged in?)" >&2; exit 2; }

STATE_FILE="${CHUMP_AUTOARM_STATE:-$REPO_ROOT/.chump-locks/auto-arm-state.tsv}"
ARMER="${CHUMP_AUTOARM_ARMER:-${REPO_ROOT}/scripts/coord/auto-merge-armer.sh}"
# RESILIENT-1613: `no-auto-merge` is the canonical hold label; `hold`,
# `do-not-merge` and `CHUMP_HOLD` stay honored. The shared policy
# (scripts/coord/lib/arm-policy.sh) also reads the `Auto-merge: hold` marker
# in the PR body/comments, which the label list here cannot see.
HOLD_LABELS_RE='^(no-auto-merge|hold|do-not-merge|CHUMP_HOLD)$'
# shellcheck source=scripts/coord/lib/arm-policy.sh
source "$(dirname "${BASH_SOURCE[0]}")/../coord/lib/arm-policy.sh"

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { printf '[auto-arm %s] %s\n' "$(ts)" "$*"; }

# WIP/hold pattern that means "don't arm me yet"
WIP_RE='[Ww][Ii][Pp]|\[skip\]|\[hold\]|\[draft\]|^Draft:|^WIP:'

# State file: num<TAB>sha<TAB>armed|disarmed<TAB>who<TAB>ts  (one line per PR)
state_get() { # <num> -> "sha<TAB>status<TAB>who" or empty
    [[ -f "$STATE_FILE" ]] || return 0
    awk -F'\t' -v n="$1" '$1==n {print $2 "\t" $3 "\t" $4}' "$STATE_FILE" | tail -1
}
state_set() { # <num> <sha> <status> [who]
    [[ "$DRY" -eq 1 ]] && return 0
    mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true
    local tmp="$STATE_FILE.tmp.$$"
    { [[ -f "$STATE_FILE" ]] && awk -F'\t' -v n="$1" '$1!=n' "$STATE_FILE"
      printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" "$(ts)"; } > "$tmp" 2>/dev/null \
        && mv "$tmp" "$STATE_FILE" 2>/dev/null || rm -f "$tmp"
}
disarm_event_info() { # <num> -> "actor<TAB>created_at" of the last auto_merge_disabled event (best effort)
    chump_gh api "repos/{owner}/{repo}/issues/$1/timeline" --paginate \
        --jq '[.[] | select(.event=="auto_merge_disabled")] | last | ((.actor.login // "") + "\t" + (.created_at // ""))' \
        2>/dev/null | tail -1
}
failing_check_timestamps() { # <sha> -> one completed_at per failed/timed-out check run
    chump_gh api "repos/{owner}/{repo}/commits/$1/check-runs" --paginate \
        --jq '.check_runs[]? | select(.conclusion=="failure" or .conclusion=="timed_out") | .completed_at // empty' \
        2>/dev/null
}

log "scanning open PRs authored by $ME"
[[ "$DRY" -eq 1 ]] && log "DRY-RUN — no arms"

# Pull author=me, state=open, not draft. mergeable + autoMergeRequest tell
# us whether to act.
PR_JSON="$(gh pr list \
    --author "$ME" --state open --limit 50 \
    --json number,title,isDraft,mergeStateStatus,autoMergeRequest,labels,headRefOid \
    2>/dev/null || echo '[]')"

armed=0; skipped_wip=0; skipped_dirty=0; skipped_armed=0; skipped_draft=0; skipped_hold=0; skipped_disarmed=0; errors=0

while IFS=$'\t' read -r num title is_draft merge_st has_auto labels sha; do
    [[ -z "$num" ]] && continue
    if [[ "$is_draft" == "true" ]]; then
        skipped_draft=$((skipped_draft + 1))
        continue
    fi
    if [[ "$has_auto" == "true" ]]; then
        skipped_armed=$((skipped_armed + 1))
        state_set "$num" "$sha" armed
        continue
    fi
    # INFRA-8047: operator hold label — never arm.
    held=0
    for l in $labels; do
        [[ "$l" =~ $HOLD_LABELS_RE ]] && held=1
    done
    if [[ "$held" -eq 1 ]]; then
        skipped_hold=$((skipped_hold + 1))
        log "  PR#$num held (hold label) — not arming"
        continue
    fi
    # INFRA-8047/INFRA-8178: respect a HUMAN disarm until the head moves —
    # but a disarm attributed to the automation login itself, or one that
    # landed within the window right after a failed required check on this
    # same head, is GitHub's own auto_merge_disabled-on-failed-check
    # behavior, not a human hold. Fall through (no `continue`) so the normal
    # eligibility checks below re-arm it once the head is actually green.
    prev="$(state_get "$num")"
    if [[ -n "$prev" ]]; then
        IFS=$'\t' read -r p_sha p_status p_who <<<"$prev"
        if [[ "$p_sha" == "$sha" ]]; then
            if [[ "$p_status" == "armed" ]]; then
                IFS=$'\t' read -r who disarm_ts <<<"$(disarm_event_info "$num")"
                failed_ts="$(failing_check_timestamps "$sha")"
                if printf '%s' "$failed_ts" | is_human_disarm "$who" "$ME" "$disarm_ts"; then
                    state_set "$num" "$sha" disarmed "${who:-unknown}"
                    log "  PR#$num was disarmed by ${who:-unknown} — respecting it until a new push"
                    skipped_disarmed=$((skipped_disarmed + 1))
                    continue
                else
                    log "  PR#$num disarmed by ${who:-$ME} — gate behaviour (automation login or post-failed-check), not a human hold; will re-arm if green"
                fi
            elif [[ "$p_status" == "disarmed" ]]; then
                skipped_disarmed=$((skipped_disarmed + 1))
                continue
            fi
        fi
    fi
    if [[ "$title" =~ $WIP_RE ]]; then
        skipped_wip=$((skipped_wip + 1))
        continue
    fi
    if [[ "$merge_st" == "DIRTY" || "$merge_st" == "CONFLICTING" ]]; then
        # DIRTY needs rebase, not arm. pr-watch.sh handles that class.
        skipped_dirty=$((skipped_dirty + 1))
        continue
    fi

    # Eligible: open, not draft, not WIP, no autoMerge yet, not DIRTY.
    if [[ "$DRY" -eq 1 ]]; then
        log "  PR#$num would arm — '$title' (merge=$merge_st)"
        armed=$((armed + 1))
        continue
    fi

    # INFRA-1223: route through centralized armer so we inherit 5s spacing +
    # 60/120/240s secondary-rate-limit backoff. Sweeping in a loop without
    # the armer is the dominant agent-blowout failure mode.
    # RESILIENT-1613: the shared policy (labels + body/comment marker).
    if ! arm_policy_allows "$num" "auto-arm-sweeper.sh"; then
        skipped_hold=$((skipped_hold + 1))
        log "  PR#$num held (arm policy: no-auto-merge / Auto-merge: hold) — not arming"
        continue
    fi
    if "$ARMER" --pr "$num" >/dev/null 2>&1; then
        state_set "$num" "$sha" armed
        log "  PR#$num ARMED — '$title'"
        armed=$((armed + 1))
    else
        # Common cause: branch protection requires reviews.
        log "  PR#$num arm failed — likely needs human review or other gate" >&2
        errors=$((errors + 1))
    fi
done < <(printf '%s' "$PR_JSON" | python3 -c "
import sys, json
for pr in json.load(sys.stdin):
    print('\t'.join([
        str(pr.get('number','')),
        (pr.get('title','') or '').replace('\t',' '),
        'true' if pr.get('isDraft') else 'false',
        pr.get('mergeStateStatus','') or '',
        'true' if pr.get('autoMergeRequest') else 'false',
        ' '.join(l.get('name','').replace(' ','_') for l in (pr.get('labels') or [])) or '-',
        pr.get('headRefOid','') or '-',
    ]))
")

echo
log "summary: armed=$armed skipped(armed=$skipped_armed wip=$skipped_wip draft=$skipped_draft dirty=$skipped_dirty hold=$skipped_hold disarmed=$skipped_disarmed) errors=$errors"
[[ "$DRY" -eq 1 ]] && log "(dry-run — no arms applied)"
exit 0
