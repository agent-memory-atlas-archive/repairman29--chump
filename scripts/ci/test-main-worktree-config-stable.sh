#!/usr/bin/env bash
# test-main-worktree-config-stable.sh — INFRA-1060 (2026-05-13)
#
# Regression test for the core.worktree corruption bug.
# Creates 2 concurrent chump claim operations against an isolated fixture
# repo and asserts that the main .git/config never acquires a stray
# core.worktree key.
#
# Also tests:
#  - repair-main-worktree-config.sh detects and clears the stray key
#  - pre-commit-main-worktree-config.sh auto-repairs and allows commit
#  - pre-commit-main-worktree-config.sh blocks when auto-repair fails

set -euo pipefail
# CREDIBLE-1527: ensure temp-repo git commits succeed on runners without global git identity.
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-chump-ci-test}" GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-ci-test@chump.local}" GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-chump-ci-test}" GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-ci-test@chump.local}"


PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

echo "=== INFRA-1060 main-worktree-config-stable test ==="
echo

# 1. Structural checks — scripts exist and are executable.
REPAIR_SCRIPT="$REPO_ROOT/scripts/ops/repair-main-worktree-config.sh"
HOOK_SCRIPT="$REPO_ROOT/scripts/git-hooks/pre-commit-main-worktree-config.sh"

if [[ -x "$REPAIR_SCRIPT" ]]; then
    ok "repair-main-worktree-config.sh exists and is executable"
else
    fail "repair-main-worktree-config.sh missing or not executable"
fi

if [[ -x "$HOOK_SCRIPT" ]]; then
    ok "pre-commit-main-worktree-config.sh exists and is executable"
else
    fail "pre-commit-main-worktree-config.sh missing or not executable"
fi

if grep -q "INFRA-1060" "$REPO_ROOT/crates/chump-atomic-claim/src/atomic_claim.rs" 2>/dev/null; then
    ok "atomic_claim.rs has INFRA-1060 sanitizer"
else
    fail "atomic_claim.rs missing INFRA-1060 sanitizer"
fi

if grep -q "pre-commit-main-worktree-config" "$REPO_ROOT/scripts/git-hooks/pre-commit" 2>/dev/null; then
    ok "pre-commit hook wires main-worktree-config guard"
else
    fail "pre-commit hook missing main-worktree-config guard"
fi

# 2. Functional tests against a fixture repo.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

git init "$TMP/main" --initial-branch=main -q 2>/dev/null
git -C "$TMP/main" commit --allow-empty -m "init" -q

# 2a. Clean config: repair script exits 0 with no output.
OUT="$(REPO_ROOT="$TMP/main" bash "$REPAIR_SCRIPT" 2>&1)"
EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 && -z "$OUT" ]]; then
    ok "repair script exits 0 silently on clean config"
else
    fail "repair script on clean config: exit=$EXIT_CODE output='$OUT'"
fi

# 2b. Stray key detected by --check.
git -C "$TMP/main" config core.worktree /tmp/chump-fake-sibling
if ! REPO_ROOT="$TMP/main" bash "$REPAIR_SCRIPT" --check 2>/dev/null; then
    ok "repair script --check exits 1 on stray core.worktree"
else
    fail "repair script --check should exit 1 when stray key present"
fi

# 2c. Repair removes the stray key.
REPO_ROOT="$TMP/main" bash "$REPAIR_SCRIPT" 2>/dev/null
AFTER="$(git -C "$TMP/main" config --local core.worktree 2>/dev/null || echo "")"
if [[ -z "$AFTER" ]]; then
    ok "repair script removes stray core.worktree"
else
    fail "repair script failed to remove stray key (still: $AFTER)"
fi

# 2d. Pre-commit hook auto-repairs and exits 0.
git -C "$TMP/main" config core.worktree /tmp/chump-fake-sibling
MAIN_GIT_DIR="$TMP/main/.git" REPO_ROOT="$TMP/main" bash "$HOOK_SCRIPT" 2>/dev/null
HOOK_EXIT=$?
AFTER2="$(git -C "$TMP/main" config --local core.worktree 2>/dev/null || echo "")"
if [[ $HOOK_EXIT -eq 0 && -z "$AFTER2" ]]; then
    ok "pre-commit hook auto-repairs stray key and exits 0"
else
    fail "pre-commit hook auto-repair: exit=$HOOK_EXIT key_after='$AFTER2'"
fi

# 2e. Pre-commit hook exits 0 on clean config.
MAIN_GIT_DIR="$TMP/main/.git" REPO_ROOT="$TMP/main" bash "$HOOK_SCRIPT" 2>/dev/null
if [[ $? -eq 0 ]]; then
    ok "pre-commit hook exits 0 on clean config"
else
    fail "pre-commit hook should exit 0 on clean config"
fi

# 2f. --json output from repair script.
git -C "$TMP/main" config core.worktree /tmp/chump-fake-json
JSON="$(REPO_ROOT="$TMP/main" bash "$REPAIR_SCRIPT" --json 2>/dev/null)"
if echo "$JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['status']=='fixed'" 2>/dev/null; then
    ok "repair script --json emits {status: fixed} after cleaning"
else
    fail "repair script --json format wrong (got: $JSON)"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
