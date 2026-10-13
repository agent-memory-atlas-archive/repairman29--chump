#!/usr/bin/env bash
# RESILIENT-1217: converge_mirror_hard_reset origin/main must leave the mirror on branch main.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL $*"; exit 1; }
git init -q --bare -b main "$TMP/o.git"
git clone -q "$TMP/o.git" "$TMP/c" 2>/dev/null
cd "$TMP/c" || exit 1
git config user.email t@e.com; git config user.name T
git checkout -q -B main; echo a > f; git add f; git commit -qm a; git push -q origin main
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/coord/lib/converge-mirror.sh"

git checkout -q -b stray; echo b > g; git add g; git commit -qm b
git fetch -q origin main
converge_mirror_hard_reset origin/main 2>/dev/null || fail "converge from stray branch failed"
[ "$(git symbolic-ref --short HEAD)" = main ] || fail "not on main after converge from branch"
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "main not at origin/main"
git show-ref --verify -q refs/heads/stray || fail "stray branch should be untouched"

git checkout -q --detach
converge_mirror_hard_reset origin/main 2>/dev/null || fail "converge from detached failed"
[ "$(git symbolic-ref --short HEAD)" = main ] || fail "not on main after converge from detached"

converge_mirror_hard_reset origin/main 2>/dev/null || fail "idempotent converge failed"
[ "$(git symbolic-ref --short HEAD)" = main ] || fail "left main on no-op converge"
echo "PASS test-resilient-1217-converge-stays-on-main"
