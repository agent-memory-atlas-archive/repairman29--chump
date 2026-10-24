#!/usr/bin/env bash
# CI test: docs-delta pre-commit gate correctly reads COMMIT_EDITMSG in linked worktrees.
# Covers INFRA-1474: $REPO_ROOT/.git/COMMIT_EDITMSG doesn't exist in a linked worktree
# because .git is a gitdir pointer file, not a directory. Fix: git rev-parse --git-dir.
set -euo pipefail
# CREDIBLE-1527: ensure temp-repo git commits succeed on runners without global git identity.
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-chump-ci-test}" GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-ci-test@chump.local}" GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-chump-ci-test}" GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-ci-test@chump.local}"


REPO_ROOT=$(git rev-parse --show-toplevel)
HOOK="$REPO_ROOT/scripts/git-hooks/pre-commit"
PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# ── Setup: create a temp linked worktree ────────────────────────────────────
WT_DIR=$(mktemp -d)
BRANCH="test-infra-1474-$$"
trap 'git worktree remove --force "$WT_DIR" 2>/dev/null; git branch -D "$BRANCH" 2>/dev/null; true' EXIT

git worktree add -b "$BRANCH" "$WT_DIR" HEAD >/dev/null 2>&1

# Verify the linked worktree has a file .git, not a directory (the precondition)
if [ -f "$WT_DIR/.git" ] && [ ! -d "$WT_DIR/.git" ]; then
    pass ".git is a file in linked worktree (gitdir pointer)"
else
    fail ".git should be a file in linked worktree (setup error)"
fi

# Verify that the old broken path doesn't exist in the linked worktree
BROKEN_PATH="$WT_DIR/.git/COMMIT_EDITMSG"
if [ ! -f "$BROKEN_PATH" ]; then
    pass "old broken path \$REPO_ROOT/.git/COMMIT_EDITMSG does not exist in linked worktree"
else
    fail "old broken path $BROKEN_PATH unexpectedly exists"
fi

# Verify that git rev-parse --git-dir returns a real directory in the linked worktree
WT_GIT_DIR=$(cd "$WT_DIR" && git rev-parse --git-dir)
if [ -d "$WT_GIT_DIR" ]; then
    pass "git rev-parse --git-dir ($WT_GIT_DIR) is a real directory"
else
    fail "git rev-parse --git-dir ($WT_GIT_DIR) is not a directory"
fi

# ── Verify neither hook contains the broken hardcoded path ─────────────────
# INFRA-1969 moved the live docs-delta enforcement from scripts/git-hooks/pre-commit
# to scripts/git-hooks/commit-msg, which reads the message from $1 (the path git
# passes it) rather than resolving any COMMIT_EDITMSG path at all — so there is no
# "$(git rev-parse --git-dir)/COMMIT_EDITMSG" string to require in either hook.
# What matters is that the broken hardcoded path is gone. See
# scripts/ci/test-docs-delta-linked-worktree.sh (INFRA-1521) for the end-to-end
# behavioral proof that a linked-worktree commit succeeds without the bypass.
COMMIT_MSG_HOOK="$REPO_ROOT/scripts/git-hooks/commit-msg"
if grep -qF '$REPO_ROOT/.git/COMMIT_EDITMSG' "$HOOK" "$COMMIT_MSG_HOOK"; then
    fail "a hook still contains the broken \$REPO_ROOT/.git/COMMIT_EDITMSG path"
else
    pass "no hook contains the broken \$REPO_ROOT/.git/COMMIT_EDITMSG path"
fi

# ── Simulate: write COMMIT_EDITMSG to the real worktree git-dir ─────────────
REAL_EDITMSG="$WT_GIT_DIR/COMMIT_EDITMSG"
echo "fix: add something

Net-new-docs: +1" > "$REAL_EDITMSG"

# Confirm git rev-parse path resolves to the file we wrote
if [ -f "$REAL_EDITMSG" ]; then
    pass "COMMIT_EDITMSG written to real git-dir is readable at expected path"
else
    fail "COMMIT_EDITMSG not found at $REAL_EDITMSG"
fi

TRAILER_VAL=$(grep -iE '^Net-new-docs:[[:space:]]*\+?[0-9]+' "$REAL_EDITMSG" | head -1 \
              | sed -E 's/^[Nn]et-new-docs:[[:space:]]*\+?([0-9]+).*/\1/')
if [ "$TRAILER_VAL" = "1" ]; then
    pass "Net-new-docs trailer parsed correctly from real git-dir COMMIT_EDITMSG"
else
    fail "Net-new-docs trailer not parsed (got: '$TRAILER_VAL')"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
