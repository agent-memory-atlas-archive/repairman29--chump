#!/usr/bin/env bash
# scripts/coord/auto-merge-rearm-daemon.sh — INFRA-2309
#
# Walks all open PRs every CHUMP_AUTO_MERGE_REARM_INTERVAL_S (default 60s).
# For each PR with mergeStateStatus=CLEAN AND autoMergeRequest=null:
#   - Check fix-class allowlist (default-on; bypass with CHUMP_AUTO_MERGE_REARM_OPEN=1)
#   - If allowlisted: gh pr merge --auto --squash
#   - Emit ambient kind=auto_merge_rearmed
#
# Env knobs:
#   CHUMP_AUTO_MERGE_REARM_INTERVAL_S   default 60
#   CHUMP_AUTO_MERGE_REARM_OPEN         non-empty = skip fix-class filter (feat/all classes)
#   CHUMP_AUTO_MERGE_REARM_DRY_RUN      non-empty = log only, no actual gh pr merge
#
# Usage:
#   bash auto-merge-rearm-daemon.sh tick       # single tick (used by launchd)
#   bash auto-merge-rearm-daemon.sh loop       # continuous loop (for tmux sessions)
#   bash auto-merge-rearm-daemon.sh --help
#
# Scanner-anchor: kind=auto_merge_rearmed kind=auto_merge_rearm_skipped kind=auto_merge_rearm_failed

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# RESILIENT-1613: one arm policy — honor `no-auto-merge` / `Auto-merge: hold`.
# shellcheck source=scripts/coord/lib/arm-policy.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/arm-policy.sh"

# github_cache.sh may not be needed for direct gh calls but source for
# chump_gh criticality tag pattern
# shellcheck disable=SC1091  # lib/ sources use dynamic $REPO_ROOT — resolved at runtime
source "$REPO_ROOT/scripts/coord/lib/github_cache.sh" 2>/dev/null || true

ALLOWLIST="$REPO_ROOT/scripts/coord/lib/fix-class-allowlist.txt"
DRY_RUN="${CHUMP_AUTO_MERGE_REARM_DRY_RUN:-}"
OPEN_MODE="${CHUMP_AUTO_MERGE_REARM_OPEN:-}"
INTERVAL_S="${CHUMP_AUTO_MERGE_REARM_INTERVAL_S:-60}"
AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"

_emit() {
  local kind="$1" pr="$2" reason="${3:-}"
  local dry_flag="false"
  [[ -n "$DRY_RUN" ]] && dry_flag="true"
  printf '{"ts":"%s","kind":"%s","pr":%s,"reason":"%s","dry_run":%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$kind" "$pr" "$reason" "$dry_flag" \
    >> "$AMBIENT" 2>/dev/null || true
}

is_allowed_fix_class() {
  local title="$1"
  # CHUMP_AUTO_MERGE_REARM_OPEN=1 bypasses the allowlist entirely
  if [[ -n "$OPEN_MODE" ]]; then
    return 0
  fi
  if [[ ! -f "$ALLOWLIST" ]]; then
    echo "[auto-merge-rearm-daemon] WARN: allowlist not found at $ALLOWLIST; skipping PR (safe default)" >&2
    return 1
  fi
  while IFS= read -r prefix; do
    # skip blank lines and comment lines
    [[ -z "$prefix" || "${prefix:0:1}" = "#" ]] && continue
    # prefix match: title starts with this prefix
    case "$title" in
      "$prefix"*) return 0 ;;
    esac
  done < "$ALLOWLIST"
  return 1
}

cmd_tick() {
  local count_armed=0 count_skipped=0 count_failed=0

  # INFRA-1080: tag as background — this is a periodic scan, not a critical-path merge
  # The gh pr list call uses direct gh (not chump_gh wrapper) with CHUMP_GH_CALL_CRITICALITY env
  local prs_json
  if ! prs_json=$(CHUMP_GH_CALL_CRITICALITY=background \
      gh pr list --state open --limit 200 \
      --json number,title,mergeStateStatus,autoMergeRequest 2>/dev/null); then
    echo "[auto-merge-rearm-daemon] WARN: gh pr list failed — skipping tick" >&2
    return 0
  fi

  if [[ -z "$prs_json" || "$prs_json" = "null" || "$prs_json" = "[]" ]]; then
    echo "[auto-merge-rearm-daemon] tick: no open PRs" >&2
    return 0
  fi

  # Extract CLEAN PRs with no auto-merge armed using python3 (macOS bash 3.2 compatible — no jq -e)
  local clean_prs
  clean_prs=$(python3 - "$prs_json" 2>/dev/null <<'PYEOF' || true
import json, sys
data = sys.argv[1]
prs = json.loads(data)
for p in prs:
    if p.get('mergeStateStatus') != 'CLEAN':
        continue
    if p.get('autoMergeRequest') is not None:
        continue
    number = p['number']
    title = p.get('title', '')
    # escape tabs in title to avoid field splitting issues
    title_safe = title.replace('\t', ' ')
    print(f"{number}\t{title_safe}")
PYEOF
)

  if [[ -z "$clean_prs" ]]; then
    echo "[auto-merge-rearm-daemon] tick: no CLEAN+unarmed PRs found" >&2
    return 0
  fi

  while IFS=$'\t' read -r pr title; do
    [[ -z "$pr" ]] && continue

    if is_allowed_fix_class "$title"; then
      if [[ -n "$DRY_RUN" ]]; then
        _emit "auto_merge_rearmed" "$pr" "dry_run"
        echo "[auto-merge-rearm-daemon] DRY-RUN would arm PR #${pr}: ${title}" >&2
        count_armed=$((count_armed + 1))
      else
        # gh pr merge is a critical-path write — no BACKGROUND tag
        if ! arm_policy_allows "$pr" "auto-merge-rearm-daemon.sh"; then
          echo "[auto-merge-rearm-daemon] held PR #${pr} (no-auto-merge / Auto-merge: hold) — not arming" >&2
        elif gh pr merge "$pr" --auto --squash >/dev/null 2>&1; then
          _emit "auto_merge_rearmed" "$pr" "armed"
          echo "[auto-merge-rearm-daemon] armed PR #${pr}: ${title}" >&2
          count_armed=$((count_armed + 1))
        else
          _emit "auto_merge_rearm_failed" "$pr" "gh_merge_failed"
          echo "[auto-merge-rearm-daemon] WARN: gh pr merge failed for PR #${pr}: ${title}" >&2
          count_failed=$((count_failed + 1))
        fi
      fi
    else
      _emit "auto_merge_rearm_skipped" "$pr" "not_in_fix_class_allowlist"
      echo "[auto-merge-rearm-daemon] skipped PR #${pr} (not in fix-class allowlist): ${title}" >&2
      count_skipped=$((count_skipped + 1))
    fi
  done <<EOF
$clean_prs
EOF

  echo "[auto-merge-rearm-daemon] tick complete — armed:${count_armed} skipped:${count_skipped} failed:${count_failed}" >&2
}

cmd_loop() {
  echo "[auto-merge-rearm-daemon] starting loop (interval=${INTERVAL_S}s dry_run=${DRY_RUN:-off} open_mode=${OPEN_MODE:-off})" >&2
  while true; do
    cmd_tick
    sleep "$INTERVAL_S"
  done
}

case "${1:-}" in
  tick)  cmd_tick ;;
  loop)  cmd_loop ;;
  --help|-h)
    sed -n '2,15p' "$0"
    exit 0
    ;;
  *)
    echo "Usage: $0 tick | loop | --help" >&2
    exit 2
    ;;
esac
