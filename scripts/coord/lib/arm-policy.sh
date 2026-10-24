#!/usr/bin/env bash
# scripts/coord/lib/arm-policy.sh — RESILIENT-1613 (PHASE-R R3)
#
# ONE arm policy for every armer. A human or architect disarm is a decision,
# not a fault: no sweeper, rebaser, rescuer or reviver may undo it.
#
# Receipt (2026-10-17): the architect ran `gh pr merge 5494 --disable-auto` at
# 02:27Z with an explaining comment; the PR timeline shows auto_squash_enabled
# by the repairman29 token at 02:52:37Z, ten seconds after a force-push at
# 02:52:27Z (the same push-then-arm pair at 00:45, 02:20 and 03:26). Every
# armer in the fleet had its own idea of "held" (a `hold` / `do-not-merge`
# label in auto-arm-sweeper.sh, CHUMP_HOLD in auto-merge-arm-watcher.sh,
# nothing at all in the rest), so a deliberate disarm lasted until the next
# rebase tick.
#
# THE CONTRACT
#   A PR is HELD — no armer may enable auto-merge on it, and the central armer
#   will not REST-merge it either — when ANY of these is true:
#     * it carries the label `no-auto-merge` (canonical), or one of the legacy
#       hold labels `hold`, `do-not-merge`, `CHUMP_HOLD`;
#     * its body, or ANY of its comments, contains a line matching
#       `^Auto-merge: hold` (case-insensitive, leading whitespace allowed).
#   Remove the label / edit the marker line out to release the hold.
#
# USAGE
#   source scripts/coord/lib/arm-policy.sh
#   arm_policy_allows <pr-number> [armer-name] [owner/repo] || continue
#
#   Returns 0 when arming is allowed, 1 when the PR is held. When it blocks it
#   emits kind=pr_arm_skipped_hold. When it allows an arm on a PR whose most
#   recent auto-merge timeline event is a DISABLE (i.e. this arm is a re-arm
#   after someone disarmed it) it emits kind=pr_rearmed naming the armer and
#   the disarm actor, so the next re-arm war is attributable in one grep.
#
# READ PATH (cache-first, INFRA-1081)
#   1. scripts/coord/lib/github_cache.sh cache_lookup_pr → labels + body. A hold
#      found there blocks without any gh call.
#   2. `gh pr view <N> --json labels,body,comments` — authoritative, and the
#      only source of comments (the cache does not store them).
#   Fails OPEN (allows) when neither source can be read: a transient API error
#   must not freeze every arm in the fleet. A hold already visible in the cache
#   still blocks in that case.
#
# ENV
#   CHUMP_ARM_POLICY_REARM_AUDIT  1 (default) = look up the timeline on allowed
#                                 arms to detect re-arms (one extra REST call).
#                                 0 = skip that lookup (no pr_rearmed events).
#   CHUMP_AMBIENT_LOG             ambient.jsonl override (shared fleet var).
#
# scanner-anchor: "kind":"pr_arm_skipped_hold"
# scanner-anchor: "kind":"pr_rearmed"

# Guard against double-sourcing.
# shellcheck disable=SC2317  # `|| true` only runs if executed rather than sourced
if [[ -n "${_CHUMP_ARM_POLICY_SOURCED:-}" ]]; then
    return 0 2>/dev/null || true
fi
_CHUMP_ARM_POLICY_SOURCED=1

# shellcheck disable=SC2034  # public constant for callers/tests
ARM_POLICY_HOLD_LABEL="no-auto-merge"
# Space-separated; compared case-insensitively. CREDIBLE-1542 adds the
# independent-review-organ hold labels (review-held / review-needs-mutants) so
# EVERY existing armer that already calls arm_policy_allows refuses a PR the
# review organ has marked unreviewed — passive, label-based fleet-wide honoring.
# (The fail-CLOSED predicate for "no current-head APPROVE even without a label"
# is scripts/coord/lib/review-hold.sh review_hold_allows, used by the organ's
# own head-pinned arm; wiring it into the other armers is a filed follow-up.)
ARM_POLICY_HOLD_LABELS="no-auto-merge hold do-not-merge CHUMP_HOLD review-held review-needs-mutants"

_arm_policy_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_arm_policy_ambient_path() {
    if [[ -n "${CHUMP_AMBIENT_LOG:-}" ]]; then
        printf '%s' "$CHUMP_AMBIENT_LOG"
        return
    fi
    local common root
    common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    if [[ -n "$common" && -d "$common" ]]; then
        root="$(cd "$common/.." && pwd)"
    else
        root="$(cd "${_arm_policy_lib_dir}/../../.." && pwd)"
    fi
    printf '%s/.chump-locks/ambient.jsonl' "$root"
}

_arm_policy_append() { # <json-line>
    local amb
    amb="$(_arm_policy_ambient_path)"
    mkdir -p "$(dirname "$amb")" 2>/dev/null || true
    printf '%s\n' "$1" >> "$amb" 2>/dev/null \
        || echo "[arm-policy] WARN: ambient write failed ($amb)" >&2
}

_arm_policy_json_str() { # <s> -> JSON-safe (quotes, backslashes, control chars stripped)
    printf '%s' "$1" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# _arm_policy_hold_reason <json>
#   Prints label:<name> | marker:body | marker:comment for a held PR, nothing
#   otherwise. Accepts both the REST pulls payload (labels:[{name}], body) and
#   the `gh pr view --json` shape (labels:[{name}], body, comments:[{body}]).
#   Exit 0 = parsed, 2 = unparseable.
_arm_policy_hold_reason() {
    python3 -c '
import json, re, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(2)
if not isinstance(d, dict):
    sys.exit(2)
holds = {h.lower() for h in sys.argv[2].split()}
for l in d.get("labels") or []:
    name = l.get("name", "") if isinstance(l, dict) else str(l)
    if name.lower() in holds:
        print("label:" + name)
        sys.exit(0)
marker = re.compile(r"^[ \t]*auto-merge:[ \t]*hold\b", re.I | re.M)
if marker.search(d.get("body") or ""):
    print("marker:body")
    sys.exit(0)
for c in d.get("comments") or []:
    body = c.get("body", "") if isinstance(c, dict) else str(c)
    if marker.search(body or ""):
        print("marker:comment")
        sys.exit(0)
' "$1" "$ARM_POLICY_HOLD_LABELS"
}

_arm_policy_gh() {
    if declare -F chump_gh >/dev/null 2>&1; then
        chump_gh "$@"
    else
        gh "$@"
    fi
}

_arm_policy_emit_hold() { # <pr> <armer> <reason> <source>
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    _arm_policy_append "$(printf '{"ts":"%s","kind":"pr_arm_skipped_hold","pr":%s,"armer":"%s","reason":"%s","source":"%s"}' \
        "$ts" "$1" "$(_arm_policy_json_str "$2")" "$(_arm_policy_json_str "$3")" "$4")"
}

_arm_policy_audit_rearm() { # <pr> <armer> <repo>
    [[ "${CHUMP_ARM_POLICY_REARM_AUDIT:-1}" == "0" ]] && return 0
    local pr="$1" armer="$2" repo="${3:-}" path last ev actor at ts
    if [[ -n "$repo" ]]; then
        path="repos/${repo}/issues/${pr}/timeline"
    else
        path="repos/{owner}/{repo}/issues/${pr}/timeline"
    fi
    last="$(CHUMP_GH_CALL_CRITICALITY=background _arm_policy_gh api "$path" --paginate \
        --jq '.[] | select(.event == "auto_merge_disabled" or .event == "auto_squash_enabled" or .event == "auto_merge_enabled" or .event == "auto_rebase_enabled") | [.event, (.actor.login // ""), (.created_at // "")] | @tsv' \
        2>/dev/null | tail -1 || true)"
    [[ -z "$last" ]] && return 0
    IFS=$'\t' read -r ev actor at <<<"$last"
    [[ "$ev" == "auto_merge_disabled" ]] || return 0
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    # GitHub attributes a check-failure disarm to whoever ENABLED auto-merge, so
    # disarm_actor alone cannot prove a human disarm (INFRA-8178); the event is
    # the audit trail, the hold label / marker is the enforcement.
    _arm_policy_append "$(printf '{"ts":"%s","kind":"pr_rearmed","pr":%s,"armer":"%s","disarm_actor":"%s","disarmed_at":"%s"}' \
        "$ts" "$pr" "$(_arm_policy_json_str "$armer")" "$(_arm_policy_json_str "$actor")" "$(_arm_policy_json_str "$at")")"
    echo "[arm-policy] PR #${pr}: re-arm by ${armer} after a disarm by ${actor:-unknown} at ${at:-?} (kind=pr_rearmed)" >&2
    return 0
}

# arm_policy_allows <pr-number> [armer-name] [owner/repo]
arm_policy_allows() {
    local pr="${1:-}" armer="${2:-${CHUMP_GH_SCRIPT:-$(basename "${0:-unknown}")}}" repo="${3:-}"
    if [[ ! "$pr" =~ ^[0-9]+$ ]]; then
        echo "[arm-policy] WARN: arm_policy_allows called without a PR number ('$pr') — allowing" >&2
        return 0
    fi

    local payload reason rc

    # 1. Cache first: labels + body (no comments in the cache).
    if [[ -f "${_arm_policy_lib_dir}/github_cache.sh" ]]; then
        if ! declare -F cache_lookup_pr >/dev/null 2>&1; then
            # shellcheck source=scripts/coord/lib/github_cache.sh
            source "${_arm_policy_lib_dir}/github_cache.sh" 2>/dev/null || true
        fi
    fi
    if [[ -z "$repo" ]] && declare -F cache_lookup_pr >/dev/null 2>&1; then
        # The cache is keyed by PR number for THIS checkout's repo only, so it
        # is skipped when the caller names another repo.
        payload="$(cache_lookup_pr "$pr" 2>/dev/null || true)"
        if [[ -n "$payload" ]]; then
            reason="$(_arm_policy_hold_reason "$payload" 2>/dev/null || true)"
            if [[ -n "$reason" ]]; then
                _arm_policy_emit_hold "$pr" "$armer" "$reason" "cache"
                echo "[arm-policy] PR #${pr}: HELD (${reason}) — ${armer} will not arm it" >&2
                return 1
            fi
        fi
    fi

    # 2. Authoritative read (the only source of comments).
    local -a _ap_repo_arg=()
    [[ -n "$repo" ]] && _ap_repo_arg=(--repo "$repo")
    payload="$(CHUMP_GH_CALL_CRITICALITY=background _arm_policy_gh pr view "$pr" ${_ap_repo_arg[@]+"${_ap_repo_arg[@]}"} \
        --json labels,body,comments 2>/dev/null || true)"
    rc=2
    if [[ -n "$payload" ]]; then
        reason="$(_arm_policy_hold_reason "$payload" 2>/dev/null)" && rc=0 || rc=$?
    fi
    if [[ "$rc" -ne 0 ]]; then
        echo "[arm-policy] WARN: PR #${pr}: could not read labels/body/comments — failing open" >&2
        return 0
    fi
    if [[ -n "$reason" ]]; then
        _arm_policy_emit_hold "$pr" "$armer" "$reason" "gh"
        echo "[arm-policy] PR #${pr}: HELD (${reason}) — ${armer} will not arm it" >&2
        return 1
    fi

    _arm_policy_audit_rearm "$pr" "$armer" "$repo"
    return 0
}


# ── CREDIBLE-1564: non-review arm scope guards ───────────────────────────────
# Every workflow that arms outside the review path must verify its narrow file
# / semver scope before calling `gh pr merge --auto`.

CENSUS_ALLOWED_FILES="docs/observability/CI_TEST_CENSUS.md docs/observability/ci-test-census.json"

# arm_scope_allows_census <pr-number> [owner/repo]
#   Returns 0 iff `gh pr view <pr> --json files` lists a non-empty file set
#   consisting exclusively of docs/observability/CI_TEST_CENSUS.md and/or
#   docs/observability/ci-test-census.json. Otherwise posts an explanatory
#   comment on the PR and returns 1 (fail-closed).
arm_scope_allows_census() {
    local pr="${1:-}" repo="${2:-}"
    if [[ ! "$pr" =~ ^[0-9]+$ ]]; then
        echo "[arm-policy] ERROR: arm_scope_allows_census called without a valid PR number ('$pr') — refusing" >&2
        return 1
    fi
    local -a _ap_repo_arg=()
    [[ -n "$repo" ]] && _ap_repo_arg=(--repo "$repo")
    local payload verdict
    payload="$(CHUMP_GH_CALL_CRITICALITY=background _arm_policy_gh pr view "$pr" ${_ap_repo_arg[@]+"${_ap_repo_arg[@]}"} \
        --json files 2>/dev/null || true)"
    verdict="$(python3 - "$payload" <<'PYCENSUS'
import json, sys

ALLOWED = {
    "docs/observability/CI_TEST_CENSUS.md",
    "docs/observability/ci-test-census.json",
}
raw = sys.argv[1].strip()
if not raw:
    print("ERR:empty-payload")
    sys.exit(0)
try:
    data = json.loads(raw)
except Exception:
    print("ERR:invalid-json")
    sys.exit(0)
files = data.get("files")
if not isinstance(files, list) or len(files) == 0:
    print("ERR:no-files")
    sys.exit(0)
paths = [str(f.get("path", "")) for f in files if isinstance(f, dict)]
if not paths or any(not p for p in paths):
    print("ERR:missing-path")
    sys.exit(0)
outside = [p for p in paths if p not in ALLOWED]
if outside:
    print("OUTSIDE:" + ",".join(outside))
    sys.exit(0)
print("OK")
PYCENSUS
    )"
    if [[ "$verdict" == "OK" ]]; then
        return 0
    fi
    local msg="[census-scope-guard] CREDIBLE-1564: refusing to arm auto-merge on PR #${pr} (${verdict}). Census auto-merge is restricted to \`docs/observability/CI_TEST_CENSUS.md\` and \`docs/observability/ci-test-census.json\`."
    echo "$msg" >&2
    _arm_policy_gh pr comment "$pr" ${_ap_repo_arg[@]+"${_ap_repo_arg[@]}"} --body "$msg" >/dev/null 2>&1 || true
    return 1
}

# arm_scope_allows_dependabot <pr-number> [owner/repo]
#   Returns 0 iff:
#     1. `gh pr view <pr> --json files,title,body,headRefName` returns a
#        non-empty file list where NO path starts with `.github/`; AND
#     2. The bump is an allowlisted update-type: `version-update:semver-patch`
#        (or patch semver bump in title), OR `version-update:semver-minor`
#        for dev-dependencies (`direct:development` / `dev-dependencies`),
#        and NEVER a major bump (`version-update:semver-major`, `cargo-major`,
#        or major version jump `from X.Y.Z to M.N.P` with X != M).
arm_scope_allows_dependabot() {
    local pr="${1:-}" repo="${2:-}"
    if [[ ! "$pr" =~ ^[0-9]+$ ]]; then
        echo "[arm-policy] ERROR: arm_scope_allows_dependabot called without a valid PR number ('$pr') — refusing" >&2
        return 1
    fi
    local -a _ap_repo_arg=()
    [[ -n "$repo" ]] && _ap_repo_arg=(--repo "$repo")
    local payload verdict
    payload="$(CHUMP_GH_CALL_CRITICALITY=background _arm_policy_gh pr view "$pr" ${_ap_repo_arg[@]+"${_ap_repo_arg[@]}"} \
        --json files,title,body,headRefName 2>/dev/null || true)"
    verdict="$(DEPENDABOT_UPDATE_TYPE="${DEPENDABOT_UPDATE_TYPE:-}" \
               DEPENDABOT_DEPENDENCY_TYPE="${DEPENDABOT_DEPENDENCY_TYPE:-}" \
               python3 - "$payload" <<'PYDEP'
import json, os, re, sys

raw = sys.argv[1].strip()
if not raw:
    print("ERR:empty-payload")
    sys.exit(0)
try:
    data = json.loads(raw)
except Exception:
    print("ERR:invalid-json")
    sys.exit(0)

files = data.get("files")
if not isinstance(files, list) or len(files) == 0:
    print("ERR:no-files")
    sys.exit(0)
paths = [str(f.get("path", "")) for f in files if isinstance(f, dict)]
if not paths or any(not p for p in paths):
    print("ERR:missing-path")
    sys.exit(0)

# Rule 1: never arm anything touching .github/
gh_paths = [p for p in paths if p == ".github" or p.startswith(".github/")]
if gh_paths:
    print("ERR:github-path:" + ",".join(gh_paths))
    sys.exit(0)

title = str(data.get("title") or "")
body = str(data.get("body") or "")
head_ref = str(data.get("headRefName") or "")

update_type = os.environ.get("DEPENDABOT_UPDATE_TYPE", "").strip()
dep_type = os.environ.get("DEPENDABOT_DEPENDENCY_TYPE", "").strip()

if not update_type:
    m_ut = re.search(r'update-type:\s*([A-Za-z0-9_:.-]+)', body, re.I)
    if m_ut:
        update_type = m_ut.group(1).strip()
if not dep_type:
    m_dt = re.search(r'dependency-type:\s*([A-Za-z0-9_:.-]+)', body, re.I)
    if m_dt:
        dep_type = m_dt.group(1).strip()

# Rule 2: never arm major bumps (by metadata, group name, or title semver jump)
if "major" in update_type.lower() or "cargo-major" in title.lower() or "cargo-major" in head_ref.lower():
    print("ERR:major-bump")
    sys.exit(0)

m_ver = re.search(r'\bfrom\s+v?(\d+)\.(\d+)(?:\.(\d+))?\s+to\s+v?(\d+)\.(\d+)(?:\.(\d+))?', title, re.I)
if m_ver:
    maj1, min1, pat1, maj2, min2, pat2 = m_ver.groups()
    if maj1 != maj2:
        print(f"ERR:major-version-jump:{maj1}->{maj2}")
        sys.exit(0)

ut_low = update_type.lower()
dt_low = dep_type.lower()

if ut_low in ("version-update:semver-patch", "semver-patch", "patch"):
    print("OK")
    sys.exit(0)

if ut_low in ("version-update:semver-minor", "semver-minor", "minor"):
    if "development" in dt_low or "dev" in dt_low:
        print("OK")
        sys.exit(0)
    print(f"ERR:minor-non-dev:{dep_type or 'unspecified'}")
    sys.exit(0)

if not ut_low and m_ver:
    maj1, min1, pat1, maj2, min2, pat2 = m_ver.groups()
    if maj1 == maj2 and min1 == min2 and pat1 != pat2:
        print("OK")
        sys.exit(0)

print(f"ERR:unallowlisted-update:{update_type or 'unknown'}")
PYDEP
    )"
    if [[ "$verdict" == "OK" ]]; then
        return 0
    fi
    echo "[dependabot-scope-guard] CREDIBLE-1564: refusing to arm auto-merge on PR #${pr} (${verdict})" >&2
    return 1
}
