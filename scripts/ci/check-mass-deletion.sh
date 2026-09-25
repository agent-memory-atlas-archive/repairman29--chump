#!/usr/bin/env bash
# check-mass-deletion.sh — CREDIBLE-027 + CREDIBLE-038: mass-deletion / scratch-commit guard.
#
# Three checks:
#   A. Vague commit titles: any commit whose subject is one of the known
#      scratch-commit patterns ('first', 'init', 'wip', 'unrelated change',
#      'INFRA-X', 'edit gap_store', etc.) is flagged.
#      Catches rogue fixture commits on production branches.
#
#   B. Net deletions: PR diff vs base deletes >100 lines from files whose
#      paths are NOT mentioned in the PR title/body or recent commit messages.
#      Catches accidental mass-wipes (PR #1441: 378k lines gone).
#
#   C. File-count-blast (CREDIBLE-038): PR title prefix is a narrow-scope
#      marker (chore(gaps): or docs:) but the diff touches files OUTSIDE
#      the expected directory for that prefix. Catches cross-cutting changes
#      disguised under a narrow title (e.g. "chore(gaps): ..." + src/ edits).
#
#      Expected paths by prefix:
#        chore(gaps): → docs/gaps/
#        docs:        → docs/
#
#      Allow-list: PR label 'cross-cutting-acknowledged' bypasses rule C.
#
# Exit: 0 = clean, 1 = violations found (unless --warn-only).
#
# Usage (local dev):
#   bash scripts/ci/check-mass-deletion.sh [--base <branch>] [--warn-only]
#
# Usage (CI — run from repo root with GITHUB_BASE_REF set):
#   bash scripts/ci/check-mass-deletion.sh

set -euo pipefail

# shellcheck source=lib/gate-emit.sh
source "$(dirname "$0")/lib/gate-emit.sh" 2>/dev/null || true
gate_emit_start "CREDIBLE-027" "$*"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
info() { printf '[INFO] %s\n' "$*"; }

WARN_ONLY=0
BASE_BRANCH="${GITHUB_BASE_REF:-main}"
# Parse args without indirect expansion (portable bash 3)
prev_arg=""
for arg in "$@"; do
    case "$arg" in
        --warn-only) WARN_ONLY=1 ;;
        --base|--repo-root) ;;
    esac
    [[ "$prev_arg" == "--base" ]] && BASE_BRANCH="$arg"
    prev_arg="$arg"
done
# Default to pwd (so CI can cd to repo root first, and tests can cd to fixture repo)
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

VIOLATIONS=0
report_violation() {
    fail "$1"
    VIOLATIONS=$((VIOLATIONS + 1))
}

# ── Resolve merge base ────────────────────────────────────────────────────────
MERGE_BASE="$(git merge-base HEAD "origin/${BASE_BRANCH}" 2>/dev/null \
    || git merge-base HEAD "${BASE_BRANCH}" 2>/dev/null \
    || git rev-parse "origin/${BASE_BRANCH}" 2>/dev/null \
    || echo "")"
if [[ -z "$MERGE_BASE" ]]; then
    warn "Could not compute merge base against $BASE_BRANCH — skipping checks"
    exit 0
fi
info "Checking diff against merge base $MERGE_BASE (${BASE_BRANCH})"

# ── Check 1: Vague commit titles ─────────────────────────────────────────────
VAGUE_PATTERNS="^(first|init|wip|unrelated change|INFRA-X|edit gap_store|test|fix|asdf|temp|tmp|placeholder)$"
COMMITS_IN_PR="$(git log --pretty=format:%s "${MERGE_BASE}..HEAD" 2>/dev/null || true)"
vague_found=()
while IFS= read -r subject; do
    [[ -z "$subject" ]] && continue
    # Match exact vague titles or subjects that are just "Co-Authored-By" trailers
    lower="$(echo "$subject" | tr '[:upper:]' '[:lower:]' | sed 's/[[:space:]]*$//')"
    if echo "$lower" | grep -qE "^(first|init|wip|unrelated change|infra-x|edit gap_store|asdf|temp|tmp|placeholder)$"; then
        vague_found+=("$subject")
    fi
done <<< "$COMMITS_IN_PR"

if [[ ${#vague_found[@]} -gt 0 ]]; then
    for v in "${vague_found[@]}"; do
        report_violation "Vague commit title detected: '$v' — use a descriptive imperative subject"
    done
else
    pass "No vague commit titles"
fi

# ── Check 2: Mass deletions from unrelated files ──────────────────────────────
# Collect PR context: title + body from gh CLI if available, else from commit messages
PR_CONTEXT=""
if command -v gh &>/dev/null; then
    # Try to get PR title + body from the current branch
    PR_INFO="$(gh pr view --json title,body 2>/dev/null || true)"
    if [[ -n "$PR_INFO" ]]; then
        PR_CONTEXT="$(echo "$PR_INFO" | python3 -c "
import json,sys
d = json.loads(sys.stdin.read())
print((d.get('title','') + ' ' + d.get('body','')).lower())
" 2>/dev/null || true)"
    fi
fi
# Fallback: use commit messages as context
if [[ -z "$PR_CONTEXT" ]]; then
    PR_CONTEXT="$(git log --pretty=format:"%s %b" "${MERGE_BASE}..HEAD" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
fi

# INFRA-5744: an explicit "Revert" commit subject already justifies the
# deletion (mirrors check-pr-scope.sh Rule B) — without this, a legitimate
# revert PR that doesn't happen to repeat the deleted file's name/dir in
# the title/body still false-positived on this check.
_revert_count_b="$(git log --pretty=format:%s "${MERGE_BASE}..HEAD" 2>/dev/null \
    | grep -icE "^revert" || true)"
has_revert_commit_b=0
[[ "$_revert_count_b" -gt 0 ]] && has_revert_commit_b=1

# Get all files with their net line-count change (deletions - insertions, per file)
# We flag a file if: net deletions > THRESHOLD and file path not in PR context
THRESHOLD=100
flagged_files=()
total_flagged_deletions=0

if [[ "$has_revert_commit_b" -eq 1 ]]; then
    pass "Explicit Revert commit detected — mass-deletion check N/A"
else
while IFS=$'\t' read -r insertions deletions filepath; do
    # Skip binary files and empty entries
    [[ -z "$filepath" || "$insertions" == "-" ]] && continue
    ins="${insertions:-0}"
    del="${deletions:-0}"
    # net deletion = del - ins; only flag when net deletions exceed threshold
    net_del=$(( del - ins ))
    [[ "$net_del" -le "$THRESHOLD" ]] && continue

    # Check if the file path (or its directory stem) appears in PR context
    # Strip path to basename stem and first directory component for matching
    base="$(basename "$filepath" | sed 's/\.[^.]*$//' | tr '[:upper:]' '[:lower:]')"
    dir1="$(echo "$filepath" | cut -d/ -f1 | tr '[:upper:]' '[:lower:]')"
    dir2="$(echo "$filepath" | cut -d/ -f2 | tr '[:upper:]' '[:lower:]')"

    mentioned=0
    for token in "$base" "$dir1" "$dir2"; do
        [[ -z "$token" ]] && continue
        if echo "$PR_CONTEXT" | grep -qF "$token"; then
            mentioned=1
            break
        fi
    done

    if [[ "$mentioned" -eq 0 ]]; then
        flagged_files+=("$filepath (net -${net_del} lines)")
        total_flagged_deletions=$((total_flagged_deletions + net_del))
    fi
done < <(git diff --numstat "${MERGE_BASE}..HEAD" 2>/dev/null || true)
fi

if [[ ${#flagged_files[@]} -gt 0 ]]; then
    report_violation "Mass deletion from files not mentioned in PR title/body (threshold: ${THRESHOLD} lines):"
    for f in "${flagged_files[@]}"; do
        fail "  $f"
    done
    fail "  Total unrelated deletions: $total_flagged_deletions lines"
    fail "  If intentional, mention the affected paths in the PR body."
else
    pass "No mass unrelated deletions (threshold: ${THRESHOLD} lines)"
fi

# ── Check C: File-count-blast under narrow-scope title (CREDIBLE-038) ────────
# Narrow-scope title prefixes and their expected root directories.
NARROW_TITLE_PREFIX=""
EXPECTED_PATH_PREFIX=""

PR_TITLE_FOR_C=""
if command -v gh &>/dev/null; then
    PR_TITLE_FOR_C="$(gh pr view --json title -q .title 2>/dev/null || true)"
fi
if [[ -z "$PR_TITLE_FOR_C" ]]; then
    PR_TITLE_FOR_C="$(git log --pretty=format:%s "${MERGE_BASE}..HEAD" 2>/dev/null | head -1 || true)"
fi

if echo "$PR_TITLE_FOR_C" | grep -qE "^chore\(gaps\):"; then
    NARROW_TITLE_PREFIX="chore(gaps):"
    EXPECTED_PATH_PREFIX="docs/gaps/"
elif echo "$PR_TITLE_FOR_C" | grep -qE "^docs:"; then
    NARROW_TITLE_PREFIX="docs:"
    EXPECTED_PATH_PREFIX="docs/"
fi

if [[ -n "$NARROW_TITLE_PREFIX" ]]; then
    # Check allow-list: 'cross-cutting-acknowledged' label bypasses rule C
    CROSS_CUTTING_OK=0
    if command -v gh &>/dev/null; then
        LABELS="$(gh pr view --json labels -q '.labels[].name' 2>/dev/null || true)"
        if echo "$LABELS" | grep -q "cross-cutting-acknowledged"; then
            CROSS_CUTTING_OK=1
        fi
    fi

    if [[ "$CROSS_CUTTING_OK" -eq 0 ]]; then
        blast_files=()
        while IFS= read -r filepath; do
            [[ -z "$filepath" ]] && continue
            # If file is NOT under the expected path → violation
            if ! echo "$filepath" | grep -q "^${EXPECTED_PATH_PREFIX}"; then
                blast_files+=("$filepath")
            fi
        done < <(git diff --name-only "${MERGE_BASE}..HEAD" 2>/dev/null || true)

        if [[ ${#blast_files[@]} -gt 0 ]]; then
            report_violation "CREDIBLE-038: title prefix '${NARROW_TITLE_PREFIX}' promises narrow scope (${EXPECTED_PATH_PREFIX}**) but diff includes ${#blast_files[@]} out-of-scope file(s):"
            for f in "${blast_files[@]}"; do
                fail "  $f"
            done
            fail "  If intentional, add PR label 'cross-cutting-acknowledged' or change the title prefix."
            # Emit ambient event
            local_ambient="${CHUMP_AMBIENT_LOG:-.chump-locks/ambient.jsonl}"
            if [[ -d "$(dirname "$local_ambient")" ]] || mkdir -p "$(dirname "$local_ambient")" 2>/dev/null; then
                ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
                printf '{"ts":"%s","kind":"pr_scope_violation","rule":"file_count_blast","title_prefix":"%s","out_of_scope_count":%d}\n' \
                    "$ts" "$NARROW_TITLE_PREFIX" "${#blast_files[@]}" >> "$local_ambient" 2>/dev/null || true
            fi
        else
            pass "Rule C: all files within expected scope for title '${NARROW_TITLE_PREFIX}'"
        fi
    else
        pass "Rule C bypassed: cross-cutting-acknowledged label present"
    fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
if [[ "$VIOLATIONS" -eq 0 ]]; then
    echo "CREDIBLE-027/CREDIBLE-038: all mass-deletion checks passed."
    gate_emit_result "CREDIBLE-027" "pass" "" ""
    exit 0
elif [[ "$WARN_ONLY" -eq 1 ]]; then
    warn "CREDIBLE-027/CREDIBLE-038: $VIOLATIONS violation(s) found (warn-only mode — not blocking)"
    gate_emit_result "CREDIBLE-027" "pass" "warn-only" "$VIOLATIONS violation(s) demoted to warning"
    exit 0
else
    fail "CREDIBLE-027/CREDIBLE-038: $VIOLATIONS violation(s) found. Fix before pushing."
    fail "How to bypass cleanly: mention the affected file paths in the PR title/body (Rule A/B), add label 'cross-cutting-acknowledged' (Rule C), or use --warn-only for local dry-runs; there is no blanket bypass — the gate demotes automatically once the mention/label is present"
    gate_emit_result "CREDIBLE-027" "fail" "mass-deletion" "$VIOLATIONS mass-deletion violation(s)"
    exit 1
fi
