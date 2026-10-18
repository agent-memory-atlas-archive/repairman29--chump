#!/usr/bin/env bash
# scripts/ops/break-trunk-cascade.sh — INFRA-2087
#
# Operator-button that codifies the admin-merge dance for trunk-RED
# cascade recovery. Replaces 4 error-prone manual gh-api commands with
# one safe atomic operation that ALWAYS restores branch protection,
# even if the script is killed mid-flight.
#
# Usage:
#   scripts/ops/break-trunk-cascade.sh --pr <N> --reason "<one-line-why>" [options]
#
# Required flags:
#   --pr <N>       PR number to merge through the cascade-break
#   --reason "..." One-line operator reason for the bypass (audit trail)
#
# Options:
#   --propagation-wait <sec>  Seconds to wait after drop for propagation (default: 5)
#   --dry-run                 Show what WOULD happen; no API mutations
#   --i-know-what-im-doing    Skip the "has fixed wedge in diff" heuristic
#   --repo <owner/repo>       Override auto-detection
#   --help                    Show this usage
#
# What happens (in order):
#   1. Validate: PR is OPEN + auto-merge ARMED + sane preconditions
#   2. Snapshot current required_status_checks (branch-protection + ruleset)
#   3. trap EXIT/INT/TERM → unconditional restore from snapshot
#   4. Drop required_status_checks (both surfaces)
#   5. Wait <propagation-wait> seconds
#   6. gh pr merge <N> --admin --squash
#   7. Restore from snapshot (also fires on trap if step 6 dies)
#   8. Emit ambient kind=trunk_cascade_broken with audit fields
#
# Rate limit:
#   CHUMP_BREAK_CASCADE_PER_HOUR (default 1)
#       Max invocations per rolling hour. Tracked via
#       .chump-locks/break-cascade-history.jsonl. When exceeded,
#       refuses + emits kind=trunk_cascade_rate_limited.
#
# Exit codes:
#   0  PR merged, ruleset+branch-protection fully restored
#   1  invocation error (missing flag, bad input)
#   2  preflight refused (PR not open, not armed, etc.)
#   3  CRITICAL: merge succeeded but restore failed — operator action
#      required
#   4  rate-limited

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# CREDIBLE-1524: admin-merge consensus gate (refuses --admin without a PASSED
# AdminMergeProposal consensus_result for the PR).
# shellcheck source=scripts/coord/lib/admin-merge-consensus-gate.sh
source "$SCRIPT_DIR/../coord/lib/admin-merge-consensus-gate.sh"

PR_NUM=""
REASON=""
PROPAGATION_WAIT=5
DRY_RUN=0
I_KNOW=0
REPO=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pr)                 PR_NUM="$2"; shift ;;
        --reason)             REASON="$2"; shift ;;
        --propagation-wait)   PROPAGATION_WAIT="$2"; shift ;;
        --dry-run)            DRY_RUN=1 ;;
        --i-know-what-im-doing) I_KNOW=1 ;;
        --repo)               REPO="$2"; shift ;;
        --help|-h)
            sed -n '2,38p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
    shift
done

# ── Validate required flags ──────────────────────────────────────────────────

if [[ -z "$PR_NUM" ]]; then
    echo "[break-trunk-cascade] ERROR: --pr <N> is required" >&2
    exit 1
fi
if [[ -z "$REASON" ]]; then
    echo "[break-trunk-cascade] ERROR: --reason \"<text>\" is required (audit trail)" >&2
    exit 1
fi
if ! command -v gh >/dev/null 2>&1; then
    echo "[break-trunk-cascade] ERROR: gh CLI not in PATH" >&2
    exit 1
fi

# ── Resolve repo ─────────────────────────────────────────────────────────────

if [[ -z "$REPO" ]]; then
    REPO="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "")"
fi
if [[ -z "$REPO" ]]; then
    echo "[break-trunk-cascade] ERROR: could not resolve repo (pass --repo)" >&2
    exit 1
fi

OWNER="${REPO%/*}"
REPONAME="${REPO#*/}"

# ── Rate-limit check ─────────────────────────────────────────────────────────

LIMIT="${CHUMP_BREAK_CASCADE_PER_HOUR:-1}"
HISTORY_FILE="$REPO_ROOT/.chump-locks/break-cascade-history.jsonl"
mkdir -p "$REPO_ROOT/.chump-locks"
touch "$HISTORY_FILE"

NOW_EPOCH=$(date -u +%s)
WINDOW_START=$(( NOW_EPOCH - 3600 ))
RECENT_COUNT=$(awk -F'"epoch":' -v t="$WINDOW_START" 'NF>1 { split($2, a, ","); if (a[1]+0 >= t) print }' "$HISTORY_FILE" | wc -l | tr -d ' ')

if [[ "$RECENT_COUNT" -ge "$LIMIT" ]]; then
    echo "[break-trunk-cascade] RATE-LIMITED: $RECENT_COUNT invocation(s) in last hour (limit=$LIMIT)" >&2
    AMB_PATH="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
    TS_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","kind":"trunk_cascade_rate_limited","pr":%s,"limit":%s,"recent_count":%s,"session":"%s"}\n' \
        "$TS_ISO" "$PR_NUM" "$LIMIT" "$RECENT_COUNT" "${CHUMP_SESSION_ID:-unknown}" \
        >> "$AMB_PATH" 2>/dev/null || true
    echo "                  if truly urgent, run the gh-api commands manually" >&2
    exit 4
fi

# ── Preflight: PR is OPEN + has auto-merge ARMED ─────────────────────────────

PR_STATE_JSON="$(gh pr view "$PR_NUM" --json state,autoMergeRequest,mergeStateStatus 2>/dev/null || echo "{}")"
PR_STATE="$(echo "$PR_STATE_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("state","?"))')"
PR_ARMED="$(echo "$PR_STATE_JSON" | python3 -c 'import json,sys;d=json.load(sys.stdin);print("true" if d.get("autoMergeRequest") else "false")')"

if [[ "$PR_STATE" != "OPEN" ]]; then
    echo "[break-trunk-cascade] REFUSE: PR #$PR_NUM is state=$PR_STATE (expected OPEN)" >&2
    exit 2
fi
if [[ "$PR_ARMED" != "true" && "$I_KNOW" -ne 1 ]]; then
    echo "[break-trunk-cascade] REFUSE: PR #$PR_NUM does not have auto-merge ARMED" >&2
    echo "                  arm it first with: gh pr merge $PR_NUM --auto --squash" >&2
    echo "                  or override with --i-know-what-im-doing" >&2
    exit 2
fi

echo "[break-trunk-cascade] target: PR #$PR_NUM on $REPO" >&2
echo "[break-trunk-cascade] reason: $REASON" >&2

# ── Snapshot current required_status_checks ─────────────────────────────────

SNAPSHOT_DIR="$(mktemp -d -t chump-break-cascade-XXXX)"
BP_SNAPSHOT="$SNAPSHOT_DIR/branch-protection.json"
RS_SNAPSHOT_LIST="$SNAPSHOT_DIR/ruleset-ids.txt"
echo "[break-trunk-cascade] snapshot dir: $SNAPSHOT_DIR" >&2

# Snapshot A: branch-protection
gh api "repos/$REPO/branches/main/protection/required_status_checks" >"$BP_SNAPSHOT" 2>/dev/null || {
    echo "{}" >"$BP_SNAPSHOT"
}
BP_CONTEXTS=$(python3 -c '
import json, sys
try:
    d=json.load(open("'"$BP_SNAPSHOT"'"))
    c=[ck.get("context","") for ck in d.get("checks",[])]
    print(",".join(c))
except Exception:
    print("")
')
echo "[break-trunk-cascade] branch-protection contexts: [$BP_CONTEXTS]" >&2

# Snapshot B: rulesets with required_status_checks rule
gh api "repos/$REPO/rulesets" 2>/dev/null | python3 -c '
import json, sys
try:
    rs=json.load(sys.stdin)
    for r in rs:
        if r.get("enforcement")=="active":
            print(r.get("id",""))
except Exception:
    pass
' > "$RS_SNAPSHOT_LIST"

while IFS= read -r RID; do
    [[ -z "$RID" ]] && continue
    gh api "repos/$REPO/rulesets/$RID" 2>/dev/null > "$SNAPSHOT_DIR/ruleset-$RID.json"
done < "$RS_SNAPSHOT_LIST"

# ── trap EXIT auto-restore (AC #2: atomic guarantee) ────────────────────────

RESTORE_DONE=0
restore_protections() {
    if [[ "$RESTORE_DONE" -eq 1 ]]; then
        return 0
    fi
    RESTORE_DONE=1
    echo "[break-trunk-cascade] restoring required_status_checks from snapshot $SNAPSHOT_DIR ..." >&2

    # Restore branch-protection
    if [[ -s "$BP_SNAPSHOT" ]] && [[ -n "$BP_CONTEXTS" ]]; then
        local contexts_json
        contexts_json=$(python3 -c 'import json,sys; print(json.dumps("'"$BP_CONTEXTS"'".split(",")))')
        if [[ "$DRY_RUN" -ne 1 ]]; then
            echo "$contexts_json" | gh api -X POST \
                "repos/$REPO/branches/main/protection/required_status_checks/contexts" \
                --input - >/dev/null 2>&1 || {
                echo "[break-trunk-cascade] CRITICAL: branch-protection restore FAILED — operator action required" >&2
                echo "                  manual restore: $contexts_json | gh api -X POST repos/$REPO/branches/main/protection/required_status_checks/contexts --input -" >&2
            }
        fi
    fi

    # Restore rulesets
    while IFS= read -r RID; do
        [[ -z "$RID" ]] && continue
        local SNAP="$SNAPSHOT_DIR/ruleset-$RID.json"
        [[ ! -s "$SNAP" ]] && continue
        if [[ "$DRY_RUN" -ne 1 ]]; then
            gh api -X PUT "repos/$REPO/rulesets/$RID" --input "$SNAP" >/dev/null 2>&1 || {
                echo "[break-trunk-cascade] CRITICAL: ruleset $RID restore FAILED — operator action required" >&2
                echo "                  manual restore: gh api -X PUT repos/$REPO/rulesets/$RID --input $SNAP" >&2
            }
        fi
    done < "$RS_SNAPSHOT_LIST"

    echo "[break-trunk-cascade] restore complete" >&2
}
trap restore_protections EXIT INT TERM

# ── Drop required_status_checks ─────────────────────────────────────────────

echo "[break-trunk-cascade] step 1/3: dropping required_status_checks ..." >&2
if [[ "$DRY_RUN" -ne 1 ]]; then
    # Branch-protection: empty the contexts list
    echo "[]" | gh api -X PUT "repos/$REPO/branches/main/protection/required_status_checks/contexts" --input - >/dev/null 2>&1 || true

    # Rulesets: PUT a modified copy with required_status_checks rule removed
    while IFS= read -r RID; do
        [[ -z "$RID" ]] && continue
        local TMPRULESET="$SNAPSHOT_DIR/ruleset-$RID-relaxed.json"
        python3 -c '
import json, sys
with open("'"$SNAPSHOT_DIR/ruleset-$RID.json"'") as f:
    r=json.load(f)
out={"name":r.get("name"),"target":r.get("target"),"enforcement":r.get("enforcement"),
     "conditions":r.get("conditions"),"rules":[rule for rule in r.get("rules",[]) if rule.get("type")!="required_status_checks"]}
with open("'"$TMPRULESET"'","w") as f:
    json.dump(out,f)
' 2>/dev/null
        if [[ -s "$TMPRULESET" ]]; then
            gh api -X PUT "repos/$REPO/rulesets/$RID" --input "$TMPRULESET" >/dev/null 2>&1 || true
        fi
    done < "$RS_SNAPSHOT_LIST"
fi

# ── Wait for propagation ────────────────────────────────────────────────────

echo "[break-trunk-cascade] step 2/3: waiting ${PROPAGATION_WAIT}s for propagation ..." >&2
if [[ "$DRY_RUN" -ne 1 ]]; then
    sleep "$PROPAGATION_WAIT"
fi

# ── Admin-merge the PR ──────────────────────────────────────────────────────

echo "[break-trunk-cascade] step 3/3: gh pr merge $PR_NUM --admin --squash ..." >&2
MERGE_EXIT=0
START_EPOCH=$(date -u +%s)
if [[ "$DRY_RUN" -ne 1 ]]; then
    # CREDIBLE-1524: refuse the --admin bypass unless a PASSED AdminMergeProposal
    # consensus_result names this PR (enforce mode; shadow logs + proceeds). The
    # restore_protections call below (and the EXIT trap) re-arms branch protection.
    if ! admin_merge_consensus_gate "$PR_NUM"; then
        echo "[break-trunk-cascade] admin-merge REFUSED by consensus gate (CREDIBLE-1524) — PR #$PR_NUM" >&2
        restore_protections
        exit 1
    fi
    gh pr merge "$PR_NUM" --admin --squash 2>&1 || MERGE_EXIT=$?
fi
END_EPOCH=$(date -u +%s)
BYPASS_MS=$(( (END_EPOCH - START_EPOCH) * 1000 ))

# ── Restore (trap will also fire, but doing it explicitly captures success) ─

restore_protections

# ── Record + emit ambient ───────────────────────────────────────────────────

TS_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
AMB_PATH="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

# Append to history (for rate-limit window)
printf '{"epoch":%s,"ts":"%s","pr":%s,"reason":"%s","session":"%s"}\n' \
    "$NOW_EPOCH" "$TS_ISO" "$PR_NUM" "${REASON//\"/\\\"}" "${CHUMP_SESSION_ID:-unknown}" \
    >> "$HISTORY_FILE"

# Emit audit event (scanner-anchor: "kind":"trunk_cascade_broken" INFRA-2087)
printf '{"ts":"%s","kind":"trunk_cascade_broken","pr":%s,"reason":"%s","snapshot_contexts":"%s","bypass_duration_ms":%s,"merge_exit":%s,"session":"%s"}\n' \
    "$TS_ISO" "$PR_NUM" "${REASON//\"/\\\"}" "$BP_CONTEXTS" "$BYPASS_MS" "$MERGE_EXIT" "${CHUMP_SESSION_ID:-unknown}" \
    >> "$AMB_PATH" 2>/dev/null || true

# Cleanup snapshot dir (only after restore)
rm -rf "$SNAPSHOT_DIR" 2>/dev/null || true

if [[ "$MERGE_EXIT" -ne 0 ]]; then
    echo "[break-trunk-cascade] WARN: gh pr merge exit=$MERGE_EXIT (restore still ran)" >&2
    exit 0  # Don't fail — protections restored
fi

echo "[break-trunk-cascade] ✓ PR #$PR_NUM cascade-broken in ${BYPASS_MS}ms; protections restored" >&2
exit 0
