#!/usr/bin/env bash
# META-011: regression test for concurrent chump-commit.sh calls on a shared
# git index. Without the index mutex (META-011 fix), two concurrent agents
# interleave their git-reset / git-add calls: agent B's git-reset-HEAD unstages
# agent A's just-staged file, silently producing an empty commit for A.
#
# This test spawns 4 concurrent agents, each committing a unique file, and
# asserts:
#   (a) all 4 agents exit 0 — no commit was rejected or silently dropped
#   (b) git log shows 4 agent commits — no lost edits
#
# Hermetic: uses a tmp git sandbox; no live repo state is touched.
#
# Run from repo root: bash scripts/ci/test-meta-011-git-stomp.sh

set -e

# INFRA-1600: brew util-linux flock not on default PATH on self-hosted CI runners.
# shellcheck source=../lib/discover-flock.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/discover-flock.sh"
REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

PASS=0
FAIL=0
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

# ── Sandbox setup ─────────────────────────────────────────────────────────────
git init -q -b main "$SANDBOX"
git -C "$SANDBOX" config user.email "t@t"
git -C "$SANDBOX" config user.name "t"
git -C "$SANDBOX" config commit.gpgsign false
git -C "$SANDBOX" commit -q --allow-empty -m "init"

# Use a no-op pre-commit hook so the guard suite doesn't run on the sandbox.
mkdir -p "$SANDBOX/scripts/git-hooks"
printf '#!/bin/bash\nexit 0\n' > "$SANDBOX/scripts/git-hooks/pre-commit"
chmod +x "$SANDBOX/scripts/git-hooks/pre-commit"
git -C "$SANDBOX" config core.hooksPath scripts/git-hooks

# Create 4 files with initial content and commit them.
for i in 1 2 3 4; do
    echo "base-$i" > "$SANDBOX/file-$i.txt"
done
git -C "$SANDBOX" add .
git -C "$SANDBOX" commit -q -m "seed"

# Make one pending change to each file (unstaged) so each agent has something
# to commit.
for i in 1 2 3 4; do
    echo "change-$i" >> "$SANDBOX/file-$i.txt"
done

RESULTS_DIR="$SANDBOX/results"
mkdir -p "$RESULTS_DIR"

# ── case 1: 4 concurrent agents each committing their own file ────────────────
# Each agent: (1) acquires the mutex (via chump-commit.sh), (2) stages its own
# file, and (3) commits. With the index mutex they serialize. Without it, agent
# B's `git reset HEAD -- file-A.txt` (the "unstage extra files" guard inside
# chump-commit.sh) would silently drop agent A's staged file.
#
# DETERMINISM (RESILIENT-303): CHUMP_AUTO_LEASE_FROM_MSG=0 is REQUIRED here.
# chump-commit.sh's INFRA-085 auto-lease block greps the commit message for
# gap-IDs and runs `chump claim <ID>` for each — and it runs INSIDE the index
# mutex's critical section (after flock acquire, before `git commit`). Our
# commit message "feat(META-011-test): ..." contains the literal "META-011",
# which matches the gap-ID regex, so every agent spawned a real `chump claim`
# subprocess (spawns children, touches git, can hit the network) while holding
# the 30s-bounded flock. Under CI load those serialized claims pushed the last
# agent past `flock -w 30` → it exited non-zero → intermittent
# "Passed: 4  Failed: 1". This is a hermetic mutex test; real gap-claiming is
# orthogonal noise (same reason we already disable AMBIENT_GLANCE / LEASE_CHECK
# / WRONG_WORKTREE / PATH_CASE below). Disabling it makes the critical section
# pure git ops, so the test is deterministic.

for i in 1 2 3 4; do
    (
        GIT_AUTHOR_NAME="agent-$i" \
        GIT_AUTHOR_EMAIL="a${i}@test" \
        GIT_COMMITTER_NAME="agent-$i" \
        GIT_COMMITTER_EMAIL="a${i}@test" \
        GIT_CONFIG_NOSYSTEM=1 \
        GIT_CONFIG_GLOBAL=/dev/null \
        GIT_DIR="$SANDBOX/.git" \
        GIT_WORK_TREE="$SANDBOX" \
        CHUMP_ALLOW_MAIN_WORKTREE=1 \
        CHUMP_PATH_CASE_CHECK=0 \
        CHUMP_AMBIENT_GLANCE=0 \
        CHUMP_WRONG_WORKTREE_CHECK=0 \
        CHUMP_LEASE_CHECK=0 \
        CHUMP_AUTO_LEASE_FROM_MSG=0 \
        "$REPO_ROOT/scripts/coord/chump-commit.sh" \
            "$SANDBOX/file-$i.txt" \
            -m "feat(META-011-test): agent-$i commit" \
            > "$RESULTS_DIR/$i.out" 2>&1
        echo "$?" > "$RESULTS_DIR/$i.exit"
    ) &
done

wait

# Check all 4 exited 0.
all_ok=1
for i in 1 2 3 4; do
    ec=$(cat "$RESULTS_DIR/$i.exit" 2>/dev/null || echo 99)
    if [[ "$ec" != "0" ]]; then
        fail "agent-$i exited $ec (output: $(head -3 "$RESULTS_DIR/$i.out" 2>/dev/null))"
        all_ok=0
    fi
done
if [[ "$all_ok" == "1" ]]; then
    pass "all 4 concurrent agents exited 0"
fi

# Check git log has ≥ 4 agent commits (seed + init + 4 agent = 6 total).
commit_count=$(git -C "$SANDBOX" rev-list --count HEAD)
if [[ "$commit_count" -ge 6 ]]; then
    pass "git log shows $commit_count commits — all 4 agent commits landed"
else
    fail "git log shows $commit_count commits — expected ≥6 (init+seed+4 agents); lost edits"
    git -C "$SANDBOX" log --oneline >&2
fi

# Check each file reflects its own change in HEAD tree.
missing=0
for i in 1 2 3 4; do
    if ! git -C "$SANDBOX" show HEAD:"file-$i.txt" 2>/dev/null | grep -q "change-$i"; then
        fail "change-$i missing from HEAD:file-$i.txt — edit was lost"
        missing=$((missing + 1))
    fi
done
if [[ "$missing" -eq 0 ]]; then
    pass "all 4 agent file changes are present in final HEAD"
fi

# ── case 2: mutex file is created ────────────────────────────────────────────
if [[ -f "$SANDBOX/.git/.chump-index-mutex" ]]; then
    pass ".git/.chump-index-mutex created by chump-commit.sh"
else
    # "$FLOCK_BIN" may be absent (BSD/macOS); only fail if "$FLOCK_BIN" is available.

    if command -v "$FLOCK_BIN" >/dev/null 2>&1; then
        fail ".git/.chump-index-mutex not created despite "$FLOCK_BIN" being available"
    else
        pass ""$FLOCK_BIN" not available — mutex creation skipped (expected on BSD/macOS)"
    fi
fi

# ── case 3: CHUMP_INDEX_LOCK=0 bypasses mutex (no exit-1 or warning spam) ────
# Just verify the bypass path doesn't break the commit.
echo "bypass-test" >> "$SANDBOX/file-1.txt"
BYPASS_EXIT=0
GIT_AUTHOR_NAME="bypass" \
GIT_AUTHOR_EMAIL="bypass@test" \
GIT_COMMITTER_NAME="bypass" \
GIT_COMMITTER_EMAIL="bypass@test" \
GIT_CONFIG_NOSYSTEM=1 \
GIT_CONFIG_GLOBAL=/dev/null \
GIT_DIR="$SANDBOX/.git" \
GIT_WORK_TREE="$SANDBOX" \
CHUMP_ALLOW_MAIN_WORKTREE=1 \
CHUMP_PATH_CASE_CHECK=0 \
CHUMP_AMBIENT_GLANCE=0 \
CHUMP_WRONG_WORKTREE_CHECK=0 \
CHUMP_LEASE_CHECK=0 \
CHUMP_AUTO_LEASE_FROM_MSG=0 \
CHUMP_INDEX_LOCK=0 \
"$REPO_ROOT/scripts/coord/chump-commit.sh" \
    "$SANDBOX/file-1.txt" \
    -m "bypass: CHUMP_INDEX_LOCK=0" \
    >/dev/null 2>&1 || BYPASS_EXIT=$?
if [[ "$BYPASS_EXIT" -eq 0 ]]; then
    pass "CHUMP_INDEX_LOCK=0 bypass allows commit without mutex"
else
    fail "CHUMP_INDEX_LOCK=0 bypass exited $BYPASS_EXIT unexpectedly"
fi

echo ""
if bash "$REPO_ROOT/scripts/ci/test-chump-commit-auto-envvar.sh"; then
    pass "test-chump-commit-auto-envvar.sh (INFRA-1853 / INFRA-8579) passed"
else
    fail "test-chump-commit-auto-envvar.sh failed"
fi

echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
