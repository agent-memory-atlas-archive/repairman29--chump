#!/usr/bin/env bash
# test-gap-closure-consistency.sh — CREDIBLE-028 + CREDIBLE-039 + CREDIBLE-031
# + CREDIBLE-268: detect premature gap closure, stale-post-merge gaps, AND
# gaps closed by a PR that never touched the files their ACs name.
#
# Forward mode (CREDIBLE-028): queries state.db for gaps with status=done and
# closed_pr=N, then verifies each PR is actually merged on GitHub.
#
# File-overlap check (CREDIBLE-268 FIX 3, made unconditional in CREDIBLE-1297):
# for each forward-mode gap whose PR IS merged, extracts file-path-looking
# tokens from the gap's acceptance_criteria and compares them against the
# PR's changed-file list. ACs that name files but share none with the PR
# diff are the fingerprint of an over-broad auto-flip (e.g. a PR merely
# CITING a gap rather than doing its work) — see PR #3556, which changed 2
# files and closed 5 gaps by citing them. Extension of the existing
# forward-mode gate, not a new detector (deliberate: MINE BEFORE BUILD).
# CREDIBLE-1297: this check now ALWAYS fails the gate on a mismatch
# (independent of --strict) and logs the offending gap IDs — CI must fail
# whenever it fires, not just advise.
#
# Reverse mode (CREDIBLE-039): queries state.db for gaps with status=open and
# closed_pr=N, then checks if that PR is merged → emits stale_post_merge_gap.
#
# --auto-fix mode (CREDIBLE-039): for premature closures where the referenced
# PR is BLOCKED or DIRTY, flips state.db status back to in_progress.
#
# CREDIBLE-031 changes:
#   - Fail-closed when gh is unavailable (exit 1 instead of silent exit 0)
#     unless CHUMP_GH_REQUIRED=0 explicitly opts out (e.g. offline CI).
#   - Fixture-aware state.db lookup: CHUMP_STATE_DB env var overrides the
#     live .chump/state.db path. Enables test isolation without touching prod.
#
# Usage:
#   bash scripts/ci/test-gap-closure-consistency.sh                     # info
#   bash scripts/ci/test-gap-closure-consistency.sh --strict            # exit 1 on drift
#   bash scripts/ci/test-gap-closure-consistency.sh --emit-alert        # emit ambient event
#   bash scripts/ci/test-gap-closure-consistency.sh --auto-fix          # self-heal mode
#   bash scripts/ci/test-gap-closure-consistency.sh --reverse           # reverse-mode only
#
# Env:
#   CHUMP_STATE_DB       override path to state.db (fixture-aware, CREDIBLE-031)
#   CHUMP_GH_REQUIRED    0 = skip silently if gh unavailable; 1 = fail-closed (default 1)
#   CHUMP_GH_PROBE_SKIP  1 = skip gh API reachability probe (for offline environments)
#   CHUMP_GH_PROBE_TIMEOUT  seconds for gh API probe (default 10)
#
# Exit codes:
#   0 — no drift found
#   1 — drift detected (with --strict), or fatal error

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=lib/gate-emit.sh
source "$SCRIPT_DIR/lib/gate-emit.sh" 2>/dev/null || true
gate_emit_start "CREDIBLE-028" "$*"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
info() { printf '[INFO] %s\n' "$*"; }

STRICT=0
EMIT_ALERT=0
AUTO_FIX=0
REVERSE=0
LIMIT=30
ALL=0
USE_MAIN=0  # CREDIBLE-051: --use-main enables git-common-dir fallback; off by default
prev_arg=""
for arg in "$@"; do
    case "$arg" in
        --strict)      STRICT=1 ;;
        --emit-alert)  EMIT_ALERT=1 ;;
        --auto-fix)    AUTO_FIX=1 ;;
        --reverse)     REVERSE=1 ;;
        --all)         ALL=1; LIMIT=999999 ;;
        --use-main)    USE_MAIN=1 ;;
    esac
    if [[ "$prev_arg" == "--limit" ]]; then
        LIMIT="$arg"
    fi
    prev_arg="$arg"
done

# ── Resolve state.db (CREDIBLE-051 + CREDIBLE-031: fixture-aware) ────────────
# Order: CHUMP_STATE_DB env → $PWD/.chump/state.db → git-common-dir (only with --use-main).
# Without --use-main, the git-common-dir fallback is disabled so test fixtures
# in a tmp dir don't accidentally resolve to the live main-repo state.db.
if [[ -n "${CHUMP_STATE_DB:-}" ]]; then
    DB="$CHUMP_STATE_DB"
    info "Using fixture state.db: $DB"
elif [[ -f "$PWD/.chump/state.db" ]]; then
    DB="$PWD/.chump/state.db"
    MAIN_REPO="$PWD"
elif [[ "$USE_MAIN" -eq 1 ]]; then
    _GIT_COMMON="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || echo ".git")"
    if [[ "$_GIT_COMMON" == ".git" ]]; then
        MAIN_REPO="$REPO_ROOT"
    else
        MAIN_REPO="$(cd "$_GIT_COMMON/.." 2>/dev/null && pwd || echo "$REPO_ROOT")"
    fi
    DB="$MAIN_REPO/.chump/state.db"
else
    # No state.db found and --use-main not set — skip gracefully.
    warn "state.db not found at $PWD/.chump/state.db; use --use-main to fall back to main repo, or set CHUMP_STATE_DB"
    exit 0
fi
: "${MAIN_REPO:=$REPO_ROOT}"

if [[ ! -f "$DB" ]]; then
    warn "state.db not found at $DB — skipping closure consistency check"
    exit 0
fi

# ── CREDIBLE-031: fail-closed when gh unavailable ───────────────────────────
_gh_required="${CHUMP_GH_REQUIRED:-1}"
if ! command -v gh &>/dev/null; then
    if [[ "$_gh_required" == "0" ]]; then
        warn "gh CLI not found and CHUMP_GH_REQUIRED=0 — skipping GitHub PR state check"
        exit 0
    fi
    fail "gh CLI not found — cannot verify PR states. Set CHUMP_GH_REQUIRED=0 to skip in offline environments."
fi

# Probe GitHub API reachability (CREDIBLE-031 + INFRA-539 pattern)
if [[ "${CHUMP_GH_PROBE_SKIP:-0}" != "1" ]]; then
    _probe_timeout="${CHUMP_GH_PROBE_TIMEOUT:-10}"
    if ! timeout "$_probe_timeout" gh api /rate_limit --silent 2>/dev/null; then
        if [[ "$_gh_required" == "0" ]]; then
            warn "GitHub API unreachable and CHUMP_GH_REQUIRED=0 — skipping"
            exit 0
        fi
        fail "GitHub API unreachable (gh api /rate_limit timed out after ${_probe_timeout}s). Set CHUMP_GH_REQUIRED=0 to skip."
    fi
fi

# CREDIBLE-051: track gh-API failures so a degraded GitHub does not silence
# the gate by making per-gap iterations skip + outer loop claim pass.
# Escape hatch CHUMP_PREMATURE_CLOSURE_ALLOW_GH_FAIL=1 preserves the old
# skip-on-fail behavior for legitimate offline use.
GH_FAIL_COUNT=0
GH_FAIL_GAPS=()
ALLOW_GH_FAIL="${CHUMP_PREMATURE_CLOSURE_ALLOW_GH_FAIL:-0}"

LOCK_DIR="$MAIN_REPO/.chump-locks"
AMBIENT="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"
emit_alert() {
    local kind="$1" json_payload="$2"
    mkdir -p "$LOCK_DIR"
    TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","event":"ALERT","kind":"%s","source":"test-gap-closure-consistency","%s}\n' \
        "$TS" "$kind" "$json_payload" >> "$AMBIENT" 2>/dev/null || true
}

overall_drift=0
FILE_OVERLAP_IDS=()

# ── File-overlap check (CREDIBLE-268 FIX 3) ─────────────────────────────────
# For a done gap whose PR merged, extract file-path-looking tokens from the
# gap's acceptance_criteria and compare them against the PR's changed-file
# list. If the ACs name files but the PR touched NONE of them, that is the
# fingerprint of a closure that rode in on a citation rather than the work
# itself (PR #3556: 2 files changed, 5 gaps closed by naming them in prose).
#
# CREDIBLE-1297: unconditional drift (not gated on --strict). A PR that
# touches none of the files its closed gap's ACs name is the fingerprint of
# a citation-only closure (PR #3556), which is exactly the failure class this
# gate exists to catch — advisory-only made it too easy to ignore in
# practice. Emits gap_closed_no_file_overlap for operator review either way.
check_file_overlap() {
    local gap_id="$1" pr_num="$2"
    local ac_text
    ac_text="$(sqlite3 "$DB" "SELECT acceptance_criteria FROM gaps WHERE id='$gap_id';" 2>/dev/null || true)"
    [[ -z "$ac_text" ]] && return 0

    # File-path-looking tokens: at least one '/', ending in a word-ish extension.
    local ac_files=()
    while IFS= read -r tok; do
        [[ -n "$tok" ]] && ac_files+=("$tok")
    done < <(grep -oE '[A-Za-z0-9_./-]+/[A-Za-z0-9_./-]+\.[A-Za-z0-9]{1,5}' <<<"$ac_text" | sort -u)
    [[ ${#ac_files[@]} -eq 0 ]] && return 0

    local pr_files
    pr_files="$(gh pr view "$pr_num" --json files --jq '.files[].path' 2>/dev/null || echo "ERROR")"
    [[ "$pr_files" == "ERROR" ]] && return 0

    local overlap=0
    local f
    for f in "${ac_files[@]}"; do
        if grep -qF "$f" <<<"$pr_files" || grep -qF "$(basename "$f")" <<<"$pr_files"; then
            overlap=1
            break
        fi
    done

    if [[ "$overlap" -eq 0 ]]; then
        warn "$gap_id: PR #$pr_num touched none of the files its ACs name (${ac_files[*]:0:3})"
        FILE_OVERLAP_IDS+=("$gap_id:#$pr_num")
        if [[ "$EMIT_ALERT" -eq 1 ]]; then
            emit_alert "gap_closed_no_file_overlap" \
                '"gap_id":"'"$gap_id"'","pr":'"$pr_num"',"ac_files_sample":"'"${ac_files[0]}"'"'
        fi
        overall_drift=1
    fi
    return 0
}

# ── Forward mode: done gaps with closed_pr, verify PR is merged ────────────
run_forward_check() {
    local rows=()
    while IFS= read -r row; do
        [[ -n "$row" ]] && rows+=("$row")
    done < <(
        sqlite3 "$DB" \
            "SELECT id, closed_pr FROM gaps WHERE status='done' AND closed_pr IS NOT NULL AND closed_pr != '' AND CAST(closed_pr AS INTEGER) > 0 ORDER BY CAST(closed_pr AS INTEGER) DESC LIMIT $LIMIT;" \
            2>/dev/null || true
    )

    [[ ${#rows[@]} -eq 0 ]] && { pass "No done gaps with closed_pr — forward check clean"; return 0; }

    local scope_note="most recent $LIMIT"
    [[ "$ALL" -eq 1 ]] && scope_note="all"
    info "Forward: checking ${#rows[@]} done gap(s) ($scope_note) with closed_pr…"

    local drift_ids=() drift_details=() auto_fix_ids=()
    for row in "${rows[@]}"; do
        local gap_id="${row%%|*}"
        local pr_num="${row##*|}"
        local merged_at pr_state pr_state_raw
        merged_at="$(gh pr view "$pr_num" --json mergedAt --jq '.mergedAt' 2>/dev/null || echo "ERROR")"
        if [[ "$merged_at" == "ERROR" ]]; then
            # CREDIBLE-051: track gh-API failures. Don't silently skip — a
            # rate-limited or offline gh used to make this loop emit "all
            # verified" because every iteration just `continue`d. Now we
            # accumulate and let the outer loop decide based on
            # ALLOW_GH_FAIL.
            GH_FAIL_COUNT=$((GH_FAIL_COUNT + 1))
            GH_FAIL_GAPS+=("$gap_id:#$pr_num")
            warn "$gap_id: could not query PR #$pr_num"
            continue
        fi

        if [[ -z "$merged_at" || "$merged_at" == "null" ]]; then
            pr_state_raw="$(gh pr view "$pr_num" --json state --jq '.state' 2>/dev/null || echo "UNKNOWN")"
            warn "$gap_id: state=done closed_pr=#$pr_num but PR is $pr_state_raw (not merged)"
            drift_ids+=("$gap_id")
            drift_details+=("$gap_id:#$pr_num/$pr_state_raw")

            # --auto-fix: if PR is BLOCKED or DIRTY, flip state.db back to in_progress.
            if [[ "$AUTO_FIX" -eq 1 ]]; then
                local mergeable
                mergeable="$(gh pr view "$pr_num" --json mergeable --jq '.mergeable' 2>/dev/null || echo "UNKNOWN")"
                if [[ "$mergeable" == "BLOCKED" || "$mergeable" == "DIRTY" ]]; then
                    info "$gap_id: auto-fix — flipping status from done to in_progress (PR #$pr_num is $mergeable)"
                    CHUMP_ALLOW_RECYCLE=1 chump gap set "$gap_id" --status in_progress 2>/dev/null || \
                        warn "$gap_id: auto-fix failed — chump gap set returned non-zero"
                    emit_alert "premature_closure_auto_fixed" \
                        '"gap_id":"'"$gap_id"'","pr":'"$pr_num"',"old_status":"done","new_status":"in_progress","mergeable":"'"$mergeable"'"'
                    auto_fix_ids+=("$gap_id")
                else
                    info "$gap_id: PR #$pr_num is $mergeable — skipping auto-fix (only BLOCKED/DIRTY qualify)"
                fi
            fi
        else
            pass "$gap_id: PR #$pr_num merged ($merged_at)"
            check_file_overlap "$gap_id" "$pr_num"
        fi
    done

    if [[ ${#drift_ids[@]} -gt 0 ]]; then
        if [[ "$EMIT_ALERT" -eq 1 ]]; then
            local ids_json="$(printf '"%s",' "${drift_ids[@]}" | sed 's/,$//')"
            local note="${#drift_ids[@]} done gap(s) have closed_pr set but PR not merged"
            emit_alert "gap_drift_premature_close" '"ids":['"$ids_json"'],"note":"'"$note"'"'
            info "Emitted gap_drift_premature_close ALERT"
        fi
        echo ""
        echo "Forward: ${#drift_ids[@]} gap(s) marked done but PR not merged:"
        for d in "${drift_details[@]}"; do echo "  $d"; done
        [[ ${#auto_fix_ids[@]} -gt 0 ]] && echo "Auto-fixed: ${auto_fix_ids[*]}"
        [[ "$STRICT" -eq 1 ]] && overall_drift=1
    else
        pass "Forward: all ${#rows[@]} done gaps verified against GitHub"
    fi
}

# ── Reverse mode: open gaps with closed_pr, check if PR is now merged ──────
run_reverse_check() {
    local rows=()
    while IFS= read -r row; do
        [[ -n "$row" ]] && rows+=("$row")
    done < <(
        sqlite3 "$DB" \
            "SELECT id, closed_pr FROM gaps WHERE status='open' AND closed_pr IS NOT NULL AND closed_pr != '' AND CAST(closed_pr AS INTEGER) > 0 ORDER BY CAST(closed_pr AS INTEGER) DESC LIMIT $LIMIT;" \
            2>/dev/null || true
    )

    [[ ${#rows[@]} -eq 0 ]] && { pass "No open gaps with closed_pr — reverse check clean"; return 0; }

    local scope_note="most recent $LIMIT"
    [[ "$ALL" -eq 1 ]] && scope_note="all"
    info "Reverse: checking ${#rows[@]} open gap(s) ($scope_note) with closed_pr…"

    local stale_ids=() stale_details=()
    for row in "${rows[@]}"; do
        local gap_id="${row%%|*}"
        local pr_num="${row##*|}"
        local merged_at pr_title
        merged_at="$(gh pr view "$pr_num" --json mergedAt --jq '.mergedAt' 2>/dev/null || echo "ERROR")"
        if [[ "$merged_at" == "ERROR" ]]; then
            # CREDIBLE-051: track gh-API failures (see forward-mode comment).
            GH_FAIL_COUNT=$((GH_FAIL_COUNT + 1))
            GH_FAIL_GAPS+=("$gap_id:#$pr_num")
            warn "$gap_id: could not query PR #$pr_num"
            continue
        fi

        if [[ -n "$merged_at" && "$merged_at" != "null" ]]; then
            pr_title="$(gh pr view "$pr_num" --json title --jq '.title' 2>/dev/null || echo "?")"
            warn "$gap_id: status=open but closed_pr=#$pr_num IS merged ($merged_at) — gap should be done"
            stale_ids+=("$gap_id")
            stale_details+=("$gap_id:#$pr_num merged")
        else
            pass "$gap_id: PR #$pr_num not yet merged (consistent with status=open)"
        fi
    done

    if [[ ${#stale_ids[@]} -gt 0 ]]; then
        if [[ "$EMIT_ALERT" -eq 1 ]]; then
            local ids_json="$(printf '"%s",' "${stale_ids[@]}" | sed 's/,$//')"
            local note="${#stale_ids[@]} open gap(s) have closed_pr set but PR is merged — run chump gap ship <ID>"
            emit_alert "stale_post_merge_gap" '"ids":['"$ids_json"'],"note":"'"$note"'"'
            info "Emitted stale_post_merge_gap ALERT"
        fi
        echo ""
        echo "Reverse: ${#stale_ids[@]} gap(s) still open but closed_pr PR is merged:"
        for d in "${stale_details[@]}"; do echo "  $d"; done
        [[ "$STRICT" -eq 1 ]] && overall_drift=1
    else
        pass "Reverse: all ${#rows[@]} open gaps verified against GitHub"
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
echo "=== gap-closure-consistency check ==="
echo ""

if [[ "$REVERSE" -eq 0 ]]; then
    run_forward_check
else
    info "Skipping forward check (--reverse mode)"
fi
run_reverse_check

# CREDIBLE-051: gh-API failures during gap iteration are drift unless the
# operator opts in via CHUMP_PREMATURE_CLOSURE_ALLOW_GH_FAIL=1. Without this,
# a rate-limited or offline gh used to make the entire check exit 0.
if [[ "$GH_FAIL_COUNT" -gt 0 ]]; then
    if [[ "$ALLOW_GH_FAIL" == "1" ]]; then
        warn "gh-API failed for $GH_FAIL_COUNT gap(s); CHUMP_PREMATURE_CLOSURE_ALLOW_GH_FAIL=1 set — treating as soft skip"
    else
        warn "gh-API failed for $GH_FAIL_COUNT gap(s) — treating as drift (set CHUMP_PREMATURE_CLOSURE_ALLOW_GH_FAIL=1 for offline use)"
        if [[ "$EMIT_ALERT" -eq 1 ]]; then
            ids_json="$(printf '"%s",' "${GH_FAIL_GAPS[@]}" | sed 's/,$//')"
            emit_alert "gap_closure_check_gh_unavailable" '"gaps":['"$ids_json"'],"note":"gh-API failed during gap iteration"'
        fi
        [[ "$STRICT" -eq 1 ]] && overall_drift=1
    fi
fi

if [[ ${#FILE_OVERLAP_IDS[@]} -gt 0 ]]; then
    echo ""
    echo "File-overlap: ${#FILE_OVERLAP_IDS[@]} gap(s) closed by a PR that touched none of the files their ACs name:"
    for d in "${FILE_OVERLAP_IDS[@]}"; do echo "  $d"; done
fi

echo ""
if [[ "$overall_drift" -eq 0 ]]; then
    echo "All closure consistency checks passed."
    gate_emit_result "CREDIBLE-028" "pass" "" ""
    exit 0
else
    echo "Closure consistency drift detected (--strict mode)."
    printf '[FAIL] %s\n' "How to bypass cleanly: fix the drifted gap(s) via 'chump gap ship <ID>' (stale_post_merge_gap) or revert status to in_progress (premature_close); if the drift is a false positive set CHUMP_PREMATURE_CLOSURE_ALLOW_GH_FAIL=1 (gh-API flake) or re-run with --auto-fix" >&2
    gate_emit_result "CREDIBLE-028" "fail" "gap_drift_premature_close" "$overall_drift drift(s)"
    exit 1
fi
