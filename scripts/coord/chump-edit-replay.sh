#!/usr/bin/env bash
# chump-edit-replay.sh — INFRA-1200
#
# Apply all saved patches from .chump-plans/<GAP-ID>/ to a target worktree
# in seq order. Idempotent: patches already applied (file content matches)
# are skipped with a SKIP log line.
#
# Usage:
#   chump-edit-replay.sh <GAP-ID> <WORKTREE-ROOT>
#
#   GAP-ID        — e.g. INFRA-1200
#   WORKTREE-ROOT — root of the (possibly fresh) worktree to replay into
#
# Environment:
#   CHUMP_PLANS_DIR  override .chump-plans/ base (default: <repo-root>/.chump-plans)
#   CHUMP_REPLAY_VERBOSE=1  print file contents while replaying

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

[[ $# -ge 2 ]] || die "Usage: chump-edit-replay.sh <GAP-ID> <WORKTREE-ROOT>"
GAP_ID="$1"
WORKTREE_ROOT="$2"

[[ -d "$WORKTREE_ROOT" ]] || die "Worktree root does not exist: $WORKTREE_ROOT"

PLANS_DIR="${CHUMP_PLANS_DIR:-$REPO_ROOT/.chump-plans}"
GAP_DIR="$PLANS_DIR/$GAP_ID"

if [[ ! -d "$GAP_DIR" ]]; then
    printf '[chump-edit-replay] No patches found for %s (dir absent: %s)\n' \
        "$GAP_ID" "$GAP_DIR" >&2
    exit 0
fi

APPLIED=0
SKIPPED=0
TOTAL=0

# Process patches in seq order.
while IFS= read -r -d '' patch; do
    TOTAL=$((TOTAL+1))

    # Parse header lines (lines starting with '# ').
    orig_file=""
    rel_file=""
    while IFS= read -r line; do
        case "$line" in
            '# file: '*)    orig_file="${line#'# file: '}" ;;
            '# relpath: '*) rel_file="${line#'# relpath: '}" ;;
            '# ---')        break ;;
        esac
    done < "$patch"

    if [[ -z "$orig_file" ]]; then
        printf '[chump-edit-replay] WARN: no file header in %s — skipping\n' \
            "$(basename "$patch")" >&2
        SKIPPED=$((SKIPPED+1))
        continue
    fi

    # Use saved relpath if present; otherwise fall back to heuristic stripping.
    if [[ -z "$rel_file" ]]; then
        if [[ "$orig_file" =~ /chump-[a-zA-Z0-9_-]+/(.+)$ ]]; then
            rel_file="${BASH_REMATCH[1]}"
        else
            rel_file="${orig_file##/}"
        fi
    fi

    target="$WORKTREE_ROOT/$rel_file"

    # Extract content (everything after the '# ---' separator).
    # awk: skip header lines, print body.
    new_content="$(awk '/^# ---$/{found=1; next} found{print}' "$patch")"

    # Idempotency: skip if target already has identical content.
    if [[ -f "$target" ]]; then
        existing="$(cat "$target")"
        if [[ "$existing" == "$new_content" ]]; then
            printf '[chump-edit-replay] SKIP (already applied): %s\n' "$rel_file" >&2
            SKIPPED=$((SKIPPED+1))
            continue
        fi
    fi

    # Ensure parent directory exists.
    mkdir -p "$(dirname "$target")"

    printf '%s\n' "$new_content" > "$target"
    printf '[chump-edit-replay] APPLY: %s → %s\n' "$(basename "$patch")" "$rel_file" >&2
    APPLIED=$((APPLIED+1))

done < <(find "$GAP_DIR" -maxdepth 1 -name '*.patch' -print0 | sort -z)

printf '[chump-edit-replay] Done: %d applied, %d skipped, %d total patches for %s\n' \
    "$APPLIED" "$SKIPPED" "$TOTAL" "$GAP_ID" >&2
