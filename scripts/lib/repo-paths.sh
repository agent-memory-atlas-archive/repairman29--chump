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
# CREDIBLE-1611: when invoked from inside a linked git worktree (.claude/worktrees/<name>
# or .chump/worktrees/<name>) whose main repo matches CHUMP_REPO_ROOT, keep REPO_ROOT
# at the invoking worktree toplevel so branch/commit operations are not clobbered
# back to the main checkout on `main`.
_rp_cwd_top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
_rp_git_dir="$(git rev-parse --git-dir 2>/dev/null || true)"
_rp_common_dir="$(git rev-parse --git-common-dir 2>/dev/null || true)"
_rp_cwd_main=""
if [[ -n "$_rp_cwd_top" && -n "$_rp_git_dir" && -n "$_rp_common_dir" && "$_rp_git_dir" != "$_rp_common_dir" ]]; then
    _rp_cwd_main="$(cd "$_rp_common_dir/.." 2>/dev/null && pwd -P || true)"
fi
if [[ -n "${CHUMP_REPO_ROOT:-}" ]]; then
    _rp_override_phys="$(cd "$CHUMP_REPO_ROOT" 2>/dev/null && pwd -P || echo "$CHUMP_REPO_ROOT")"
    if [[ -n "$_rp_cwd_main" && ( "$_rp_override_phys" == "$_rp_cwd_main" || "$_rp_cwd_top" == "$_rp_override_phys/"* ) ]]; then
        REPO_ROOT="$_rp_cwd_top"
    else
        REPO_ROOT="$CHUMP_REPO_ROOT"
    fi
    unset _rp_override_phys
else
    REPO_ROOT="${_rp_cwd_top:-$(pwd)}"
fi
unset _rp_cwd_top _rp_git_dir _rp_common_dir _rp_cwd_main

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
