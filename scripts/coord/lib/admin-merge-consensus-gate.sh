#!/usr/bin/env bash
# admin-merge-consensus-gate.sh — CREDIBLE-1524 (PHASE-R R3 slice of CREDIBLE-1492)
#
# Every `gh pr merge --admin` call site under scripts/ MUST route through this
# gate before invoking the admin merge. The gate refuses the admin-merge unless
# a kind=consensus_result verdict=PASSED event exists for an AdminMergeProposal
# naming that PR (canonical corr_id: admin-merge-pr-<N>).
#
# Builds on:
#   - INFRA-2274 — the shadow consensus merge gate wired into bot-merge.sh's
#     *auto-merge* path (corr_id pr-<N>). This lib is the sibling gate for the
#     *admin-merge* bypass path, which is a distinct, higher-trust decision.
#   - META-195  — productize admin-merge-by-consensus (AdminMergeProposal type).
#
# Mode is read from CHUMP_CONSENSUS_MERGE_GATE (written by chump-node-install.sh,
# shadow-first) — NOT a new *_BYPASS/SKIP env var (INFRA-2429 debt ceiling):
#   unset / 0 / off  → gate disabled (dev/local checkout), proceed, no emit
#   1 / shadow       → shadow: log would-refuse / approved, PROCEED anyway
#   enforce          → blocking: REFUSE (return 1) unless a PASSED verdict exists
#
# Public API:
#   admin_merge_consensus_gate <pr_num> [corr_id]
#     return 0 → PROCEED with the admin merge
#     return 1 → REFUSE (enforce mode, no PASSED AdminMergeProposal verdict)
#
# Ambient kinds emitted here (registered in docs/observability/EVENT_REGISTRY.yaml):
#   admin_merge_consensus_approved  — PASSED verdict found → proceeding
#   admin_merge_consensus_refused   — no PASSED verdict, enforce mode → refused
#   admin_merge_consensus_shadow    — no PASSED verdict, shadow mode → proceeding
#
# Deliberately self-contained: no hard dependency on bot-merge primitives so any
# call site (coord/ or ops/) can source it. flock-safe append is used when the
# ambient-write lib is present; otherwise a plain append fallback.

# Resolve an ambient-write helper once (optional; plain-append fallback below).
if ! command -v _ambient_write >/dev/null 2>&1; then
  _amg_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -f "$_amg_self_dir/ambient-write.sh" ]; then
    # shellcheck source=ambient-write.sh
    . "$_amg_self_dir/ambient-write.sh" 2>/dev/null || true
  fi
  unset _amg_self_dir
fi

# Plain-append fallback if the ambient-write lib was unavailable.
if ! command -v _ambient_write >/dev/null 2>&1; then
  _ambient_write() { printf '%s\n' "$2" >> "$1" 2>/dev/null || true; }
fi

# _amg_emit <ambient_log> <kind> <pr> <corr_id> <verdict> <mode> <gap_id>
# Builds the JSON line with the kind interpolated. Scanner-anchor comments below
# satisfy the EVENT_REGISTRY emit-site check even though `kind` is a variable.
_amg_emit() {
  local amb="$1" kind="$2" pr="$3" corr="$4" verdict="$5" mode="$6" gap="$7"
  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local line
  line="$(printf '{"ts":"%s","kind":"%s","pr":%s,"corr_id":"%s","verdict":"%s","mode":"%s","gap_id":"%s","proposal_type":"AdminMergeProposal"}' \
    "$ts" "$kind" "$pr" "$corr" "$verdict" "$mode" "$gap")"
  _ambient_write "$amb" "$line"
  # scanner-anchor: "kind":"admin_merge_consensus_approved"
  # scanner-anchor: "kind":"admin_merge_consensus_refused"
  # scanner-anchor: "kind":"admin_merge_consensus_shadow"
}

# admin_merge_consensus_gate <pr_num> [corr_id]
admin_merge_consensus_gate() {
  local pr_num="${1:?admin_merge_consensus_gate: pr_num required}"
  local corr_id="${2:-admin-merge-pr-${pr_num}}"
  local mode="${CHUMP_CONSENSUS_MERGE_GATE:-0}"
  local gap_id="${CHUMP_GAP_ID:-${GAP_ID:-unknown}}"
  local repo_root="${REPO_ROOT:-${CHUMP_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"
  local amb="${CHUMP_AMBIENT_LOG:-$repo_root/.chump-locks/ambient.jsonl}"

  # Normalize mode.
  case "$mode" in
    0|off|"") return 0 ;;          # disabled — proceed silently (dev/local)
    1|shadow) mode="shadow" ;;
    enforce)  mode="enforce" ;;
    *)        mode="shadow" ;;     # unknown value → fail safe to shadow (non-blocking)
  esac

  # Look for a PASSED AdminMergeProposal consensus_result for this PR's corr_id.
  # Capture the matching line(s) rather than ending a pipeline in `grep -q`
  # (set -o pipefail hazard per the Phase-R architecture rule).
  local hits=""
  if [ -f "$amb" ]; then
    hits="$(grep -F "\"corr_id\":\"${corr_id}\"" "$amb" 2>/dev/null \
      | grep -F '"kind":"consensus_result"' \
      | grep -F '"verdict":"PASSED"' || true)"
  fi

  if [ -n "$hits" ]; then
    _amg_emit "$amb" "admin_merge_consensus_approved" "$pr_num" "$corr_id" "PASSED" "$mode" "$gap_id"
    echo "[admin-merge-gate] PR #${pr_num}: PASSED AdminMergeProposal consensus (corr_id=${corr_id}) — proceeding" >&2
    return 0
  fi

  if [ "$mode" = "enforce" ]; then
    _amg_emit "$amb" "admin_merge_consensus_refused" "$pr_num" "$corr_id" "NO_PASSED" "enforce" "$gap_id"
    echo "[admin-merge-gate] PR #${pr_num}: REFUSED — no PASSED AdminMergeProposal consensus_result (corr_id=${corr_id}, enforce mode)" >&2
    echo "[admin-merge-gate]   Cast votes: chump vote ${corr_id} +1 --reason '<why>' from N>=3 curators, then re-run." >&2
    return 1
  fi

  # shadow — log that we WOULD refuse, but proceed.
  _amg_emit "$amb" "admin_merge_consensus_shadow" "$pr_num" "$corr_id" "NO_PASSED" "shadow" "$gap_id"
  echo "[admin-merge-gate] PR #${pr_num}: WOULD REFUSE (no PASSED AdminMergeProposal consensus_result, corr_id=${corr_id}) — shadow mode, proceeding" >&2
  return 0
}
