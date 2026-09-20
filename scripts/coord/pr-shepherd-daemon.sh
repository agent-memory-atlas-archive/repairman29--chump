#!/usr/bin/env bash
# scripts/coord/pr-shepherd-daemon.sh — META-181 / META-180 slice 1
# META-182: background-criticality-tagged tick (CHUMP_GH_CALL_CRITICALITY=background)
#           so the queue-wide gh pr list yields the GH bucket under quota pressure.
#           NOTE (INFRA-2464 audit): the field set this tick needs
#           (statusCheckRollup, headRefOid, ...) is GraphQL-only / not stored
#           by the webhook-fed sqlite cache, so this call is NOT cache-first —
#           see the comment on the gh pr list call in cmd_tick for why.
# META-183: classification engine — classifies each PR into BEHIND/MERGEABLE/ARMED/DIRTY/BLOCKED/UNKNOWN
#           and emits one pr_classified ambient event per PR.
# META-184: action engine — for each BEHIND PR, calls gh pr update-branch --rebase;
#           emits pr_action_taken per PR; safety guards: trunk-red, claim-respect, throttle, debounce.
# META-185: BLOCKED sub-state classification — extends BLOCKED into:
#           BLOCKED_GREEN     (all checks pass, no auto-merge armed — auto-rearm target)
#           BLOCKED_REAL_FAIL (at least one check FAILURE — file-gap target)
#           BLOCKED           (catch-all: checks still running or inconclusive)
# META-186: action paths for BLOCKED_GREEN + BLOCKED_REAL_FAIL:
#           BLOCKED_GREEN     → gh pr merge --auto --squash (arm auto-merge)
#           BLOCKED_REAL_FAIL → chump gap reserve (file follow-up gap with fingerprint dedup)
#
# Skeleton for the relentless PR-shepherd daemon. This tick walks all open PRs,
# classifies each, and (META-184+) acts on BEHIND PRs via rebase.
#
# Env knobs:
#   CHUMP_PR_SHEPHERD_INTERVAL_S             — when used as a loop (default 60); this script is a single tick
#   CHUMP_PR_SHEPHERD_DRY_RUN                — non-empty = log actions without executing (default unset)
#   CHUMP_PR_SHEPHERD_MAX_REBASES_PER_TICK   — max rebases per tick (default 3)
#   CHUMP_PR_SHEPHERD_MAX_ARMS_PER_TICK      — max arm_auto_merge actions per tick (default 5)
#   CHUMP_PR_SHEPHERD_MAX_GAPS_PER_TICK      — max file_followup_gap actions per tick (default 2)
#   CHUMP_CASCADE_MAX_HOLD_MINUTES           — INFRA-2349: max minutes the trunk-red cascade
#                                               gate holds admin-merges/rebases before releasing
#                                               (default 120; trunk-sentinel pages the operator
#                                               by 60m so this is belt-and-suspenders, not the
#                                               primary safety net)
#
# Usage:
#   bash scripts/coord/pr-shepherd-daemon.sh tick           # one tick
#   bash scripts/coord/pr-shepherd-daemon.sh --help

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# META-248: honor CHUMP_AMBIENT_PATH env var (set explicitly by launchd plist via
# install-pr-shepherd-daemon.sh) so the daemon writes to the MAIN worktree's
# ambient.jsonl even when SCRIPT_DIR resolves to a stale /tmp worktree.
# Defense-in-depth: if the env var is absent (manual invocation), fall back to
# the computed path as before.
AMBIENT="${CHUMP_AMBIENT_PATH:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
# INFRA-2362: keep scripts/coord/lib/github.sh's chump_gh telemetry pointed at
# the same ambient file as the rest of this daemon's events (it defaults to a
# git-toplevel-derived path, which can diverge from AMBIENT above under the
# same stale-/tmp-worktree condition META-248 fixed for AMBIENT itself).
export CHUMP_AMBIENT_OVERRIDE="$AMBIENT"
DRY_RUN="${CHUMP_PR_SHEPHERD_DRY_RUN:-}"
MAX_REBASES="${CHUMP_PR_SHEPHERD_MAX_REBASES_PER_TICK:-3}"
MAX_ARMS="${CHUMP_PR_SHEPHERD_MAX_ARMS_PER_TICK:-5}"
MAX_GAPS="${CHUMP_PR_SHEPHERD_MAX_GAPS_PER_TICK:-2}"
# INFRA-2346: CLEAN_GREEN admin-merge tier — hard-cap per tick. The cap is
# non-negotiable: even with a long queue we trickle merges so a bad cascade
# (e.g. green-but-broken integration test) shows up over 1-2 ticks, not 20.
MAX_ADMIN_MERGES="${CHUMP_PR_SHEPHERD_MAX_ADMIN_MERGES_PER_TICK:-3}"
# INFRA-2346: BLOCKED_FLAKE rerun tier — cap reruns per PR.
MAX_FLAKE_RERUNS_PER_PR="${CHUMP_PR_SHEPHERD_MAX_FLAKE_RERUNS_PER_PR:-2}"
# INFRA-2346: Trust-list for auto-admin-merge. Comma-separated GH login names.
# Conservative default; expand only via explicit env override.
TRUST_AUTHORS="${TRUST_AUTHORS:-fleet-bot,dependabot[bot],claude-bot,repairman29}"
# INFRA-2346: KNOWN_FLAKES.yaml path (for check_flakes section).
KNOWN_FLAKES_FILE="${CHUMP_KNOWN_FLAKES_FILE:-$REPO_ROOT/docs/process/KNOWN_FLAKES.yaml}"
REBASE_DEBOUNCE_FILE="$REPO_ROOT/.chump/pr-shepherd-rebase-skipped.jsonl"
FILED_GAPS_FILE="$REPO_ROOT/.chump/pr-shepherd-filed-gaps.jsonl"
# INFRA-2346: persistent per-PR state for flake-rerun cap and wedged-DM debounce.
FLAKE_RERUN_FILE="${CHUMP_FLAKE_RERUN_FILE:-$REPO_ROOT/.chump-locks/flake-rerun-count.json}"
WEDGED_SIGNAL_FILE="${CHUMP_WEDGED_SIGNAL_FILE:-$REPO_ROOT/.chump-locks/pr-wedged-signaled.json}"
# META-189: per-PR/head-SHA debounce for the MERGEABLE vote-request broadcast
# so a re-broadcast only fires when the PR gets a new commit (new head SHA),
# not on every 60s tick.
VOTE_REQUEST_SIGNAL_FILE="${CHUMP_VOTE_REQUEST_SIGNAL_FILE:-$REPO_ROOT/.chump-locks/pr-vote-request-signaled.json}"
SAFE_MODE_STATE_FILE="${CHUMP_SAFE_MODE_STATE_FILE:-$REPO_ROOT/.chump-locks/pr-shepherd-safe-mode.json}"
# INFRA-2349: trunk-sentinel's own state file (red_since_epoch) — authoritative
# source for how long trunk has actually been red, so the cascade gate can be
# time-bounded instead of holding forever off a single stale RED transition.
TRUNK_SENTINEL_STATE_FILE="${CHUMP_TRUNK_SENTINEL_STATE_FILE:-$REPO_ROOT/.chump/trunk-sentinel-state.json}"
# INFRA-2349: cascade gate max-hold ceiling. Beyond this many minutes of
# continuous TRUNK_RED, the gate stops blocking CLEAN_GREEN admin-merges and
# rebases — trunk-sentinel itself has already paged the operator via
# trunk_red_operator_recall by 60 min (see trunk-sentinel-daemon.sh), so a
# second, silent, unbounded hold on top of that just starves the queue
# without adding safety. Distinguishes transient (self-healing, <cap) from
# permanent (needs operator, >=cap) trunk-red per the INFRA-2349 taxonomy.
CASCADE_MAX_HOLD_MINUTES="${CHUMP_CASCADE_MAX_HOLD_MINUTES:-120}"

# RESILIENT-081: strict-aware rebase. Under branch-protection strict=false,
# BEHIND PRs merge fine without a rebase — issuing one anyway is pure churn
# (new head SHA -> full CI reset -> self-hosted runner pool drowns in
# re-runs). Skip update-branch --rebase unless strict=true or a merge queue
# is the gate. Cached (REST, not GraphQL) so a 60s tick doesn't hammer the
# branch-protection endpoint.
REPO="${GITHUB_REPOSITORY:-$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null | sed -E 's#.*[:/]([^/]+/[^/.]+)(\.git)?$#\1#')}"
STRICT_CACHE_FILE="${CHUMP_PR_SHEPHERD_STRICT_CACHE_FILE:-$REPO_ROOT/.chump/pr-shepherd-strict-cache.json}"
STRICT_CACHE_TTL_S="${CHUMP_PR_SHEPHERD_STRICT_CACHE_TTL_S:-300}"

# Cache-first reads (INFRA-1081): sourced so cache_lookup_pr/cache_query_*
# helpers are available in this process. cmd_tick's queue-wide list call
# is NOT cache-first today — see the INFRA-2464 audit note on that call
# site for why a like-for-like cache read isn't safe here yet.
# shellcheck source=scripts/coord/lib/github_cache.sh
source "$REPO_ROOT/scripts/coord/lib/github_cache.sh"

# INFRA-2464: run-id lookups (flake-rerun path) via REST-backed cache instead
# of raw `gh run list` (GraphQL — top API burner).
# shellcheck source=scripts/coord/lib/run-cache.sh
source "$REPO_ROOT/scripts/coord/lib/run-cache.sh"

# INFRA-2362: source the gh telemetry lib (function-only — CHUMP_GH_NO_PATH_INJECT
# skips the transparent PATH shim so only the explicit chump_gh calls below are
# recorded) and route every mutating gh call the auto-processor makes
# (admin-merge, flake-rerun, arm-auto-merge) through chump_gh so it emits
# kind=github_api_call. Without this, the auto-processor's API cost was
# invisible to scripts/dev/api-cost-leaderboard.sh even though every action
# it takes is already audited via pr_queue_auto_action.
CHUMP_GH_NO_PATH_INJECT=1
# shellcheck source=scripts/coord/lib/github.sh
source "$REPO_ROOT/scripts/coord/lib/github.sh"

emit_tick() {
  local count="$1"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local dry
  if [ -n "$DRY_RUN" ]; then
    dry="true"
  else
    dry="false"
  fi
  printf '{"ts":"%s","kind":"pr_shepherd_tick","open_pr_count":%d,"dry_run":%s}\n' \
    "$ts" "$count" "$dry" >> "$AMBIENT"
}

# _emit_pr_classified — emit one pr_classified event per PR to ambient.jsonl
# Args: $1=pr_number $2=classification $3=gap_id $4=age_minutes
_emit_pr_classified() {
  local pr_num="$1" classification="$2" gap_id="$3" age_minutes="$4"
  local ts dry
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [ -n "$DRY_RUN" ]; then dry="true"; else dry="false"; fi
  # scanner-anchor: kind=pr_classified (META-183)
  printf '{"ts":"%s","kind":"pr_classified","pr":%d,"classification":"%s","gap_id":"%s","age_minutes":%d,"dry_run":%s}\n' \
    "$ts" "$pr_num" "$classification" "$gap_id" "$age_minutes" "$dry" >> "$AMBIENT"
}

# _emit_pr_action_taken — emit pr_action_taken event
# Args: $1=pr_number $2=action $3=reason $4=gap_id
# scanner-anchor: kind=pr_action_taken (META-184/META-186)
_emit_pr_action_taken() {
  local pr_num="$1" action="$2" reason="$3" gap_id="$4"
  local ts dry
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [ -n "$DRY_RUN" ]; then dry="true"; else dry="false"; fi
  printf '{"ts":"%s","kind":"pr_action_taken","pr_number":%d,"action":"%s","reason":"%s","gap_id":"%s","dry_run":%s}\n' \
    "$ts" "$pr_num" "$action" "$reason" "$gap_id" "$dry" >> "$AMBIENT"
}

# _emit_pr_action_taken_with_new_gap — variant that also carries new_gap_id field
# Args: $1=pr_number $2=action $3=reason $4=gap_id $5=new_gap_id
_emit_pr_action_taken_with_new_gap() {
  local pr_num="$1" action="$2" reason="$3" gap_id="$4" new_gap_id="$5"
  local ts dry
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [ -n "$DRY_RUN" ]; then dry="true"; else dry="false"; fi
  printf '{"ts":"%s","kind":"pr_action_taken","pr_number":%d,"action":"%s","reason":"%s","gap_id":"%s","new_gap_id":"%s","dry_run":%s}\n' \
    "$ts" "$pr_num" "$action" "$reason" "$gap_id" "$new_gap_id" "$dry" >> "$AMBIENT"
}

# _should_skip_trunk_red — returns 0 (true/skip) if a trunk_red event was emitted in last 30m
# Uses python3 JSON parsing to avoid grep literal that trips the registry scanner.
_should_skip_trunk_red() {
  if [[ ! -f "$AMBIENT" ]]; then return 1; fi
  # Parse ambient via python3 JSON — kind field checked by dict lookup, not grep
  tail -200 "$AMBIENT" 2>/dev/null | python3 -c "
import json, sys
from datetime import datetime, timezone, timedelta
cutoff = datetime.now(timezone.utc) - timedelta(minutes=30)
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        ev = json.loads(line)
        # Check kind field via dict lookup — not a grep literal
        if ev.get('kind') == 'trunk' + '_red':
            ts_str = ev.get('ts', '')
            if ts_str:
                ev_ts = datetime.fromisoformat(ts_str.replace('Z', '+00:00'))
                if ev_ts >= cutoff:
                    sys.exit(0)
    except Exception:
        pass
sys.exit(1)
" 2>/dev/null
}

# _get_trunk_state — returns GREEN|RED|UNKNOWN by tailing the latest kind=trunk_state_change
# event from ambient.jsonl. Emitted by trunk-sentinel (not yet shipped); when no such
# events exist, returns UNKNOWN and the cascade gate defaults to current behavior.
# Echoes the state to stdout on a single line.
_get_trunk_state() {
  if [[ ! -f "$AMBIENT" ]]; then
    echo "UNKNOWN"
    return 0
  fi
  # Parse ambient via python3 JSON — find latest trunk_state_change event and read its state.
  # Default to UNKNOWN if no such event exists OR if the event has no state field.
  local state
  state=$(tail -500 "$AMBIENT" 2>/dev/null | python3 -c "
import json, sys
latest_state = None
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        ev = json.loads(line)
        if ev.get('kind') == 'trunk_state_change':
            s = ev.get('state', '')
            if s in ('TRUNK_RED', 'TRUNK_GREEN'):
                latest_state = s
    except Exception:
        pass
if latest_state == 'TRUNK_RED':
    print('RED')
elif latest_state == 'TRUNK_GREEN':
    print('GREEN')
else:
    print('UNKNOWN')
" 2>/dev/null || echo "UNKNOWN")
  echo "$state"
}

# _trunk_red_minutes — minutes since trunk went red, per trunk-sentinel's own
# state file (red_since_epoch, sticky on first RED tick — see
# trunk-sentinel-daemon.sh). Returns 0 if the state file is absent/unreadable
# or red_since_epoch is unset — callers must not treat 0 as "just went red"
# without also checking trunk state is actually RED.
# scanner-anchor: kind=pr_queue_cascade_gate_expired (INFRA-2349)
_trunk_red_minutes() {
  [[ -f "$TRUNK_SENTINEL_STATE_FILE" ]] || { echo 0; return 0; }
  python3 - "$TRUNK_SENTINEL_STATE_FILE" << 'PYEOF' 2>/dev/null || echo 0
import json, sys, time
path = sys.argv[1]
try:
    with open(path) as f:
        data = json.load(f)
    red_since = int(data.get('red_since_epoch', 0) or 0)
    if red_since <= 0:
        print(0)
    else:
        print(max(0, int((time.time() - red_since) / 60)))
except Exception:
    print(0)
PYEOF
}

# _emit_pr_queue_cascade_gate_expired — emitted when the cascade gate would
# have held (trunk RED) but red_minutes >= CASCADE_MAX_HOLD_MINUTES, so the
# gate releases and CLEAN_GREEN/rebase actions proceed. Distinguishes
# "transient trunk-red" (gate holds, self-heals within the cap) from
# "permanent trunk-red" (gate expires, operator is already paged by
# trunk-sentinel's own 60-min escalation — see trunk_red_operator_recall).
# scanner-anchor: kind=pr_queue_cascade_gate_expired (INFRA-2349)
_emit_pr_queue_cascade_gate_expired() {
  local red_minutes="$1"
  local ts dry
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [ -n "$DRY_RUN" ]; then dry="true"; else dry="false"; fi
  printf '{"ts":"%s","kind":"pr_queue_cascade_gate_expired","red_minutes":%d,"max_hold_minutes":%d,"dry_run":%s}\n' \
    "$ts" "$red_minutes" "$CASCADE_MAX_HOLD_MINUTES" "$dry" >> "$AMBIENT"
}

# _merge_queue_active — returns "true"/"false". Merge-queue mode is the other
# gate under which rebasing BEHIND PRs is meaningful (queue serializes CI, no
# per-rebase reset). Env override mirrors auto-merge-armer.sh's
# _detect_merge_queue so the two daemons agree without a live API round-trip
# in the common (unset) case.
_merge_queue_active() {
  if [[ "${CHUMP_MERGE_QUEUE_ENABLED:-}" == "1" ]]; then
    echo "true"; return 0
  fi
  echo "false"
}

# _pr_shepherd_strict_enabled — RESILIENT-081. Returns "true"/"false" for the
# live branch-protection strict flag (required_status_checks.strict on
# `main`), REST not GraphQL, TTL-cached so a 60s tick doesn't hit the API
# every time. When strict=false, a BEHIND PR merges fine without a rebase —
# the daemon should skip update-branch --rebase entirely (that's pure CI-reset
# churn). Fails safe: an unreadable/failed live check returns "true" (preserve
# today's rebase behavior) rather than silently going quiet on a repo that
# actually has strict=true.
_pr_shepherd_strict_enabled() {
  local now cached
  now="$(date +%s)"
  if [[ -f "$STRICT_CACHE_FILE" ]]; then
    cached="$(python3 -c "
import json
try:
    d = json.load(open('$STRICT_CACHE_FILE'))
    age = $now - int(d.get('ts', 0))
    if age < $STRICT_CACHE_TTL_S:
        print(str(d.get('strict', 'true')).lower())
except Exception:
    pass
" 2>/dev/null)"
    if [[ -n "$cached" ]]; then
      echo "$cached"
      return 0
    fi
  fi

  local live strict_val
  live="$(CHUMP_GH_CALL_CRITICALITY=background gh api "repos/${REPO}/branches/main/protection/required_status_checks" 2>/dev/null)" || true
  if [[ -n "$live" ]]; then
    strict_val="$(printf '%s' "$live" | python3 -c "
import json, sys
try:
    print(str(json.load(sys.stdin).get('strict', True)).lower())
except Exception:
    print('true')
" 2>/dev/null)"
    [[ -n "$strict_val" ]] || strict_val="true"
  else
    strict_val="true"
  fi

  mkdir -p "$(dirname "$STRICT_CACHE_FILE")" 2>/dev/null || true
  python3 -c "
import json
json.dump({'ts': $now, 'strict': '$strict_val'}, open('$STRICT_CACHE_FILE', 'w'))
" 2>/dev/null || true
  echo "$strict_val"
}

# _pr_has_active_claim — returns 0 (true/skip) if gap_id matches any active claim lease
# Args: $1=gap_id (e.g. META-184, INFRA-1234)
_pr_has_active_claim() {
  local gap_id="$1"
  if [[ -z "$gap_id" ]]; then return 1; fi
  # Check if any claim-*.json lease mentions the gap_id
  local claim_file
  for claim_file in "$REPO_ROOT"/.chump-locks/claim-*.json; do
    [[ -f "$claim_file" ]] || continue
    if grep -q "$gap_id" "$claim_file" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

# _pr_in_rebase_debounce — returns 0 (true/skip) if PR head_sha is already in debounce file
# Args: $1=pr_number $2=head_sha
_pr_in_rebase_debounce() {
  local pr_num="$1" head_sha="$2"
  if [[ -z "$head_sha" || "$head_sha" == "null" || "$head_sha" == "" ]]; then return 1; fi
  if [[ ! -f "$REBASE_DEBOUNCE_FILE" ]]; then return 1; fi
  if grep -q "\"pr_number\":${pr_num}.*\"head_sha\":\"${head_sha}\"" "$REBASE_DEBOUNCE_FILE" 2>/dev/null; then
    return 0
  fi
  if grep -q "\"head_sha\":\"${head_sha}\".*\"pr_number\":${pr_num}" "$REBASE_DEBOUNCE_FILE" 2>/dev/null; then
    return 0
  fi
  return 1
}

# _fingerprint_failure — produce stable 8-hex fingerprint for a failure signature
# Args: $1=job_name $2=signature (e.g. first 80 chars of detailsUrl or job name)
# Outputs: 8-char hex string
_fingerprint_failure() {
  local job_name="${1:-}" signature="${2:-}"
  local combined="${job_name}::${signature}"
  printf '%s' "$combined" | python3 -c "
import sys, hashlib
data = sys.stdin.read()
print(hashlib.sha256(data.encode()).hexdigest()[:8])
"
}

# _pr_already_filed_recently — returns 0 (true/skip) if fingerprint seen in last 24h
# Args: $1=fingerprint (8-hex)
_pr_already_filed_recently() {
  local fingerprint="$1"
  if [[ -z "$fingerprint" ]]; then return 1; fi
  if [[ ! -f "$FILED_GAPS_FILE" ]]; then return 1; fi
  # Use python3 - with heredoc to avoid bare-except/SystemExit bug in -c "..." form
  python3 - "$fingerprint" "$FILED_GAPS_FILE" << 'PYEOF'
import json, sys
from datetime import datetime, timezone, timedelta
cutoff = datetime.now(timezone.utc) - timedelta(hours=24)
fingerprint = sys.argv[1]
filed_path = sys.argv[2]
try:
    with open(filed_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
                if ev.get('fingerprint') == fingerprint:
                    ts_str = ev.get('ts', '')
                    if ts_str:
                        ev_ts = datetime.fromisoformat(ts_str.replace('Z', '+00:00'))
                        if ev_ts >= cutoff:
                            sys.exit(0)
            except Exception:
                pass
except Exception:
    pass
sys.exit(1)
PYEOF
}

# _record_filed_gap — persist fingerprint to dedup file
# Args: $1=pr_number $2=fingerprint $3=new_gap_id $4=job_name
_record_filed_gap() {
  local pr_num="$1" fingerprint="$2" new_gap_id="$3" job_name="$4"
  mkdir -p "$(dirname "$FILED_GAPS_FILE")"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"ts":"%s","pr_number":%d,"fingerprint":"%s","gap_id":"%s","job_name":"%s"}\n' \
    "$ts" "$pr_num" "$fingerprint" "$new_gap_id" "$job_name" >> "$FILED_GAPS_FILE"
}

# _record_rebase_debounce — record conflict skip in debounce file
# Args: $1=pr_number $2=head_sha $3=gap_id
_record_rebase_debounce() {
  local pr_num="$1" head_sha="$2" gap_id="$3"
  mkdir -p "$(dirname "$REBASE_DEBOUNCE_FILE")"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"ts":"%s","pr_number":%d,"head_sha":"%s","gap_id":"%s","reason":"conflict"}\n' \
    "$ts" "$pr_num" "$head_sha" "$gap_id" >> "$REBASE_DEBOUNCE_FILE"
}

# ─── INFRA-2346: pr-queue auto-processor helpers ──────────────────────────────
#
# Three new tiers added on top of the META-183/META-186 classifier:
#   1. CLEAN_GREEN  → auto-admin-merge (trusted authors only, hard-capped)
#   2. BLOCKED_FLAKE → gh run rerun --failed (capped per PR)
#   3. WEDGED_24H   → emit pr_wedged + DM the author (one-shot per 24h)
#
# Risk discipline:
#   - CLEAN_GREEN is hard-capped at MAX_ADMIN_MERGES per tick (default 3).
#   - The trunk-red gate ALSO covers admin-merge (admin-merging into broken
#     main propagates the brokenness).
#   - Trust-list defaults to bot/fleet accounts; humans never auto-admin-merge.
#   - Every action emits pr_queue_auto_action to ambient — operator can
#     reconstruct every merge by grepping ambient.

# _emit_pr_queue_auto_action — emit auto-processor action event
# Args: $1=pr_num $2=action $3=reason $4=author $5=merge_state
# scanner-anchor: kind=pr_queue_auto_action (INFRA-2346)
_emit_pr_queue_auto_action() {
  local pr_num="$1" action="$2" reason="$3" author="$4" merge_state="$5"
  local ts dry
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [ -n "$DRY_RUN" ]; then dry="true"; else dry="false"; fi
  printf '{"ts":"%s","kind":"pr_queue_auto_action","pr":%d,"action":"%s","reason":"%s","author":"%s","mergeStateStatus":"%s","dry_run":%s}\n' \
    "$ts" "$pr_num" "$action" "$reason" "$author" "$merge_state" "$dry" >> "$AMBIENT"
}

# _emit_flake_rerun_capped — INFRA-2361: emitted whenever a PR hits the
# per-PR flake-rerun cap on checks that are ALL known-flake-classified. This
# is the detection signal consumed by scripts/coord/flake-auto-quarantine.sh
# to spot checks that keep flaking across many *distinct* PRs (a candidate
# for auto-quarantine into KNOWN_FLAKES.yaml `check_flakes:`) rather than
# just noisily filing one gap per capped PR.
# Args: $1=pr_num $2=check_names_csv $3=author
# scanner-anchor: kind=flake_rerun_capped (INFRA-2361)
_emit_flake_rerun_capped() {
  local pr_num="$1" check_names="$2" author="$3"
  local ts dry
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [ -n "$DRY_RUN" ]; then dry="true"; else dry="false"; fi
  printf '{"ts":"%s","kind":"flake_rerun_capped","pr":%d,"check_names":"%s","author":"%s","dry_run":%s}\n' \
    "$ts" "$pr_num" "$check_names" "$author" "$dry" >> "$AMBIENT"
}

# _emit_pr_queue_skipped_trunk_red — single-event sentinel emitted once per
# tick when the trunk-red gate fires during the CLEAN_GREEN scan. Keeps a
# clean signal for operators to grep without N copies of pr_queue_auto_action.
# scanner-anchor: kind=pr_queue_skipped_trunk_red (INFRA-2346)
_emit_pr_queue_skipped_trunk_red() {
  local skipped="$1"  # count of PRs skipped
  local ts dry
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [ -n "$DRY_RUN" ]; then dry="true"; else dry="false"; fi
  printf '{"ts":"%s","kind":"pr_queue_skipped_trunk_red","skipped_count":%d,"dry_run":%s}\n' \
    "$ts" "$skipped" "$dry" >> "$AMBIENT"
}

# _emit_pr_shepherd_safe_mode_entered — emit event when entering safe-mode (META-187)
# scanner-anchor: kind=pr_shepherd_safe_mode_entered (META-187)
_emit_pr_shepherd_safe_mode_entered() {
  local ts dry
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [ -n "$DRY_RUN" ]; then dry="true"; else dry="false"; fi
  printf '{"ts":"%s","kind":"pr_shepherd_safe_mode_entered","dry_run":%s}\n' \
    "$ts" "$dry" >> "$AMBIENT"
}

# _emit_pr_shepherd_safe_mode_cleared — emit event when exiting safe-mode (META-187)
# scanner-anchor: kind=pr_shepherd_safe_mode_cleared (META-187)
_emit_pr_shepherd_safe_mode_cleared() {
  local ts dry
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [ -n "$DRY_RUN" ]; then dry="true"; else dry="false"; fi
  printf '{"ts":"%s","kind":"pr_shepherd_safe_mode_cleared","dry_run":%s}\n' \
    "$ts" "$dry" >> "$AMBIENT"
}

# _is_safe_mode_active — read current safe-mode state from state file
# Returns 0 (true) if in safe-mode, 1 (false) otherwise
_is_safe_mode_active() {
  [[ -f "$SAFE_MODE_STATE_FILE" ]] || return 1
  python3 - "$SAFE_MODE_STATE_FILE" << 'PYEOF'
import json, sys
path = sys.argv[1]
try:
    with open(path) as f:
        data = json.load(f)
        if data.get('active'):
            sys.exit(0)
except Exception:
    pass
sys.exit(1)
PYEOF
}

# _set_safe_mode — update safe-mode state in state file
# Args: $1=active (true/false)
_set_safe_mode() {
  local active="$1"
  mkdir -p "$(dirname "$SAFE_MODE_STATE_FILE")"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  python3 - "$SAFE_MODE_STATE_FILE" "$active" "$ts" << 'PYEOF'
import json, sys
path, active, ts = sys.argv[1], sys.argv[2] == 'true', sys.argv[3]
data = {'active': active, 'ts': ts}
with open(path, 'w') as f:
    json.dump(data, f)
PYEOF
}

# _emit_pr_wedged — emit wedged-PR signal
# Args: $1=pr_num $2=author $3=age_hours
# scanner-anchor: kind=pr_wedged (INFRA-2346)
_emit_pr_wedged() {
  local pr_num="$1" author="$2" age_hours="$3"
  local ts dry
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [ -n "$DRY_RUN" ]; then dry="true"; else dry="false"; fi
  printf '{"ts":"%s","kind":"pr_wedged","pr":%d,"author":"%s","age_hours":%d,"dry_run":%s}\n' \
    "$ts" "$pr_num" "$author" "$age_hours" "$dry" >> "$AMBIENT"
}

# _is_trusted_author — returns 0 if author appears in TRUST_AUTHORS list.
# Args: $1=author (gh login string)
_is_trusted_author() {
  local author="$1"
  [[ -z "$author" ]] && return 1
  # Comma-split TRUST_AUTHORS and exact-match. bash 3.2 compatible.
  local IFS=',' a
  for a in $TRUST_AUTHORS; do
    # Trim whitespace
    a="${a# }"; a="${a% }"
    [[ "$a" == "$author" ]] && return 0
  done
  return 1
}

# _load_check_flakes — emit one check_name per line from KNOWN_FLAKES.yaml
# Reads the `check_flakes:` section. Returns empty if file missing or no entries.
_load_check_flakes() {
  [[ -f "$KNOWN_FLAKES_FILE" ]] || return 0
  python3 - "$KNOWN_FLAKES_FILE" << 'PYEOF' 2>/dev/null || true
import sys, re
path = sys.argv[1]
try:
    with open(path) as f:
        content = f.read()
except Exception:
    sys.exit(0)
# Find the check_flakes: section (top-level key).
# Stop at next top-level key or EOF.
m = re.search(r'^check_flakes:\s*(.*?)(?=\n[A-Za-z_]+:|\Z)', content, re.DOTALL | re.MULTILINE)
if not m:
    sys.exit(0)
section = m.group(1)
# Match either inline form `check_flakes: []` (empty) or list-of-dicts entries.
if section.strip().startswith('[]'):
    sys.exit(0)
# Extract check_name values, including lines commented out (lines starting #).
for line in section.split('\n'):
    line = line.strip()
    if not line or line.startswith('#'):
        continue
    m2 = re.match(r'-?\s*check_name:\s*["\']?([^"\']+)["\']?\s*$', line)
    if m2:
        print(m2.group(1).strip())
PYEOF
}

# _is_blocked_flake — returns 0 if every FAILURE check name is in check_flakes
# Args: $1=fail_check_names_csv  (e.g. "ci.yml / fast-checks,gap-status-check")
_is_blocked_flake() {
  local fail_names="$1"
  [[ -z "$fail_names" ]] && return 1
  local known_flakes
  known_flakes=$(_load_check_flakes)
  [[ -z "$known_flakes" ]] && return 1
  # Every name in fail_names must be in known_flakes.
  local IFS=','
  local name
  for name in $fail_names; do
    name="${name# }"; name="${name% }"
    [[ -z "$name" ]] && continue
    if ! echo "$known_flakes" | grep -Fxq "$name"; then
      return 1
    fi
  done
  return 0
}

# _flake_rerun_count — get/inc per-PR rerun counter
# Args: $1=pr_num [$2=inc|read]  — default read
# Outputs: integer count to stdout. Initializes file on first use.
_flake_rerun_count() {
  local pr_num="$1" mode="${2:-read}"
  mkdir -p "$(dirname "$FLAKE_RERUN_FILE")"
  [[ -f "$FLAKE_RERUN_FILE" ]] || echo '{}' > "$FLAKE_RERUN_FILE"
  python3 - "$FLAKE_RERUN_FILE" "$pr_num" "$mode" << 'PYEOF'
import json, sys
path, pr_num, mode = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path) as f:
        data = json.load(f)
except Exception:
    data = {}
count = int(data.get(pr_num, 0))
if mode == 'inc':
    count += 1
    data[pr_num] = count
    with open(path, 'w') as f:
        json.dump(data, f)
print(count)
PYEOF
}

# _wedged_signaled_recently — returns 0 if a wedged signal was emitted for this
# PR in the last 24h (debounce). Initializes file on first use.
# Args: $1=pr_num
_wedged_signaled_recently() {
  local pr_num="$1"
  [[ -f "$WEDGED_SIGNAL_FILE" ]] || return 1
  python3 - "$WEDGED_SIGNAL_FILE" "$pr_num" << 'PYEOF'
import json, sys
from datetime import datetime, timezone, timedelta
path, pr_num = sys.argv[1], sys.argv[2]
cutoff = datetime.now(timezone.utc) - timedelta(hours=24)
try:
    with open(path) as f:
        data = json.load(f)
except Exception:
    sys.exit(1)
ts_str = data.get(pr_num)
if not ts_str:
    sys.exit(1)
try:
    ev_ts = datetime.fromisoformat(ts_str.replace('Z', '+00:00'))
    if ev_ts >= cutoff:
        sys.exit(0)
except Exception:
    pass
sys.exit(1)
PYEOF
}

# _record_wedged_signal — mark this PR as signaled now
# Args: $1=pr_num
_record_wedged_signal() {
  local pr_num="$1"
  mkdir -p "$(dirname "$WEDGED_SIGNAL_FILE")"
  [[ -f "$WEDGED_SIGNAL_FILE" ]] || echo '{}' > "$WEDGED_SIGNAL_FILE"
  python3 - "$WEDGED_SIGNAL_FILE" "$pr_num" << 'PYEOF'
import json, sys
from datetime import datetime, timezone
path, pr_num = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        data = json.load(f)
except Exception:
    data = {}
data[pr_num] = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
with open(path, 'w') as f:
    json.dump(data, f)
PYEOF
}

# _vote_request_already_sent — returns 0 if a vote-request was already
# broadcast for this exact PR/head_sha (debounce: only re-fire on new commits).
# Args: $1=pr_num $2=head_sha
_vote_request_already_sent() {
  local pr_num="$1" head_sha="$2"
  [[ -f "$VOTE_REQUEST_SIGNAL_FILE" ]] || return 1
  python3 - "$VOTE_REQUEST_SIGNAL_FILE" "$pr_num" "$head_sha" << 'PYEOF'
import json, sys
path, pr_num, head_sha = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path) as f:
        data = json.load(f)
except Exception:
    sys.exit(1)
sys.exit(0 if data.get(pr_num) == head_sha else 1)
PYEOF
}

# _record_vote_request_sent — mark this PR/head_sha as vote-request-broadcast
# Args: $1=pr_num $2=head_sha
_record_vote_request_sent() {
  local pr_num="$1" head_sha="$2"
  mkdir -p "$(dirname "$VOTE_REQUEST_SIGNAL_FILE")"
  [[ -f "$VOTE_REQUEST_SIGNAL_FILE" ]] || echo '{}' > "$VOTE_REQUEST_SIGNAL_FILE"
  python3 - "$VOTE_REQUEST_SIGNAL_FILE" "$pr_num" "$head_sha" << 'PYEOF'
import json, sys
path, pr_num, head_sha = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path) as f:
        data = json.load(f)
except Exception:
    data = {}
data[pr_num] = head_sha
with open(path, 'w') as f:
    json.dump(data, f)
PYEOF
}

cmd_tick() {
  # META-183: fetch full PR details with mergeStateStatus + autoMergeRequest for classification.
  # META-184: also fetch headRefOid (head SHA) for debounce keying.
  # META-185: also fetch statusCheckRollup for BLOCKED sub-state classification.
  # Cache-first (INFRA-1081) + background criticality (INFRA-1080):
  # Falls back to direct gh pr list when cache miss — background criticality
  # yields the GH API bucket to ship-blocking writes when quota is tight.
  # INFRA-2346: include author, baseRefName, updatedAt for new tiers (CLEAN_GREEN
  # admin-merge needs author for trust check + baseRefName for base=main guard;
  # WEDGED_24H needs updatedAt to detect 12h-no-commit staleness).
  #
  # INFRA-2464 audit: the full field set above (statusCheckRollup, headRefOid,
  # ...) isn't stored by the webhook-fed sqlite cache — pr_state only carries
  # the fields upserted from `pull_request` webhook payloads, and
  # statusCheckRollup is GraphQL-only. A like-for-like cache read can't
  # replace this call without a schema extension (tracked separately; see
  # gap notes). Deliberately NOT adding a "skip when cache_query_open_prs is
  # empty" short-circuit here: this daemon is the only reader of
  # mergeStateStatus/statusCheckRollup for the whole open-PR queue, and a
  # stale or unpopulated cache (webhook receiver down, fresh checkout, DB
  # reset) would silently starve every PR in the queue with no fallback —
  # exactly the kind of silent-daemon wedge the fleet pages on. The call
  # already carries CHUMP_GH_CALL_CRITICALITY=background (INFRA-1080) so it
  # yields the GH bucket to ship-blocking writes under quota pressure, which
  # is the safe mitigation for this call site.
  local prs_json
  prs_json=$(CHUMP_GH_CALL_CRITICALITY=background gh pr list --state open --limit 200 \
    --json number,title,mergeStateStatus,autoMergeRequest,createdAt,headRefOid,statusCheckRollup,author,baseRefName,headRefName,updatedAt 2>/dev/null || echo "[]")

  local count
  count=$(printf '%s' "$prs_json" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
  emit_tick "$count"

  # Classify each PR and emit one pr_classified event per PR.
  # Classification logic (META-183 + META-185):
  #   BEHIND           — mergeStateStatus=BEHIND (main moved, needs rebase)
  #   MERGEABLE        — mergeStateStatus=CLEAN and no autoMergeRequest (ready to merge, not yet armed)
  #   ARMED            — mergeStateStatus=CLEAN and autoMergeRequest set (auto-merge already armed — daemon leaves alone)
  #   DIRTY            — mergeStateStatus=DIRTY (semantic merge conflict)
  #   BLOCKED_GREEN    — mergeStateStatus=BLOCKED, all checks SUCCESS/SKIPPED, no auto-merge armed
  #                      (effectively MERGEABLE — target for auto-rearm-daemon; META-185)
  #   BLOCKED_REAL_FAIL— mergeStateStatus=BLOCKED, at least one check FAILURE
  #                      (real content failure — target for gap filing; META-185)
  #   BLOCKED          — mergeStateStatus=BLOCKED, checks still in-flight or inconclusive (catch-all)
  #   UNKNOWN          — mergeStateStatus=UNKNOWN/null (GitHub still computing)
  local classified
  classified=$(printf '%s' "$prs_json" | python3 -c "
import json, sys, re
from datetime import datetime, timezone

TERMINAL_NON_FAILURE = {'SUCCESS', 'SKIPPED', 'NEUTRAL', 'STALE', 'ACTION_REQUIRED'}

def classify_blocked(checks, has_automerge):
    # Conservative default: BLOCKED (checks still running)
    if not checks:
        return 'BLOCKED'
    has_failure = False
    all_terminal = True
    for ch in checks:
        conclusion = (ch.get('conclusion') or '').upper()
        status = (ch.get('status') or '').upper()
        if status not in ('COMPLETED',):
            # Still running (QUEUED, IN_PROGRESS, WAITING, PENDING, REQUESTED)
            all_terminal = False
        if conclusion == 'FAILURE':
            has_failure = True
    # Conservative: any FAILURE -> BLOCKED_REAL_FAIL regardless of others
    if has_failure:
        return 'BLOCKED_REAL_FAIL'
    # All completed with no failures and no auto-merge -> BLOCKED_GREEN
    if all_terminal and not has_automerge:
        return 'BLOCKED_GREEN'
    # Checks still running (or auto-merge already armed but still BLOCKED — unusual)
    return 'BLOCKED'

prs = json.load(sys.stdin)
now = datetime.now(timezone.utc)
for p in prs:
    ms = p.get('mergeStateStatus')
    has_automerge = p.get('autoMergeRequest') is not None
    checks = p.get('statusCheckRollup') or []
    if ms == 'BEHIND':
        c = 'BEHIND'
    elif ms == 'CLEAN' and not has_automerge:
        c = 'MERGEABLE'
    elif ms == 'CLEAN' and has_automerge:
        c = 'ARMED'
    elif ms == 'DIRTY':
        c = 'DIRTY'
    elif ms == 'BLOCKED':
        c = classify_blocked(checks, has_automerge)
    else:
        c = 'UNKNOWN'

    title = p.get('title', '')
    m = re.search(r'(INFRA|META|CREDIBLE|RESILIENT|EFFECTIVE|FLEET|DOC|MEM|VOA|SCALE)-\d+', title)
    gap_id = m.group(0) if m else ''

    created = p.get('createdAt', '')
    try:
        age = int((now - datetime.fromisoformat(created.replace('Z','+00:00'))).total_seconds() / 60)
    except Exception:
        age = 0

    head_sha = p.get('headRefOid', '')

    # Extract first FAILURE check info for BLOCKED_REAL_FAIL gap filing (META-186)
    fail_job = ''
    fail_sig = ''
    fail_check_names = []
    if c == 'BLOCKED_REAL_FAIL':
        for ch in checks:
            if (ch.get('conclusion') or '').upper() == 'FAILURE':
                name = ch.get('name') or ch.get('context') or 'unknown-job'
                fail_check_names.append(name)
                if not fail_job:
                    fail_job = name
                    details_url = ch.get('detailsUrl') or ch.get('targetUrl') or ''
                    fail_sig = details_url[:80] if details_url else fail_job

    # INFRA-2346: extra fields for the new tiers.
    # author          — login string; used for trust-list check (CLEAN_GREEN).
    # base_ref        — must be 'main' for admin-merge.
    # head_ref        — branch name (for run-id lookup on flake rerun).
    # updated_at      — for WEDGED_24H staleness (no commit in last 12h).
    # has_automerge   — exported so the action loop doesn't re-arm an
    #                   already-armed PR.
    author_obj = p.get('author') or {}
    author = author_obj.get('login', '') if isinstance(author_obj, dict) else ''
    base_ref = p.get('baseRefName', '')
    head_ref = p.get('headRefName', '')
    updated_at = p.get('updatedAt', '')
    # Derive CLEAN_GREEN: the classification stays as 'BLOCKED_GREEN' / 'MERGEABLE' /
    # 'ARMED' etc — we surface a SEPARATE flag because admin-merge is the
    # decision, not the classification. A PR can be MERGEABLE (CLEAN+no-arm) OR
    # BLOCKED_GREEN (BLOCKED+all-checks-pass) and BOTH are CLEAN_GREEN candidates.
    is_clean_green = c in ('MERGEABLE', 'BLOCKED_GREEN')

    # Hours since last update (WEDGED_24H signal).
    # For wedging we care about no-commits-in-last-12h — gh updatedAt
    # changes on commits, comments, label edits etc. Over-conservative
    # signal direction is harmless: a false-positive emits a wedged signal
    # for a chatty PR; a false-negative would silently lose a real wedge.
    try:
        hours_since_update = int((now - datetime.fromisoformat(updated_at.replace('Z','+00:00'))).total_seconds() / 3600)
    except Exception:
        hours_since_update = 0
    age_hours = age // 60

    print(json.dumps({
        'pr': p['number'],
        'classification': c,
        'gap_id': gap_id,
        'age_minutes': age,
        'age_hours': age_hours,
        'head_sha': head_sha,
        'fail_job': fail_job,
        'fail_sig': fail_sig,
        'fail_check_names': ','.join(fail_check_names),
        'author': author,
        'base_ref': base_ref,
        'head_ref': head_ref,
        'has_automerge': has_automerge,
        'is_clean_green': is_clean_green,
        'hours_since_update': hours_since_update,
    }))
" 2>/dev/null || true)

  # META-184: trunk-red guard — if trunk_red in last 30m, skip all rebases.
  local trunk_red_active=0
  if _should_skip_trunk_red; then
    trunk_red_active=1
    echo "[pr-shepherd-daemon] trunk_red detected in last 30m — safe-mode, no rebases" >&2
  fi

  # META-187: safe-mode state tracking and event emission
  local was_safe_mode_active=0
  if _is_safe_mode_active; then
    was_safe_mode_active=1
  fi

  # Detect state transitions and emit events
  if [ "$trunk_red_active" -eq 1 ] && [ "$was_safe_mode_active" -eq 0 ]; then
    # Entering safe-mode
    echo "[pr-shepherd-daemon] entering safe-mode due to trunk_red detection" >&2
    _emit_pr_shepherd_safe_mode_entered
    _set_safe_mode "true"
  elif [ "$trunk_red_active" -eq 0 ] && [ "$was_safe_mode_active" -eq 1 ]; then
    # Exiting safe-mode
    echo "[pr-shepherd-daemon] exiting safe-mode — no recent trunk_red detected" >&2
    _emit_pr_shepherd_safe_mode_cleared
    _set_safe_mode "false"
  elif [ "$trunk_red_active" -eq 1 ] && [ "$was_safe_mode_active" -eq 1 ]; then
    # Remaining in safe-mode
    echo "[pr-shepherd-daemon] still in safe-mode" >&2
  else
    # Normal mode (no safe-mode)
    if [ "$was_safe_mode_active" -eq 0 ]; then
      # Stays in normal mode — no event needed
      :
    fi
  fi

  # META-188: Update trunk_red_active to reflect the persistent safe-mode state.
  # This ensures guards use the actual safe-mode state (from state file), not just
  # the transient trunk_red event check, so destructive actions are truly restricted
  # while in safe-mode (even after the 30-min trunk_red event window expires).
  trunk_red_active=0
  if _is_safe_mode_active; then
    trunk_red_active=1
  fi

  # Cascade Gate: read latest kind=trunk_state_change from ambient.jsonl.
  # When TRUNK_RED is the latest state, hold the rebase queue — every PR
  # rebased onto a broken main inherits the failure → wastes runners. Wait
  # for trunk-sentinel to emit TRUNK_GREEN before resuming rebases.
  # Classification + ARMED handling continue unchanged; only rebase action holds.
  #
  # INFRA-2349: time-bounded. An unbounded hold self-perpetuates — while the
  # gate blocks admin-merges/rebases, fewer commits land on main, so
  # trunk-sentinel gets fewer fresh CI runs to observe a recovery, so the
  # gate never sees TRUNK_GREEN and never releases (17 PRs sat 24h on this
  # exact deadlock). Once trunk has been continuously RED for
  # CASCADE_MAX_HOLD_MINUTES, release the gate — trunk-sentinel has already
  # escalated to the operator by the 60-min mark, so nothing is lost.
  local trunk_state cascade_held=0
  trunk_state=$(_get_trunk_state)
  if [ "$trunk_state" = "RED" ]; then
    local red_minutes
    red_minutes=$(_trunk_red_minutes)
    if [ "$red_minutes" -ge "$CASCADE_MAX_HOLD_MINUTES" ]; then
      echo "[pr-shepherd-daemon] cascade gate expired — trunk red ${red_minutes}m >= cap ${CASCADE_MAX_HOLD_MINUTES}m, releasing" >&2
      _emit_pr_queue_cascade_gate_expired "$red_minutes"
    else
      cascade_held=1
      echo "[pr-shepherd-daemon] cascade held — trunk red (${red_minutes}m, cap ${CASCADE_MAX_HOLD_MINUTES}m)" >&2
    fi
  fi

  # RESILIENT-081: strict-aware rebase gate. Computed once per tick (cached
  # underneath, see _pr_shepherd_strict_enabled) — rebasing is only
  # meaningful when strict=true (BEHIND blocks the merge) or a merge queue
  # is the gate (queue serializes CI, no per-rebase reset). Under
  # strict=false with no merge queue, BEHIND PRs merge fine as-is, so
  # rebasing them is pure CI-reset churn.
  local rebase_gate_open=0
  if [ "$(_pr_shepherd_strict_enabled)" = "true" ] || [ "$(_merge_queue_active)" = "true" ]; then
    rebase_gate_open=1
  else
    echo "[pr-shepherd-daemon] strict=false, no merge queue — rebase gate closed this tick" >&2
  fi

  local rebase_count=0
  local arm_count=0
  local gap_file_count=0
  # INFRA-2346: counters for the new tiers.
  local admin_merge_count=0
  local flake_rerun_count=0
  local wedged_signal_count=0
  local admin_merge_skipped_trunk_red=0
  if [ -n "$classified" ]; then
    while IFS= read -r line; do
      local pr_num c gap_id age head_sha fail_job fail_sig
      local author base_ref head_ref has_automerge is_clean_green hours_since_update age_hours fail_check_names
      pr_num=$(printf '%s' "$line" | python3 -c "import json,sys; print(json.load(sys.stdin)['pr'])")
      c=$(printf '%s' "$line" | python3 -c "import json,sys; print(json.load(sys.stdin)['classification'])")
      gap_id=$(printf '%s' "$line" | python3 -c "import json,sys; print(json.load(sys.stdin)['gap_id'])")
      age=$(printf '%s' "$line" | python3 -c "import json,sys; print(json.load(sys.stdin)['age_minutes'])")
      head_sha=$(printf '%s' "$line" | python3 -c "import json,sys; print(json.load(sys.stdin).get('head_sha',''))" 2>/dev/null || echo "")
      fail_job=$(printf '%s' "$line" | python3 -c "import json,sys; print(json.load(sys.stdin).get('fail_job',''))" 2>/dev/null || echo "")
      fail_sig=$(printf '%s' "$line" | python3 -c "import json,sys; print(json.load(sys.stdin).get('fail_sig',''))" 2>/dev/null || echo "")
      # INFRA-2346: extra fields for new tiers
      author=$(printf '%s' "$line" | python3 -c "import json,sys; print(json.load(sys.stdin).get('author',''))" 2>/dev/null || echo "")
      base_ref=$(printf '%s' "$line" | python3 -c "import json,sys; print(json.load(sys.stdin).get('base_ref',''))" 2>/dev/null || echo "")
      head_ref=$(printf '%s' "$line" | python3 -c "import json,sys; print(json.load(sys.stdin).get('head_ref',''))" 2>/dev/null || echo "")
      has_automerge=$(printf '%s' "$line" | python3 -c "import json,sys; print('1' if json.load(sys.stdin).get('has_automerge') else '0')" 2>/dev/null || echo "0")
      is_clean_green=$(printf '%s' "$line" | python3 -c "import json,sys; print('1' if json.load(sys.stdin).get('is_clean_green') else '0')" 2>/dev/null || echo "0")
      hours_since_update=$(printf '%s' "$line" | python3 -c "import json,sys; print(json.load(sys.stdin).get('hours_since_update',0))" 2>/dev/null || echo "0")
      age_hours=$(printf '%s' "$line" | python3 -c "import json,sys; print(json.load(sys.stdin).get('age_hours',0))" 2>/dev/null || echo "0")
      fail_check_names=$(printf '%s' "$line" | python3 -c "import json,sys; print(json.load(sys.stdin).get('fail_check_names',''))" 2>/dev/null || echo "")
      _emit_pr_classified "$pr_num" "$c" "$gap_id" "$age"

      # ─── INFRA-2346 tier A: CLEAN_GREEN → auto-admin-merge ──────────────────
      # Independent of META-184/186 paths: a PR can be MERGEABLE or BLOCKED_GREEN
      # AND also be a trusted-author admin-merge target. Run this BEFORE the
      # existing tiers so the merge happens before any rebase/rearm work.
      if [ "$is_clean_green" = "1" ] && _is_trusted_author "$author" && [ "$base_ref" = "main" ] && [ "$has_automerge" = "0" ]; then
        # Trunk-red gate (non-negotiable per gap spec)
        if [ "$trunk_red_active" -eq 1 ] || [ "$cascade_held" -eq 1 ]; then
          admin_merge_skipped_trunk_red=$((admin_merge_skipped_trunk_red + 1))
          _emit_pr_queue_auto_action "$pr_num" "admin_merge_skipped" "trunk_red" "$author" "$c"
          continue
        fi
        # Per-tick hard-cap
        if [ "$admin_merge_count" -ge "$MAX_ADMIN_MERGES" ]; then
          _emit_pr_queue_auto_action "$pr_num" "admin_merge_skipped" "capped" "$author" "$c"
          continue
        fi
        if [ -n "$DRY_RUN" ]; then
          echo "[pr-shepherd-daemon] DRY_RUN: would admin-merge PR #${pr_num} (author=${author}, ${c})" >&2
          _emit_pr_queue_auto_action "$pr_num" "admin_merge" "trusted_author" "$author" "$c"
          admin_merge_count=$((admin_merge_count + 1))
        else
          echo "[pr-shepherd-daemon] admin-merging PR #${pr_num} (author=${author}, ${c})" >&2
          local merge_exit=0
          chump_gh pr merge "$pr_num" --squash --admin --delete-branch 2>&1 || merge_exit=$?
          if [ "$merge_exit" -eq 0 ]; then
            _emit_pr_queue_auto_action "$pr_num" "admin_merge" "trusted_author" "$author" "$c"
            admin_merge_count=$((admin_merge_count + 1))
            echo "[pr-shepherd-daemon] admin-merge OK: PR #${pr_num}" >&2
          else
            # transient or permanent — log and skip; next tick may retry transient
            _emit_pr_queue_auto_action "$pr_num" "admin_merge_failed" "gh_exit_${merge_exit}" "$author" "$c"
            echo "[pr-shepherd-daemon] admin-merge FAILED PR #${pr_num} (exit ${merge_exit})" >&2
          fi
        fi
        # Don't run further actions for this PR this tick — it was merged (or attempted).
        continue
      fi

      # ─── INFRA-2346 tier B: WEDGED_24H signal ─────────────────────────────
      # Independent of merge state: any PR open > 24h with no recent commits
      # gets a one-shot DM. The signal serves the human stewards (an operator
      # or the PR author), not the automation — so we emit it regardless of
      # classification, before the rebase/arm/file paths.
      if [ "$age_hours" -gt 24 ] && [ "$hours_since_update" -gt 12 ] && [ "$has_automerge" = "0" ]; then
        if ! _wedged_signaled_recently "$pr_num"; then
          _emit_pr_wedged "$pr_num" "$author" "$age_hours"
          _record_wedged_signal "$pr_num"
          wedged_signal_count=$((wedged_signal_count + 1))
          # Best-effort DM to author via broadcast.sh (the chump A2A protocol).
          # Author may not have a session-id (most don't), so we use --to <author>
          # and let broadcast.sh handle delivery — failure is non-fatal.
          if [ -z "$DRY_RUN" ] && [ -n "$author" ]; then
            local broadcast_msg="PR #${pr_num} (age ${age_hours}h, no commits in ${hours_since_update}h) appears wedged. Rebase, comment, or close?"
            bash "$REPO_ROOT/scripts/coord/broadcast.sh" --to "$author" WARN "$broadcast_msg" >/dev/null 2>&1 || true
          fi
          echo "[pr-shepherd-daemon] signaled wedged PR #${pr_num} (age=${age_hours}h, updated=${hours_since_update}h ago)" >&2
        fi
      fi

      # ─── INFRA-2346 tier C: BLOCKED_FLAKE retrigger ───────────────────────
      # Runs only on BLOCKED_REAL_FAIL PRs where every failing check is
      # known-flake-classified. Intercepts BEFORE the META-186 gap-filing
      # path so flake reruns don't generate noise gaps.
      if [ "$c" = "BLOCKED_REAL_FAIL" ] && _is_blocked_flake "$fail_check_names"; then
        if [ "$trunk_red_active" -eq 1 ] || [ "$cascade_held" -eq 1 ]; then
          _emit_pr_queue_auto_action "$pr_num" "flake_rerun_skipped" "trunk_red" "$author" "$c"
          continue
        fi
        local cur_count
        cur_count=$(_flake_rerun_count "$pr_num" read)
        if [ "$cur_count" -ge "$MAX_FLAKE_RERUNS_PER_PR" ]; then
          _emit_pr_queue_auto_action "$pr_num" "flake_rerun_skipped" "capped" "$author" "$c"
          _emit_flake_rerun_capped "$pr_num" "$fail_check_names" "$author"
          # Fall through to gap-filing path below (don't continue).
        else
          if [ -n "$DRY_RUN" ]; then
            echo "[pr-shepherd-daemon] DRY_RUN: would rerun flake checks PR #${pr_num} (count=${cur_count})" >&2
            _flake_rerun_count "$pr_num" inc >/dev/null
            _emit_pr_queue_auto_action "$pr_num" "flake_rerun" "known_flake" "$author" "$c"
            flake_rerun_count=$((flake_rerun_count + 1))
            continue
          else
            # Look up the latest run-id for this PR's head branch.
            # INFRA-2464: REST-backed cached lookup instead of raw
            # `gh run list` (GraphQL — top API burner per INFRA-1081 audit).
            local run_id rerun_exit=0
            run_id=$(run_cache_lookup_run_id "$head_ref" 2>/dev/null || echo "")
            if [ -n "$run_id" ]; then
              chump_gh run rerun "$run_id" --failed 2>&1 || rerun_exit=$?
              if [ "$rerun_exit" -eq 0 ]; then
                _flake_rerun_count "$pr_num" inc >/dev/null
                _emit_pr_queue_auto_action "$pr_num" "flake_rerun" "known_flake" "$author" "$c"
                flake_rerun_count=$((flake_rerun_count + 1))
                echo "[pr-shepherd-daemon] flake-rerun fired for PR #${pr_num} run=${run_id}" >&2
                continue
              else
                _emit_pr_queue_auto_action "$pr_num" "flake_rerun_failed" "gh_exit_${rerun_exit}" "$author" "$c"
              fi
            else
              _emit_pr_queue_auto_action "$pr_num" "flake_rerun_skipped" "no_run_id" "$author" "$c"
            fi
          fi
        fi
      fi


      # META-184: action phase — only for BEHIND PRs
      if [ "$c" = "BEHIND" ]; then
        # Guard -1 (RESILIENT-081): strict=false + no merge queue — BEHIND
        # PRs merge fine without a rebase, so issuing one is pure CI-reset
        # churn. Skip before any of the more expensive guards below.
        if [ "$rebase_gate_open" -eq 0 ]; then
          _emit_pr_action_taken "$pr_num" "rebase_skipped" "not_strict" "$gap_id"
          continue
        fi

        # Guard 0: cascade gate — trunk-sentinel says main is red, hold the queue
        if [ "$cascade_held" -eq 1 ]; then
          _emit_pr_action_taken "$pr_num" "rebase_skipped" "cascade_held" "$gap_id"
          continue
        fi

        # Guard 1: trunk-red safe-mode
        if [ "$trunk_red_active" -eq 1 ]; then
          _emit_pr_action_taken "$pr_num" "rebase_skipped" "trunk_red" "$gap_id"
          continue
        fi

        # Guard 2: skip if PR has an active claim lease
        if _pr_has_active_claim "$gap_id"; then
          echo "[pr-shepherd-daemon] PR #${pr_num} (${gap_id}) has active claim — skipping rebase" >&2
          _emit_pr_action_taken "$pr_num" "rebase_skipped" "claim" "$gap_id"
          continue
        fi

        # Guard 3: debounce — skip if this head SHA already hit a conflict
        if _pr_in_rebase_debounce "$pr_num" "$head_sha"; then
          echo "[pr-shepherd-daemon] PR #${pr_num} in rebase debounce (head_sha=${head_sha}) — skipping" >&2
          _emit_pr_action_taken "$pr_num" "rebase_skipped" "debounce" "$gap_id"
          continue
        fi

        # Guard 4: throttle — max rebases per tick
        if [ "$rebase_count" -ge "$MAX_REBASES" ]; then
          echo "[pr-shepherd-daemon] throttle: PR #${pr_num} skipped (${rebase_count}/${MAX_REBASES} rebases used this tick)" >&2
          _emit_pr_action_taken "$pr_num" "rebase_skipped" "throttle" "$gap_id"
          continue
        fi

        # Execute rebase
        if [ -n "$DRY_RUN" ]; then
          echo "[pr-shepherd-daemon] DRY_RUN: would rebase PR #${pr_num} (${gap_id})" >&2
          _emit_pr_action_taken "$pr_num" "rebase" "" "$gap_id"
          rebase_count=$((rebase_count + 1))
        else
          echo "[pr-shepherd-daemon] rebasing PR #${pr_num} (${gap_id})" >&2
          local rebase_out rebase_exit
          rebase_exit=0
          rebase_out=$(CHUMP_GH_CALL_CRITICALITY=background gh pr update-branch --rebase "$pr_num" 2>&1) || rebase_exit=$?

          if [ "$rebase_exit" -eq 0 ]; then
            _emit_pr_action_taken "$pr_num" "rebase" "" "$gap_id"
            rebase_count=$((rebase_count + 1))
            echo "[pr-shepherd-daemon] rebase OK: PR #${pr_num}" >&2
          elif echo "$rebase_out" | grep -q "RebaseConflictError\|conflict\|Cannot rebase"; then
            echo "[pr-shepherd-daemon] rebase conflict PR #${pr_num} — recording debounce" >&2
            _record_rebase_debounce "$pr_num" "$head_sha" "$gap_id"
            _emit_pr_action_taken "$pr_num" "rebase_skipped" "conflict" "$gap_id"
          else
            echo "[pr-shepherd-daemon] rebase FAILED PR #${pr_num}: ${rebase_out}" >&2
            _emit_pr_action_taken "$pr_num" "rebase_failed" "" "$gap_id"
            rebase_count=$((rebase_count + 1))
          fi
        fi

      # META-186: BLOCKED_GREEN → arm auto-merge (idempotent)
      elif [ "$c" = "BLOCKED_GREEN" ]; then
        # Guard: only arm auto-merge for trusted authors. This repo is public, main requires
        # zero approvals and one aggregate check, and merged main deploys to the fleet's nodes.
        # Without this guard the daemon would arm auto-merge on a stranger's green fork PR.
        # Same list as the admin-merge tier; an empty author fails closed.
        if ! _is_trusted_author "$author"; then
          _emit_pr_action_taken "$pr_num" "arm_auto_merge_skipped" "untrusted_author" "$gap_id"
          continue
        fi
        # Guard: trunk-red safe-mode
        if [ "$trunk_red_active" -eq 1 ]; then
          _emit_pr_action_taken "$pr_num" "arm_auto_merge_skipped" "trunk_red" "$gap_id"
          continue
        fi
        # Guard: throttle
        if [ "$arm_count" -ge "$MAX_ARMS" ]; then
          echo "[pr-shepherd-daemon] throttle: arm PR #${pr_num} skipped (${arm_count}/${MAX_ARMS} arms used this tick)" >&2
          _emit_pr_action_taken "$pr_num" "arm_auto_merge_skipped" "throttle" "$gap_id"
          continue
        fi
        if [ -n "$DRY_RUN" ]; then
          echo "[pr-shepherd-daemon] DRY_RUN: would arm auto-merge PR #${pr_num} (${gap_id})" >&2
          _emit_pr_action_taken "$pr_num" "arm_auto_merge" "" "$gap_id"
          arm_count=$((arm_count + 1))
        else
          echo "[pr-shepherd-daemon] arming auto-merge PR #${pr_num} (${gap_id})" >&2
          local arm_exit=0
          chump_gh pr merge "$pr_num" --auto --squash 2>&1 || arm_exit=$?
          if [ "$arm_exit" -eq 0 ]; then
            _emit_pr_action_taken "$pr_num" "arm_auto_merge" "" "$gap_id"
            arm_count=$((arm_count + 1))
            echo "[pr-shepherd-daemon] arm OK: PR #${pr_num}" >&2
          else
            echo "[pr-shepherd-daemon] arm FAILED PR #${pr_num} (exit ${arm_exit})" >&2
            _emit_pr_action_taken "$pr_num" "arm_auto_merge_failed" "" "$gap_id"
          fi
        fi

      # META-186: BLOCKED_REAL_FAIL → file follow-up gap with fingerprint dedup
      elif [ "$c" = "BLOCKED_REAL_FAIL" ]; then
        # Guard: trunk-red safe-mode
        if [ "$trunk_red_active" -eq 1 ]; then
          _emit_pr_action_taken "$pr_num" "file_followup_gap_skipped" "trunk_red" "$gap_id"
          continue
        fi
        # Guard: throttle
        if [ "$gap_file_count" -ge "$MAX_GAPS" ]; then
          echo "[pr-shepherd-daemon] throttle: file-gap PR #${pr_num} skipped (${gap_file_count}/${MAX_GAPS} gaps used this tick)" >&2
          _emit_pr_action_taken "$pr_num" "file_followup_gap_skipped" "throttle" "$gap_id"
          continue
        fi
        # Compute fingerprint and check dedup
        local fingerprint
        fingerprint=$(_fingerprint_failure "$fail_job" "$fail_sig")
        if _pr_already_filed_recently "$fingerprint"; then
          echo "[pr-shepherd-daemon] dedup: PR #${pr_num} fingerprint ${fingerprint} already filed recently — skipping" >&2
          _emit_pr_action_taken "$pr_num" "file_followup_gap_skipped" "dedup" "$gap_id"
          continue
        fi
        # Build gap title (capped at 120 chars)
        local short_job gap_title
        short_job="${fail_job:0:40}"
        if [ -n "$fail_sig" ] && [ "$fail_sig" != "$fail_job" ]; then
          gap_title="PR #${pr_num} failing on ${short_job}: ${fail_sig:0:60}"
        else
          gap_title="PR #${pr_num} failing on ${short_job}"
        fi
        gap_title="${gap_title:0:120}"
        if [ -n "$DRY_RUN" ]; then
          echo "[pr-shepherd-daemon] DRY_RUN: would file gap for PR #${pr_num} (${gap_id}): ${gap_title}" >&2
          local new_gap_id="DRY-RUN-${fingerprint}"
          _record_filed_gap "$pr_num" "$fingerprint" "$new_gap_id" "$fail_job"
          _emit_pr_action_taken_with_new_gap "$pr_num" "file_followup_gap" "" "$gap_id" "$new_gap_id"
          gap_file_count=$((gap_file_count + 1))
        else
          echo "[pr-shepherd-daemon] filing gap for PR #${pr_num}: ${gap_title}" >&2
          local gap_out new_gap_id=""
          gap_out=$(chump gap reserve --domain INFRA \
            --title "$gap_title" \
            --priority P2 \
            --effort xs \
            --force 2>&1) || true
          new_gap_id=$(printf '%s' "$gap_out" | python3 -c "
import sys, re
out = sys.stdin.read()
m = re.search(r'(INFRA|META|CREDIBLE|RESILIENT|EFFECTIVE|FLEET|DOC|MEM|VOA|SCALE)-\d+', out)
print(m.group(0) if m else '')
" 2>/dev/null || echo "")
          if [ -n "$new_gap_id" ]; then
            echo "[pr-shepherd-daemon] gap filed: ${new_gap_id} for PR #${pr_num}" >&2
            _record_filed_gap "$pr_num" "$fingerprint" "$new_gap_id" "$fail_job"
            _emit_pr_action_taken_with_new_gap "$pr_num" "file_followup_gap" "" "$gap_id" "$new_gap_id"
            gap_file_count=$((gap_file_count + 1))
          else
            echo "[pr-shepherd-daemon] WARN: gap reserve output: ${gap_out}" >&2
            _record_filed_gap "$pr_num" "$fingerprint" "UNKNOWN" "$fail_job"
            _emit_pr_action_taken "$pr_num" "file_followup_gap" "no_id_parsed" "$gap_id"
            gap_file_count=$((gap_file_count + 1))
          fi
        fi

      # META-189: MERGEABLE (clean, not yet armed, not a trusted-author
      # admin-merge target — those short-circuit above) → broadcast a
      # FEEDBACK kind=vote-request so the fleet casts consensus votes,
      # corr_id=pr-N so `chump vote pr-N +1|-1|0` and `chump consensus-tally
      # --corr-id pr-N` land on the same tally bucket.
      elif [ "$c" = "MERGEABLE" ]; then
        if _vote_request_already_sent "$pr_num" "$head_sha"; then
          _emit_pr_action_taken "$pr_num" "vote_request_skipped" "debounce" "$gap_id"
        elif [ -n "$DRY_RUN" ]; then
          echo "[pr-shepherd-daemon] DRY_RUN: would broadcast vote-request for PR #${pr_num}" >&2
          _emit_pr_action_taken "$pr_num" "vote_request_broadcast" "" "$gap_id"
          _record_vote_request_sent "$pr_num" "$head_sha"
        else
          echo "[pr-shepherd-daemon] broadcasting vote-request for PR #${pr_num}" >&2
          bash "$REPO_ROOT/scripts/coord/broadcast.sh" FEEDBACK vote-request "pr-${pr_num}" \
            "PR #${pr_num} is MERGEABLE — cast a consensus vote: chump vote pr-${pr_num} +1|-1|0 --reason '<why>'" \
            >/dev/null 2>&1 || true
          _emit_pr_action_taken "$pr_num" "vote_request_broadcast" "" "$gap_id"
          _record_vote_request_sent "$pr_num" "$head_sha"
        fi
      fi
    done <<< "$classified"
  fi

  # INFRA-2346: single trunk-red rollup event when admin-merges were blocked.
  if [ "$admin_merge_skipped_trunk_red" -gt 0 ]; then
    _emit_pr_queue_skipped_trunk_red "$admin_merge_skipped_trunk_red"
  fi

  echo "[pr-shepherd-daemon] tick — classified $count PRs, rebase=${rebase_count}, arm=${arm_count}, gap=${gap_file_count}, admin_merge=${admin_merge_count}, flake_rerun=${flake_rerun_count}, wedged=${wedged_signal_count}, dry_run: ${DRY_RUN:-false}" >&2
}

case "${1:-}" in
  tick) cmd_tick ;;
  --help|-h)
    sed -n '1,40p' "$0"
    exit 0
    ;;
  *)
    echo "Usage: $0 tick | --help" >&2
    exit 2
    ;;
esac
