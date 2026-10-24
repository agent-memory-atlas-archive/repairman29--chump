#!/usr/bin/env bash
# pre-push-ci-regression-guard.sh — INFRA-1421
#
# Enforces the CI-regression-guard protocol: when a push (or PR) includes
# commits that touch .github/workflows/ci.yml, any commit carrying a
# "CI-Regression-Guard: <test-script>" trailer must have that test script
# present in the repo. Commits with fix( subjects that touch ci.yml but
# lack the trailer emit a non-blocking warning so the operator knows to add
# the guard before the next regression slips through.
#
# Protocol summary:
#   1. Fix a CI regression (e.g. tauri paths-filter re-added).
#   2. Create scripts/ci/test-<fix>.sh that asserts the broken state
#      CANNOT come back (asserts the INVERSE / healthy condition).
#   3. Add to commit body:
#        CI-Regression-Guard: scripts/ci/test-<fix>.sh
#   4. This hook verifies the test exists before push.
#   5. The CI audit job runs the full regression-guard suite.
#
# Full protocol: docs/process/CI_REGRESSION_GUARDS.md
#
# Usage (standalone):
#   bash scripts/git-hooks/pre-push-ci-regression-guard.sh
#
# Usage (from main pre-push hook):
#   GUARD_SCRIPT="$REPO_ROOT/scripts/git-hooks/pre-push-ci-regression-guard.sh"
#   [[ -x "$GUARD_SCRIPT" ]] && bash "$GUARD_SCRIPT" || exit 1
#
# CI usage (set GITHUB_BASE_SHA for PR diff range):
#   GITHUB_BASE_SHA="${{ github.event.pull_request.base.sha }}" \
#     bash scripts/git-hooks/pre-push-ci-regression-guard.sh
#
# Bypass: CHUMP_CI_REGRESSION_GUARD=0 — skips all checks (use sparingly;
#   document reason in commit body as "CI-Regression-Guard-Bypass: <reason>")

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"
mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true

emit_ambient() {
    local kind="$1" note="${2:-}"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
    local payload
    payload=$(printf '{"ts":"%s","event":"INFO","kind":"%s","source":"pre-push-ci-regression-guard","note":"%s"}\n' \
        "$ts" "$kind" "$note")
    echo "$payload" >> "$AMBIENT" 2>/dev/null || true
    echo "[ci-regression-guard] $payload" >&2
}

# Bypass
if [[ "${CHUMP_CI_REGRESSION_GUARD:-1}" == "0" ]]; then
    echo "[ci-regression-guard] CHUMP_CI_REGRESSION_GUARD=0 — guard disabled." >&2
    exit 0
fi

# Determine the commit range to inspect.
# Pre-push context: compare against origin/main.
# CI context: use GITHUB_BASE_SHA if available.
if [[ -n "${GITHUB_BASE_SHA:-}" ]]; then
    BASE_REF="$GITHUB_BASE_SHA"
    echo "[ci-regression-guard] CI mode: comparing ${GITHUB_BASE_SHA:0:8}...HEAD" >&2
elif git rev-parse origin/main &>/dev/null; then
    BASE_REF="origin/main"
    echo "[ci-regression-guard] local mode: comparing origin/main...HEAD" >&2
else
    # Can't determine base — skip silently to avoid false positives.
    echo "[ci-regression-guard] WARN: cannot determine base ref; skipping guard." >&2
    exit 0
fi

# Does this push touch .github/workflows/ci.yml?
CHANGED_CI=$(git diff --name-only "${BASE_REF}...HEAD" 2>/dev/null \
    | grep -E '^\.github/workflows/ci\.yml$' || true)

if [[ -z "$CHANGED_CI" ]]; then
    # No ci.yml changes — nothing to guard.
    exit 0
fi

echo "[ci-regression-guard] ci.yml changed in this push — checking CI-Regression-Guard trailers." >&2

# Phase 0 (CREDIBLE-1545 AC2, blocking): verify .github/workflows/ci.yml on HEAD/worktree
# retains every (job, step_name) present on BASE_REF unless intentionally deleted in
# the branch's own non-merge commits.
if [[ -f "$REPO_ROOT/scripts/git/ci-yml-yaml-merge.py" ]] && command -v python3 &>/dev/null; then
    if ! python3 "$REPO_ROOT/scripts/git/ci-yml-yaml-merge.py" --check-repo-step-retention "$REPO_ROOT" "$BASE_REF"; then
        emit_ambient "ci_regression_guard_suite_failed" "ci_step_retention_failed base=$BASE_REF"
        exit 1
    fi
fi

# Phase 1 (blocking): CI-Regression-Guard trailers that reference missing test files.
MISSING_TESTS=()
while IFS= read -r sha; do
    [[ -z "$sha" ]] && continue
    body="$(git log -1 --format="%B" "$sha" 2>/dev/null)"
    # Extract all CI-Regression-Guard: trailers from this commit.
    while IFS= read -r trailer_line; do
        [[ -z "$trailer_line" ]] && continue
        # Strip leading whitespace and the trailer key.
        test_path="${trailer_line#*: }"
        test_path="${test_path%%#*}"   # strip inline comments
        test_path="$(echo "$test_path" | xargs)"  # trim whitespace
        [[ -z "$test_path" ]] && continue
        if [[ ! -f "$REPO_ROOT/$test_path" ]]; then
            MISSING_TESTS+=("$sha: $test_path")
        fi
    done < <(echo "$body" | grep -E '^CI-Regression-Guard:' || true)
done < <(git log --format="%H" "${BASE_REF}...HEAD" 2>/dev/null)

if [[ "${#MISSING_TESTS[@]}" -gt 0 ]]; then
    echo "" >&2
    echo "[ci-regression-guard] BLOCKED (INFRA-1421): CI-Regression-Guard trailer references missing test(s):" >&2
    for m in "${MISSING_TESTS[@]}"; do
        echo "[ci-regression-guard]   $m" >&2
    done
    echo "" >&2
    echo "[ci-regression-guard] Create the test script before pushing, or remove the trailer." >&2
    echo "[ci-regression-guard] See docs/process/CI_REGRESSION_GUARDS.md for the template." >&2
    echo "" >&2
    missing_csv="$(IFS=','; echo "${MISSING_TESTS[*]}")"
    emit_ambient "ci_regression_guard_blocked" "$missing_csv"
    exit 1
fi

# Phase 2 (non-blocking warning): fix( commits touching ci.yml with no guard trailer.
FIX_SHAS=()
while IFS= read -r sha_subject; do
    [[ -z "$sha_subject" ]] && continue
    sha="${sha_subject%% *}"
    FIX_SHAS+=("$sha")
done < <(git log --format="%H %s" "${BASE_REF}...HEAD" 2>/dev/null \
    | grep -E '^\S+ fix\(' || true)

if [[ "${#FIX_SHAS[@]}" -gt 0 ]]; then
    UNGUARDED=()
    for sha in "${FIX_SHAS[@]}"; do
        body="$(git log -1 --format="%B" "$sha" 2>/dev/null)"
        if ! echo "$body" | grep -qE '^CI-Regression-Guard:'; then
            short="$(git log -1 --format="%h %s" "$sha" 2>/dev/null)"
            UNGUARDED+=("$short")
        fi
    done
    if [[ "${#UNGUARDED[@]}" -gt 0 ]]; then
        echo "" >&2
        echo "[ci-regression-guard] WARN: fix commit(s) touch ci.yml but have no CI-Regression-Guard trailer:" >&2
        for u in "${UNGUARDED[@]}"; do
            echo "[ci-regression-guard]   $u" >&2
        done
        echo "" >&2
        echo "[ci-regression-guard] Consider adding to the commit body:" >&2
        echo "[ci-regression-guard]   CI-Regression-Guard: scripts/ci/test-<your-fix>.sh" >&2
        echo "[ci-regression-guard] See docs/process/CI_REGRESSION_GUARDS.md" >&2
        echo "" >&2
        unguarded_csv="$(IFS=','; echo "${UNGUARDED[*]}")"
        emit_ambient "ci_regression_guard_missing" "$unguarded_csv"
    fi
fi

# Phase 3: Run all registered regression-guard test scripts that exist.
# Collects scripts/ci/test-*.sh files that are listed in any commit's
# CI-Regression-Guard trailers in the push range — runs them as a suite.
GUARD_SCRIPTS=()
while IFS= read -r sha; do
    [[ -z "$sha" ]] && continue
    body="$(git log -1 --format="%B" "$sha" 2>/dev/null)"
    while IFS= read -r trailer_line; do
        [[ -z "$trailer_line" ]] && continue
        test_path="${trailer_line#*: }"
        test_path="${test_path%%#*}"
        test_path="$(echo "$test_path" | xargs)"
        [[ -z "$test_path" ]] && continue
        [[ -f "$REPO_ROOT/$test_path" ]] || continue
        GUARD_SCRIPTS+=("$REPO_ROOT/$test_path")
    done < <(echo "$body" | grep -E '^CI-Regression-Guard:' || true)
done < <(git log --format="%H" "${BASE_REF}...HEAD" 2>/dev/null)

# Deduplicate.
# shellcheck disable=SC2207
GUARD_SCRIPTS=($(printf '%s\n' "${GUARD_SCRIPTS[@]}" | sort -u))

if [[ "${#GUARD_SCRIPTS[@]}" -gt 0 ]]; then
    echo "[ci-regression-guard] Running ${#GUARD_SCRIPTS[@]} regression-guard test(s)..." >&2
    SUITE_FAIL=0
    for script in "${GUARD_SCRIPTS[@]}"; do
        echo "[ci-regression-guard] → $script" >&2
        if bash "$script"; then
            echo "[ci-regression-guard]   ✓ PASS" >&2
        else
            echo "[ci-regression-guard]   ✗ FAIL — regression guard tripped!" >&2
            SUITE_FAIL=1
        fi
    done
    if [[ "$SUITE_FAIL" -ne 0 ]]; then
        echo "" >&2
        echo "[ci-regression-guard] BLOCKED: one or more regression-guard tests failed." >&2
        echo "[ci-regression-guard] A previously-fixed CI regression may have been re-introduced." >&2
        emit_ambient "ci_regression_guard_suite_failed" "one or more guard tests failed"
        exit 1
    fi
    echo "[ci-regression-guard] ✓ all regression-guard tests passed." >&2
fi

exit 0
