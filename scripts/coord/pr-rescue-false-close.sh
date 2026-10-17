#!/usr/bin/env bash
# pr-rescue-false-close.sh — INFRA-1406
#
# Recovers a PR that was falsely closed by orphan-pr-closer (or any other
# auto-closer). Reopens the PR (if branch still exists on remote),
# re-arms auto-merge, and posts a "recovered from false close" comment
# explaining what happened.
#
# Usage:
#   scripts/coord/pr-rescue-false-close.sh <PR-number> [--repo owner/repo] [--no-squash]
#
# Pre-flight checks:
#   - Branch still exists on remote (git ls-remote)
#   - PR is in CLOSED state (refuse if MERGED — nothing to rescue)
#   - PR has at least one commit (not totally empty)
#
# Side effects:
#   1. gh pr reopen <pr>
#   2. gh pr comment <pr> --body "recovered from false close..."
#   3. scripts/coord/arm-auto-merge.sh <pr> (INFRA-1439 wrapper)
#   4. emit kind=orphan_pr_rescued {pr, gap_from_branch}

set -uo pipefail

PR=""
REPO=""
NO_SQUASH=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)       REPO="$2"; shift 2 ;;
        --no-squash)  NO_SQUASH=1; shift ;;
        -h|--help)    sed -n '2,22p' "$0"; exit 0 ;;
        --*)          echo "unknown flag: $1" >&2; exit 2 ;;
        *)            PR="$1"; shift ;;
    esac
done

if [[ -z "$PR" ]] || ! [[ "$PR" =~ ^[0-9]+$ ]]; then
    echo "usage: pr-rescue-false-close.sh <PR-number> [--repo owner/repo] [--no-squash]" >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${CHUMP_HOME:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
# RESILIENT-1613: one arm policy — honor `no-auto-merge` / `Auto-merge: hold`.
# shellcheck source=scripts/coord/lib/arm-policy.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/arm-policy.sh"
# RESILIENT-1616: the shared pr-cut predicate — a deliberate close is terminal;
# never reopen/re-arm/comment it even if an auto-closer looks "false".
# shellcheck source=scripts/coord/lib/pr-cut-guard.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/pr-cut-guard.sh"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

repo_arg=""
[[ -n "$REPO" ]] && repo_arg="--repo $REPO"

# ── Pre-flight checks ──────────────────────────────────────────────────────
pr_json="$(gh pr view "$PR" $repo_arg --json state,headRefName,title 2>/dev/null || echo '{}')"
state="$(echo "$pr_json" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('state',''))" 2>/dev/null)"
head_ref="$(echo "$pr_json" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('headRefName',''))" 2>/dev/null)"
title="$(echo "$pr_json" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('title',''))" 2>/dev/null)"

if [[ -z "$state" ]]; then
    echo "[pr-rescue] ERROR: cannot fetch PR #$PR (gh access? wrong repo?)" >&2
    exit 1
fi
if [[ "$state" == "MERGED" ]]; then
    echo "[pr-rescue] ERROR: PR #$PR is MERGED — nothing to rescue" >&2
    exit 1
fi
if [[ "$state" == "OPEN" ]]; then
    echo "[pr-rescue] PR #$PR already OPEN — re-arming auto-merge only" >&2
fi
if [[ -z "$head_ref" ]]; then
    echo "[pr-rescue] ERROR: PR #$PR has no head ref recorded" >&2
    exit 1
fi

# RESILIENT-1616: a deliberately cut PR is terminal — do NOT reopen, comment or
# re-arm it. A "false close" never looks like a pr-cut, but an organ must prove
# it consulted the predicate before undoing any close.
if pr_cut_honored "$PR" "pr-rescue-false-close.sh" "reopen" "" "${REPO:-}"; then
    echo "[pr-rescue] PR #$PR is pr-cut (deliberate close, terminal; RESILIENT-1616) — NOT reopening." >&2
    exit 0
fi

# Confirm branch still exists on remote.
if ! gh api "repos/{owner}/{repo}/branches/$head_ref" $repo_arg --silent 2>/dev/null; then
    echo "[pr-rescue] ERROR: branch '$head_ref' deleted from remote — cannot reopen" >&2
    echo "[pr-rescue] Re-push the branch first: git push -u chump $head_ref" >&2
    exit 1
fi

# Best-effort gap-id extraction.
gap_id="$(echo "$head_ref" | sed -E 's|^chump/||' | awk -F- '{print toupper($1)"-"$2}')"

# ── Mergeability guard (INFRA-5349, INFRA-3604 slice) ───────────────────────
# A manually closed PR should stay closed if the target branch is not
# mergeable/rebaseable — reopening a DIRTY/CONFLICTING PR just re-jams the
# merge queue with something nobody can land anyway.
if [[ "$state" == "CLOSED" ]]; then
    rest_json="$(gh api "repos/{owner}/{repo}/pulls/$PR" $repo_arg 2>/dev/null || echo '{}')"
    mergeable="$(echo "$rest_json" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('mergeable',''))" 2>/dev/null)"
    rebaseable="$(echo "$rest_json" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('rebaseable',''))" 2>/dev/null)"
    mergeable_state="$(echo "$rest_json" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('mergeable_state',''))" 2>/dev/null)"

    if [[ "$mergeable" == "False" || "$rebaseable" == "False" ]]; then
        ts_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true
        reason="mergeable=$mergeable rebaseable=$rebaseable mergeable_state=$mergeable_state"
        echo "[pr-rescue] REFUSED: PR #$PR not reopened — target branch not mergeable/rebaseable ($reason)" >&2
        printf '{"ts":"%s","session":"pr-rescue","event":"AUDIT","kind":"pr_reopen_refused","pr":%s,"branch":"%s","gap":"%s","reason":"%s"}\n' \
            "$ts_iso" "$PR" "$head_ref" "$gap_id" "$reason" \
            >> "$AMBIENT" 2>/dev/null || true
        exit 1
    fi
fi

# ── Reopen + comment + re-arm ──────────────────────────────────────────────
if [[ "$state" == "CLOSED" ]]; then
    echo "[pr-rescue] Reopening PR #$PR ($head_ref)..."
    if ! gh pr reopen "$PR" $repo_arg 2>/dev/null; then
        echo "[pr-rescue] ERROR: gh pr reopen failed" >&2
        exit 1
    fi
fi

comment_body="Recovered from false close via \`pr-rescue-false-close.sh\` (INFRA-1406). Likely auto-closer mis-classified this as an orphan. Operators investigating false-close patterns: grep \`kind=orphan_pr_rescued\` in ambient.jsonl."
gh pr comment "$PR" $repo_arg --body "$comment_body" >/dev/null 2>&1 || true

# Re-arm auto-merge via the INFRA-1439 wrapper (verifies post-arm).
if ! arm_policy_allows "$PR" "pr-rescue-false-close.sh" "${REPO:-}"; then
    echo "[pr-rescue] PR #$PR is held (no-auto-merge / Auto-merge: hold) — reopened, NOT re-armed."
elif [[ -x "$SCRIPT_DIR/arm-auto-merge.sh" ]]; then
    arm_args=("$PR")
    [[ -n "$REPO" ]] && arm_args+=(--repo "$REPO")
    [[ "$NO_SQUASH" -eq 1 ]] && arm_args+=(--no-squash)
    echo "[pr-rescue] Re-arming auto-merge via arm-auto-merge.sh..."
    bash "$SCRIPT_DIR/arm-auto-merge.sh" "${arm_args[@]}" || true
else
    # Fallback when arm-auto-merge.sh isn't built yet.
    if [[ "$NO_SQUASH" -eq 1 ]]; then
        gh pr merge "$PR" $repo_arg --auto >/dev/null 2>&1 || true
    else
        gh pr merge "$PR" $repo_arg --auto --squash >/dev/null 2>&1 || true
    fi
fi

# ── Audit emit ──────────────────────────────────────────────────────────────
ts_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true
# Sanitise title for JSON.
title_clean="$(echo "$title" | tr -d '"\\' | head -c 200)"
printf '{"ts":"%s","session":"pr-rescue","event":"AUDIT","kind":"orphan_pr_rescued","pr":%s,"branch":"%s","gap":"%s","title":"%s"}\n' \
    "$ts_iso" "$PR" "$head_ref" "$gap_id" "$title_clean" \
    >> "$AMBIENT" 2>/dev/null || true

echo "[pr-rescue] DONE — PR #$PR rescued (branch=$head_ref gap=$gap_id)"
exit 0
