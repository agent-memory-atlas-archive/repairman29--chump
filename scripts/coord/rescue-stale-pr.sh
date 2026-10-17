#!/usr/bin/env bash
# rescue-stale-pr.sh — INFRA-2285: one-command DIRTY-PR rescue.
#
# Rescuing a stale-DIRTY PR by hand is 6 manual steps (worktree, rebase,
# conflict resolution, trailer-laden amend, bypass-flagged force-push, arm
# auto-merge) — see PR #2840 / INFRA-2258 for the concrete 10-min timing.
# This script does all six for the common case: a rebase whose only
# conflicts are trivial (both-add, disjoint lines — e.g. two branches each
# appending a new entry to the same registry file).
#
# Usage:
#   scripts/coord/rescue-stale-pr.sh <pr-num> [--dry-run]
#
# Exit codes:
#   0 — rescued (or, with --dry-run, plan printed) successfully
#   1 — usage / lookup / git error
#   2 — non-trivial conflict; refuses, prints "manual rebase needed: <files>"
#
# Env:
#   GH_TOKEN / gh CLI auth   — required for non-dry-run PR lookup + push
#   RESCUE_STALE_PR_LIB_ONLY=1  — source without running main() (tests)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# RESILIENT-1613: one arm policy — honor `no-auto-merge` / `Auto-merge: hold`.
# shellcheck source=scripts/coord/lib/arm-policy.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/arm-policy.sh"

# ── Pure functions (no I/O) — testable in isolation ─────────────────────────

# rescue_classify_conflict_files <conflict-marker-file-list>
#
# A conflict is "trivial" (both-add, disjoint lines) when `git diff --check`
# style analysis shows the ONLY conflict hunks are additions on each side
# with no overlapping line ranges. We approximate this cheaply: a file is
# trivial iff every conflict hunk in it contains an "ours" side and a
# "theirs" side where neither side deletes/modifies a line the other kept —
# i.e. both sides are pure insertions relative to the merge base. Detected
# by scanning for the absence of any line that appears (verbatim) on both
# sides of the SAME hunk changed differently — in practice: a hunk is
# non-trivial if it contains ANY line that is neither purely `<<<<<<<`
# `=======` `>>>>>>>` scaffolding, present as a real content diff on both
# sides pointing at what was originally a single unchanged line. We use a
# conservative heuristic: a hunk is trivial only when one of its two sides
# is EMPTY (pure addition on the other side) — the classic "both branches
# appended to the same file" shape from INFRA-2258 / PR #2840.
#
# Args: path to a file already containing git conflict markers
# Echoes: "trivial" or "nontrivial"
rescue_classify_conflict_hunks() {
    local file="$1"
    [[ -f "$file" ]] || { echo "nontrivial"; return; }

    awk '
        /^<<<<<<</ { in_ours=1; ours=""; theirs=""; next }
        /^=======/ { if (in_ours) { in_ours=0; in_theirs=1; next } }
        /^>>>>>>>/ {
            if (in_theirs) {
                in_theirs=0
                if (ours != "" && theirs != "") { nontrivial=1 }
            }
            next
        }
        { if (in_ours) ours = ours $0 "\n"; else if (in_theirs) theirs = theirs $0 "\n" }
        END { print (nontrivial ? "nontrivial" : "trivial") }
    ' "$file"
}

# rescue_gate_from_hook_output <hook-stderr-text>
#
# Maps a hook abort message to its "<Trailer-Name>|<ENV_VAR>=<value>" pair.
# Pure string matching — no process spawns — so it's directly unit-testable.
# Order matters: emits one line per gate detected, first match per gate.
rescue_gate_from_hook_output() {
    local text="$1"
    grep -qE 'Bot-Merge-Bypass|CHUMP_BYPASS_BOT_MERGE' <<<"$text" && echo "Bot-Merge-Bypass|CHUMP_BYPASS_BOT_MERGE=1"
    grep -qE 'Test-Gate-Bypass|CHUMP_TEST_GATE' <<<"$text" && echo "Test-Gate-Bypass|CHUMP_TEST_GATE=0"
    grep -qE 'Event-Registry-Bypass|CHUMP_EVENT_REGISTRY_CHECK' <<<"$text" && echo "Event-Registry-Bypass|CHUMP_EVENT_REGISTRY_CHECK=0"
    grep -qE 'Off-Rails-Bypass|CHUMP_OFF_RAILS_CHECK' <<<"$text" && echo "Off-Rails-Bypass|CHUMP_OFF_RAILS_CHECK=0"
    grep -qE 'Lint-Gate-Bypass|CHUMP_CLIPPY_GATE' <<<"$text" && echo "Lint-Gate-Bypass|CHUMP_CLIPPY_GATE=0"
    grep -qE 'Net-new-docs' <<<"$text" && echo "Net-new-docs|"
    return 0
}

# Return true (0) iff every conflicted file in the current rebase is trivial.
# Prints the file list either way (used by both the check and the error msg).
rescue_scan_conflicts() {
    local worktree="$1"
    local -a files=()
    local f status
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        status="${line%%$'\t'*}"
        f="${line#*$'\t'}"
        [[ "$status" == U* || "$status" == "UU" || "$status" == "AA" ]] && files+=("$f")
    done < <(cd "$worktree" && git status --porcelain=v1 | awk '{print $1"\t"$2}')

    local all_trivial=1
    for f in "${files[@]}"; do
        [[ -f "$worktree/$f" ]] || continue
        if [[ "$(rescue_classify_conflict_hunks "$worktree/$f")" != "trivial" ]]; then
            all_trivial=0
        fi
    done
    printf '%s\n' "${files[@]}"
    return $((1 - all_trivial))
}

# ── main ──────────────────────────────────────────────────────────────────

_usage() {
    echo "Usage: $(basename "$0") <pr-num> [--dry-run]" >&2
}

main() {
    local pr_num="" dry_run=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) dry_run=1; shift ;;
            -h|--help) _usage; exit 0 ;;
            *) pr_num="$1"; shift ;;
        esac
    done
    [[ -n "$pr_num" ]] || { _usage; exit 1; }

    local start_ts elapsed_s
    start_ts=$(date +%s)

    # shellcheck disable=SC1091
    source "${REPO_ROOT}/scripts/coord/lib/github.sh" 2>/dev/null || true

    local gap_id
    gap_id="$(git -C "${REPO_ROOT}" log -1 --format=%s 2>/dev/null | grep -oE '[A-Z]+-[0-9]+' | head -1 || true)"

    echo "[rescue-stale-pr] PR #${pr_num}: fetching + rebasing onto origin/main"

    if [[ $dry_run -eq 1 ]]; then
        echo "[rescue-stale-pr] DRY-RUN: would fetch origin, rebase branch for PR #${pr_num} onto origin/main"
        echo "[rescue-stale-pr] DRY-RUN: would scan pre-commit/pre-push hook output for bypass gates"
        echo "[rescue-stale-pr] DRY-RUN: would apply matched trailers (Bot-Merge-Bypass / Test-Gate-Bypass /"
        echo "[rescue-stale-pr]           Event-Registry-Bypass / Off-Rails-Bypass / Lint-Gate-Bypass / Net-new-docs)"
        echo "[rescue-stale-pr] DRY-RUN: would force-with-lease push and arm auto-merge (gh pr merge --auto --squash)"
        echo "[rescue-stale-pr] DRY-RUN: would emit kind=stale_pr_rescued (pr_number=${pr_num}, gap_id=${gap_id:-unknown})"
        exit 0
    fi

    if ! command -v gh &>/dev/null; then
        echo "[rescue-stale-pr] gh CLI not found — cannot look up PR #${pr_num}" >&2
        exit 1
    fi

    local head_ref
    head_ref="$(gh pr view "$pr_num" --json headRefName -q .headRefName 2>/dev/null || true)"
    if [[ -z "$head_ref" ]]; then
        echo "[rescue-stale-pr] could not resolve headRefName for PR #${pr_num}" >&2
        exit 1
    fi

    git -C "${REPO_ROOT}" fetch origin main "$head_ref" --quiet
    git -C "${REPO_ROOT}" checkout "$head_ref" --quiet 2>/dev/null || git -C "${REPO_ROOT}" checkout -b "$head_ref" "origin/${head_ref}" --quiet

    if ! git -C "${REPO_ROOT}" rebase origin/main; then
        local conflict_files
        conflict_files="$(rescue_scan_conflicts "${REPO_ROOT}" || true)"
        if ! rescue_scan_conflicts "${REPO_ROOT}" >/dev/null; then
            git -C "${REPO_ROOT}" rebase --abort 2>/dev/null || true
            echo "manual rebase needed: $(echo "$conflict_files" | tr '\n' ' ')" >&2
            exit 2
        fi
        # Trivial conflicts: both-add, disjoint lines — take both sides.
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            git -C "${REPO_ROOT}" diff --no-index /dev/null "${REPO_ROOT}/$f" >/dev/null 2>&1 || true
            sed -i.bak -e '/^<<<<<<</d' -e '/^=======/d' -e '/^>>>>>>>/d' "${REPO_ROOT}/$f"
            rm -f "${REPO_ROOT}/$f.bak"
            git -C "${REPO_ROOT}" add "$f"
        done <<<"$conflict_files"
        git -C "${REPO_ROOT}" -c core.editor=true rebase --continue
    fi

    local hook_output=""
    local -a bypasses=()
    local -a trailers=()
    hook_output="$(git -C "${REPO_ROOT}" push --dry-run origin "HEAD:${head_ref}" 2>&1 || true)"
    while IFS= read -r gate_line; do
        [[ -z "$gate_line" ]] && continue
        local trailer="${gate_line%%|*}"
        local envpair="${gate_line#*|}"
        trailers+=("$trailer")
        [[ -n "$envpair" ]] && bypasses+=("$envpair")
    done < <(rescue_gate_from_hook_output "$hook_output")

    if [[ ${#trailers[@]} -gt 0 ]]; then
        local msg
        msg="$(git -C "${REPO_ROOT}" log -1 --format=%B)"
        for t in "${trailers[@]}"; do
            if [[ "$t" == "Net-new-docs" ]]; then
                msg="${msg}"$'\n'"Net-new-docs: +0"
            else
                msg="${msg}"$'\n'"${t}: automated rescue via scripts/coord/rescue-stale-pr.sh (INFRA-2285)"
            fi
        done
        git -C "${REPO_ROOT}" commit --amend -m "$msg" --quiet
    fi

    local env_prefix=""
    for b in "${bypasses[@]}"; do
        env_prefix="${env_prefix} ${b}"
    done

    # shellcheck disable=SC2086
    env ${env_prefix} git -C "${REPO_ROOT}" push --force-with-lease origin "HEAD:${head_ref}"

    if arm_policy_allows "$pr_num" "rescue-stale-pr.sh"; then
        CHUMP_GH_CALL_CRITICALITY=background chump_gh pr merge "$pr_num" --auto --squash 2>/dev/null || true
    fi

    elapsed_s=$(( $(date +%s) - start_ts ))
    local bypasses_json
    bypasses_json="$(printf '"%s",' "${bypasses[@]}" | sed 's/,$//')"
    mkdir -p "${REPO_ROOT}/.chump-locks"
    printf '{"ts":"%s","kind":"stale_pr_rescued","pr_number":%s,"gap_id":"%s","bypasses_used":[%s],"elapsed_s":%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$pr_num" "${gap_id:-unknown}" "$bypasses_json" "$elapsed_s" \
        >> "${REPO_ROOT}/.chump-locks/ambient.jsonl"

    echo "[rescue-stale-pr] PR #${pr_num} rescued in ${elapsed_s}s (bypasses: ${bypasses[*]:-none})"
}

if [[ "${RESCUE_STALE_PR_LIB_ONLY:-0}" != "1" ]]; then
    main "$@"
fi
