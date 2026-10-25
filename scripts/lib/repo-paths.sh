#!/usr/bin/env bash
# scripts/lib/repo-paths.sh — INFRA-109 (2026-05-02)
#
# Canonical path resolution for coordination scripts that read/write
# `.chump-locks/` and `.chump/`. Source this file from any script that
# touches those directories so paths resolve to the **main repo**, not
# the linked worktree, regardless of cwd.
#
# Usage (in caller):
#
#     # shellcheck source=scripts/lib/repo-paths.sh
#     source "$(dirname "$0")/../lib/repo-paths.sh"
#     # MAIN_REPO and LOCK_DIR are now set.
#
# Why this exists: `git rev-parse --show-toplevel` returns the WORKTREE
# root, not the main repo. So `$REPO_ROOT/.chump-locks` from a linked
# worktree writes to the worktree's own `.chump-locks/` — invisible to
# sibling agents running from other worktrees. The `--git-common-dir`
# escape hatch returns the main repo's `.git`, whose parent is the main
# repo root regardless of cwd.
#
# Pattern lifted from `scripts/dev/chump-ambient-glance.sh` (which has
# always done it correctly). INFRA-109 spreads it to gap-claim.sh,
# gap-preflight.sh, gap-reserve.sh, chump-commit.sh, bot-merge.sh.
#
# CHUMP_LOCK_DIR overrides LOCK_DIR (used by tests).

# Worktree root (or pwd if not in a git repo — tests, bootstrap).
# CREDIBLE-1584: honor CHUMP_REPO_ROOT when tests override the target repo so
# scripts invoked from a developer checkout never leak into the caller's git tree.
if [[ -n "${CHUMP_REPO_ROOT:-}" ]]; then
    REPO_ROOT="$CHUMP_REPO_ROOT"
else
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi

# Resolve main-repo root via --git-common-dir. In the main checkout this
# returns ".git"; in a linked worktree it returns the absolute path to
# the main repo's .git. Either way, MAIN_REPO is the .git's parent.
_GIT_COMMON_DIR="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON_DIR" == ".git" ]]; then
    MAIN_REPO="$REPO_ROOT"
else
    MAIN_REPO="$(cd "$_GIT_COMMON_DIR/.." 2>/dev/null && pwd || echo "$REPO_ROOT")"
fi
unset _GIT_COMMON_DIR

# Canonical lock dir. Always under the main repo so siblings see each
# other's leases. Tests can override via CHUMP_LOCK_DIR.
LOCK_DIR="${CHUMP_LOCK_DIR:-$MAIN_REPO/.chump-locks}"
