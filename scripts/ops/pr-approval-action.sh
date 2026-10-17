#!/usr/bin/env bash
# scripts/ops/pr-approval-action.sh — RESILIENT-265 "approve-from-phone".
#
# THE ACTION half of the Discord PR-approval flow. Given an operator decision
# (merge or reject) for one OS-authored product-repo PR, this script does the
# real GitHub work idempotently and prints a single human-readable status line
# (the text the gateway edits the Discord message to). It is the ONE codepath a
# real "✅ Merge" / "❌ Reject" tap triggers, so it is independently testable:
#   scripts/ops/discord-gateway.py shells out to it on INTERACTION_CREATE, and
#   the proof harness invokes it directly with the same arguments.
#
# WHY A SEPARATE SCRIPT (not inline in the gateway): keeping the mutation in one
# bash entrypoint means the gateway stays thin, and the exact action a tap
# performs can be dry-run or exercised against a throwaway PR without faking a
# Discord interaction. Mirrors how notify-operator.sh is the reusable SEND half.
#
# CONTRACT:
#   pr-approval-action.sh <merge|reject> <owner/repo> <number> [--dry-run]
#     → prints ONE status line to stdout (safe to drop straight into Discord)
#     → exit 0 on success OR idempotent no-op (already merged/closed)
#     → exit 1 on a real error (bad args, gh failure on an actionable PR)
#
# IDEMPOTENCY IS LOAD-BEARING. A second tap on an already-acted PR must be a
# no-op with a clear message, never a double-merge. Before acting we read live
# PR state: MERGED → "already merged", CLOSED → "already closed/rejected", and
# only an OPEN PR is actually merged/closed. This is the human-in-the-loop
# guarantee: the button is safe to double-tap.
#
# MERGE METHOD: honors the repo's allowed methods (squash > merge > rebase),
# defaulting to --squash when permitted. Override with CHUMP_PR_MERGE_METHOD.
#
# SAFETY: never auto-merges anything on its own — it only runs when explicitly
# invoked with a decision (by a real operator tap, or the proof harness). It
# does not scan, poll, or decide; it executes one already-made decision.
set -uo pipefail

emit_ambient() {  # kind, extra-json (no leading/trailing comma), best-effort
  local root kind="$1" extra="${2:-}" ts line log
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)" || return 0
  log="${CHUMP_AMBIENT_LOG:-$root/.chump-locks/ambient.jsonl}"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [[ -n "$extra" ]]; then line="{\"ts\":\"$ts\",\"kind\":\"$kind\",$extra}"
  else line="{\"ts\":\"$ts\",\"kind\":\"$kind\"}"; fi
  mkdir -p "$(dirname "$log")" 2>/dev/null || true
  printf '%s\n' "$line" >> "$log" 2>/dev/null || true
  return 0
}

# EVENT_REGISTRY scanner-anchors (INFRA-754): emit_ambient builds the "kind"
# field from a variable, so the grep-based event-registry rule cannot see these
# kinds at their call sites. These literal anchors keep register-and-emit in
# sync (each is registered in docs/observability/EVENT_REGISTRY.yaml):
#   scanner-anchor: "kind":"pr_approval_merged"
#   scanner-anchor: "kind":"pr_approval_rejected"
#   scanner-anchor: "kind":"pr_approval_action_noop"
#   scanner-anchor: "kind":"pr_approval_action_error"
#   scanner-anchor: "kind":"pr_approval_action_refused"

# INFRA-8221 (RESILIENT-1613 arm policy): a held PR is not merged by a tap.
# shellcheck source=scripts/coord/lib/arm-policy.sh
source "$(dirname "${BASH_SOURCE[0]}")/../coord/lib/arm-policy.sh"

usage() { echo "usage: pr-approval-action.sh <merge|reject> <owner/repo> <number> [--dry-run]" >&2; exit 1; }

ACTION="${1:-}"; REPO="${2:-}"; NUMBER="${3:-}"; DRY="${4:-}"
[[ "$ACTION" == "merge" || "$ACTION" == "reject" ]] || usage
[[ "$REPO" == */* ]] || usage
[[ "$NUMBER" =~ ^[0-9]+$ ]] || usage
DRYRUN=0; [[ "$DRY" == "--dry-run" ]] && DRYRUN=1

# NEVER act on the chump repo itself here — internal chump PRs auto-merge through
# the gate gauntlet and must never be squashed by a phone tap. Defense in depth:
# the detector already excludes it, but the action refuses too.
if [[ "$REPO" == */chump || "$REPO" == */Chump ]]; then
  echo "refused: $REPO is the internal chump repo (auto-merges via CI, not by tap) ⛔"
  emit_ambient pr_approval_action_refused "\"repo\":\"$REPO\",\"number\":$NUMBER,\"reason\":\"internal_chump\""
  exit 1
fi

# --- read live PR state (idempotency gate) -----------------------------------
state_json="$(gh pr view "$NUMBER" -R "$REPO" --json state,title,url,isDraft 2>/dev/null)" || {
  echo "error: cannot read $REPO#$NUMBER (does it exist? is gh authed?) ⚠️"
  emit_ambient pr_approval_action_error "\"repo\":\"$REPO\",\"number\":$NUMBER,\"reason\":\"pr_view_failed\""
  exit 1
}
state="$(printf '%s' "$state_json" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("state",""))' 2>/dev/null)"
title="$(printf '%s' "$state_json" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("title",""))' 2>/dev/null)"
url="$(printf '%s' "$state_json" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("url",""))' 2>/dev/null)"
short="$REPO#$NUMBER"

# Idempotent no-ops: whatever a second tap hits, report it plainly, exit 0.
if [[ "$state" == "MERGED" ]]; then
  echo "$short already merged ✅ (no-op — $title)"
  emit_ambient pr_approval_action_noop "\"repo\":\"$REPO\",\"number\":$NUMBER,\"state\":\"MERGED\""
  exit 0
fi
if [[ "$state" == "CLOSED" ]]; then
  echo "$short already closed/rejected ❌ (no-op — $title)"
  emit_ambient pr_approval_action_noop "\"repo\":\"$REPO\",\"number\":$NUMBER,\"state\":\"CLOSED\""
  exit 0
fi
if [[ "$state" != "OPEN" ]]; then
  echo "$short is in state '$state' — nothing to do"
  exit 0
fi

# ============================ REJECT =========================================
if [[ "$ACTION" == "reject" ]]; then
  if [[ "$DRYRUN" == 1 ]]; then
    echo "[dry-run] would run: gh pr close $NUMBER -R $REPO --comment 'Rejected by operator via Discord (RESILIENT-265).'"
    exit 0
  fi
  if gh pr close "$NUMBER" -R "$REPO" \
       --comment "Rejected by operator via Discord tap (RESILIENT-265 approve-from-phone)." 2>/tmp/pr-approval-reject.err; then
    echo "$short rejected ❌ — closed. ($title)"
    emit_ambient pr_approval_rejected "\"repo\":\"$REPO\",\"number\":$NUMBER"
    exit 0
  fi
  echo "$short reject FAILED ⚠️ — $(tail -1 /tmp/pr-approval-reject.err 2>/dev/null)"
  emit_ambient pr_approval_action_error "\"repo\":\"$REPO\",\"number\":$NUMBER,\"reason\":\"close_failed\""
  exit 1
fi

# ============================ MERGE ==========================================
# INFRA-8221: refuse a held PR (label no-auto-merge / hold / do-not-merge /
# CHUMP_HOLD, or an `Auto-merge: hold` line in the body or a comment). The hold
# is a standing human decision; remove the label / marker, then tap again.
# arm_policy_allows emits kind=pr_arm_skipped_hold and logs the reason on stderr.
if ! arm_policy_allows "$NUMBER" "pr-approval-action.sh" "$REPO"; then
  echo "$short held ⛔ — not merged (no-auto-merge label or 'Auto-merge: hold' marker; remove it to release, then tap ✅ again)"
  emit_ambient pr_approval_action_refused "\"repo\":\"$REPO\",\"number\":$NUMBER,\"reason\":\"arm_policy_hold\""
  exit 1
fi

# Pick a merge method the repo actually allows (squash preferred).
method="${CHUMP_PR_MERGE_METHOD:-}"
if [[ -z "$method" ]]; then
  methods_json="$(gh repo view "$REPO" --json squashMergeAllowed,mergeCommitAllowed,rebaseMergeAllowed 2>/dev/null)" || methods_json=""
  if [[ -n "$methods_json" ]]; then
    method="$(printf '%s' "$methods_json" | python3 -c '
import sys,json
d=json.load(sys.stdin)
print("squash" if d.get("squashMergeAllowed") else ("merge" if d.get("mergeCommitAllowed") else ("rebase" if d.get("rebaseMergeAllowed") else "squash")))' 2>/dev/null)"
  fi
  method="${method:-squash}"
fi
case "$method" in
  squash) flag="--squash" ;;
  merge)  flag="--merge" ;;
  rebase) flag="--rebase" ;;
  *)      flag="--squash"; method="squash" ;;
esac

if [[ "$DRYRUN" == 1 ]]; then
  echo "[dry-run] would run: gh pr merge $NUMBER -R $REPO $flag  (method=$method)"
  exit 0
fi

if gh pr merge "$NUMBER" -R "$REPO" "$flag" 2>/tmp/pr-approval-merge.err; then
  echo "$short merged ✅ ($method) — $title"
  emit_ambient pr_approval_merged "\"repo\":\"$REPO\",\"number\":$NUMBER,\"method\":\"$method\""
  exit 0
fi

# Merge can legitimately fail (required check red, branch behind). Surface why —
# the PR stays OPEN so the operator can re-tap once it's green (idempotent).
err="$(tail -1 /tmp/pr-approval-merge.err 2>/dev/null)"
echo "$short merge did NOT complete ⚠️ — $err (PR left open; tap ✅ again once green)"
emit_ambient pr_approval_action_error "\"repo\":\"$REPO\",\"number\":$NUMBER,\"reason\":\"merge_failed\""
exit 1
