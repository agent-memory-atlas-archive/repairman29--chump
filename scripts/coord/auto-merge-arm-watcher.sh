#!/usr/bin/env bash
# auto-merge-arm-watcher.sh — INFRA-2289
#
# One-shot: detect OPEN PRs whose auto-merge ARM was silently dropped after a
# conflict-rebase race, then re-arm them. Invoke via launchd StartInterval.
#
# Detection: PR is OPEN with autoMergeRequest=null AND a cascade_rebase_triggered
# or stacked_pr_rebased event appears in ambient.jsonl within the last
# CHUMP_AM_WATCHER_REBASE_WINDOW_S (default 1800s). Safety guards: CHUMP_HOLD
# label, operator commit in last 30 min, CHUMP_AM_WATCHER_RATE_PER_HOUR (10/hr).
# Bypass: CHUMP_AM_WATCHER=0
#
# Emits: auto_merge_arm_dropped, auto_merge_arm_restored, auto_merge_arm_skipped
# scanner-anchor: scripts/coord/auto-merge-arm-watcher.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CHUMP_REPO_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
LOCKS_DIR="${CHUMP_LOCK_DIR:-${REPO_ROOT}/.chump-locks}"
AMBIENT_LOG="${LOCKS_DIR}/ambient.jsonl"

# shellcheck source=scripts/coord/lib/ambient-write.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/ambient-write.sh"
# RESILIENT-1613: one arm policy — honor `no-auto-merge` / `Auto-merge: hold`.
# shellcheck source=scripts/coord/lib/arm-policy.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/arm-policy.sh"

RATE_PER_HOUR="${CHUMP_AM_WATCHER_RATE_PER_HOUR:-10}"
REBASE_WINDOW_S="${CHUMP_AM_WATCHER_REBASE_WINDOW_S:-1800}"
OPERATOR_COMMIT_WINDOW_S="${CHUMP_AM_WATCHER_OPERATOR_COMMIT_WINDOW_S:-1800}"
MERGE_QUEUE="${CHUMP_MERGE_QUEUE_ENABLED:-0}"
RATE_STATE_FILE="${LOCKS_DIR}/auto-merge-arm-watcher-rate.jsonl"

REPO="${GITHUB_REPOSITORY:-}"
[[ -z "${REPO}" ]] && REPO="$(git -C "${REPO_ROOT}" remote get-url origin 2>/dev/null \
    | sed 's|.*github.com[:/]||;s|.git$||' || true)"

mkdir -p "${LOCKS_DIR}" 2>/dev/null || true

log() { printf '[%s] [auto-merge-arm-watcher] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

emit() {
    local kind="$1" pr="${2:-}" extra="${3:-}"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local payload
    if   [[ -n "${pr}" && -n "${extra}" ]]; then payload="{\"ts\":\"${ts}\",\"kind\":\"${kind}\",\"pr\":${pr},${extra}}"
    elif [[ -n "${pr}" ]];                  then payload="{\"ts\":\"${ts}\",\"kind\":\"${kind}\",\"pr\":${pr}}"
    elif [[ -n "${extra}" ]];               then payload="{\"ts\":\"${ts}\",\"kind\":\"${kind}\",${extra}}"
    else                                         payload="{\"ts\":\"${ts}\",\"kind\":\"${kind}\"}"
    fi
    _ambient_write "${AMBIENT_LOG}" "${payload}"
    log "${kind} pr=${pr:-<none>} ${extra}"
}

_rate_count() {
    [[ -f "${RATE_STATE_FILE}" ]] || { printf '0'; return; }
    local cutoff count=0
    cutoff=$(( $(date -u +%s) - 3600 ))
    while IFS= read -r line; do
        local ts_s
        ts_s="$(printf '%s' "${line}" | grep -o '"ts_epoch":[0-9]*' | grep -o '[0-9]*' || echo 0)"
        [[ "${ts_s}" -gt "${cutoff}" ]] && count=$(( count + 1 ))
    done < "${RATE_STATE_FILE}"
    printf '%s' "${count}"
}

_rate_record() {
    printf '{"ts_epoch":%s,"ts":"%s","pr":%s}\n' \
        "$(date -u +%s)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "${RATE_STATE_FILE}"
    if [[ "$(wc -l < "${RATE_STATE_FILE}")" -gt 200 ]]; then
        local tmp; tmp="$(mktemp)"
        tail -100 "${RATE_STATE_FILE}" > "${tmp}" && mv "${tmp}" "${RATE_STATE_FILE}"
    fi
}

_operator_committed_recently() {
    local pr_num="$1" cutoff commit_epoch
    cutoff=$(( $(date -u +%s) - OPERATOR_COMMIT_WINDOW_S ))
    local commits_json
    commits_json="$(gh api "repos/${REPO}/pulls/${pr_num}/commits" \
        --jq '.[].commit.author.date' 2>/dev/null || true)"
    [[ -z "${commits_json}" ]] && return 1
    while IFS= read -r commit_date; do
        [[ -z "${commit_date}" ]] && continue
        commit_epoch="$(date -j -f '%Y-%m-%dT%H:%M:%SZ' "${commit_date}" '+%s' 2>/dev/null \
            || date -d "${commit_date}" '+%s' 2>/dev/null || echo 0)"
        [[ "${commit_epoch}" -gt "${cutoff}" ]] && return 0
    done <<< "${commits_json}"
    return 1
}

_fetch_unarmed_prs() {
    # shellcheck disable=SC2016  # $repo_owner/$repo_name are GraphQL vars, not shell vars
    gh api graphql -f query='
        query($repo_owner: String!, $repo_name: String!) {
            repository(owner: $repo_owner, name: $repo_name) {
                pullRequests(states: OPEN, first: 50, orderBy: {field: UPDATED_AT, direction: DESC}) {
                    nodes { number headRefOid autoMergeRequest { mergeMethod }
                            labels(first: 10) { nodes { name } } }
                }
            }
        }' \
        -f repo_owner="${REPO%%/*}" -f repo_name="${REPO##*/}" \
        --jq '.data.repository.pullRequests.nodes[]
              | select(.autoMergeRequest == null)
              | {number: .number, sha: .headRefOid, labels: [.labels.nodes[].name]}
              | @json' 2>/dev/null || true
}

# Returns 0 if ambient.jsonl contains a qualifying rebase event within REBASE_WINDOW_S.
# Accepts cascade_rebase_triggered (no sha) and stacked_pr_rebased (has sha).
_recent_auto_rebase() {
    local head_sha="$1" cutoff found=0
    cutoff=$(( $(date -u +%s) - REBASE_WINDOW_S ))
    [[ -f "${AMBIENT_LOG}" ]] || return 1
    while IFS= read -r line; do
        local kind ts_raw ts_s sha_in_line
        kind="$(printf '%s' "${line}" | grep -o '"kind":"[^"]*"' | head -1 | sed 's/"kind":"//;s/"//')"
        [[ "${kind}" == "cascade_rebase_triggered" || "${kind}" == "stacked_pr_rebased" \
           || "${kind}" == "cascade_rebase_skipped_duplicate" ]] || continue
        ts_raw="$(printf '%s' "${line}" | grep -o '"ts":"[^"]*"' | head -1 | sed 's/"ts":"//;s/"//')"
        ts_s="$(date -j -f '%Y-%m-%dT%H:%M:%SZ' "${ts_raw}" '+%s' 2>/dev/null \
            || date -d "${ts_raw}" '+%s' 2>/dev/null || echo 0)"
        [[ "${ts_s}" -gt "${cutoff}" ]] || continue
        sha_in_line="$(printf '%s' "${line}" | grep -o '"sha":"[^"]*"' | head -1 | sed 's/"sha":"//;s/"//')"
        if [[ -n "${sha_in_line}" ]]; then
            [[ "${sha_in_line:0:12}" == "${head_sha:0:12}" ]] && { found=1; break; }
        else
            found=1; break  # cascade_rebase_triggered carries no sha; accept any recent
        fi
    done < <(tac "${AMBIENT_LOG}" 2>/dev/null || true)
    return $(( 1 - found ))
}

_rearm_pr() {
    if [[ "${MERGE_QUEUE}" == "1" ]]; then
        gh pr merge "$1" --auto --repo "${REPO}" 2>&1
    else
        gh pr merge "$1" --auto --squash --repo "${REPO}" 2>&1
    fi
}

# ── Entry point ───────────────────────────────────────────────────────────────
if [[ "${CHUMP_AM_WATCHER:-1}" == "0" ]]; then log "BYPASS: CHUMP_AM_WATCHER=0"; exit 0; fi
[[ -z "${REPO}" ]] && { log "ERROR: cannot determine GITHUB_REPOSITORY." >&2; exit 1; }

log "Polling — repo=${REPO} rate_cap=${RATE_PER_HOUR}/hr"

current_rate="$(_rate_count)"
if [[ "${current_rate}" -ge "${RATE_PER_HOUR}" ]]; then
    log "Rate cap reached (${current_rate}/${RATE_PER_HOUR}) — exiting."
    emit "auto_merge_arm_skipped" "" "\"reason\":\"rate_limit_reached\",\"count\":${current_rate},\"cap\":${RATE_PER_HOUR}"
    exit 0
fi

pr_json_list="$(_fetch_unarmed_prs)"
[[ -z "${pr_json_list}" ]] && { log "No unarmed OPEN PRs."; exit 0; }

while IFS= read -r pr_json; do
    [[ -z "${pr_json}" ]] && continue
    pr_num="$(printf '%s' "${pr_json}" | grep -o '"number":[0-9]*' | grep -o '[0-9]*')"
    head_sha="$(printf '%s' "${pr_json}" | grep -o '"sha":"[^"]*"' | head -1 | sed 's/"sha":"//;s/"//')"
    labels_json="$(printf '%s' "${pr_json}" | grep -o '"labels":\[[^]]*\]' | head -1)"
    [[ -z "${pr_num}" ]] && continue

    # INFRA-2396: pipefail-race fix (INFRA-1658) — assign-then-check via lowercasing tr + case
    labels_lower="$(printf '%s' "${labels_json:-}" | tr '[:upper:]' '[:lower:]')"
    case "${labels_lower}" in
        *chump_hold*)
            emit "auto_merge_arm_skipped" "${pr_num}" '"reason":"chump_hold_label"'
            continue
            ;;
    esac

    # RESILIENT-1613: the shared policy (no-auto-merge label, legacy hold
    # labels, Auto-merge: hold marker in body/comments).
    if ! arm_policy_allows "${pr_num}" "auto-merge-arm-watcher.sh" "${REPO}"; then
        continue
    fi

    if ! _recent_auto_rebase "${head_sha}"; then
        log "PR #${pr_num}: no recent rebase event — skipping."
        continue
    fi

    if _operator_committed_recently "${pr_num}"; then
        emit "auto_merge_arm_skipped" "${pr_num}" "\"reason\":\"operator_recent_commit\",\"window_s\":${OPERATOR_COMMIT_WINDOW_S}"
        continue
    fi

    current_rate="$(_rate_count)"
    if [[ "${current_rate}" -ge "${RATE_PER_HOUR}" ]]; then
        emit "auto_merge_arm_skipped" "${pr_num}" "\"reason\":\"rate_limit_reached\",\"count\":${current_rate},\"cap\":${RATE_PER_HOUR}"
        break
    fi

    log "PR #${pr_num}: ARM dropped — re-arming (sha=${head_sha:0:12})."
    emit "auto_merge_arm_dropped" "${pr_num}" "\"sha\":\"${head_sha:0:12}\""

    arm_out="$(_rearm_pr "${pr_num}" 2>&1)" && arm_exit=0 || arm_exit=$?
    if [[ "${arm_exit}" -eq 0 ]]; then
        emit "auto_merge_arm_restored" "${pr_num}" "\"sha\":\"${head_sha:0:12}\""
        _rate_record "${pr_num}"
    else
        log "PR #${pr_num}: re-arm FAILED (exit=${arm_exit}): ${arm_out}" >&2
    fi
done <<< "${pr_json_list}"
