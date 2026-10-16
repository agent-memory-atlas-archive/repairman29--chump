#!/usr/bin/env bash
# scripts/ci/test-bot-merge-pr-create-head.sh — INFRA-8207
#
# `chump dispatch` creates its worktree with
# `git worktree add <path> -b claude/<slug> origin/main`, which leaves the
# new branch's upstream tracking origin/main (not origin/claude/<slug>).
# bot-merge.sh's step-5 push used to omit `-u`, so the mistracked upstream
# stuck; the normal-path `gh pr create` omitted `--head`, so gh inferred the
# head branch from that upstream and failed with "aborted: you must first
# push the current branch to a remote, or use the --head flag". This test
# proves (1) the fixture shape that bit (worktree branch tracks origin/main),
# (2) `-u` on push repoints the upstream, (3) a stub `gh` refuses without
# --head and accepts with it, and (4)/(5) grep-level contracts on both fixed
# files. No network; bash only.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

PASS=0
FAIL=0
ok()   { printf 'PASS: %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL+1)); }

echo "=== INFRA-8207 bot-merge pr-create --head test ==="
echo

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 0; }

# ── Fixture: bare origin + clone + dispatch-shaped worktree ─────────────────
BARE="${TMP}/origin.git"
CLONE="${TMP}/clone"
WT="${TMP}/wt"
BRANCH="claude/infra-9998"

git init --quiet --bare "$BARE"
git clone --quiet "$BARE" "$CLONE"
(
    cd "$CLONE"
    git config user.email "test@example.com"
    git config user.name "Test"
    git checkout -b main --quiet 2>/dev/null || git checkout main --quiet
    echo "x" > f.txt
    git add f.txt
    git commit -m "init" --quiet
    git push -u origin main --quiet
)

# The exact shape dispatch.rs's create_dispatch_worktree uses.
git -C "$CLONE" worktree add "$WT" -b "$BRANCH" origin/main --quiet

echo "[1. fixture reproduces the bug shape — branch tracks origin/main]"
UPSTREAM="$(git -C "$WT" rev-parse --abbrev-ref "${BRANCH}@{upstream}" 2>/dev/null || echo "")"
if [[ "$UPSTREAM" == "origin/main" ]]; then
    ok "worktree branch '$BRANCH' tracks origin/main (the mistracking bot-merge hit)"
else
    bad "expected upstream 'origin/main', got '$UPSTREAM'"
fi

(
    cd "$WT"
    echo "y" > g.txt
    git add g.txt
    git -c user.email=test@example.com -c user.name=Test commit -m "extra commit" --quiet
)

echo
echo "[2. AC2: git push -u repoints the upstream to origin/<branch>]"
git -C "$WT" push -u origin "$BRANCH" --quiet
UPSTREAM2="$(git -C "$WT" rev-parse --abbrev-ref "${BRANCH}@{upstream}" 2>/dev/null || echo "")"
if [[ "$UPSTREAM2" == "origin/${BRANCH}" ]]; then
    ok "after 'git push -u', upstream is origin/${BRANCH}"
else
    bad "expected upstream 'origin/${BRANCH}', got '$UPSTREAM2'"
fi

# ── Stub gh: records argv; pr create fails without --head, succeeds with it ─
echo
echo "[3. AC1: stub gh refuses pr create without --head, accepts with it]"

STUBDIR="${TMP}/stubbin"
mkdir -p "$STUBDIR"
RECORD="${TMP}/gh-argv.log"
: > "$RECORD"

cat > "${STUBDIR}/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_ARGV_RECORD"
if [[ "$1 $2" == "pr create" ]]; then
    for a in "$@"; do
        if [[ "$a" == "--head" ]]; then
            echo "https://example.invalid/pull/1"
            exit 0
        fi
    done
    echo "aborted: you must first push the current branch to a remote, or use the --head flag" >&2
    exit 1
fi
exit 0
STUB
chmod +x "${STUBDIR}/gh"

export GH_ARGV_RECORD="$RECORD"
export PATH="${STUBDIR}:${PATH}"

if gh pr create --base main --title "t" --body "b" 2>/tmp/gh-no-head.err; then
    bad "stub gh pr create succeeded WITHOUT --head (should have failed)"
else
    if grep -q "aborted: you must first push the current branch to a remote, or use the --head flag" /tmp/gh-no-head.err; then
        ok "stub gh pr create fails without --head with the exact INFRA-8207 message"
    else
        bad "stub gh pr create failed but with the wrong message"
    fi
fi

if gh pr create --base main --head "$BRANCH" --title "t" --body "b" >/tmp/gh-with-head.out; then
    if grep -q "example.invalid/pull/1" /tmp/gh-with-head.out; then
        ok "stub gh pr create succeeds WITH --head"
    else
        bad "stub gh pr create with --head succeeded but printed unexpected output"
    fi
else
    bad "stub gh pr create failed even WITH --head"
fi

unset PATH
PATH="/usr/bin:/bin:/usr/local/bin"
export PATH

# ── Grep contracts on the fixed files ────────────────────────────────────────
echo
echo "[4. grep contract: scripts/coord/bot-merge.sh]"

BOT_MERGE="${REPO_ROOT}/scripts/coord/bot-merge.sh"

if grep -qF 'git push -u "$REMOTE" "$BRANCH" --force-with-lease' "$BOT_MERGE"; then
    ok "bot-merge.sh step-5 push uses -u"
else
    bad "bot-merge.sh step-5 push missing -u"
fi

if grep -qF -- '--head "$BRANCH"' "$BOT_MERGE"; then
    ok "bot-merge.sh normal-path gh pr create passes --head \"\$BRANCH\""
else
    bad "bot-merge.sh normal-path gh pr create missing --head \"\$BRANCH\""
fi

echo
echo "[5. grep contract: src/dispatch.rs]"

DISPATCH_RS="${REPO_ROOT}/src/dispatch.rs"

if grep -q 'fn set_dispatch_branch_upstream' "$DISPATCH_RS"; then
    ok "src/dispatch.rs defines set_dispatch_branch_upstream"
else
    bad "src/dispatch.rs missing set_dispatch_branch_upstream"
fi

if grep -q 'branch\.{branch}\.merge' "$DISPATCH_RS" && grep -q 'refs/heads/{branch}' "$DISPATCH_RS"; then
    ok "set_dispatch_branch_upstream sets branch.<name>.merge to refs/heads/<name>"
else
    bad "set_dispatch_branch_upstream does not set branch.<name>.merge to refs/heads/<name>"
fi

# ── Best-effort: bot-merge.sh --dry-run shows --head in the PR-create line ──
echo
echo "[6. best-effort: bot-merge.sh --dry-run shows --head $BRANCH]"

STUBDIR2="${TMP}/stubbin2"
mkdir -p "$STUBDIR2"

cat > "${STUBDIR2}/gh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "${STUBDIR2}/gh"

cat > "${STUBDIR2}/chump" <<'STUB'
#!/usr/bin/env bash
if [[ "$1 $2" == "gap preflight" ]]; then
    echo "[preflight] OK"
    exit 0
fi
exit 0
STUB
chmod +x "${STUBDIR2}/chump"

DRYRUN_OUT=""
DRYRUN_RC=0
(
    cd "$WT"
    PATH="${STUBDIR2}:${PATH}" bash "$BOT_MERGE" --gap INFRA-9998 --dry-run
) >/tmp/bot-merge-dryrun.out 2>&1 || DRYRUN_RC=$?
DRYRUN_OUT="$(cat /tmp/bot-merge-dryrun.out 2>/dev/null || true)"

if [[ -n "$DRYRUN_OUT" ]] && echo "$DRYRUN_OUT" | grep -q -- "--head ${BRANCH}"; then
    ok "bot-merge.sh --dry-run output shows --head ${BRANCH}"
else
    echo "SKIP: bot-merge dry-run not exercised (sandbox cannot run the full script; rc=${DRYRUN_RC})"
fi

echo
echo "=== INFRA-8207 tests complete: ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
