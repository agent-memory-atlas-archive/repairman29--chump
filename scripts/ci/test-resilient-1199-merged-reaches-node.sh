#!/usr/bin/env bash
# RESILIENT-1199: Merged fix reaches the node even when untracked files collide.
#
# Scenario: a tracked file in origin/main conflicts with an untracked file in
# the working tree. The old code would skip the reset --hard after a successful
# checkout, so the merged content would NOT overwrite the untracked collision.
# This broke the guarantee: merged changes are deployed during auto-converge.
#
# This test proves that converge_mirror_hard_reset now always runs reset --hard
# to cleanup untracked collisions, guaranteeing merged content reaches the tree.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL $*"; exit 1; }
ok() { echo "PASS $*"; }

git init -q --bare -b main "$TMP/o.git"
git clone -q "$TMP/o.git" "$TMP/c" 2>/dev/null
cd "$TMP/c" || exit 1
git config user.email t@e.com; git config user.name T

# ── Setup: base commit on main with a tracked file ──────────────────────────
git checkout -q -B main
echo "base content" > shared.txt
git add shared.txt
git commit -qm "base: shared.txt"
git push -q origin main
BASE_SHA="$(git rev-parse HEAD)"

# ── Advance origin/main: merged fix updates the tracked file ────────────────
echo "merged fix content" > shared.txt
git commit -qam "merged fix: update shared.txt"
git push -q origin main
MERGED_SHA="$(git rev-parse HEAD)"

# ── Rollback checkout: now BEHIND origin/main ──────────────────────────────
git reset --hard -q "$BASE_SHA"

# Checkout is now on main but BEHIND, with "base content" in shared.txt.
# The merged commit is in origin/main but not yet in the working tree.
[ "$(cat shared.txt)" = "base content" ] || fail "setup failed: shared.txt should be base content"

# ── Create the collision: an untracked file with the same name ──────────────
# Switch to a stray branch and create an untracked collision, then go back to main.
git checkout -q -b stray
echo "untracked collision" > shared.txt
git checkout -q main
# At this point: working tree still has "untracked collision", main ref is at BASE_SHA.
# Without the fix, git checkout wouldn't overwrite untracked files.
# But converge_mirror_hard_reset should switch the ref AND run reset --hard to clean them up.

# Fetch to make origin/main available for converge.
git fetch -q origin main

# ── Source the converge function and test ──────────────────────────────────
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/coord/lib/converge-mirror.sh"

# Verify the collision exists before converge.
[ "$(cat shared.txt)" = "untracked collision" ] || fail "collision not set up correctly"

# Run converge_mirror_hard_reset to origin/main.
# This should:
#   1. Detect we're on main but BEHIND origin/main
#   2. Stay on main (no branch switch needed)
#   3. Run reset --hard to bring in the merged fix AND clean the collision
converge_mirror_hard_reset origin/main 2>/dev/null || fail "converge failed"

# ── Verify: merged content reached the working tree (collision was cleaned) ──
[ "$(cat shared.txt)" = "merged fix content" ] \
    || fail "merged content did NOT reach working tree (collision not cleaned). Got: $(cat shared.txt)"
ok "merged content reached working tree (untracked collision was overwritten)"

# ── Verify: HEAD is at the merged commit ──────────────────────────────────
[ "$(git rev-parse HEAD)" = "$MERGED_SHA" ] \
    || fail "HEAD not at merged commit. Got: $(git rev-parse HEAD), expected: $MERGED_SHA"
ok "HEAD converged to origin/main (the merged commit)"

# ── Verify: we're still on main branch ────────────────────────────────────
[ "$(git symbolic-ref --short HEAD)" = main ] \
    || fail "not on main after converge. Got: $(git symbolic-ref --short HEAD)"
ok "remained on main branch"

echo "ALL PASS test-resilient-1199-merged-reaches-node.sh"
