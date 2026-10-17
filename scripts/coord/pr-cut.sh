#!/usr/bin/env bash
# scripts/coord/pr-cut.sh — RESILIENT-1607 (with RESILIENT-1606)
#
# `chump pr cut <N> --reason "<text>"`: the ONE sanctioned way to close a fleet
# PR on purpose (a duplicate cut, a superseded slice, an architect's decision).
#
# Why a verb: two organs police closed fleet PRs and they read the same
# evidence with opposite meanings.
#   - post-push-integrity-watch.sh (INFRA-2026) reopens any unmerged close of a
#     chump/* PR inside its window (a GitHub stale-push auto-close is the case it
#     exists for).
#   - trunk-recovery-reviver.sh (RESILIENT-1190) revives a reaper-closed PR that
#     was closed inside a trunk-red window.
# A human who closes a PR by hand, or by hand plus the `rot-reaped` label, has
# to know both organs' internals to make the close stick. On 2026-10-16 the
# architect's deliberate cuts of #5478 and #5483 were reopened within 15s by the
# watch (twice each) and revived at 14:31Z by the reviver after being labeled
# rot-reaped at 14:02Z.
#
# Label vocabulary (one meaning each):
#   rot-reaped  the no-abandon janitor closed it; a reaper VICTIM; revivable
#               (only with a matching kind=pr_reaped event).
#   pr-cut      closed DELIBERATELY by a human or architect; TERMINAL. No organ
#               reopens or revives it.
#
# What this does, in order (the label goes on BEFORE the close so a poller in the
# close window already sees it, the same ordering rot-reaper uses):
#   1. create the `pr-cut` label if missing
#   2. add the label
#   3. close the PR with a comment carrying the reason (a PR that is already
#      closed gets the label and a comment, no second close)
#   4. emit kind=pr_cut to ambient.jsonl
#   5. append a note to the PR's gap (chump gap show/set --notes); if the gap
#      store is not reachable, PRINT the command instead of failing
#
# Usage:
#   bash scripts/coord/pr-cut.sh <PR-NUMBER> --reason "text" [--repo owner/repo] [--dry-run]
#
# Exit: 0 cut done (or dry-run), 1 gh failure, 2 usage error / PR already merged.
#
# Env: CHUMP_BIN (chump binary used for the gap note, default `chump`),
#      CHUMP_AMBIENT_PATH / CHUMP_AMBIENT_LOG (ambient.jsonl override).
#
# Rust-first note: closing a PR is GitHub state, so shell glue is acceptable
# here; the Rust `chump pr cut` arm follows (Phase R R6, RESILIENT-1607).
#
# scanner-anchor: "kind":"pr_cut"

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AMBIENT="${CHUMP_AMBIENT_PATH:-${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}}"
CHUMP_CMD="${CHUMP_BIN:-chump}"
CUT_LABEL="pr-cut"
# shellcheck source=scripts/coord/lib/ambient-write.sh
source "$SCRIPT_DIR/lib/ambient-write.sh"

PR=""
REASON=""
REPO="repairman29/chump"
DRY_RUN=0

usage() { sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; }
die() { printf 'pr-cut: %s\n' "$*" >&2; exit 2; }
log() { printf '[pr-cut] %s\n' "$*"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --reason)   [[ $# -ge 2 ]] || die "--reason needs a value"; REASON="$2"; shift 2 ;;
        --reason=*) REASON="${1#--reason=}"; shift ;;
        --repo)     [[ $# -ge 2 ]] || die "--repo needs a value"; REPO="$2"; shift 2 ;;
        --dry-run)  DRY_RUN=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        -*)         die "unknown flag: $1" ;;
        *)          [[ -z "$PR" ]] || die "unexpected extra argument: $1"; PR="$1"; shift ;;
    esac
done

[[ "$PR" =~ ^[0-9]+$ ]] || die "usage: pr-cut.sh <PR-NUMBER> --reason \"text\" (PR number required)"
[[ -n "${REASON// /}" ]] || die "--reason is required: say why this PR is being cut"

command -v gh >/dev/null 2>&1 || { echo "pr-cut: gh CLI not found" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "pr-cut: python3 not found" >&2; exit 1; }

# ── Look the PR up ────────────────────────────────────────────────────────────
VIEW="$(gh pr view "$PR" --repo "$REPO" --json state,title,headRefName,mergedAt 2>/dev/null)" || {
    echo "pr-cut: could not read PR #$PR on $REPO (gh pr view failed)" >&2
    exit 1
}
field() {  # <key>
    printf '%s' "$VIEW" | python3 -c "import json,sys; print(json.load(sys.stdin).get('$1') or '')"
}
STATE="$(field state)"
TITLE="$(field title)"
BRANCH="$(field headRefName)"
MERGED_AT="$(field mergedAt)"

if [[ -n "$MERGED_AT" || "$STATE" == "MERGED" ]]; then
    echo "pr-cut: PR #$PR is already MERGED; there is nothing to cut." >&2
    exit 2
fi

# Gap id: the title first, then the branch (chump/resilient-1606-... -> RESILIENT-1606).
GAP_ID="$(printf '%s' "$TITLE" | grep -oE '[A-Z]+(-[A-Z]+)*-[0-9]+' | head -1)"
if [[ -z "$GAP_ID" ]]; then
    GAP_ID="$(printf '%s' "$BRANCH" | sed -n 's#^chump/\([A-Za-z]\{1,\}\(-[A-Za-z]\{1,\}\)*\)-\([0-9]\{1,\}\).*#\1-\3#p' | tr '[:lower:]' '[:upper:]')"
fi

CLOSE_COMMENT="pr-cut: ${REASON}

Closed deliberately (scripts/coord/pr-cut.sh, RESILIENT-1607). The \`${CUT_LABEL}\` label is terminal: the post-push integrity watch will not reopen this PR and the trunk-recovery reviver will not revive it. To bring the work back, open a new PR."

if [[ "$DRY_RUN" == "1" ]]; then
    log "[dry-run] PR #$PR ($BRANCH, state=$STATE, gap=${GAP_ID:-none}) on $REPO"
    log "[dry-run] would: ensure label '$CUT_LABEL'; add it; close with the reason comment; emit kind=pr_cut; note the gap"
    exit 0
fi

# ── 1+2. Label first ──────────────────────────────────────────────────────────
if ! gh label list --repo "$REPO" --limit 300 2>/dev/null | grep -qE "^${CUT_LABEL}([[:space:]]|\$)"; then
    gh label create "$CUT_LABEL" --repo "$REPO" --color 6E7781 \
        --description "Deliberately closed by a human or architect; organs must not reopen or revive" \
        >/dev/null 2>&1 || log "WARN: could not create label '$CUT_LABEL' (it may already exist)"
fi
if ! gh pr edit "$PR" --repo "$REPO" --add-label "$CUT_LABEL" >/dev/null 2>&1; then
    echo "pr-cut: could not add label '$CUT_LABEL' to PR #$PR; NOT closing (the label must land before the close, or an organ will reopen it)." >&2
    exit 1
fi
log "labeled PR #$PR '$CUT_LABEL'"

# ── 3. Close with the reason ──────────────────────────────────────────────────
if [[ "$STATE" == "OPEN" ]]; then
    if ! gh pr close "$PR" --repo "$REPO" --comment "$CLOSE_COMMENT" >/dev/null 2>&1; then
        echo "pr-cut: gh pr close #$PR failed (label '$CUT_LABEL' is already on it)." >&2
        exit 1
    fi
    log "closed PR #$PR with the reason comment"
else
    if ! gh pr comment "$PR" --repo "$REPO" --body "$CLOSE_COMMENT" >/dev/null 2>&1; then
        log "WARN: PR #$PR was already $STATE and the reason comment could not be posted"
    else
        log "PR #$PR was already $STATE; labeled and commented"
    fi
fi

# ── 4. Ambient event ──────────────────────────────────────────────────────────
mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true
REASON_JSON="$(printf '%s' "$REASON" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))')"
BRANCH_JSON="$(printf '%s' "$BRANCH" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))')"
_ambient_write "$AMBIENT" "$(printf '{"ts":"%s","kind":"pr_cut","pr":%s,"branch":%s,"gap":"%s","reason":%s}' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PR" "$BRANCH_JSON" "$GAP_ID" "$REASON_JSON")"

# ── 5. Gap note (never fails the cut) ─────────────────────────────────────────
if [[ -n "$GAP_ID" ]]; then
    NOTE="[pr-cut $(date -u +%Y-%m-%d)] PR #$PR closed deliberately: $REASON"
    OLD_NOTES=""
    GAP_OK=0
    if command -v "$CHUMP_CMD" >/dev/null 2>&1; then
        if GAP_JSON="$("$CHUMP_CMD" gap show "$GAP_ID" --json 2>/dev/null)" && [[ -n "$GAP_JSON" ]]; then
            if OLD_NOTES="$(printf '%s' "$GAP_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('notes') or '')" 2>/dev/null)"; then
                NEW_NOTES="${OLD_NOTES:+$OLD_NOTES
}$NOTE"
                if "$CHUMP_CMD" gap set "$GAP_ID" --notes "$NEW_NOTES" >/dev/null 2>&1; then
                    GAP_OK=1
                    log "noted gap $GAP_ID"
                fi
            fi
        fi
    fi
    if [[ "$GAP_OK" -ne 1 ]]; then
        log "gap store not reachable here; record the note yourself (this appends nothing automatically):"
        printf '  chump gap set %s --notes "<existing notes>\\n%s"\n' "$GAP_ID" "$NOTE"
    fi
else
    log "no gap id found in the title or branch; skipping the gap note"
fi

log "done: PR #$PR is cut ('$CUT_LABEL' = terminal; rot-reaped = reaper victim, revivable)"
exit 0
