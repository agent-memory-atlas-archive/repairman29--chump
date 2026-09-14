#!/usr/bin/env bash
# shellcheck disable=SC1091  # lib/ sources use dynamic $SCRIPT_DIR — resolved at runtime
# RESILIENT-006: PR-stale auto-rebase.
#
# When a PR that has auto-merge armed is BLOCKED because of CI failures on
# checks that have since PASSED on main HEAD, rebases the branch onto main,
# force-pushes with lease, and re-arms auto-merge.
#
# This unwedges PRs like #1433 (17h stall: checks failed transiently on an
# older main, later passed on main, but the PR branch never got rebased).
#
# Fork-aware rescue (INFRA-2114):
#   When a PR is opened from a fork (isCrossRepository=true), the standard
#   same-repo rebase+push path would fail because the head branch lives in a
#   different repository. The fork-aware path:
#     1. Clones the upstream (base) repo
#     2. Adds the fork owner as a named git remote (idempotent — falls back to
#        set-url if the remote already exists)
#     3. Fetches the fork's head branch
#     4. Checks out a local tracking branch named <fork_owner>-<head_ref>
#     5. Rebases onto upstream main
#     6. Pushes back to the FORK remote (not origin/upstream)
#   Same-repo PRs continue through the original logic unchanged.
#
# Don't: push fork PRs to origin — that would create a branch on the upstream
#         repo rather than updating the contributor's fork branch.
#
# Usage:
#   bash scripts/coord/pr-rescue.sh [--pr <N>] [--repo <owner/repo>]
#
# Env vars:
#   GH_TOKEN              — GitHub token (exits 0 silently if absent)
#   GITHUB_REPOSITORY     — <owner/repo> (fallback: git remote get-url origin)
#   PR_RESCUE_STALE_HOURS — Only touch PRs blocked >= this many hours (default: 4)
#   PR_RESCUE_NOCI_MINUTES — RESILIENT-248: minutes a PR may sit with ZERO CI
#                            check runs before CI is re-fired (default: 25)
#   PR_RESCUE_MAX_REFIRES — cap on zero-CI re-fires per scan (default: 3)
#   PR_RESCUE_DRY_RUN     — 1 = log intended re-fires, touch nothing
#
# Exits:
#   0 — completed (may have rescued 0 PRs)
#   1 — error (bad args, git failure, etc.)

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
STALE_HOURS="${PR_RESCUE_STALE_HOURS:-4}"
# RESILIENT-248: zero-CI-runs re-fire. SEPARATE threshold from STALE_HOURS on
# purpose — STALE_HOURS=4 governs "CI went red, has it since passed on main",
# where waiting is cheap. Total CI absence is a different failure on a different
# clock: PR #3489 sat 2h35m with zero runs, then merged 9 minutes after a
# close/reopen. Minutes, not hours.
NOCI_MINUTES="${PR_RESCUE_NOCI_MINUTES:-25}"
# Cap re-fires per scan. This path closes and reopens real PRs on a 2h cron;
# a bug that flaps the whole queue must be bounded by construction.
MAX_REFIRES="${PR_RESCUE_MAX_REFIRES:-3}"
# Log intent without touching any PR.
REFIRE_DRY_RUN="${PR_RESCUE_DRY_RUN:-0}"

# RESILIENT-248: the re-fire decision, as a pure function — no API calls, no
# globals — so scripts/ci/test-pr-rescue-noci.sh can prove it fires AND prove it
# stays quiet. A detector nobody can demonstrate firing is the EFFECTIVE-407
# failure class: a blind detector reads as a clean bill of health.
#
# Args: <check_count> <age_minutes> <threshold_minutes>
# Exit: 0 = re-fire, 1 = leave alone.
pr_rescue_should_refire() {
    local check_count="${1:-}" age_min="${2:-}" threshold="${3:-}"
    # Non-numeric means an API call failed. Refuse — never re-fire on a value
    # we could not parse.
    [[ "${check_count}" =~ ^[0-9]+$ ]] || return 1
    [[ "${age_min}"     =~ ^-?[0-9]+$ ]] || return 1
    [[ "${threshold}"   =~ ^[0-9]+$ ]] || return 1
    # ZERO checks specifically. A single queued check means the trigger DID
    # fire and CI is merely slow; re-firing that would cancel real work.
    (( check_count == 0 )) || return 1
    (( age_min >= threshold )) || return 1
    return 0
}

# Let the test fixture source this file for its pure functions without running
# the scan (which needs GH_TOKEN and hits the API).
if [[ "${PR_RESCUE_LIB_ONLY:-0}" == "1" ]]; then
    return 0 2>/dev/null || exit 0
fi
# INFRA-1016: REST-only mode — skip auto-merge arm (unavailable via REST) and
# do an immediate merge instead. Use when GraphQL bucket is exhausted.
REST_ONLY="${CHUMP_PR_RESCUE_REST_ONLY:-0}"
# INFRA-1153: wall-clock timeout so pr-rescue never runs >5 min and hammers
# the secondary GitHub rate limit. Processes that survived 335+ min were the
# root cause of the 2026-05-13 secondary rate limit outage.
TIMEOUT_S="${CHUMP_PR_RESCUE_TIMEOUT_S:-300}"
_PR_RESCUE_START="$(date -u +%s)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# INFRA-999: API cost telemetry. CHUMP_GH_SCRIPT tags the script in
# the emitted ambient.jsonl `github_api_call` lines.
# shellcheck source=lib/github.sh
source "${SCRIPT_DIR}/lib/github.sh"
# INFRA-1109: cache-first per-PR meta lookup via INFRA-1081 cache.
# shellcheck source=lib/github_cache.sh
[[ -f "${SCRIPT_DIR}/lib/github_cache.sh" ]] && source "${SCRIPT_DIR}/lib/github_cache.sh"
# INFRA-1241: route ambient appends through helper (surfaces errors to stderr).
# shellcheck source=lib/ambient-write.sh
source "${SCRIPT_DIR}/lib/ambient-write.sh"
export CHUMP_GH_SCRIPT="pr-rescue.sh"
# shellcheck source=../lib/orchestrator-log.sh
source "${SCRIPT_DIR}/../lib/orchestrator-log.sh"
orch_log_start "pr-rescue.sh" "$@"
trap 'orch_log_end "pr-rescue.sh" "$?"' EXIT
REPO="${GITHUB_REPOSITORY:-}"
TARGET_PR=""

# ── Args ──────────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --pr) TARGET_PR="$2"; shift 2 ;;
        --repo) REPO="$2"; shift 2 ;;
        --rest-only) REST_ONLY=1; shift ;;
        *) echo "[pr-rescue] ERROR: unknown arg: $1" >&2; exit 1 ;;
    esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
log() { echo "[pr-rescue] $*" >&2; orch_log_step "$*"; }

emit_ambient() {
    local kind="$1" pr_num="$2" detail="${3:-}"
    local locks_dir="${REPO_ROOT}/.chump-locks"
    mkdir -p "${locks_dir}" 2>/dev/null || true
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    _ambient_write "${locks_dir}/ambient.jsonl" \
        "$(printf '{"ts":"%s","kind":"%s","pr":%s,"detail":"%s"}' \
            "${ts}" "${kind}" "${pr_num}" "${detail}")"
}

# ── Guard: skip if no GH_TOKEN ───────────────────────────────────────────────
if [[ -z "${GH_TOKEN:-}" && -z "${GITHUB_TOKEN:-}" ]]; then
    log "No GH_TOKEN set — skipping PR rescue (non-CI environment)."
    exit 0
fi

# Resolve repo from git remote if not set
if [[ -z "${REPO}" ]]; then
    REPO="$(git -C "${REPO_ROOT}" remote get-url origin 2>/dev/null \
        | sed 's|.*github.com[:/]||;s|.git$||' || true)"
fi
if [[ -z "${REPO}" ]]; then
    log "ERROR: Could not determine GITHUB_REPOSITORY."
    exit 1
fi

log "PR rescue scan for ${REPO} (stale threshold: ${STALE_HOURS}h${REST_ONLY:+, REST-only mode})."

# ── Collect candidate PRs ─────────────────────────────────────────────────────
# We want PRs that:
#   1. Are OPEN
#   2. Have auto-merge armed (autoMergeRequest != null)
#   3. Are mergeable (not conflicting — conflicts need human help)
#   4. Have been open for at least STALE_HOURS hours
if [[ -n "${TARGET_PR}" ]]; then
    PR_NUMBERS="${TARGET_PR}"
else
    PR_NUMBERS="$(chump_gh api \
        "repos/${REPO}/pulls?state=open&per_page=50" \
        --jq '[.[] | select(.auto_merge != null) | .number] | .[]' \
        2>/dev/null || echo '')"
fi

if [[ -z "${PR_NUMBERS}" ]]; then
    log "No auto-merge-armed PRs found."
    exit 0
fi

# Get main HEAD SHA once for check comparison
MAIN_SHA="$(chump_gh api "repos/${REPO}/git/ref/heads/main" --jq .object.sha 2>/dev/null || echo '')"
if [[ -z "${MAIN_SHA}" ]]; then
    log "ERROR: Could not resolve main HEAD SHA."
    exit 1
fi
log "main HEAD: ${MAIN_SHA}"

RESCUED=0
SKIPPED=0
FAILED=0

for PR_NUM in ${PR_NUMBERS}; do
    # ── INFRA-1153: wall-clock timeout guard ──────────────────────────────────
    _elapsed=$(( $(date -u +%s) - _PR_RESCUE_START ))
    if [[ $_elapsed -ge $TIMEOUT_S ]]; then
        log "WARN: wall-clock timeout (${TIMEOUT_S}s) reached after ${_elapsed}s — stopping early (INFRA-1153)."
        emit_ambient "pr_rescue_timeout" "0" "elapsed=${_elapsed}s remaining_prs_skipped=true"
        break
    fi

    # ── Fetch PR metadata (INFRA-1109 cache-first) ────────────────────────────
    # Prefer reading from .chump/github_cache.db (INFRA-1081, populated by
    # webhooks). cache_lookup_pr emits kind=cache_miss + falls back to REST
    # when stale/missing — zero API calls when cache is warm, one when cold.
    PR_META=""
    if declare -F cache_lookup_pr >/dev/null 2>&1; then
        PR_META="$(cache_lookup_pr "${PR_NUM}" 2>/dev/null)"
    fi
    if [[ -z "$PR_META" ]]; then
        # Cache lib not loaded or cache empty + REST fallback failed.
        PR_META="$(chump_gh api "repos/${REPO}/pulls/${PR_NUM}" 2>/dev/null)" || {
            log "WARN: Could not fetch PR #${PR_NUM} — skipping."
            continue
        }
    fi

    PR_STATE="$(echo "${PR_META}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['state'])")"
    MERGEABLE="$(echo "${PR_META}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('mergeable','') or '')")"
    PR_BRANCH="$(echo "${PR_META}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['head']['ref'])")"
    PR_CREATED="$(echo "${PR_META}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['created_at'])")"

    # ── INFRA-2114: fork detection ─────────────────────────────────────────────
    # Query isCrossRepository + headRepositoryOwner to detect fork PRs.
    # Same-repo PRs have isCrossRepository=false (or field absent) — skip this
    # extra gh call for those once we know the base REST meta doesn't surface it.
    FORK_META="$(chump_gh pr view "${PR_NUM}" \
        --repo "${REPO}" \
        --json isCrossRepository,headRepositoryOwner,baseRepositoryOwner \
        2>/dev/null || echo '{}')"
    IS_CROSS_REPO="$(echo "${FORK_META}" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print(str(d.get('isCrossRepository',False)).lower())")"
    FORK_OWNER="$(echo "${FORK_META}" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print((d.get('headRepositoryOwner') or {}).get('login',''))")"
    # Derive base repo name from REPO (owner/repo → repo)
    BASE_REPO_NAME="${REPO##*/}"

    if [[ "${PR_STATE}" != "open" ]]; then
        log "PR #${PR_NUM}: not open — skip."
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    if [[ "${MERGEABLE}" == "CONFLICTING" ]]; then
        log "PR #${PR_NUM}: has merge conflicts — skip (human intervention needed)."
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # ── Staleness check ───────────────────────────────────────────────────────
    CREATED_EPOCH="$(date -d "${PR_CREATED}" +%s 2>/dev/null \
        || python3 -c "import datetime,sys; \
           s='${PR_CREATED}'; \
           dt=datetime.datetime.strptime(s,'%Y-%m-%dT%H:%M:%SZ'); \
           print(int(dt.replace(tzinfo=datetime.timezone.utc).timestamp()))")"
    NOW_EPOCH="$(date -u +%s)"
    AGE_HOURS=$(( (NOW_EPOCH - CREATED_EPOCH) / 3600 ))

    # ── RESILIENT-248: zero-CI-runs detector ──────────────────────────────────
    # Runs BEFORE the staleness guard, because it has its own (much shorter)
    # clock. PR #3489 stalled 2h35m — under STALE_HOURS=4 — and had zero failing
    # checks, so the rebase path below skipped it on both counts. It hunts for
    # RED; that PR was BLANK.
    AGE_MINUTES=$(( (NOW_EPOCH - CREATED_EPOCH) / 60 ))
    NOCI_HEAD_SHA="$(echo "${PR_META}" | python3 -c \
        "import sys,json; print(json.load(sys.stdin)['head']['sha'])" 2>/dev/null || echo '')"

    if [[ -n "${NOCI_HEAD_SHA}" ]]; then
        # Count ALL check runs regardless of conclusion — queued and
        # in_progress included. Only a true zero means the trigger never fired.
        NOCI_COUNT="$(chump_gh api \
            "repos/${REPO}/commits/${NOCI_HEAD_SHA}/check-runs?per_page=1" \
            --jq '.total_count' 2>/dev/null || echo 'ERR')"

        if pr_rescue_should_refire "${NOCI_COUNT}" "${AGE_MINUTES}" "${NOCI_MINUTES}"; then
            # Idempotency: never re-fire the same head SHA twice. A PR whose CI
            # is genuinely broken must not be flapped every 2h forever. The
            # marker is a PR comment because it survives across workflow runs —
            # this script keeps no state between invocations.
            NOCI_MARKER="pr-rescue:refire sha=${NOCI_HEAD_SHA}"
            ALREADY="$(chump_gh api \
                "repos/${REPO}/issues/${PR_NUM}/comments?per_page=100" \
                --jq "[.[] | select(.body | contains(\"${NOCI_MARKER}\"))] | length" \
                2>/dev/null || echo '1')"

            if [[ "${ALREADY}" != "0" ]]; then
                log "PR #${PR_NUM}: zero CI runs but SHA ${NOCI_HEAD_SHA:0:8} already re-fired once — skip (not flapping it)."
                SKIPPED=$((SKIPPED + 1))
                continue
            fi

            if (( ${REFIRES:-0} >= MAX_REFIRES )); then
                log "PR #${PR_NUM}: zero CI runs, but re-fire cap ${MAX_REFIRES} reached this scan — leaving for next run."
                SKIPPED=$((SKIPPED + 1))
                continue
            fi

            if [[ "${REFIRE_DRY_RUN}" == "1" ]]; then
                log "PR #${PR_NUM}: DRY RUN — would re-fire CI (zero runs, age ${AGE_MINUTES}m >= ${NOCI_MINUTES}m)."
                SKIPPED=$((SKIPPED + 1))
                continue
            fi

            log "PR #${PR_NUM}: ZERO CI runs after ${AGE_MINUTES}m — re-firing via close/reopen."
            # The marker goes down BEFORE the close/reopen. If the reopen fails
            # we must still never retry this SHA blindly; a missing marker after
            # a partial failure would reintroduce the flap risk.
            chump_gh api "repos/${REPO}/issues/${PR_NUM}/comments" \
                -f body="<!-- ${NOCI_MARKER} -->
🔄 **pr-rescue (RESILIENT-248)**: this PR had **zero CI check runs** ${AGE_MINUTES} minutes after its head commit, which means the \`pull_request\` event did not create any workflow runs. Re-firing CI via close/reopen and re-arming auto-merge.

This is automated and happens at most once per head SHA." \
                >/dev/null 2>&1 || log "PR #${PR_NUM}: WARN — marker comment failed; continuing."

            if chump_gh pr close "${PR_NUM}" --repo "${REPO}" >/dev/null 2>&1 \
               && chump_gh pr reopen "${PR_NUM}" --repo "${REPO}" >/dev/null 2>&1; then
                # Close/reopen DROPS auto-merge — verified on #3489, whose
                # timeline shows auto_merge_disabled at the close. Re-arming is
                # not optional: without it a stalled PR becomes a green PR that
                # sits forever, which is a quieter failure than the original.
                if chump_gh pr merge "${PR_NUM}" --repo "${REPO}" --auto --squash >/dev/null 2>&1; then
                    log "PR #${PR_NUM}: re-fired and auto-merge re-armed."
                else
                    log "PR #${PR_NUM}: re-fired, but AUTO-MERGE RE-ARM FAILED — needs a human."
                fi
                # ── EVENT_REGISTRY coverage scanner-anchor (INFRA-1237/INFRA-1287) ──
                # emit_ambient takes the kind as a POSITIONAL argument and builds
                # the JSON with printf, so the coverage regex cannot see the
                # literal. Anchor it in the scanner's detectable JSON form, same
                # pattern as src/fleet_self_rescue_conductor.rs:138. This is a
                # REAL emit (the call is on the next line), not a reservation:
                #   "kind":"pr_rescue_ci_refire"
                # Distinct from pr_rescue_triggered: that fires when CI ran and
                # went RED; this fires when CI never ran at all.
                emit_ambient "pr_rescue_ci_refire" "${PR_NUM}" "zero_runs_after_${AGE_MINUTES}m"
                REFIRES=$(( ${REFIRES:-0} + 1 ))
                RESCUED=$(( ${RESCUED:-0} + 1 ))
            else
                log "PR #${PR_NUM}: re-fire FAILED at close/reopen — leaving alone."
            fi
            continue
        fi
    fi

    if [[ ${AGE_HOURS} -lt ${STALE_HOURS} ]]; then
        log "PR #${PR_NUM}: age ${AGE_HOURS}h < threshold ${STALE_HOURS}h — skip."
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # ── Check if PR CI has failures that passed on main ───────────────────────
    # Get latest commit check runs for the PR HEAD
    PR_HEAD_SHA="$(echo "${PR_META}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['head']['sha'])")"

    FAILING_CHECKS="$(chump_gh api \
        "repos/${REPO}/commits/${PR_HEAD_SHA}/check-runs?per_page=50" \
        --jq '[.check_runs[] | select(.conclusion == "failure") | .name] | .[]' \
        2>/dev/null || echo '')"

    if [[ -z "${FAILING_CHECKS}" ]]; then
        log "PR #${PR_NUM}: no failing checks — skip (may already be passing or pending)."
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # Check if those same check names passed on main HEAD
    MAIN_PASSING_CHECKS="$(chump_gh api \
        "repos/${REPO}/commits/${MAIN_SHA}/check-runs?per_page=50" \
        --jq '[.check_runs[] | select(.conclusion == "success") | .name] | .[]' \
        2>/dev/null || echo '')"

    # Find overlap: failing on PR but passing on main
    RESCUABLE=0
    for CHECK in ${FAILING_CHECKS}; do
        if echo "${MAIN_PASSING_CHECKS}" | grep -qxF "${CHECK}"; then
            log "PR #${PR_NUM}: check '${CHECK}' fails on PR but passes on main HEAD."
            RESCUABLE=1
            break
        fi
    done

    if [[ ${RESCUABLE} -eq 0 ]]; then
        log "PR #${PR_NUM}: failing checks are not transient (not passing on main) — skip."
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    if [[ "${IS_CROSS_REPO}" == "true" ]]; then
        log "PR #${PR_NUM} (branch: ${PR_BRANCH}): fork PR from ${FORK_OWNER} — fork-aware rescue."
    else
        log "PR #${PR_NUM} (branch: ${PR_BRANCH}): rescue candidate — rebasing onto main."
    fi
    emit_ambient "pr_rescue_triggered" "${PR_NUM}" "branch=${PR_BRANCH} age=${AGE_HOURS}h fork=${IS_CROSS_REPO}"

    # ── Rebase via temp clone ─────────────────────────────────────────────────
    TEMP_DIR="$(mktemp -d)"
    RESCUE_OK=0

    if [[ "${IS_CROSS_REPO}" == "true" && -n "${FORK_OWNER}" ]]; then
        # ── INFRA-2114: fork-aware rescue path ────────────────────────────────
        # Fork PR: head lives in a different repo than base. We must:
        #   (a) clone the upstream (base) repo
        #   (b) add the fork as a named remote (idempotent)
        #   (c) fetch the fork's head branch
        #   (d) checkout a local tracking branch
        #   (e) rebase onto upstream main
        #   (f) push back to the FORK (not upstream)
        UPSTREAM_URL="$(git -C "${REPO_ROOT}" remote get-url origin)"
        FORK_URL="https://github.com/${FORK_OWNER}/${BASE_REPO_NAME}.git"
        (
            set -euo pipefail
            git clone --quiet \
                "${UPSTREAM_URL}" \
                "${TEMP_DIR}/repo" \
                --depth 50 2>&1 | tail -2

            git -C "${TEMP_DIR}/repo" config user.name  "chump-pr-rescue"
            git -C "${TEMP_DIR}/repo" config user.email "chump-pr-rescue@users.noreply.github.com"

            # (b) Add fork remote — idempotent (ignore error if already exists)
            git -C "${TEMP_DIR}/repo" remote add "${FORK_OWNER}" "${FORK_URL}" 2>/dev/null \
                || git -C "${TEMP_DIR}/repo" remote set-url "${FORK_OWNER}" "${FORK_URL}"

            # (c) Fetch fork branch
            git -C "${TEMP_DIR}/repo" fetch --quiet "${FORK_OWNER}" "${PR_BRANCH}" 2>&1 | tail -2

            # (d) Checkout local tracking branch
            git -C "${TEMP_DIR}/repo" checkout -b "${FORK_OWNER}-${PR_BRANCH}" \
                "${FORK_OWNER}/${PR_BRANCH}"

            # (e) Fetch main and rebase
            git -C "${TEMP_DIR}/repo" fetch --quiet origin main 2>&1 | tail -2
            CHUMP_GIT_IDENTITY_CHECK=0 CHUMP_GAPS_LOCK=0 \
                git -C "${TEMP_DIR}/repo" rebase origin/main

            # (f) Push back to fork, NOT to upstream
            git -C "${TEMP_DIR}/repo" push "${FORK_OWNER}" \
                "HEAD:${PR_BRANCH}" \
                --force-with-lease --quiet 2>&1 | tail -2
        ) && RESCUE_OK=1 || RESCUE_OK=0
    else
        # ── Same-repo rescue path (original logic, unchanged) ─────────────────
        (
            set -euo pipefail
            git clone --quiet \
                "$(git -C "${REPO_ROOT}" remote get-url origin)" \
                "${TEMP_DIR}/repo" \
                --depth 50 --branch "${PR_BRANCH}" 2>&1 | tail -2

            git -C "${TEMP_DIR}/repo" config user.name  "chump-pr-rescue"
            git -C "${TEMP_DIR}/repo" config user.email "chump-pr-rescue@users.noreply.github.com"

            # Fetch main and rebase
            git -C "${TEMP_DIR}/repo" fetch --quiet origin main 2>&1 | tail -2
            CHUMP_GIT_IDENTITY_CHECK=0 CHUMP_GAPS_LOCK=0 \
                git -C "${TEMP_DIR}/repo" rebase origin/main

            # Force-push with lease
            git -C "${TEMP_DIR}/repo" push origin "${PR_BRANCH}" \
                --force-with-lease --quiet 2>&1 | tail -2
        ) && RESCUE_OK=1 || RESCUE_OK=0
    fi

    rm -rf "${TEMP_DIR}"

    if [[ ${RESCUE_OK} -eq 1 ]]; then
        if [[ "${REST_ONLY}" == "1" ]]; then
            # INFRA-1016: REST path — immediate merge (no auto-merge available via REST).
            # Accepted limitation: only use this when GraphQL is exhausted and PR is
            # already green (status checks passing). Not suitable for arming auto-merge.
            chump_gh api -X PUT "repos/${REPO}/pulls/${PR_NUM}/merge" \
                -f merge_method=squash 2>/dev/null || true
            log "PR #${PR_NUM}: rebased + merged (REST-only, no auto-merge). RESCUED."
        else
            # INFRA-1113: delegate to centralized armer (5s spacing, retry on rate-limit).
            bash "${SCRIPT_DIR}/auto-merge-armer.sh" --pr "${PR_NUM}" --repo "${REPO}" \
                2>/dev/null || true
            log "PR #${PR_NUM}: rebased + re-armed. RESCUED."
        fi
        emit_ambient "pr_rescue_completed" "${PR_NUM}" "branch=${PR_BRANCH} rest_only=${REST_ONLY} fork=${IS_CROSS_REPO}"

        # ── INFRA-2169: external-repo ship audit receipt ──────────────────────
        # After a cross-repository fork PR is successfully merged, emit a
        # kind=external_repo_ship event so operators can audit Mode D throughput.
        if [[ "${IS_CROSS_REPO}" == "true" && -n "${FORK_OWNER}" ]]; then
            _pr_url="https://github.com/${REPO}/pull/${PR_NUM}"
            # Count files touched by the PR (best-effort; 0 on REST failure).
            _files_count="$(chump_gh api "repos/${REPO}/pulls/${PR_NUM}/files?per_page=100" \
                --jq 'length' 2>/dev/null || echo '0')"
            _shipper_session="${CHUMP_SESSION_ID:-${SESSION_ID:-unknown}}"
            _external_repo="${FORK_OWNER}/${BASE_REPO_NAME}"
            _gap_id="${CHUMP_GAP_ID:-unknown}"
            _ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            _ext_locks_dir="${REPO_ROOT}/.chump-locks"
            mkdir -p "${_ext_locks_dir}" 2>/dev/null || true
            _ambient_write "${_ext_locks_dir}/ambient.jsonl" \
                "$(printf '{"ts":"%s","kind":"external_repo_ship","gap_id":"%s","external_repo":"%s","pr_url":"%s","head_sha":"%s","files_touched_count":%s,"shipper_session":"%s"}' \
                    "${_ts}" "${_gap_id}" "${_external_repo}" "${_pr_url}" \
                    "${PR_HEAD_SHA}" "${_files_count}" "${_shipper_session}")"
            # Broadcast DONE so other agents on the bus know this cross-repo PR shipped.
            if [[ -x "${SCRIPT_DIR}/broadcast.sh" ]]; then
                CHUMP_SESSION_ID="${_shipper_session}" \
                    bash "${SCRIPT_DIR}/broadcast.sh" DONE "${_gap_id}" "${PR_HEAD_SHA}" \
                    2>/dev/null || true
            fi
            log "PR #${PR_NUM}: external_repo_ship emitted (external_repo=${_external_repo} head_sha=${PR_HEAD_SHA})."
        fi

        RESCUED=$((RESCUED + 1))
    else
        log "PR #${PR_NUM}: rebase failed (conflicts?). FAILED."
        emit_ambient "pr_rescue_failed" "${PR_NUM}" "branch=${PR_BRANCH} reason=rebase_conflict fork=${IS_CROSS_REPO}"
        FAILED=$((FAILED + 1))
    fi
done

log "Done. rescued=${RESCUED} skipped=${SKIPPED} failed=${FAILED}"
