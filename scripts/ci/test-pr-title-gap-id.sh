#!/usr/bin/env bash
# test-pr-title-gap-id.sh — INFRA-8594
#
# Refuses a PR whose title:
#   1. Equals or derives from its head branch name (e.g. 'claude/infra 8588'
#      derived from branch 'claude/infra-8588', or any '<prefix>/<slug>'
#      branch-shaped title without a colon), OR
#   2. Lacks a canonical uppercase gap ID (DOMAIN-NNNN, e.g. 'INFRA-8594: ...',
#      'fix(INFRA-8594): ...', or 'fix(ci): ... (INFRA-8594)').
#
# Exempt (explicit allowlist with documented reasons):
#   - Nightly census bot PRs:         ^census: [0-9]{4}-[0-9]{2}-[0-9]{2}\b
#   - Orphan-branch-sweeper manifests: ^ZERO-WASTE: orphan-branch-sweeper stash manifest\b
#   - Explicit Revert PRs:            ^[Rr]evert([(: ]|$)
#   - Dependabot / release-plz bots:  ^Bump\b, ^(chore|build)\(deps(-dev)?\):, ^chore\(release\):,
#                                     or PR_AUTHOR in dependabot[bot] / github-actions[bot] / release-plz[bot]
#
# Runs a hermetic fixture test matrix + mutant check on every invocation, and
# when PR_TITLE is non-empty in the environment (passed by ci.yml pr-hygiene),
# validates the live PR title as well.

set -euo pipefail

PASS=0
FAIL=0
ok()   { printf '  [PASS] %s\n' "$*"; PASS=$((PASS + 1)); }
fail() {
    printf '  [FAIL] %s\n' "$*" >&2
    printf '  How to bypass cleanly: retitle the PR with a leading gap ID (e.g. "INFRA-8594: <summary>" or "fix(INFRA-8594): <summary>"), or if this is a sanctioned automated bot PR, add its pattern + reason to allowlist_reason() in scripts/ci/test-pr-title-gap-id.sh\n' >&2
    FAIL=$((FAIL + 1))
}

normalize_branch_like() {
    printf '%s' "$1" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[[:space:]]*\(#[0-9]+\)[[:space:]]*$//; s/[-_\/[:space:]]+/ /g; s/^ +//; s/ +$//'
}

# Explicit allowlist with documented reasons. Prints the reason and returns 0
# if exempt; returns 1 otherwise.
allowlist_reason() {
    local title="$1" author="${2:-}"
    case "$author" in
        "dependabot[bot]"|"github-actions[bot]"|"release-plz[bot]")
            printf 'allowlisted bot author (%s)' "$author"
            return 0
            ;;
    esac
    if printf '%s
' "$title" | grep -qE '^census: [0-9]{4}-[0-9]{2}-[0-9]{2}'; then
        printf 'nightly census report PR (automated metrics snapshot)'
        return 0
    fi
    if printf '%s
' "$title" | grep -qE '^ZERO-WASTE: orphan-branch-sweeper stash manifest'; then
        printf 'orphan-branch-sweeper automated stash manifest PR'
        return 0
    fi
    if printf '%s
' "$title" | grep -qE '^[Rr]evert([(:[:space:]]|$)'; then
        printf 'explicit git/GitHub revert PR'
        return 0
    fi
    if printf '%s
' "$title" | grep -qE '^(Bump |(chore|build)\(deps(-dev)?\):|chore\(release\):)'; then
        printf 'automated dependency or release bump PR'
        return 0
    fi
    return 1
}

# Returns 0 if valid, 1 if refused (printing reason on stdout/stderr).
validate_pr_title() {
    local title="$1" head_ref="${2:-}" author="${3:-}"
    local stripped_title
    stripped_title="$(printf '%s' "$title" | sed -E 's/[[:space:]]*\(#[0-9]+\)[[:space:]]*$//')"

    if [[ -z "${stripped_title// /}" ]]; then
        printf 'empty PR title'
        return 1
    fi

    local reason=""
    if reason="$(allowlist_reason "$stripped_title" "$author")"; then
        printf 'EXEMPT: %s' "$reason"
        return 0
    fi

    # Rule 1: refuse if title equals or derives from head_ref (e.g. 'claude/infra 8588' from 'claude/infra-8588')
    if [[ -n "$head_ref" ]]; then
        local norm_title norm_head
        norm_title="$(normalize_branch_like "$stripped_title")"
        norm_head="$(normalize_branch_like "$head_ref")"
        if [[ -n "$norm_head" && "$norm_title" == "$norm_head" ]]; then
            printf "title '%s' equals or derives from head branch '%s'" "$title" "$head_ref"
            return 1
        fi
    fi

    # Also refuse branch-shaped titles (<prefix>/<slug> with no colon), which
    # happen when `gh pr create` defaults the title from a branch name like
    # `claude/infra-8588` -> `claude/infra 8588` even if head_ref is unset.
    if printf '%s
' "$stripped_title" | grep -qE '^(claude|fix|feat|chore|docs|test|refactor|salvage|auto-claude|cursor|codex|chump)/[^:]+$'; then
        printf "title '%s' is shaped like a branch name (no ':' separator)" "$title"
        return 1
    fi

    # Rule 2: require a canonical uppercase gap ID (DOMAIN-NNNN, e.g. INFRA-8594 or ZERO-WASTE-136)
    # either as a leading prefix 'DOMAIN-NNNN:' or in a conventional commit title.
    if printf '%s
' "$stripped_title" | grep -qE '^[A-Z][A-Z0-9]*(-[A-Z0-9]+)*-[0-9]+([[:space:],+/]+[A-Z][A-Z0-9]*(-[A-Z0-9]+)*-[0-9]+)*:'; then
        printf 'VALID: leading gap ID prefix'
        return 0
    fi

    if printf '%s
' "$stripped_title" | grep -qE '^(feat|fix|chore|docs|test|refactor|perf|ci|build|style)(\([^)]*\))?!?:' \
       && printf '%s
' "$stripped_title" | grep -qE '[A-Z][A-Z0-9]*(-[A-Z0-9]+)*-[0-9]+'; then
        printf 'VALID: conventional commit with canonical gap ID'
        return 0
    fi

    printf "title '%s' lacks a leading or conventional-commit gap ID (DOMAIN-NNNN)" "$title"
    return 1
}

echo "=== INFRA-8594: PR title gap-ID and branch-name guard ==="

# ── 1. Hermetic fixture matrix ────────────────────────────────────────────────
# Refused cases (must return non-zero):
for case_spec in \
    "claude/infra 8588|claude/infra-8588|repairman29|PR #5598 branch-derived title" \
    "claude/infra 8588 (#5598)|claude/infra-8588|repairman29|PR #5598 squashed branch-derived title" \
    "claude/infra 8573||repairman29|branch-shaped title without head_ref" \
    "fix/infra-8594|fix/INFRA-8594|repairman29|raw fix/ branch name as title" \
    "misc cleanup without gap id|fix/INFRA-8594-clean|repairman29|missing gap ID" \
    "fix(ci): unjam fast-checks without gap id|fix/INFRA-8594-ci|repairman29|conventional commit lacking gap ID"; do
    IFS='|' read -r t_title t_head t_author t_label <<<"$case_spec"
    if msg="$(validate_pr_title "$t_title" "$t_head" "$t_author" 2>&1)"; then
        fail "fixture ($t_label): expected refusal for '$t_title', got PASS ($msg)"
    else
        ok "fixture ($t_label): refused '$t_title' ($msg)"
    fi
done

# Accepted cases (must return 0):
for case_spec in \
    "INFRA-8594: refuse branch-derived PR titles in pr-hygiene|fix/INFRA-8594-title-guard|repairman29|leading DOMAIN-NNNN:" \
    "ZERO-WASTE-136: orphan sweeper pagination|fix/ZERO-WASTE-136-sweeper|repairman29|hyphenated domain leading ID" \
    "fix(CREDIBLE-1574): use json_extract for closed PR state|fix/CREDIBLE-1574-cache|repairman29|conventional commit scoped gap ID" \
    "fix(coord): guard bot-merge dry-run staging (CREDIBLE-1584, INFRA-8594)|fix/CREDIBLE-1574-cache|repairman29|conventional commit trailing gap IDs" \
    "census: 2026-10-23 (unwired 1204, red 371)|census/2026-10-23|repairman29|allowlisted nightly census PR" \
    "ZERO-WASTE: orphan-branch-sweeper stash manifest (8 row(s), sweep-123)|sweeper/manifest|repairman29|allowlisted orphan-branch-sweeper manifest" \
    "Bump the cargo-patch-and-minor group with 9 updates|dependabot/cargo/all|dependabot[bot]|allowlisted dependabot PR" \
    "Revert \"fix(ci): broken change\"|revert-123|repairman29|allowlisted Revert PR"; do
    IFS='|' read -r t_title t_head t_author t_label <<<"$case_spec"
    if msg="$(validate_pr_title "$t_title" "$t_head" "$t_author" 2>&1)"; then
        ok "fixture ($t_label): accepted '$t_title' ($msg)"
    else
        fail "fixture ($t_label): expected PASS for '$t_title', got refusal ($msg)"
    fi
done

# ── 2. Mutant check ───────────────────────────────────────────────────────────
# If normalize_branch_like fails to normalize '/' and '-' to spaces, 'claude/infra 8588'
# against head_ref 'claude/infra-8588' with a fake gap suffix would slip past Rule 1.
norm_a="$(normalize_branch_like "claude/infra 8588")"
norm_b="$(normalize_branch_like "claude/infra-8588")"
if [[ "$norm_a" == "$norm_b" && "$norm_a" == "claude infra 8588" ]]; then
    ok "INFRA-8594 mutant check: normalize_branch_like equates 'claude/infra 8588' and 'claude/infra-8588'"
else
    fail "INFRA-8594 mutant check: normalize_branch_like mismatch ('$norm_a' vs '$norm_b')"
fi

# ── 3. Live PR check (when PR_TITLE is provided by ci.yml pr-hygiene) ─────────
if [[ -n "${PR_TITLE:-}" ]]; then
    if live_msg="$(validate_pr_title "$PR_TITLE" "${HEAD_REF:-${GITHUB_HEAD_REF:-}}" "${PR_AUTHOR:-}" 2>&1)"; then
        ok "live PR title valid: '$PR_TITLE' ($live_msg)"
    else
        fail "live PR title refused: $live_msg"
    fi
fi

echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
