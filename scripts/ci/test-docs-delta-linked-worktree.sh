#!/usr/bin/env bash
# CI test: docs-delta commit-msg gate works end-to-end in a linked worktree
# WITHOUT the CHUMP_DOCS_DELTA_CHECK=0 bypass (INFRA-1521).
#
# INFRA-1521 diagnosed a hardcoded $REPO_ROOT/.git/COMMIT_EDITMSG path that
# doesn't exist in a linked worktree (.git is a gitdir-pointer FILE there,
# not a directory) — the correct path is $(git rev-parse --git-dir)/COMMIT_EDITMSG,
# resolving to .git/worktrees/<name>/COMMIT_EDITMSG. By the time this test
# was written, the docs-delta enforcement had already moved to the
# commit-msg hook (INFRA-1969) which reads the message from $1 directly —
# no COMMIT_EDITMSG path resolution at all — so the class of bug is
# structurally gone from the live check. This test proves the end-to-end
# behavior (real `git commit` in a real linked worktree) rather than
# grepping hook source for a specific string, so it stays valid across
# future refactors of *how* the message is located.
set -euo pipefail
# CREDIBLE-1527: ensure temp-repo git commits succeed on runners without global git identity.
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-chump-ci-test}" GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-ci-test@chump.local}" GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-chump-ci-test}" GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-ci-test@chump.local}"


REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

WT_DIR=$(mktemp -d)
BRANCH="test-infra-1521-$$"
cleanup() {
    git worktree remove --force "$WT_DIR" >/dev/null 2>&1 || true
    git branch -D "$BRANCH" >/dev/null 2>&1 || true
}
trap cleanup EXIT

git worktree add -b "$BRANCH" "$WT_DIR" HEAD >/dev/null 2>&1

# Precondition: .git is a gitdir-pointer FILE, not a directory, in the linked worktree.
if [ -f "$WT_DIR/.git" ] && [ ! -d "$WT_DIR/.git" ]; then
    pass ".git is a file (gitdir pointer) in the linked worktree"
else
    fail ".git should be a file in the linked worktree (setup error)"
fi

DOC_FILE="docs/test-infra-1521-doc-$$.md"

(
    cd "$WT_DIR"
    echo "infra-1521 regression fixture" > "$DOC_FILE"
    git add "$DOC_FILE"
    # Net-new-docs trailer satisfies the docs-delta gate; CHUMP_DOCS_DELTA_CHECK
    # is intentionally left at its default (unset/1 = enforced) — the whole
    # point is proving the gate resolves the message WITHOUT the bypass.
    git -c core.hooksPath="$REPO_ROOT/scripts/git-hooks" commit \
        -m "docs: infra-1521 linked-worktree regression fixture

Net-new-docs: +1" > /tmp/infra-1521-commit-output.$$ 2>&1
) && COMMIT_RC=0 || COMMIT_RC=$?

if [ "$COMMIT_RC" -eq 0 ]; then
    pass "commit in linked worktree succeeded without CHUMP_DOCS_DELTA_CHECK=0"
else
    fail "commit in linked worktree failed (rc=$COMMIT_RC); see /tmp/infra-1521-commit-output.$$"
    cat /tmp/infra-1521-commit-output.$$ >&2
fi

if grep -qE 'PASS[[:space:]]+docs-delta' /tmp/infra-1521-commit-output.$$; then
    pass "docs-delta rule reported PASS (message file was actually read)"
else
    fail "docs-delta rule did not report PASS — message file may not have been read"
fi

rm -f "/tmp/infra-1521-commit-output.$$"

# ── Caller's own checkout unaffected ─────────────────────────────────────────
# Don't perform a real commit against the caller's actual checkout (risky:
# could collide with an active claim lease or in-progress work — this test
# may itself be running from a linked worktree). Instead assert the
# structural precondition the fix depends on: `git rev-parse --git-dir`
# resolves to a real directory here too (main checkout -> ".git", linked
# worktree -> ".git/worktrees/<name>") — the commit-msg hook's `$1`-based
# message resolution never depended on which shape this is, so behavior is
# unaffected either way.
CALLER_GIT_DIR="$(git rev-parse --git-dir)"
if [ -d "$CALLER_GIT_DIR" ]; then
    pass "caller's git-dir ($CALLER_GIT_DIR) resolves to a real directory"
else
    fail "caller's git-dir ($CALLER_GIT_DIR) is not a directory"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
