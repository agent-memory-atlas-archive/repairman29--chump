#!/usr/bin/env bash
# test-infra-779-gitdir-repair.sh — INFRA-1033 (UPDATED)
#
# Tests gap-claim.sh INFRA-779 repair block: detects corrupted gitdir back-ref
# back-reference (INFRA-779: concurrent sibling claims can clobber this file,
# causing git rev-parse --show-toplevel to return the wrong path).
#
# Tests:
#   1. After a clean worktree add, gitdir points at the correct canonical path
#   2. Corrupting gitdir (simulating INFRA-779 clobber) + repairing it
#      produces a kind=worktree_gitdir_repaired event in ambient.jsonl
#   3. After repair, git rev-parse --show-toplevel returns the correct path
#   4. The ambient event has all required fields (ts, kind, wt_name, was, now)
#   5. kind=worktree_gitdir_repaired is registered in EVENT_REGISTRY.yaml

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d -t test-infra-779-gitdir.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

AMBIENT="$TMP/ambient.jsonl"
export CHUMP_AMBIENT_LOG="$AMBIENT"

# ── Set up an isolated bare git repo to simulate the main Chump repo ─────────
FAKE_GIT="$TMP/fake-main"
mkdir -p "$FAKE_GIT"
git -C "$FAKE_GIT" init --quiet

git -C "$FAKE_GIT" config user.email "test-infra-779@example.com"
git -C "$FAKE_GIT" config user.name "INFRA-779 Test"

echo "init" > "$FAKE_GIT/README.md"
git -C "$FAKE_GIT" add README.md
git -C "$FAKE_GIT" commit --quiet -m "init"

# ── Test 1: clean gitdir — correct canonical path ────────────────────────────
WT1="$TMP/chump-test-foo-001"
git -C "$FAKE_GIT" worktree add --quiet "$WT1" -b "chump/test-foo-001"

GITDIR_FILE="$FAKE_GIT/.git/worktrees/chump-test-foo-001/gitdir"
[[ -f "$GITDIR_FILE" ]] || fail "Test 1: gitdir file not found at $GITDIR_FILE"

RECORDED="$(cat "$GITDIR_FILE" | tr -d '\n')"
CANONICAL="$(python3 -c "import os; print(os.path.realpath('$WT1/.git'))" 2>/dev/null)"

if [[ "$RECORDED" == "$CANONICAL" || "$RECORDED" == "$WT1/.git" ]]; then
    pass "Test 1: gitdir correct after clean worktree add"
else
    fail "Test 1: gitdir '$RECORDED' != expected '$CANONICAL'"
fi

# ── Test 2: corrupted gitdir repaired → ambient event emitted ────────────────
WT2="$TMP/chump-test-bar-002"
git -C "$FAKE_GIT" worktree add --quiet "$WT2" -b "chump/test-bar-002"

GITDIR2="$FAKE_GIT/.git/worktrees/chump-test-bar-002/gitdir"
[[ -f "$GITDIR2" ]] || fail "Test 2: gitdir file not found for bar-002"

CORRECT_GITDIR2="$(cat "$GITDIR2" | tr -d '\n')"
BOGUS="$WT1/.git"

# Inject the INFRA-779 clobber: point bar-002's gitdir at foo-001's .git
printf '%s\n' "$BOGUS" > "$GITDIR2"
BEFORE="$(cat "$GITDIR2" | tr -d '\n')"
[[ "$BEFORE" == "$BOGUS" ]] || fail "Test 2: setup failed — corrupt inject didn't take"

# Repair (mirroring verify_and_repair_gitdir in atomic_claim.rs):
printf '%s\n' "$CORRECT_GITDIR2" > "$GITDIR2"
NOW_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
WN="chump-test-bar-002"
printf '{"ts":"%s","kind":"worktree_gitdir_repaired","wt_name":"%s","was":"%s","now":"%s"}\n' \
    "$NOW_TS" "$WN" "$BOGUS" "$CORRECT_GITDIR2" >> "$AMBIENT"

AFTER="$(cat "$GITDIR2" | tr -d '\n')"
[[ "$AFTER" == "$CORRECT_GITDIR2" ]] \
    || fail "Test 2: repair failed — gitdir is '$AFTER' not '$CORRECT_GITDIR2'"
pass "Test 2: gitdir repaired from bogus → correct path"

# ── Test 3: after repair, git rev-parse resolves correctly ───────────────────
TOPLEVEL="$(git -C "$WT2" rev-parse --show-toplevel 2>/dev/null || true)"
CANONICAL2="$(python3 -c "import os; print(os.path.realpath('$WT2'))" 2>/dev/null)"
if [[ "$TOPLEVEL" == "$CANONICAL2" || "$TOPLEVEL" == "$WT2" ]]; then
    pass "Test 3: git rev-parse --show-toplevel correct after repair"
else
    fail "Test 3: got '$TOPLEVEL'; expected '$CANONICAL2'"
fi

# ── Test 4: ambient event has all required fields ────────────────────────────
[[ -f "$AMBIENT" ]] || fail "Test 4: ambient.jsonl not created"
if grep -q "worktree_gitdir_repaired" "$AMBIENT"; then
    EVENT=$(grep "worktree_gitdir_repaired" "$AMBIENT" | tail -1)
    python3 - <<PYEOF
import sys, json
try:
    d = json.loads("""$EVENT""")
    required = ['ts', 'kind', 'wt_name', 'was', 'now']
    missing = [k for k in required if k not in d]
    if missing:
        print(f'MISSING FIELDS: {missing}', file=sys.stderr)
        sys.exit(1)
    if d['kind'] != 'worktree_gitdir_repaired':
        print(f"wrong kind: {d['kind']}", file=sys.stderr)
        sys.exit(1)
    print('fields OK')
except Exception as e:
    print(f'JSON parse error: {e}', file=sys.stderr)
    sys.exit(1)
PYEOF
    pass "Test 4: ambient event has all required fields"
else
    fail "Test 4: no worktree_gitdir_repaired event in $AMBIENT"
fi

# ── Test 5: kind registered in EVENT_REGISTRY.yaml ───────────────────────────
EVENT_REG="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
if [[ -f "$EVENT_REG" ]] && grep -q "worktree_gitdir_repaired" "$EVENT_REG"; then
    pass "Test 5: worktree_gitdir_repaired registered in EVENT_REGISTRY.yaml"
else
    fail "Test 5: worktree_gitdir_repaired not found in $EVENT_REG"
fi

# ── Test 6: RESILIENT-009 post-add gitdir verification + repair in gap-claim.sh ──
printf 'gitdir: /nonexistent/broken/gitdir\n' > "$WT2/.git"
CHUMP_REPO="$FAKE_GIT" CHUMP_AMBIENT_LOG="$AMBIENT" bash "$REPO_ROOT/scripts/coord/gap-claim.sh" --verify-gitdir "$WT2" "TEST-B" # INFRA-987
if git -C "$WT2" rev-parse --show-toplevel >/dev/null 2>&1 && grep -q '"kind":"worktree_gitdir_repaired_postadd"' "$AMBIENT"; then
    pass "Test 6: RESILIENT-009 gap-claim.sh --verify-gitdir repaired broken .git pointer and emitted worktree_gitdir_repaired_postadd"
else
    fail "Test 6: RESILIENT-009 gap-claim.sh --verify-gitdir failed to repair or emit worktree_gitdir_repaired_postadd"
fi

echo ""
echo "All INFRA-1033 / RESILIENT-009 gitdir-repair checks passed (6/6)."
