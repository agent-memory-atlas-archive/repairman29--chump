#!/usr/bin/env bash
# RESILIENT-1198: converge_mirror_hard_reset must always cleanup untracked collisions,
# even when checkout succeeds (ensuring merged fixes are deployed to the node).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL $*"; exit 1; }
ok() { echo "PASS $*"; }

# Create a bare origin + clone (mirrors the test-node-converge pattern)
git init -q --bare -b main "$TMP/o.git"
git clone -q "$TMP/o.git" "$TMP/c" 2>/dev/null
cd "$TMP/c" || exit 1
git config user.email t@e.com; git config user.name T

# Base commit: tracked file at src/foo.txt with content OLD
git checkout -q -B main
mkdir -p src
printf 'OLD\n' > src/foo.txt
git add src/foo.txt
git commit -qm "base: tracked file src/foo.txt"
git push -q origin main
BASE_SHA="$(git rev-parse HEAD)"

# Advance origin/main: merged fix changes src/foo.txt to NEW
printf 'NEW\n' > src/foo.txt
git commit -qam "merged fix: update src/foo.txt"
git push -q origin main
NEW_SHA="$(git rev-parse HEAD)"

# Roll back the local checkout to base (simulating a stale node)
git reset --hard -q "$BASE_SHA"

# The critical scenario: drop an UNTRACKED file that collides with the merged tracked path.
# This mirrors what happens when a node has a local generated file or temporary untracked
# file at a path that the merged commit touches.
printf 'UNTRACKED\n' > src/foo.txt
[ ! -f src/foo.txt ] && fail "failed to create untracked collision file"

# Verify the untracked file has the untracked content (not the base tracked content)
grep -q 'UNTRACKED' src/foo.txt || fail "untracked file not properly set up"

# Source the converge function
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/coord/lib/converge-mirror.sh"

# Fetch origin/main so the ref is available
git fetch -q origin main

# Run converge_mirror_hard_reset origin/main
# Before RESILIENT-1198 fix: if checkout succeeded, the early return would skip
# the git reset --hard, leaving the untracked file in place (merged fix NOT deployed).
# After RESILIENT-1198 fix: reset --hard always runs, overwriting the untracked file.
converge_mirror_hard_reset origin/main 2>/dev/null || fail "converge failed"

# Verify the node is at the merged fix (origin/main)
[ "$(git rev-parse HEAD)" = "$NEW_SHA" ] || fail "HEAD not at merged commit $NEW_SHA"
ok "HEAD at merged commit"

# CRITICAL: verify the untracked file was overwritten with the merged content.
# This is the core guarantee the fix enforces: merged != deployed before the fix,
# but after the fix merged changes are guaranteed to reach the working tree.
grep -q 'NEW' src/foo.txt || fail "untracked collision file not overwritten with merged content"
! grep -q 'UNTRACKED' src/foo.txt || fail "untracked collision file still has untracked content"
ok "untracked collision file overwritten with merged content (merged fix reached the node)"

echo "PASS test-resilient-1198-untracked-collision-cleanup"
