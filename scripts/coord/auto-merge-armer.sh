#!/usr/bin/env bash
# shellcheck disable=SC1091  # lib/ sources use dynamic $SCRIPT_DIR — resolved at runtime
# INFRA-1113: Single-owner auto-merge armer — enforces 5s spacing between
# successive arm calls to avoid GitHub secondary rate limits.
#
# All callers (bot-merge.sh, pr-rescue.sh) delegate here instead of calling
# gh pr merge --auto directly. One process = one rate-limit signature.
#
# Usage:
#   auto-merge-armer.sh --pr <N> [--pr <N> ...] [--repo <owner/repo>]
#
# Exit codes:
#   0 — all PRs armed (or already armed)
#   1 — bad args / unresolvable repo
#   2 — arm failed after retries on at least one PR

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOCKS_DIR="${REPO_ROOT}/.chump-locks"

# shellcheck source=lib/github.sh
source "${SCRIPT_DIR}/lib/github.sh"
# INFRA-1241: route ambient appends through helper (surfaces errors to stderr).
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/ambient-write.sh"
export CHUMP_GH_SCRIPT="auto-merge-armer.sh"
# RESILIENT-1613: the one arm policy — a `no-auto-merge` label (or legacy hold
# label) or an `Auto-merge: hold` body/comment line is a decision, not a fault.
# shellcheck source=lib/arm-policy.sh
source "${SCRIPT_DIR}/lib/arm-policy.sh"
# RESILIENT-1616: the shared pr-cut predicate — a deliberately cut PR is
# terminal; the central armer must refuse it no matter which organ delegated here.
# shellcheck source=lib/pr-cut-guard.sh
source "${SCRIPT_DIR}/lib/pr-cut-guard.sh"

# RESILIENT-1613: name the caller in pr_arm_skipped_hold / pr_rearmed so a
# re-arm war is attributable to the organ that started it, not just to the
# armer every organ routes through.
_armer_caller() {
    local cmd
    cmd="$(ps -o command= -p "${PPID}" 2>/dev/null || true)"
    cmd="$(printf '%s' "${cmd}" | tr ' ' '\n' | grep -E '\.(sh|py)$' | head -1 || true)"
    if [[ -n "${cmd}" ]]; then
        printf 'auto-merge-armer.sh<-%s' "$(basename "${cmd}")"
    else
        printf 'auto-merge-armer.sh'
    fi
}
ARMER_NAME="$(_armer_caller)"

# INFRA-1113: min wall-clock seconds between successive gh pr merge --auto calls.
ARM_SPACING_S="${CHUMP_AUTO_MERGE_SPACING_S:-5}"

# INFRA-1377: merge queue mode.
# When merge queue is active on main, REST-direct merge bypasses queue ordering
# (bad!), and --squash conflicts with the queue's configured merge method.
# Set CHUMP_MERGE_QUEUE_ENABLED=1 to force-enable, =0 to force-disable, or
# leave unset for live detection via the GitHub GraphQL API.
MERGE_QUEUE_ACTIVE=""   # lazily set on first arm_with_retry call

REPO="${GITHUB_REPOSITORY:-}"
PR_NUMS=()

# ── Args ──────────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --pr)   PR_NUMS+=("$2"); shift 2 ;;
        --repo) REPO="$2";       shift 2 ;;
        *) echo "[auto-merge-armer] ERROR: unknown arg: $1" >&2; exit 1 ;;
    esac
done

if [[ ${#PR_NUMS[@]} -eq 0 ]]; then
    echo "[auto-merge-armer] ERROR: at least one --pr <N> required." >&2
    exit 1
fi

# ── Resolve repo ──────────────────────────────────────────────────────────────
if [[ -z "${REPO}" ]]; then
    REPO="$(git -C "${REPO_ROOT}" remote get-url origin 2>/dev/null \
        | sed 's|.*github.com[:/]||;s|.git$||' || true)"
fi
if [[ -z "${REPO}" ]]; then
    echo "[auto-merge-armer] ERROR: Could not determine GITHUB_REPOSITORY." >&2
    exit 1
fi

mkdir -p "${LOCKS_DIR}" 2>/dev/null || true

# ── Helpers ───────────────────────────────────────────────────────────────────
emit_ambient() {
    local kind="$1" pr_num="$2" detail="${3:-}"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    _ambient_write "${LOCKS_DIR}/ambient.jsonl" \
        "$(printf '{"ts":"%s","kind":"%s","pr":%s,"detail":"%s"}' \
            "${ts}" "${kind}" "${pr_num}" "${detail}")"
}

# INFRA-1311: Per-PR exponential backoff for failed gh pr merge attempts.
# Backoff state is persisted in .chump-locks/bot-merge-backoff-<pr>.ts as a
# UNIX epoch timestamp (the earliest time the next attempt is allowed).
# Initial delay: 30s. Multiplier: 2x per retry. Max: 300s.
# File is written on any non-200 merge failure, deleted on success.

# _backoff_file <pr_num>  — path to the backoff timestamp file
_backoff_file() {
    printf '%s/bot-merge-backoff-%s.ts' "${LOCKS_DIR}" "$1"
}

# _backoff_remaining <pr_num>
# Prints remaining seconds in backoff window (0 if not in backoff).
_backoff_remaining() {
    local pr_num="$1" bf
    bf="$(_backoff_file "${pr_num}")"
    [[ -f "${bf}" ]] || { printf '0'; return 0; }
    local until_ts now
    until_ts="$(cat "${bf}" 2>/dev/null || echo 0)"
    now="$(date -u +%s)"
    local remaining=$(( until_ts - now ))
    if [[ $remaining -le 0 ]]; then
        printf '0'
    else
        printf '%s' "${remaining}"
    fi
}

# _backoff_write <pr_num> <delay_s>
# Writes the backoff deadline (now + delay_s) to the backoff file.
_backoff_write() {
    local pr_num="$1" delay_s="$2"
    local bf until_ts
    bf="$(_backoff_file "${pr_num}")"
    until_ts=$(( $(date -u +%s) + delay_s ))
    printf '%s\n' "${until_ts}" > "${bf}" 2>/dev/null || true
}

# _backoff_clear <pr_num>
# Removes the backoff file (called on successful merge).
_backoff_clear() {
    local bf
    bf="$(_backoff_file "$1")"
    rm -f "${bf}" 2>/dev/null || true
}

# _backoff_next_delay <pr_num>
# Returns the next backoff duration based on current file contents.
# 30s initial, ×2 per retry, max 300s.
_backoff_next_delay() {
    local pr_num="$1" bf until_ts now delay
    bf="$(_backoff_file "${pr_num}")"
    if [[ ! -f "${bf}" ]]; then
        # No prior backoff — first failure gets 30s.
        printf '30'
        return 0
    fi
    until_ts="$(cat "${bf}" 2>/dev/null || echo 0)"
    now="$(date -u +%s)"
    # Estimate current delay from (until - now_at_write). We store only the
    # deadline, not the duration; reconstruct an approximation by reading how
    # much was remaining when we last wrote. For simplicity: double the current
    # window relative to a 30s base, clamped to 300s.
    # We read elapsed since the deadline was set; use a tag-file to track retry count.
    local count_file="${LOCKS_DIR}/bot-merge-backoff-${pr_num}.count"
    local count=0
    [[ -f "${count_file}" ]] && count="$(cat "${count_file}" 2>/dev/null || echo 0)"
    count=$(( count + 1 ))
    printf '%s\n' "${count}" > "${count_file}" 2>/dev/null || true
    # 30 * 2^(count-1), max 300
    delay=30
    local i
    for (( i=1; i<count; i++ )); do
        delay=$(( delay * 2 ))
        [[ $delay -ge 300 ]] && delay=300 && break
    done
    printf '%s' "${delay}"
}

# INFRA-1223: try REST PUT /pulls/N/merge first when all required checks are
# already green. REST PUT lives on a different rate-limit lane than the
# GraphQL `enablePullRequestAutoMerge` mutation, so it bypasses the
# secondary mutation gag entirely. Returns 0 on REST-direct success, 1 if
# the PR isn't yet mergeable-now (so the caller should fall through to the
# GraphQL arm path). Disable with CHUMP_AUTO_MERGE_REST_DIRECT=0.
rest_direct_merge_if_green() {
    local pr_num="$1"
    [[ "${CHUMP_AUTO_MERGE_REST_DIRECT:-1}" == "0" ]] && return 1

    local sha checks_json incomplete failed total commit_title
    sha="$(chump_gh api "repos/${REPO}/pulls/${pr_num}" --jq '.head.sha' 2>/dev/null || true)"
    [[ -z "${sha}" ]] && return 1

    checks_json="$(chump_gh api "repos/${REPO}/commits/${sha}/check-runs" --paginate 2>/dev/null || true)"
    [[ -z "${checks_json}" ]] && return 1

    # Count incomplete/failed required checks. We treat all non-skipped/
    # neutral/cancelled checks as required at this layer — same heuristic
    # as bot-merge.sh INFRA-1166. Pass the JSON via $1 not stdin to avoid
    # the `python3 - <<HEREDOC` stdin-collision footgun (SC2259).
    local counts
    counts="$(python3 -c '
import sys, json
try:
    data = json.loads(sys.argv[1])
except Exception:
    print("0 0 0"); sys.exit(0)
checks = data.get("check_runs", [])
incomplete = failed = total = 0
for c in checks:
    conclusion = (c.get("conclusion") or "").lower()
    if conclusion in ("skipped", "neutral", "cancelled"):
        continue
    total += 1
    status = (c.get("status") or "").lower()
    if status != "completed":
        incomplete += 1
    elif conclusion != "success":
        failed += 1
print(f"{incomplete} {failed} {total}")
' "${checks_json}")"
    incomplete="$(printf '%s' "${counts}" | awk '{print $1}')"
    failed="$(printf '%s' "${counts}" | awk '{print $2}')"
    total="$(printf '%s' "${counts}" | awk '{print $3}')"

    [[ "${total:-0}" -gt 0 ]] || return 1
    [[ "${incomplete:-1}" -eq 0 ]] || return 1
    [[ "${failed:-1}" -eq 0 ]] || return 1

    commit_title="$(chump_gh api "repos/${REPO}/pulls/${pr_num}" --jq '.title' 2>/dev/null || echo "Merge PR #${pr_num}")"

    echo "[auto-merge-armer] PR #${pr_num}: all ${total} checks green — trying REST PUT (no GraphQL)" >&2
    if chump_gh api "repos/${REPO}/pulls/${pr_num}/merge" \
            -X PUT \
            -f merge_method=squash \
            -f "commit_title=${commit_title}" \
            >/dev/null 2>&1; then
        emit_ambient "auto_merge_rest_direct" "${pr_num}" \
            "script=auto-merge-armer.sh checks=${total}"
        echo "[auto-merge-armer] PR #${pr_num}: REST-direct merge succeeded (no GraphQL)" >&2
        return 0
    fi
    # REST PUT failed (often 405 — branch protection requires admin). Fall
    # through to GraphQL arm so we still queue the merge.
    return 1
}

# INFRA-1438: Post-arm verification — confirm autoMergeRequest is non-null.
# gh pr merge --auto can return exit 0 silently while GraphQL is exhausted,
# leaving the PR without an auto-merge arm. Detect and retry before returning.
#
# verify_arm <pr_num> [attempt_count]
#   Returns 0 if verified, 1 if null after one 30s retry.
verify_arm() {
    local pr_num="$1" attempt_count="${2:-1}"
    local armed

    sleep 2
    armed="$(chump_gh api "repos/${REPO}/pulls/${pr_num}" \
        --jq '.auto_merge != null' 2>/dev/null || echo 'false')"

    if [[ "${armed}" == "true" ]]; then
        emit_ambient "auto_merge_arm_verified" "${pr_num}" \
            "attempt_count=${attempt_count} script=auto-merge-armer.sh"
        echo "[auto-merge-armer] PR #${pr_num}: arm verified (autoMergeRequest non-null)." >&2
        return 0
    fi

    # Null on first check — retry once with 30s backoff (INFRA-1438).
    local retry_count=$(( attempt_count + 1 ))
    echo "[auto-merge-armer] PR #${pr_num}: WARNING: arm returned 0 but autoMergeRequest is null — retrying in 30s… (attempt ${retry_count})" >&2
    sleep 30

    armed="$(chump_gh api "repos/${REPO}/pulls/${pr_num}" \
        --jq '.auto_merge != null' 2>/dev/null || echo 'false')"

    if [[ "${armed}" == "true" ]]; then
        emit_ambient "auto_merge_arm_verified" "${pr_num}" \
            "attempt_count=${retry_count} script=auto-merge-armer.sh"
        echo "[auto-merge-armer] PR #${pr_num}: arm verified on retry (autoMergeRequest non-null)." >&2
        return 0
    fi

    emit_ambient "auto_merge_arm_verify_failed" "${pr_num}" \
        "attempt_count=${retry_count} script=auto-merge-armer.sh"
    echo "[auto-merge-armer] ERROR: PR #${pr_num}: autoMergeRequest still null after retry — arm silently failed." >&2
    return 1
}

# INFRA-8180: refuse to (re-)arm a PR whose current head already has a FAILED
# required check. Arming such a PR is a guaranteed no-op: GitHub disables
# auto-merge again within seconds and attributes the disable to the enabling
# token, which is exactly the signal INFRA-8178's human-vs-bot disarm
# classifier misread as a "bot disarm" and re-armed again — manufacturing a
# 5-minute arm/disarm loop (PR #5414, 2026-10-15T11:25Z-16:20Z, 9 cycles).
# Reads `gh pr view --json statusCheckRollup` for the PR's CURRENT head (not
# a cached/prior sha) so a push that fixes the red check is picked up on the
# next tick. Any check with conclusion FAILURE blocks the arm; PENDING,
# QUEUED, NEUTRAL, and SUCCESS checks do not. Fails OPEN (returns 1, i.e. "no
# failing check detected") on any gh/parse error so a transient API hiccup
# never blocks a legitimate arm — the existing retry/backoff machinery in
# arm_with_retry already covers transient failure.
#
# head_has_failing_required_check <pr_num>
head_has_failing_required_check() {
    local pr_num="$1"
    local rollup_json
    rollup_json="$(chump_gh pr view "${pr_num}" --repo "${REPO}" \
        --json statusCheckRollup 2>/dev/null || true)"
    [[ -z "${rollup_json}" ]] && return 1

    python3 -c '
import json, sys
try:
    data = json.loads(sys.argv[1])
except Exception:
    sys.exit(1)
for c in (data.get("statusCheckRollup") or []):
    if (c.get("conclusion") or "").upper() == "FAILURE":
        sys.exit(0)
sys.exit(1)
' "${rollup_json}"
}

# INFRA-8180: emit auto_merge_arm_skipped(reason=required_check_failed) at
# most once per (pr, head_sha) pair — not once per tick — by remembering the
# last sha we logged for this PR in a small marker file. A head that stays
# red across many armer invocations (every farmer/bot-merge tick) would
# otherwise spam ambient.jsonl and burn the same API budget INFRA-8178 was
# trying to protect.
#
# log_red_head_once <pr_num> <head_sha>
log_red_head_once() {
    local pr_num="$1" head_sha="$2"
    local marker="${LOCKS_DIR}/auto-merge-armer-red-head-${pr_num}.last"
    local last_logged
    last_logged="$(cat "${marker}" 2>/dev/null || true)"
    if [[ "${last_logged}" == "${head_sha}" ]]; then
        return 0
    fi
    printf '%s' "${head_sha}" > "${marker}" 2>/dev/null || true
    emit_ambient "auto_merge_arm_skipped" "${pr_num}" \
        "reason=required_check_failed sha=${head_sha:0:12} script=auto-merge-armer.sh"
    echo "[auto-merge-armer] PR #${pr_num}: head ${head_sha:0:12} has a FAILED required check — refusing to arm." >&2
}

# INFRA-1377: detect whether GitHub Merge Queue is active for main.
# Cached in $MERGE_QUEUE_ACTIVE after first call — one API round-trip per
# armer invocation. Returns "true" or "false".
_detect_merge_queue() {
    if [[ "${CHUMP_MERGE_QUEUE_ENABLED:-}" == "1" || "${CHUMP_USE_MERGE_QUEUE:-}" == "1" ]]; then
        printf 'true'; return
    fi
    if [[ "${CHUMP_MERGE_QUEUE_ENABLED:-}" == "0" || "${CHUMP_USE_MERGE_QUEUE:-}" == "0" ]]; then
        printf 'false'; return
    fi
    # Live check: GitHub returns a non-null MergeQueue object when the queue
    # is configured for the branch.
    local owner repo_name result
    owner="${REPO%%/*}"
    repo_name="${REPO##*/}"
    result="$(gh api graphql \
        -f owner="${owner}" -f name="${repo_name}" \
        -f query='query($owner:String!,$name:String!){
          repository(owner:$owner,name:$name){
            mergeQueue(branch:"main"){id}}}' \
        --jq '.data.repository.mergeQueue != null' 2>/dev/null || printf 'false')"
    printf '%s' "${result}"
}

# Arm with secondary-rate-limit-aware retry (mirrors gh_with_backoff in bot-merge.sh).
# INFRA-1223: tries REST-direct path first before the GraphQL arm.
# INFRA-1311: writes per-PR backoff file on failure; clears it on success.
# INFRA-1377: skips REST-direct and --squash when merge queue is active.
arm_with_retry() {
    local pr_num="$1"
    local -a delays=(60 120 240)
    local attempt=0 rc tmpout

    # INFRA-1377: detect merge queue on first call and cache for this run.
    if [[ -z "${MERGE_QUEUE_ACTIVE}" ]]; then
        MERGE_QUEUE_ACTIVE="$(_detect_merge_queue)"
        if [[ "${MERGE_QUEUE_ACTIVE}" == "true" ]]; then
            echo "[auto-merge-armer] Merge queue active on main — REST-direct bypass disabled; using queue arm (no --squash)." >&2
        fi
    fi

    # INFRA-1223: REST-direct fast path. If all checks are green, merge now
    # via REST PUT — bypasses the GraphQL mutation entirely.
    # INFRA-1377: skip REST-direct when merge queue is active — REST PUT would
    # bypass the queue's ordering guarantee and violate the serialization contract.
    if [[ "${MERGE_QUEUE_ACTIVE}" != "true" ]]; then
        if rest_direct_merge_if_green "${pr_num}"; then
            # REST-direct success — clear any lingering backoff state.
            _backoff_clear "${pr_num}"
            rm -f "${LOCKS_DIR}/bot-merge-backoff-${pr_num}.count" 2>/dev/null || true
            return 0
        fi
    fi

    while true; do
        tmpout="$(mktemp)"
        set +e
        # INFRA-1377: omit --squash when merge queue is active — the queue uses
        # its own configured merge method (SQUASH by default). Passing --squash
        # to the queue arm is redundant and may cause "already queued" errors on
        # some GitHub versions. Without merge queue: keep --squash for history.
        if [[ "${MERGE_QUEUE_ACTIVE}" == "true" ]]; then
            CHUMP_GH_CALL_CRITICALITY=background chump_gh pr merge "${pr_num}" --repo "${REPO}" --auto >"${tmpout}" 2>&1
        else
            CHUMP_GH_CALL_CRITICALITY=background chump_gh pr merge "${pr_num}" --repo "${REPO}" --auto --squash >"${tmpout}" 2>&1
        fi
        rc=$?
        set -e

        if [[ $rc -eq 0 ]]; then
            rm -f "${tmpout}"
            # INFRA-1438: verify that auto-merge actually engaged — gh pr merge
            # --auto can return 0 silently under GraphQL exhaustion without setting
            # autoMergeRequest. verify_arm sleeps 2s then checks; retries once at 30s.
            if verify_arm "${pr_num}" "${attempt}"; then
                if [[ "${MERGE_QUEUE_ACTIVE}" == "true" ]]; then
                    # scanner-anchor: "kind":"pr_merge_group_enqueued"
                    _ambient_write "${LOCKS_DIR}/ambient.jsonl" \
                        "$(printf '{"ts":"%s","kind":"pr_merge_group_enqueued","pr":%s,"branch":"main","mode":"merge_group"}' \
                            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${pr_num}")"
                fi
                # INFRA-1311: successful merge + verified — clear backoff state.
                _backoff_clear "${pr_num}"
                rm -f "${LOCKS_DIR}/bot-merge-backoff-${pr_num}.count" 2>/dev/null || true
                return 0
            fi
            # verify_arm failed: fall through as rc=2 so the outer caller marks
            # this PR as failed and emits auto_merge_arm_failed.
            rc=2
        fi

        if grep -qi "secondary rate limit\|rate limit already exceeded" "${tmpout}" \
                && [[ $attempt -lt 3 ]]; then
            local sleep_secs=${delays[$attempt]}
            rm -f "${tmpout}"
            attempt=$(( attempt + 1 ))
            echo "[auto-merge-armer] PR #${pr_num}: secondary rate limit — sleeping ${sleep_secs}s (retry ${attempt}/3)…" >&2
            sleep "${sleep_secs}"
            continue
        fi

        # INFRA-1311: non-200/non-rate-limit failure — write backoff file so
        # the next invocation skips this PR until the window expires.
        local _next_delay
        _next_delay="$(_backoff_next_delay "${pr_num}")"
        _backoff_write "${pr_num}" "${_next_delay}"
        local _until_ts
        _until_ts=$(( $(date -u +%s) + _next_delay ))
        local _until_human
        _until_human="$(date -u -r "${_until_ts}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
            || date -u -d "@${_until_ts}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
            || printf '%s' "${_until_ts}")"
        echo "[auto-merge-armer] PR #${pr_num}: merge failed — backoff ${_next_delay}s until ${_until_human}" >&2
        emit_ambient "bot_merge_backoff_written" "${pr_num}" \
            "delay_s=${_next_delay} until=${_until_human} script=auto-merge-armer.sh"

        cat "${tmpout}" >&2
        rm -f "${tmpout}"
        return "$rc"
    done
}

# ── Main ──────────────────────────────────────────────────────────────────────
LAST_ARM_TS=0
ANY_FAILED=0

for PR_NUM in "${PR_NUMS[@]}"; do
    # RESILIENT-1616: a deliberately cut PR is terminal — refuse to arm it even
    # when a sweeper or rescue organ delegated the arm here.
    if pr_cut_honored "${PR_NUM}" "auto-merge-armer.sh" "arm" "" "${REPO}"; then
        echo "[auto-merge-armer] PR #${PR_NUM}: pr-cut (deliberate close, terminal; RESILIENT-1616) — skipping."
        LAST_ARM_TS="$(date -u +%s)"
        continue
    fi

    # Enforce spacing between successive arm calls.
    _now="$(date -u +%s)"
    _since=$(( _now - LAST_ARM_TS ))
    if [[ $LAST_ARM_TS -gt 0 && $_since -lt $ARM_SPACING_S ]]; then
        _wait=$(( ARM_SPACING_S - _since ))
        echo "[auto-merge-armer] Rate spacing: sleeping ${_wait}s before next arm…"
        sleep "${_wait}"
    fi

    # Skip already-armed PRs — unless CONFLICTING/DIRTY (RESILIENT-1576: disarm conflicting PRs).
    _already="$(CHUMP_GH_CALL_CRITICALITY=background chump_gh api "repos/${REPO}/pulls/${PR_NUM}" \
        --jq '.auto_merge != null' 2>/dev/null || echo 'false')"
    _pr_conflict_json="$(CHUMP_GH_CALL_CRITICALITY=background chump_gh pr view "${PR_NUM}" --repo "${REPO}" \
        --json mergeable,mergeStateStatus 2>/dev/null || true)"
    _pr_mergeable="$(printf '%s' "${_pr_conflict_json}" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read() or "{}"); print((d.get("mergeable") or "").upper())' 2>/dev/null || true)"
    _pr_mss="$(printf '%s' "${_pr_conflict_json}" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read() or "{}"); print((d.get("mergeStateStatus") or "").upper())' 2>/dev/null || true)"
    if [[ "${_pr_mergeable}" == "CONFLICTING" || "${_pr_mss}" == "DIRTY" ]]; then
        _conflict_action="refused_arm"
        if [[ "${_already}" == "true" ]]; then
            CHUMP_GH_CALL_CRITICALITY=background chump_gh pr merge "${PR_NUM}" --repo "${REPO}" --disable-auto >/dev/null 2>&1 || true
            _conflict_action="disarmed_conflicting"
        fi
        # scanner-anchor: "kind":"pr_conflict_triage"
        _ambient_write "${LOCKS_DIR}/ambient.jsonl" \
            "$(printf '{"ts":"%s","kind":"pr_conflict_triage","pr":%s,"mergeable":"%s","merge_state_status":"%s","action":"%s"}' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${PR_NUM}" "${_pr_mergeable:-UNKNOWN}" "${_pr_mss:-UNKNOWN}" "${_conflict_action}")"
        echo "[auto-merge-armer] PR #${PR_NUM}: CONFLICTING/DIRTY (mergeable=${_pr_mergeable:-?} mss=${_pr_mss:-?}) — ${_conflict_action} (RESILIENT-1576)." >&2
        LAST_ARM_TS="$(date -u +%s)"
        continue
    fi
    if [[ "${_already}" == "true" ]]; then
        echo "[auto-merge-armer] PR #${PR_NUM}: already armed — skipping."
        LAST_ARM_TS="$(date -u +%s)"
        continue
    fi

    # Skip closed/merged PRs.
    _state="$(chump_gh api "repos/${REPO}/pulls/${PR_NUM}" \
        --jq '.state' 2>/dev/null || echo '')"
    if [[ "${_state}" != "open" ]]; then
        echo "[auto-merge-armer] PR #${PR_NUM}: not open (state=${_state:-unknown}) — skipping."
        LAST_ARM_TS="$(date -u +%s)"
        continue
    fi

    # INFRA-1311: check per-PR backoff before attempting merge arm.
    _remaining="$(_backoff_remaining "${PR_NUM}")"
    if [[ "${_remaining}" -gt 0 ]]; then
        _bo_until_ts=$(( $(date -u +%s) + _remaining ))
        _bo_until_human="$(date -u -r "${_bo_until_ts}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
            || date -u -d "@${_bo_until_ts}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
            || printf '%s' "${_bo_until_ts}")"
        echo "[auto-merge-armer] PR #${PR_NUM} in backoff until ${_bo_until_human} (${_remaining}s remaining) — skipping."
        emit_ambient "bot_merge_backoff_skipped" "${PR_NUM}" \
            "remaining_s=${_remaining} until=${_bo_until_human} script=auto-merge-armer.sh"
        LAST_ARM_TS="$(date -u +%s)"
        continue
    fi

    # RESILIENT-1613: honor a deliberate hold BEFORE any arm or REST-direct
    # merge. arm_policy_allows emits pr_arm_skipped_hold when it blocks.
    if ! arm_policy_allows "${PR_NUM}" "${ARMER_NAME}" "${REPO}"; then
        echo "[auto-merge-armer] PR #${PR_NUM}: held (no-auto-merge / Auto-merge: hold) — skipping."
        LAST_ARM_TS="$(date -u +%s)"
        continue
    fi

    # INFRA-8180: refuse to arm a PR whose CURRENT head has a FAILED required
    # check. GitHub would disable auto-merge again within seconds and blame
    # the enabling token, which is exactly the false "bot disarm" signal
    # INFRA-8178's classifier used to re-arm on — manufacturing the
    # 5-minute arm/disarm war. Pending/queued/neutral/success heads still arm.
    if head_has_failing_required_check "${PR_NUM}"; then
        _red_head_sha="$(chump_gh api "repos/${REPO}/pulls/${PR_NUM}" \
            --jq '.head.sha' 2>/dev/null || echo 'unknown')"
        log_red_head_once "${PR_NUM}" "${_red_head_sha}"
        LAST_ARM_TS="$(date -u +%s)"
        continue
    fi

    echo "[auto-merge-armer] Arming auto-merge for PR #${PR_NUM}…"
    if arm_with_retry "${PR_NUM}"; then
        emit_ambient "auto_merge_armed" "${PR_NUM}" \
            "script=auto-merge-armer.sh spacing=${ARM_SPACING_S}s"
        echo "[auto-merge-armer] PR #${PR_NUM}: armed."
    else
        emit_ambient "auto_merge_arm_failed" "${PR_NUM}" \
            "script=auto-merge-armer.sh attempt=${attempt:-0}"
        echo "[auto-merge-armer] ERROR: PR #${PR_NUM}: arm failed." >&2
        ANY_FAILED=1
    fi

    LAST_ARM_TS="$(date -u +%s)"
done

[[ $ANY_FAILED -eq 0 ]] || exit 2
echo "[auto-merge-armer] Done."
