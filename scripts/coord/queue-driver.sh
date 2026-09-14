#!/usr/bin/env bash
# shellcheck disable=SC1091  # lib/ sources use dynamic $SCRIPT_DIR — resolved at runtime
# INFRA-048 — queue driver: refresh the oldest BEHIND PR with auto-merge armed
# so GitHub branch protection's "require up-to-date" doesn't strand the queue.
#
# Background: branch protection requires PRs to be up-to-date with main, but
# auto-merge does not auto-rebase. When PR N lands, every other auto-merge-armed
# PR goes BEHIND and stays there until something pushes them forward. This
# script does that push.
#
# INFRA-056 extension: also auto-resolve DIRTY PRs whose ONLY conflict is
# docs/gaps.yaml (mechanical tail-append collisions are 90% of DIRTY events
# in this repo). Calls scripts/coord/resolve-gaps-conflict.py — refuses if any
# other file conflicts so non-append conflicts still get human attention.
#
# Usage:
#   scripts/coord/queue-driver.sh                 # process oldest BEHIND/DIRTY, exit
#   scripts/coord/queue-driver.sh --dry-run       # report what it would do
#   scripts/coord/queue-driver.sh --max N         # process up to N PRs (default 1)
#
# Designed to run from .github/workflows/queue-driver.yml on a 5-min cron and
# on push-to-main. Safe to run from a laptop too.
#
# Requires: gh CLI authenticated (GH_TOKEN env in CI; gh auth login locally).

set -euo pipefail

# INFRA-999: API cost telemetry. CHUMP_GH_SCRIPT sets the script tag in
# the emitted ambient.jsonl `github_api_call` lines.
# shellcheck source=lib/github.sh
# shellcheck disable=SC1091
source "$(dirname "$0")/lib/github.sh"
# INFRA-1241: route ambient appends through helper (surfaces errors to stderr).
# shellcheck source=lib/ambient-write.sh
# shellcheck disable=SC1091
source "$(dirname "$0")/lib/ambient-write.sh"
export CHUMP_GH_SCRIPT="queue-driver.sh"
# shellcheck source=../lib/orchestrator-log.sh
# shellcheck disable=SC1091
source "$(dirname "$0")/../lib/orchestrator-log.sh"
orch_log_start "queue-driver.sh" "$@"
trap 'orch_log_end "queue-driver.sh" "$?"' EXIT

DRY_RUN=0
MAX=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --max) MAX="$2"; shift 2 ;;
    -h|--help) sed -n '1,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if ! command -v gh >/dev/null 2>&1; then
  echo "queue-driver: gh CLI not found" >&2
  exit 3
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "queue-driver: jq not found" >&2
  exit 3
fi

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RESOLVER="$REPO_ROOT/scripts/coord/resolve-gaps-conflict.py"
export RESOLVER

# INFRA-670/INFRA-711: files whose change in a merged commit requires ALL open
# PRs to be rebased immediately, not just the next-in-queue one. Includes
# workspace config (Cargo.toml, rust-toolchain.toml) and high-traffic shared code
# (src/main.rs, src/lib.rs, src/agent_loop/**, src/dispatch.rs). Invalidates
# every branch's build state, which causes DIRTY conflicts if left unattended.
# Additional paths are configurable via scripts/coord/cascade-rebase-trigger-paths.txt
WORKSPACE_HOT_FILES=(
    "Cargo.toml"
    "rust-toolchain.toml"
)

_cascade_config="$REPO_ROOT/scripts/coord/cascade-rebase-trigger-paths.txt"
if [[ -f "$_cascade_config" ]]; then
    while IFS= read -r line; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        # Skip paths that are already hardcoded
        [[ "$line" == "Cargo.toml" || "$line" == "rust-toolchain.toml" ]] && continue
        WORKSPACE_HOT_FILES+=("$line")
    done < "$_cascade_config"
fi

# Detect whether the most recent commit on main touched any WORKSPACE_HOT_FILES.
# If it did, call `gh pr update-branch` on every open non-draft PR and emit an
# ambient event. Returns 0 always (errors per-PR are soft).
cascade_rebase_if_hot() {
    local changed
    changed=$(git -C "$REPO_ROOT" diff HEAD~1..HEAD --name-only 2>/dev/null || true)
    [[ -z "$changed" ]] && return 0

    local triggered_by=""
    for hot in "${WORKSPACE_HOT_FILES[@]}"; do
        if echo "$changed" | grep -qx "$hot"; then
            triggered_by="$hot"
            break
        fi
    done
    [[ -z "$triggered_by" ]] && return 0

    # ── INFRA-2232: skip-redundant-rerun gate ─────────────────────────────────
    # The per-SHA lock below (INFRA-1310) only dedupes *concurrent* workers
    # racing on the SAME commit. It does nothing for a *batch* of hot-file
    # commits landing seconds apart (e.g. an admin-merge queue draining 5
    # keystone PRs back to back) — each commit has a distinct SHA, so each one
    # independently fires a full `gh pr update-branch` sweep across every open
    # PR. Real incident (2026-08-15): a 5-commit hot-file batch fired 5 full
    # cascades within 90s, each resetting all ~30 open PRs' check-runs back to
    # pending (ok=1) — 150 redundant CI re-runs when 1 sweep (against the
    # final SHA) would have sufficed. This gate coalesces: if a cascade sweep
    # already ran within CHUMP_CASCADE_REBASE_DEBOUNCE_S (default 180s), skip
    # this one — the next natural queue-driver tick picks up any PR still
    # BEHIND once the batch settles.
    #
    # Bypass: CHUMP_CASCADE_REBASE_FORCE_RESWEEP=1 disables the gate (always
    # fire a fresh sweep per hot-file commit — pre-INFRA-2232 behavior).
    local _debounce_s="${CHUMP_CASCADE_REBASE_DEBOUNCE_S:-180}"
    local _last_run_file="$REPO_ROOT/.chump-locks/cascade-rebase-last-run.ts"
    if [[ "${CHUMP_CASCADE_REBASE_FORCE_RESWEEP:-0}" != "1" && -f "$_last_run_file" ]]; then
        local _last_run_s _now_s _elapsed_s
        _last_run_s="$(cat "$_last_run_file" 2>/dev/null || echo 0)"
        _now_s="$(date +%s)"
        _elapsed_s=$(( _now_s - _last_run_s ))
        if [[ "$_last_run_s" =~ ^[0-9]+$ ]] && (( _elapsed_s < _debounce_s )); then
            local _ambient_db="$REPO_ROOT/.chump-locks/ambient.jsonl"
            local _now_ts; _now_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            _ambient_write "$_ambient_db" \
                "$(printf '{"ts":"%s","kind":"cascade_rebase_skipped_redundant","triggered_by":"%s","seconds_since_last":%d,"debounce_s":%d}' \
                    "$_now_ts" "$triggered_by" "$_elapsed_s" "$_debounce_s")"
            echo "queue-driver: cascade debounced — sweep ran ${_elapsed_s}s ago (< ${_debounce_s}s window), skipping redundant CI re-run cascade"
            return 0
        fi
    fi

    # ── INFRA-1310: per-commit-SHA debounce lock ──────────────────────────────
    # With N concurrent workers all running queue-driver.sh, each one would
    # independently detect the hot-file commit and fire cascade_rebase_if_hot,
    # multiplying update-branch calls by worker count. Use an atomic mkdir lock
    # keyed on the commit SHA: the winning worker runs the cascade; all others
    # skip and emit kind=cascade_rebase_skipped_duplicate to ambient.jsonl.
    # Lock expires after 10 min (cascade for this SHA is done well before then).
    local head_sha
    head_sha=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null | cut -c1-12 || echo "unknown")
    local lock_dir="$REPO_ROOT/.chump-locks/cascade-rebase-${head_sha}.lock"

    # Sweep expired locks (older than 10 min) from previous commits.
    find "$REPO_ROOT/.chump-locks" -maxdepth 1 -name 'cascade-rebase-*.lock' \
        -type d -mmin +10 -exec rm -rf {} + 2>/dev/null || true

    if ! mkdir "$lock_dir" 2>/dev/null; then
        # Another worker already holds the lock for this SHA — skip.
        local _ambient="$REPO_ROOT/.chump-locks/ambient.jsonl"
        local _now; _now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        _ambient_write "$_ambient" \
            "$(printf '{"ts":"%s","kind":"cascade_rebase_skipped_duplicate","sha":"%s","triggered_by":"%s"}' \
                "$_now" "$head_sha" "$triggered_by")"
        echo "queue-driver: cascade already handled for sha=${head_sha} — skipping"
        return 0
    fi
    # Lock acquired — we are the designated cascade runner for this SHA.
    # Lock directory intentionally NOT removed after cascade; let it expire via
    # the 10-min sweep above so late-arriving workers also skip.

    echo "queue-driver: workspace hot-file '$triggered_by' changed on main — cascade rebasing all open PRs"

    # INFRA-2186: prefer webhook cache over `gh pr list` (which routes via
    # GraphQL when isDraft is requested). Multi-PR cascade waves (e.g. a 9-PR
    # admin-merge batch) fire this branch per merged hot-file commit and were
    # burning ~48 pr-list calls/hr -> graphql_exhausted spam. Fall back to
    # gh pr list only on cache miss.
    local all_prs=""
    if [[ -f "$(dirname "$0")/lib/github_cache.sh" ]]; then
        # shellcheck source=lib/github_cache.sh
        # shellcheck disable=SC1091
        source "$(dirname "$0")/lib/github_cache.sh"
        all_prs="$(cache_query_open_non_draft_prs)"
    fi
    if [[ -z "$all_prs" ]]; then
        all_prs=$(CHUMP_GH_CALL_CRITICALITY=background chump_gh pr list \
            --state open \
            --limit 100 \
            --json number,isDraft \
            -q '[.[] | select(.isDraft == false) | .number] | sort | .[]')
    fi

    if [[ -z "$all_prs" ]]; then
        echo "queue-driver: cascade — no open non-draft PRs to rebase"
        return 0
    fi

    local run_started_s; run_started_s="$(date +%s)"
    local ok=0 fail=0 auto_resolved=0 timeout_count=0
    for pr in $all_prs; do
        if [[ "$DRY_RUN" -eq 1 ]]; then
            echo "queue-driver: (dry-run) cascade would rebase PR #$pr"
            ok=$((ok + 1))
        else
            local _pr_started_ms _pr_ended_ms _pr_out _pr_rc
            _pr_started_ms="$(_chump_gh_now_ms 2>/dev/null || echo 0)"
            # INFRA-1648: 30s per-PR latency budget (INFRA-1458 AC5, never
            # actually enforced) — bound update-branch so one hung PR can't
            # stall the whole cascade sweep. Routed through chump_gh (not raw
            # gh) so throttling/secondary-rate-limit retry still applies;
            # _cascade_run_with_timeout forks a subshell rather than exec'ing
            # `timeout gh ...` so chump_gh's shell function stays reachable.
            _pr_out="$(_cascade_run_with_timeout 30 chump_gh pr update-branch "$pr")"
            _pr_rc=$?
            _pr_ended_ms="$(_chump_gh_now_ms 2>/dev/null || echo 0)"
            echo "$_pr_out"
            if [[ $_pr_rc -eq 0 ]]; then
                echo "queue-driver: ✓ cascade rebased PR #$pr"
                ok=$((ok + 1))
                _cascade_emit_pr_result "$pr" "success" "update_branch" "" "$((_pr_ended_ms - _pr_started_ms))"
            elif [[ $_pr_rc -eq 124 ]]; then
                echo "queue-driver: ⏱ cascade rebase timed out for PR #$pr (30s budget)"
                timeout_count=$((timeout_count + 1))
                fail=$((fail + 1))
                _cascade_emit_pr_result "$pr" "timeout" "update_branch" "transient" "$((_pr_ended_ms - _pr_started_ms))"
            else
                # INFRA-2255: server-side update-branch failed (DIRTY add-both).
                # Try local rebase + auto-resolve via the allowlist before
                # giving up. This kills today's manual rebase loop.
                if cascade_auto_resolve_pr "$pr"; then
                    echo "queue-driver: ✓ cascade auto-resolved PR #$pr"
                    ok=$((ok + 1))
                    auto_resolved=$((auto_resolved + 1))
                    _cascade_emit_pr_result "$pr" "success" "auto_resolve" "" "$((_pr_ended_ms - _pr_started_ms))"
                else
                    echo "queue-driver: ✗ cascade rebase failed for PR #$pr (may already be up-to-date or DIRTY with semantic conflicts)"
                    fail=$((fail + 1))
                    local _fclass; _fclass="$(_cascade_classify_failure "$_pr_rc" "$_pr_out")"
                    _cascade_emit_pr_result "$pr" "failed" "update_branch" "$_fclass" "$((_pr_ended_ms - _pr_started_ms))"
                fi
            fi
        fi
    done
    local run_duration_s=$(( $(date +%s) - run_started_s ))

    # INFRA-2232: record sweep completion time so a hot-file batch landing
    # within the debounce window is coalesced instead of re-firing the sweep.
    if [[ "$DRY_RUN" -ne 1 ]]; then
        date +%s > "$REPO_ROOT/.chump-locks/cascade-rebase-last-run.ts" 2>/dev/null || true
    fi

    local ambient="$REPO_ROOT/.chump-locks/ambient.jsonl"
    local now
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    _ambient_write "$ambient" \
        "$(printf '{"ts":"%s","kind":"cascade_rebase_triggered","triggered_by":"%s","pr_ok":%d,"pr_fail":%d,"auto_resolved":%d,"timeout_count":%d,"duration_s":%d,"dry_run":%d}' \
            "$now" "$triggered_by" "$ok" "$fail" "$auto_resolved" "$timeout_count" "$run_duration_s" "$DRY_RUN")"

    echo "queue-driver: cascade done — $ok rebased ($auto_resolved auto-resolved), $fail failed ($timeout_count timed out), ${run_duration_s}s elapsed"
}

# INFRA-1648: run a shell function (not just an external binary — `timeout`
# can't exec a bash function directly) under a wall-clock budget. Forks a
# subshell, which inherits already-defined functions like chump_gh without
# needing `export -f`. Returns 124 on timeout, matching `timeout`(1)'s
# convention so callers can share the same rc==124 check.
_cascade_run_with_timeout() {
    local budget="$1"; shift
    local out_file; out_file="$(mktemp)"
    ( "$@" >"$out_file" 2>&1 ) &
    local cmd_pid=$! waited=0
    while kill -0 "$cmd_pid" 2>/dev/null; do
        if [[ $waited -ge $budget ]]; then
            kill -9 "$cmd_pid" 2>/dev/null || true
            wait "$cmd_pid" 2>/dev/null || true
            cat "$out_file"
            rm -f "$out_file"
            return 124
        fi
        sleep 1
        waited=$((waited + 1))
    done
    wait "$cmd_pid"
    local rc=$?
    cat "$out_file"
    rm -f "$out_file"
    return "$rc"
}

# INFRA-1648: failure-class taxonomy — distinguishes failures worth retrying
# (transient: network blip, secondary rate limit, host hiccup, a PR that
# raced to merged/closed mid-sweep) from failures that need a human or a
# code change (permanent: semantic merge conflict, missing branch, PR not
# found). Callers use this to decide whether a follow-up sweep is likely to
# succeed without operator intervention.
_cascade_classify_failure() {
    local rc="$1" output="$2"
    if [[ "$rc" -eq 124 ]]; then
        echo "transient"
        return
    fi
    if echo "$output" | grep -qiE 'could not resolve host|network is unreachable|timed out|temporarily unavailable|connection reset|rate limit|502 Bad Gateway|503 Service Unavailable'; then
        echo "transient"
        return
    fi
    if echo "$output" | grep -qiE 'not found|no such|already merged|is closed|conflict'; then
        echo "permanent"
        return
    fi
    # Unknown shape — default to permanent so we don't silently retry-loop
    # something that will never resolve on its own.
    echo "permanent"
}

# INFRA-1648: per-PR observability event. One row per PR processed by the
# cascade, so `cascade_rebase_triggered`'s aggregate counts (pr_ok/pr_fail)
# can be cross-checked and drilled into per-PR after the fact.
# scanner-anchor: "kind":"cascade_rebase_pr_result"
_cascade_emit_pr_result() {
    local pr="$1" result="$2" phase="$3" failure_class="$4" duration_ms="$5"
    local _amb="$REPO_ROOT/.chump-locks/ambient.jsonl"
    local _now; _now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    _ambient_write "$_amb" \
        "$(printf '{"ts":"%s","kind":"cascade_rebase_pr_result","pr":%s,"result":"%s","phase":"%s","failure_class":"%s","duration_ms":%d}' \
            "$_now" "$pr" "$result" "$phase" "$failure_class" "${duration_ms:-0}")"
}

# INFRA-2255: when `gh pr update-branch` fails during cascade because the PR
# is DIRTY with add-both conflicts on append-only files, fall back to a local
# rebase + auto-resolve via scripts/coord/auto-resolve-add-both.sh.
#
# Returns 0 if the rebase + push succeeded (PR now refreshed); non-zero
# otherwise (out-of-scope conflict, worktree failure, push failure).
#
# Allowlist source-of-truth lives in auto-resolve-add-both.sh; we re-check
# here so we can emit kind=cascade_resolve_skipped_semantic with the
# offending file list before delegating.
cascade_auto_resolve_pr() {
    local pr="$1"
    local branch
    branch=$(cache_lookup_pr "$pr" 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
    print(d.get("headRefName") or d.get("head_ref") or "")
except Exception:
    pass
' 2>/dev/null)
    if [[ -z "$branch" ]]; then
        branch=$(CHUMP_GH_CALL_CRITICALITY=background chump_gh pr view "$pr" --json headRefName -q .headRefName 2>/dev/null || true)
    fi
    if [[ -z "$branch" ]]; then
        return 1
    fi

    local _amb="$REPO_ROOT/.chump-locks/ambient.jsonl"
    local _now; _now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    local tmpdir
    tmpdir=$(mktemp -d)
    if ! git -C "$REPO_ROOT" worktree add --quiet "$tmpdir" "origin/$branch" 2>&1; then
        rm -rf "$tmpdir"
        return 1
    fi

    pushd "$tmpdir" >/dev/null

    git fetch origin main --quiet 2>&1 || true

    if git rebase origin/main 2>&1 | grep -q "Successfully rebased"; then
        # Clean rebase — push.
        local _push_out _push_rc
        _push_out=$(git push origin "HEAD:$branch" --force-with-lease 2>&1)
        _push_rc=$?
        popd >/dev/null
        git -C "$REPO_ROOT" worktree remove --force "$tmpdir" 2>/dev/null || true
        return $_push_rc
    fi

    # Conflicted — classify against the allowlist (must match
    # auto-resolve-add-both.sh's allowlist).
    local conflicting
    conflicting=$(git diff --name-only --diff-filter=U)

    if [[ -z "$conflicting" ]]; then
        # No conflicts and no "Successfully rebased" — odd state, abort.
        git rebase --abort 2>/dev/null || true
        popd >/dev/null
        git -C "$REPO_ROOT" worktree remove --force "$tmpdir" 2>/dev/null || true
        return 1
    fi

    local out_of_scope=""
    local in_scope=""
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        case "$f" in
            scripts/ci/event-registry-reserved.txt|\
            Cargo.toml|\
            docs/observability/EVENT_REGISTRY.yaml|\
            scripts/setup/bootstrap-manifest.yaml|\
            scripts/coord/cascade-rebase-trigger-paths.txt)
                in_scope+="$f "
                ;;
            *)
                out_of_scope+="$f "
                ;;
        esac
    done <<< "$conflicting"

    if [[ -n "$out_of_scope" ]]; then
        # scanner-anchor: "kind":"cascade_resolve_skipped_semantic"
        _ambient_write "$_amb" \
            "$(printf '{"ts":"%s","kind":"cascade_resolve_skipped_semantic","pr":%s,"out_of_scope":"%s"}' \
                "$_now" "$pr" "${out_of_scope% }")"
        git rebase --abort 2>/dev/null || true
        popd >/dev/null
        git -C "$REPO_ROOT" worktree remove --force "$tmpdir" 2>/dev/null || true
        return 1
    fi

    # All conflicts in allowlist → delegate to auto-resolve-add-both.sh.
    # shellcheck disable=SC2086
    if ! "$REPO_ROOT/scripts/coord/auto-resolve-add-both.sh" $in_scope >/dev/null 2>&1; then
        git rebase --abort 2>/dev/null || true
        popd >/dev/null
        git -C "$REPO_ROOT" worktree remove --force "$tmpdir" 2>/dev/null || true
        return 1
    fi

    # Stage resolved files + continue rebase.
    local file_count=0
    for f in $in_scope; do
        git add "$f" 2>/dev/null || true
        file_count=$((file_count + 1))
    done

    if ! git -c core.editor=true rebase --continue 2>&1 | tail -3 >/dev/null; then
        git rebase --abort 2>/dev/null || true
        popd >/dev/null
        git -C "$REPO_ROOT" worktree remove --force "$tmpdir" 2>/dev/null || true
        return 1
    fi

    # Push the resolved branch.
    local _push_out _push_rc
    _push_out=$(git push origin "HEAD:$branch" --force-with-lease 2>&1)
    _push_rc=$?
    popd >/dev/null
    git -C "$REPO_ROOT" worktree remove --force "$tmpdir" 2>/dev/null || true

    if [[ $_push_rc -eq 0 ]]; then
        # scanner-anchor: "kind":"cascade_auto_resolved"
        _ambient_write "$_amb" \
            "$(printf '{"ts":"%s","kind":"cascade_auto_resolved","pr":%s,"file_count":%d,"files":"%s"}' \
                "$_now" "$pr" "$file_count" "${in_scope% }")"
        return 0
    fi
    return 1
}

# INFRA-1137: Auto-resolve a DIRTY PR by rebasing on main + leveraging the
# configured merge drivers in .gitattributes (chump-state-sql-regen,
# ci-yml-add-row, pre-commit-add-guard, gap-yaml-add-line, union). Accept the
# rebase if EVERY remaining conflict is in a merge-driver-configured file
# (the driver tried to resolve, and even if it produced markers, we trust
# `union`/the-driver's-state on the file). Refuse otherwise.
#
# Previously this function only accepted conflicts in the (now-defunct)
# docs/gaps.yaml legacy file — that left ~6 PRs/day stuck DIRTY for hours.
# Returns 0 on successful push, non-zero otherwise.
# INFRA-2464: cache-first branch resolution, mirroring cascade_auto_resolve_pr
# above — this was the one unconditional raw `gh pr view` left in the file
# (every other read site here already tries the sqlite cache before falling
# back to a live call).
resolve_dirty_pr() {
  local pr="$1"
  local branch
  branch=$(cache_lookup_pr "$pr" 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
    print(d.get("headRefName") or d.get("head_ref") or "")
except Exception:
    pass
' 2>/dev/null)
  if [[ -z "$branch" ]]; then
    branch=$(CHUMP_GH_CALL_CRITICALITY=background chump_gh pr view "$pr" --json headRefName -q .headRefName 2>/dev/null || true)
  fi
  if [[ -z "$branch" ]]; then
    echo "queue-driver: ✗ #$pr — could not resolve branch name"
    return 1
  fi

  local tmpdir
  tmpdir=$(mktemp -d)
  trap 'rm -rf "$tmpdir"' RETURN

  # Shallow checkout — we only need to rebase one branch on top of main.
  if ! git -C "$REPO_ROOT" worktree add --quiet "$tmpdir" "origin/$branch" 2>&1; then
    echo "queue-driver: ✗ #$pr — worktree add failed (branch=$branch)"
    return 1
  fi

  pushd "$tmpdir" >/dev/null

  git fetch origin main --quiet 2>&1 || true
  if git rebase origin/main 2>&1 | grep -q "Successfully rebased"; then
    # Clean rebase — push and we're done.
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "queue-driver: (dry-run) #$pr clean rebase — would force-push"
    else
      git fetch origin "$branch" --quiet 2>/dev/null || true
      local _push_out
      _push_out=$(git push origin "HEAD:$branch" --force-with-lease 2>&1)
      local _push_rc=$?
      echo "$_push_out" | tail -1
      if [[ $_push_rc -ne 0 ]]; then
        echo "queue-driver: ✗ #$pr push failed after clean rebase"
        _ambient_write "${LOCK_DIR:-$REPO_ROOT/.chump-locks}/ambient.jsonl" \
          "$(printf '{"ts":"%s","kind":"dirty_pr_push_failed","pr":%s,"phase":"clean_rebase","error":"%s"}' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$pr" "$(echo "$_push_out" | tail -1 | sed 's/"/\\"/g')")"
        popd >/dev/null
        git -C "$REPO_ROOT" worktree remove --force "$tmpdir" 2>/dev/null || true
        return 1
      fi
      echo "queue-driver: ✓ #$pr clean rebase pushed"
    fi
    popd >/dev/null
    git -C "$REPO_ROOT" worktree remove --force "$tmpdir" 2>/dev/null || true
    return 0
  fi

  # Conflicted — read .gitattributes for files with configured merge drivers.
  # Any conflicting file in this set is auto-resolvable; anything else is
  # genuine human-attention conflict.
  local md_patterns=()
  if [[ -f .gitattributes ]]; then
    # Each line: `<pattern> merge=<driver>` or `<pattern> merge=union`
    while IFS= read -r line; do
      local pat="${line%% *}"
      [[ -n "$pat" && "$pat" != "#"* ]] && md_patterns+=("$pat")
    done < <(grep -E "merge=" .gitattributes 2>/dev/null)
  fi

  local _amb="${LOCK_DIR:-$REPO_ROOT/.chump-locks}/ambient.jsonl"
  local conflicting
  conflicting=$(git diff --name-only --diff-filter=U)
  local conflict_files; conflict_files=$(echo "$conflicting" | tr '\n' ' ')

  # Helper: does a file match any merge-driver pattern?
  _is_md_file() {
    local f="$1" pat
    for pat in "${md_patterns[@]}"; do
      # bash extglob substring match — patterns are filenames or globs.
      # Use bash's [[ var == glob ]] which handles wildcards.
      [[ "$f" == "$pat" ]] && return 0
    done
    return 1
  }

  # Check every conflicting file is merge-driver-managed.
  local unresolvable=""
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if ! _is_md_file "$f"; then
      unresolvable+="$f "
    fi
  done <<< "$conflicting"

  if [[ -n "$unresolvable" ]]; then
    echo "queue-driver: ✗ #$pr DIRTY but conflicts in non-merge-driver files: $unresolvable"
    _ambient_write "$_amb" \
      "$(printf '{"ts":"%s","kind":"dirty_pr_unresolvable","pr":%s,"conflict_files":"%s","unresolvable":"%s"}' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$pr" "${conflict_files% }" "${unresolvable% }")"
    git rebase --abort 2>/dev/null || true
    popd >/dev/null
    git -C "$REPO_ROOT" worktree remove --force "$tmpdir" 2>/dev/null || true
    return 1
  fi

  # Every conflict is in a merge-driver-managed file. The driver should have
  # run already during rebase — re-stage each file (in case the driver wrote
  # a resolved version but didn't clear the conflict flag) and try to continue.
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    git add "$f" 2>/dev/null || true
  done <<< "$conflicting"

  if ! git -c core.editor=true rebase --continue 2>&1 | tail -3; then
    echo "queue-driver: ✗ #$pr — rebase --continue failed after merge-driver resolution"
    _ambient_write "$_amb" \
      "$(printf '{"ts":"%s","kind":"dirty_pr_unresolvable","pr":%s,"conflict_files":"%s","note":"rebase_continue_failed"}' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$pr" "${conflict_files% }")"
    git rebase --abort 2>/dev/null || true
    popd >/dev/null
    git -C "$REPO_ROOT" worktree remove --force "$tmpdir" 2>/dev/null || true
    return 1
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "queue-driver: (dry-run) #$pr DIRTY auto-resolved via merge drivers — would force-push ($conflict_files)"
  else
    git fetch origin "$branch" --quiet 2>/dev/null || true
    local _push_out
    _push_out=$(git push origin "HEAD:$branch" --force-with-lease 2>&1)
    local _push_rc=$?
    echo "$_push_out" | tail -1
    if [[ $_push_rc -ne 0 ]]; then
      echo "queue-driver: ✗ #$pr push failed after dirty auto-resolve"
      _ambient_write "$_amb" \
        "$(printf '{"ts":"%s","kind":"dirty_pr_push_failed","pr":%s,"conflict_files":"%s","phase":"dirty_resolve","error":"%s"}' \
          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$pr" "${conflict_files% }" "$(echo "$_push_out" | tail -1 | sed 's/"/\\"/g')")"
      git rebase --abort 2>/dev/null || true
      popd >/dev/null
      git -C "$REPO_ROOT" worktree remove --force "$tmpdir" 2>/dev/null || true
      return 1
    fi
    echo "queue-driver: ✓ #$pr DIRTY auto-resolved via merge drivers ($conflict_files)"
    _ambient_write "$_amb" \
      "$(printf '{"ts":"%s","kind":"dirty_pr_auto_resolved","pr":%s,"conflict_files":"%s"}' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$pr" "${conflict_files% }")"
  fi

  popd >/dev/null
  git -C "$REPO_ROOT" worktree remove --force "$tmpdir" 2>/dev/null || true
  return 0
}

# INFRA-670: cascade rebase when a workspace-wide file (Cargo.toml, etc.) just
# landed on main. Must run before the BEHIND/DIRTY loop so we don't miss PRs
# that don't have auto-merge armed but still need rebasing.
cascade_rebase_if_hot

# INFRA-1081: prefer reading BEHIND PRs from .chump/github_cache.db (populated
# by github-webhook-receiver.py + reconcile). Avoids burning GraphQL on every
# 5-min cron tick. Falls back to direct gh pr list when cache is empty (first
# run, after cache nuke, or smee/webhook receiver down).
behind_candidates=""
dirty_candidates=""
if [[ -f "$(dirname "$0")/lib/github_cache.sh" ]]; then
    # shellcheck source=lib/github_cache.sh
    # shellcheck disable=SC1091
    source "$(dirname "$0")/lib/github_cache.sh"
    behind_candidates="$(cache_query_behind_prs)"
    # INFRA-2186: DIRTY analog via dedicated helper (was inline sqlite). Emits
    # consistent cache_hit/cache_miss events to ambient.
    dirty_candidates="$(cache_query_dirty_armed_prs)"
fi
# Fallback: cache empty (or library missing) → one direct gh pr list call.
if [[ -z "$behind_candidates" && -z "$dirty_candidates" ]]; then
    behind_candidates=$(CHUMP_GH_CALL_CRITICALITY=background chump_gh pr list \
      --state open \
      --limit 50 \
      --json number,mergeStateStatus,autoMergeRequest,isDraft \
      -q '[.[] | select(.isDraft == false) | select(.autoMergeRequest != null) | select(.mergeStateStatus == "BEHIND") | .number] | sort | .[]')
    dirty_candidates=$(CHUMP_GH_CALL_CRITICALITY=background chump_gh pr list \
      --state open \
      --limit 50 \
      --json number,mergeStateStatus,autoMergeRequest,isDraft \
      -q '[.[] | select(.isDraft == false) | select(.autoMergeRequest != null) | select(.mergeStateStatus == "DIRTY") | .number] | sort | .[]')
fi

if [[ -z "$behind_candidates" && -z "$dirty_candidates" ]]; then
  echo "queue-driver: no BEHIND or DIRTY auto-merge PRs — nothing to do"
  exit 0
fi

count=0

# BEHIND first (cheap, common case).
for pr in $behind_candidates; do
  if [[ "$count" -ge "$MAX" ]]; then
    break
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "queue-driver: (dry-run) would refresh PR #$pr (BEHIND)"
  else
    echo "queue-driver: refreshing PR #$pr (BEHIND)"
    orch_log_step "refreshing PR #$pr (BEHIND)"
    if chump_gh pr update-branch "$pr" 2>&1; then
      echo "queue-driver: ✓ #$pr refreshed"
    else
      echo "queue-driver: ✗ #$pr refresh failed (may have just turned DIRTY — try next run)"
    fi
  fi
  count=$((count + 1))
done

# DIRTY second (rebase + auto-resolve gaps.yaml only).
# INFRA-2271: only count SUCCESSFUL resolution toward MAX budget. Semantic-skip
# (resolve_dirty_pr returns non-zero) must continue to next DIRTY, otherwise
# every invocation re-picks the same skipped PR and other DIRTY never get tried.
skipped=0
for pr in $dirty_candidates; do
  if [[ "$count" -ge "$MAX" ]]; then
    break
  fi
  echo "queue-driver: attempting DIRTY auto-resolve for PR #$pr"
  orch_log_step "attempting DIRTY auto-resolve for PR #$pr"
  if resolve_dirty_pr "$pr"; then
    # success — count toward MAX budget
    count=$((count + 1))
    _ambient_write "$REPO_ROOT/.chump-locks/ambient.jsonl" \
      "$(printf '{"ts":"%s","kind":"queue_driver_iter_attempted","pr":%s,"outcome":"resolved"}' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$pr")"
  else
    # skip — DO NOT count toward MAX; advance to next DIRTY in same run
    echo "queue-driver: leaving #$pr for human owner — continuing to next DIRTY"
    skipped=$((skipped + 1))
    _ambient_write "$REPO_ROOT/.chump-locks/ambient.jsonl" \
      "$(printf '{"ts":"%s","kind":"queue_driver_iter_attempted","pr":%s,"outcome":"skipped_semantic"}' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$pr")"
  fi
done

echo "queue-driver: processed $count PR(s), skipped $skipped semantic-conflict PR(s)"
orch_log_step "done — processed $count PR(s), skipped $skipped semantic-conflict PR(s)"
