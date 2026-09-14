#!/usr/bin/env bash
# chump-edit-wrap.sh — INFRA-1200
#
# Write-ahead log for worktree edits. Saves a patch to .chump-plans/<GAP-ID>/
# in the stable main-repo tree BEFORE applying to the /tmp worktree.  If the
# worktree is reaped or corrupted, `chump-edit-replay.sh` re-applies all
# patches to a fresh worktree.
#
# Usage:
#   chump-edit-wrap.sh <GAP-ID> <WORKTREE-FILE-PATH> < <new-content>
#
#   GAP-ID            — e.g. INFRA-1200
#   WORKTREE-FILE-PATH — absolute path inside the worktree being edited
#
# The new file content is read from stdin.
#
# Patch format: simple header + new-content (not a unified diff — replay just
# overwrites the file from the patch). seq number zero-padded to 5 digits.
#
# Environment:
#   CHUMP_PLANS_DIR      override .chump-plans/ base (default: <repo-root>/.chump-plans)
#   CHUMP_WORKTREE_ROOT  root of the worktree containing FILE_PATH; used to compute
#                        the relative path saved in the patch. If unset, auto-detected
#                        by walking up from FILE_PATH until a .git entry is found.
#   CHUMP_EDIT_DRY_RUN   print patch path but don't write (tests)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

[[ $# -ge 2 ]] || die "Usage: chump-edit-wrap.sh <GAP-ID> <WORKTREE-FILE-PATH>"
GAP_ID="$1"
FILE_PATH="$2"
shift 2

# Resolve the main-repo root (the stable tree, not the /tmp worktree).
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PLANS_DIR="${CHUMP_PLANS_DIR:-$REPO_ROOT/.chump-plans}"
GAP_DIR="$PLANS_DIR/$GAP_ID"
mkdir -p "$GAP_DIR"

# Assign the next seq number (zero-padded 5 digits).
NEXT_SEQ="$(find "$GAP_DIR" -maxdepth 1 -name '*.patch' 2>/dev/null | wc -l | tr -d ' ')"
NEXT_SEQ=$(printf '%05d' "$NEXT_SEQ")

BASENAME="$(basename "$FILE_PATH")"
PATCH_PATH="$GAP_DIR/${NEXT_SEQ}-${BASENAME}.patch"

# Compute relative path for replay. Walk up from FILE_PATH looking for .git
# (present in all real git worktrees). Override with CHUMP_WORKTREE_ROOT.
detect_worktree_root() {
    local dir
    dir="$(cd "$(dirname "$1")" && pwd)"
    while [[ "$dir" != "/" ]]; do
        [[ -e "$dir/.git" ]] && { echo "$dir"; return 0; }
        dir="$(dirname "$dir")"
    done
    echo ""
}

if [[ -n "${CHUMP_WORKTREE_ROOT:-}" ]]; then
    WT_ROOT="$CHUMP_WORKTREE_ROOT"
else
    WT_ROOT="$(detect_worktree_root "$FILE_PATH")"
fi

if [[ -n "$WT_ROOT" ]]; then
    REL_PATH="${FILE_PATH#"$WT_ROOT/"}"
else
    # Fallback: strip any /tmp/chump-*/ prefix heuristically.
    if [[ "$FILE_PATH" =~ /chump-[a-zA-Z0-9_-]+/(.+)$ ]]; then
        REL_PATH="${BASH_REMATCH[1]}"
    else
        REL_PATH="${FILE_PATH##/}"
    fi
fi

# Read new content from stdin.
NEW_CONTENT="$(cat)"

if [[ "${CHUMP_EDIT_DRY_RUN:-0}" == "1" ]]; then
    printf '[chump-edit-wrap] DRY-RUN: would write %s (%d bytes)\n' \
        "$PATCH_PATH" "${#NEW_CONTENT}" >&2
    exit 0
fi

# Write the patch: header line + new content.
{
    printf '# chump-edit-wrap patch\n'
    printf '# gap: %s\n' "$GAP_ID"
    printf '# file: %s\n' "$FILE_PATH"
    printf '# relpath: %s\n' "$REL_PATH"
    printf '# seq: %s\n' "$NEXT_SEQ"
    printf '# ts: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '# ---\n'
    printf '%s\n' "$NEW_CONTENT"
} > "$PATCH_PATH"

printf '[chump-edit-wrap] saved patch: %s\n' "$PATCH_PATH" >&2

# Emit ambient event (INFRA-1200).
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-${CHUMP_PLANS_DIR%/.chump-plans}/.chump-locks/ambient.jsonl}"
if [[ -n "$AMBIENT_LOG" ]] && [[ -w "$(dirname "$AMBIENT_LOG")" ]]; then
    printf '{"ts":"%s","kind":"chump_plan_patch_saved","gap":"%s","seq":"%s","relpath":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$GAP_ID" "$NEXT_SEQ" "$REL_PATH" \
        >> "$AMBIENT_LOG"
fi

# Apply the new content to the target file in the worktree.
if [[ -n "$FILE_PATH" ]] && [[ -e "$(dirname "$FILE_PATH")" ]]; then
    printf '%s\n' "$NEW_CONTENT" > "$FILE_PATH"
    printf '[chump-edit-wrap] applied to: %s\n' "$FILE_PATH" >&2
else
    printf '[chump-edit-wrap] WARNING: target path %s does not exist; patch saved but not applied\n' \
        "$FILE_PATH" >&2
fi
