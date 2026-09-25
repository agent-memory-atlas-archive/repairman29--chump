#!/usr/bin/env bash
# check-pr-scope.sh — CREDIBLE-026 + CREDIBLE-041: PR scope-vs-title divergence detector.
#
# Checks that a PR's file changes are consistent with its title/body scope.
# Three rules:
#
#   Rule A — chore(gaps) purity: a PR prefixed 'chore(gaps):' or 'docs(gaps):'
#     must NOT modify src/**, scripts/** (non-ci), or delete test files.
#     These prefixes imply gap-registry-only changes.
#
#   Rule B — silent revert: a PR that deletes a file added/modified in another
#     merged PR within 72h, where no commit in the current PR has subject
#     starting with 'Revert', is flagged as a potential silent revert.
#     (Lightweight proxy for PR #1444's META-044 silent revert.)
#
#   Rule C — no-bundle-PR (CREDIBLE-041): a PR title listing multiple gap IDs
#     separated by ',' or '+' (e.g. "feat(INFRA-1,INFRA-2): bundle") FAILS
#     unless those IDs are depends_on-linked in .chump/state.db.
#     Catches PRs that bundle unrelated gaps under a single title (PR #1469).
#     Allow-list: PR label 'intentional-bundle' bypasses Rule C.
#
# Exit: 0 = clean, 1 = violations found (unless --warn-only).
#
# Usage:
#   bash scripts/ci/check-pr-scope.sh [--base <branch>] [--warn-only]

set -euo pipefail

# shellcheck source=lib/gate-emit.sh
source "$(dirname "$0")/lib/gate-emit.sh" 2>/dev/null || true
gate_emit_start "CREDIBLE-026" "$*"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
info() { printf '[INFO] %s\n' "$*"; }

WARN_ONLY=0
BASE_BRANCH="${GITHUB_BASE_REF:-main}"
prev_arg=""
for arg in "$@"; do
    case "$arg" in
        --warn-only) WARN_ONLY=1 ;;
        --base|--repo-root) ;;
    esac
    [[ "$prev_arg" == "--base" ]] && BASE_BRANCH="$arg"
    prev_arg="$arg"
done

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
    || echo "")"
if [[ -z "$MERGE_BASE" ]]; then
    warn "Could not compute merge base against $BASE_BRANCH — skipping scope check"
    gate_emit_result "CREDIBLE-026" "skipped" "" "no merge base for $BASE_BRANCH"
    exit 0
fi

# ── Gather PR context ─────────────────────────────────────────────────────────
# INFRA-976: title-lookup priority (highest first):
#   1. PR_TITLE env — the canonical, always-current source; workflow passes
#      `env: PR_TITLE: ${{ github.event.pull_request.title }}`. Survives
#      retitles + detached-HEAD CI checkouts. PR_TITLE_OVERRIDE is an alias.
#   2. PR_TITLE_ENV — legacy alias kept for backward compat (pre-INFRA-976).
#   3. `gh pr view` scoped explicitly via GITHUB_REPOSITORY + GITHUB_HEAD_REF
#      so it doesn't rely on the detached-HEAD checkout inferring a PR #.
#   4. Bare `gh pr view` — works locally with a branch that has an open PR.
#   5. First commit subject — last-resort fallback. WRONG for retitled PRs
#      (the original commit may have been `chore(gaps):` while the PR title
#      is `fix(ship_quality):` after a rebase + retitle). Only here so the
#      gate doesn't refuse-to-run on rebase-preview / local-script contexts.
#
# History: 2026-05-13 PR #1648 was retitled chore(gaps): → fix(ship_quality):
# but pr-hygiene kept reading the original commit subject because gh CLI
# couldn't resolve a PR # from the detached-HEAD CI checkout and the
# workflow didn't pass the title via env. Squashing the PR was the
# only workaround.

# Capture PR_TITLE from environment BEFORE overwriting the local variable.
_pr_title_from_env="${PR_TITLE:-}"
PR_TITLE=""
if [[ -n "${PR_TITLE_OVERRIDE:-}" ]]; then
    PR_TITLE="$PR_TITLE_OVERRIDE"
elif [[ -n "$_pr_title_from_env" ]]; then
    PR_TITLE="$_pr_title_from_env"
elif [[ -n "${PR_TITLE_ENV:-}" ]]; then
    # Legacy: pre-INFRA-976 callers passed PR_TITLE_ENV rather than PR_TITLE.
    PR_TITLE="$PR_TITLE_ENV"
fi
unset _pr_title_from_env
if [[ -z "$PR_TITLE" ]] && command -v gh &>/dev/null; then
    if [[ -n "${GITHUB_REPOSITORY:-}" && -n "${GITHUB_HEAD_REF:-}" ]]; then
        _gh_title="$(gh pr view --repo "$GITHUB_REPOSITORY" "$GITHUB_HEAD_REF" \
            --json title --jq '.title' 2>/dev/null || true)"
        [[ -n "$_gh_title" ]] && PR_TITLE="$_gh_title"
    fi
    if [[ -z "$PR_TITLE" ]]; then
        _gh_title="$(gh pr view --json title --jq '.title' 2>/dev/null || true)"
        [[ -n "$_gh_title" ]] && PR_TITLE="$_gh_title"
    fi
fi
if [[ -z "$PR_TITLE" ]]; then
    PR_TITLE="$(git log --pretty=format:%s "${MERGE_BASE}..HEAD" 2>/dev/null | tail -1 || true)"
fi

# Normalize title prefix (e.g. "chore(gaps): ..." → "chore(gaps)")
PR_PREFIX="$(echo "$PR_TITLE" | grep -oE '^[a-z]+(\([^)]+\))?' || true)"
info "PR title: '$PR_TITLE' (prefix: '$PR_PREFIX')"

# ── Collect changed files ─────────────────────────────────────────────────────
changed_files="$(git diff --name-only "${MERGE_BASE}..HEAD" 2>/dev/null || true)"
deleted_files="$(git diff --name-only --diff-filter=D "${MERGE_BASE}..HEAD" 2>/dev/null || true)"

# ── Rule A: chore(gaps) / docs(gaps) purity ──────────────────────────────────
if echo "$PR_PREFIX" | grep -qE "^(chore|docs)\(gaps\)$"; then
    # These prefixes claim the PR only touches gap YAML / docs
    src_touched=()
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        # Allow: docs/gaps/*.yaml, docs/**/*.md, CLAUDE.md, AGENTS.md, MEMORY.md
        # Disallow: src/**, scripts/ (non-ci), *.rs, *.toml (except docs)
        case "$f" in
            src/*.rs|src/**/*.rs)           src_touched+=("$f") ;;
            crates/*/*.rs|crates/**/*.rs)   src_touched+=("$f") ;;
            scripts/coord/*|scripts/dispatch/*|scripts/dev/*|scripts/setup/*)
                                            src_touched+=("$f") ;;
            *.toml)                         src_touched+=("$f") ;;
        esac
    done <<< "$changed_files"

    if [[ ${#src_touched[@]} -gt 0 ]]; then
        report_violation "Rule A (chore/docs gaps purity): title claims gap-only change but modifies source files:"
        for f in "${src_touched[@]}"; do fail "  $f"; done
        fail "  → If intentional, use 'feat:' or 'fix:' prefix, not 'chore(gaps):'"
    else
        pass "Rule A: chore(gaps) prefix matches gap-only changes"
    fi
else
    pass "Rule A: non-gaps-only prefix — skipping purity check"
fi

# ── Rule B: silent revert detection ──────────────────────────────────────────
# Check if any commit in PR range says "Revert" explicitly
# Use a temp file to avoid subshell variable scoping with <() and pipefail
_revert_count="$(git log --pretty=format:%s "${MERGE_BASE}..HEAD" 2>/dev/null \
    | grep -icE "^revert" || true)"
has_revert_commit=0
[[ "$_revert_count" -gt 0 ]] && has_revert_commit=1

# INFRA-1861 slice (AC #2, false-positive fix for PR #2418): the PR body
# can also explicitly acknowledge a deleted file — either as a markdown
# link "[label](path/to/file)" / "[path/to/file](path/to/file)" or as a
# plain-text mention of the filename/basename. Previously ONLY an explicit
# "Revert" commit subject satisfied this rule, so a PR that deleted a file
# and called it out in prose still false-positived.
PR_BODY_FOR_B=""
if command -v gh &>/dev/null; then
    PR_BODY_FOR_B="$(gh pr view --json body -q .body 2>/dev/null || true)"
fi
file_mentioned_in_pr_body() {
    local f="$1"
    [[ -z "$PR_BODY_FOR_B" ]] && return 1
    local base; base="$(basename "$f")"
    # Markdown link form: [...](path) or [...](.../path) — match on basename
    # so a relative-vs-absolute path style difference still hits.
    if echo "$PR_BODY_FOR_B" | grep -qE "\]\([^)]*${base//./\\.}\)"; then
        return 0
    fi
    # Plain-text mention: the full path or just the basename appears in prose.
    if echo "$PR_BODY_FOR_B" | grep -qF "$f" || echo "$PR_BODY_FOR_B" | grep -qF "$base"; then
        return 0
    fi
    return 1
}

if [[ "$has_revert_commit" -eq 1 ]]; then
    pass "Rule B: explicit Revert commit detected — silent-revert check N/A"
elif [[ -n "$deleted_files" ]] && command -v gh &>/dev/null; then
    # For each deleted file, check if it appeared in a recently merged PR
    # We use git log on origin/main to find when the file was last modified
    silent_reverts=()
    CUTOFF_SECS=259200  # 72 hours
    now_secs="$(date +%s)"
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        # PR body already acknowledges this deletion — not silent.
        if file_mentioned_in_pr_body "$f"; then
            continue
        fi
        # Get last commit on origin/main that touched this file
        last_sha="$(git log "origin/${BASE_BRANCH}" --pretty=format:%H --follow -- "$f" 2>/dev/null | head -1 || true)"
        [[ -z "$last_sha" ]] && continue
        last_ts="$(git log -1 --pretty=format:%ct "$last_sha" 2>/dev/null || true)"
        [[ -z "$last_ts" ]] && continue
        age_secs=$(( now_secs - last_ts ))
        if [[ "$age_secs" -lt "$CUTOFF_SECS" ]]; then
            last_msg="$(git log -1 --pretty=format:%s "$last_sha" 2>/dev/null || true)"
            silent_reverts+=("$f (last touched ${age_secs}s ago: '$last_msg')")
        fi
    done <<< "$deleted_files"

    if [[ ${#silent_reverts[@]} -gt 0 ]]; then
        report_violation "Rule B (silent revert): PR deletes recently-modified files without 'Revert' commit:"
        for r in "${silent_reverts[@]}"; do fail "  $r"; done
        fail "  → If intentional, add a commit titled 'Revert: <reason>' or mention files in PR body"
    else
        pass "Rule B: no silent reverts of recent files detected"
    fi
else
    pass "Rule B: no deleted files or gh unavailable — skipping"
fi

# ── Rule C: no-bundle-PR (CREDIBLE-041) ──────────────────────────────────────
# Extract all gap IDs (domain-NNN pattern) from the PR title, e.g.
# "feat(INFRA-1,CREDIBLE-2+PRODUCT-3): bundle" → [INFRA-1, CREDIBLE-2, PRODUCT-3]
_gap_ids_in_title=()
while IFS= read -r _gid; do
    [[ -n "$_gid" ]] && _gap_ids_in_title+=("$(echo "$_gid" | tr '[:lower:]' '[:upper:]')")
done < <(echo "$PR_TITLE" | grep -oE '[A-Za-z]+-[0-9]+' | sort -u || true)

if [[ "${#_gap_ids_in_title[@]}" -ge 2 ]]; then
    # Check allow-list label
    _bundle_ok=0
    if command -v gh &>/dev/null; then
        _labels="$(gh pr view --json labels -q '.labels[].name' 2>/dev/null || true)"
        echo "$_labels" | grep -q "intentional-bundle" && _bundle_ok=1
    fi

    if [[ "$_bundle_ok" -eq 1 ]]; then
        pass "Rule C: intentional-bundle label present — no-bundle check bypassed"
    else
        # Check depends_on linkage in state.db using sqlite3 if available
        _state_db="${CHUMP_REPO:-$REPO_ROOT}/.chump/state.db"
        _linked=0
        if [[ -f "$_state_db" ]] && command -v sqlite3 &>/dev/null; then
            # For each pair of gap IDs, check if either depends_on the other
            for _a in "${_gap_ids_in_title[@]}"; do
                for _b in "${_gap_ids_in_title[@]}"; do
                    [[ "$_a" == "$_b" ]] && continue
                    # depends_on stored as JSON array or comma-separated; use LIKE
                    _found="$(sqlite3 "$_state_db" \
                        "SELECT COUNT(*) FROM gaps WHERE id='$_a' AND depends_on LIKE '%$_b%';" 2>/dev/null || echo 0)"
                    if [[ "${_found:-0}" -gt 0 ]]; then
                        _linked=1
                        break 2
                    fi
                done
            done
        else
            # No state.db or sqlite3 — can't verify linkage; pass with warning
            warn "Rule C: state.db not found or sqlite3 unavailable — skipping depends_on linkage check"
            _linked=1
        fi

        if [[ "$_linked" -eq 0 ]]; then
            report_violation "CREDIBLE-041 Rule C (no-bundle-PR): title lists ${#_gap_ids_in_title[@]} gap IDs (${_gap_ids_in_title[*]}) but none are depends_on-linked in state.db"
            fail "  → Bundle PRs obscure scope. One gap per PR. If gaps are linked, set depends_on in state.db."
            fail "  → To bypass: add PR label 'intentional-bundle' with a comment explaining why."
            # Emit ambient event
            _lock_dir="${CHUMP_AMBIENT_LOG:-.chump-locks/ambient.jsonl}"
            _amb_dir="$(dirname "${CHUMP_AMBIENT_LOG:-.chump-locks/ambient.jsonl}")"
            mkdir -p "$_amb_dir" 2>/dev/null || true
            _ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            printf '{"ts":"%s","kind":"pr_bundle_blocked","gap_ids":[%s],"depends_on_check_result":"no_link","branch":"%s"}\n' \
                "$_ts" \
                "$(printf '"%s",' "${_gap_ids_in_title[@]}" | sed 's/,$//')" \
                "$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)" \
                >> "${CHUMP_AMBIENT_LOG:-.chump-locks/ambient.jsonl}" 2>/dev/null || true
        else
            pass "Rule C: gap IDs in title are depends_on-linked — bundle is intentional"
        fi
    fi
else
    pass "Rule C: single or no gap ID in title — no-bundle check N/A"
fi

# ── Emit ambient event on violation ──────────────────────────────────────────
if [[ "$VIOLATIONS" -gt 0 ]]; then
    _lock_dir="$REPO_ROOT/.chump-locks"
    mkdir -p "$_lock_dir" 2>/dev/null || true
    _amb="${CHUMP_AMBIENT_LOG:-$_lock_dir/ambient.jsonl}"
    _ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    _pr="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"
    printf '{"ts":"%s","event":"ALERT","kind":"pr_scope_divergence","source":"check-pr-scope","branch":"%s","violations":%d}\n' \
        "$_ts" "$_pr" "$VIOLATIONS" >> "$_amb" 2>/dev/null || true
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
if [[ "$VIOLATIONS" -eq 0 ]]; then
    echo "CREDIBLE-026/CREDIBLE-041: all PR scope checks passed."
    gate_emit_result "CREDIBLE-026" "pass" "" ""
    exit 0
elif [[ "$WARN_ONLY" -eq 1 ]]; then
    warn "CREDIBLE-026/CREDIBLE-041: $VIOLATIONS violation(s) found (warn-only — not blocking)"
    gate_emit_result "CREDIBLE-026" "pass" "warn-only" "$VIOLATIONS violation(s) demoted to warning"
    exit 0
else
    fail "CREDIBLE-026/CREDIBLE-041: $VIOLATIONS violation(s). Fix scope or update PR title."
    fail "How to bypass cleanly: retitle to feat:/fix: (Rule A), add a commit titled 'Revert: <reason>' OR mention the affected filename in the PR body as a markdown link or plain text (Rule B), or add PR label 'intentional-bundle' with a comment explaining the bundle (Rule C)"
    gate_emit_result "CREDIBLE-026" "fail" "scope-violation" "$VIOLATIONS PR scope violation(s)"
    exit 1
fi
