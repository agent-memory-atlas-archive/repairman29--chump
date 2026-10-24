#!/usr/bin/env bash
# test-credible-154-ship-evidence.sh — CREDIBLE-154
#
# "shipped" must be an OBSERVATION, not a claim:
#  1. worker.sh no longer classifies rc==0 as shipped unconditionally —
#     the evidence block (cache/canonical-db/gh) must guard it
#  2. bot-merge Mode A enqueue verifies the canonical-db write and fails
#     open to Mode B on miss (no bare `|| true` swallow)
#  3. canonical-repo derivation returns the MAIN worktree from inside a
#     linked worktree (the exact resolution bug that made phantoms)
set -euo pipefail
# CREDIBLE-1527: ensure temp-repo git commits succeed on runners without global git identity.
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-chump-ci-test}" GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-ci-test@chump.local}" GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-chump-ci-test}" GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-ci-test@chump.local}"


PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"
BOTMERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"

echo "=== CREDIBLE-154 ship-evidence test ==="

# ── 1. worker classification guarded by evidence ─────────────────────────────
if grep -q 'unverified_ship' "$WORKER"; then
    ok "worker.sh has unverified_ship classification"
else
    fail "worker.sh missing unverified_ship classification"
fi

if grep -q '_ship_evidence' "$WORKER" && \
   grep -q 'SELECT number FROM pr_state WHERE head_ref' "$WORKER"; then
    ok "worker.sh checks webhook-cache PR evidence before classifying shipped"
else
    fail "worker.sh must check pr_state cache for ship evidence"
fi

# the old unconditional pattern must be gone: rc==0 directly assigning shipped
if awk '/_cycle_kind="failed"/,/elif/' "$WORKER" | grep -q '_cycle_kind="shipped"$' && \
   ! grep -q '_ship_evidence' "$WORKER"; then
    fail "rc==0 still unconditionally classified as shipped"
else
    ok "rc==0 no longer unconditionally shipped"
fi

# ── 2. bot-merge Mode A verifies canonical write ─────────────────────────────
if grep -q 'bot_merge_enqueue_failed' "$BOTMERGE"; then
    ok "bot-merge emits bot_merge_enqueue_failed on unverified enqueue"
else
    fail "bot-merge missing enqueue-failure fail-open"
fi

if grep -qE 'chump gap set "\$_bm_route_gap" --status ready_to_ship 2>/dev/null \|\| true' "$BOTMERGE"; then
    fail "bot-merge still has the bare '|| true' ready_to_ship swallow"
else
    ok "bare '|| true' ready_to_ship swallow removed"
fi

if grep -q '_bm_canon_repo' "$BOTMERGE" && grep -q 'worktree list --porcelain' "$BOTMERGE"; then
    ok "bot-merge pins the canonical repo for the enqueue write"
else
    fail "bot-merge must derive the canonical (main) worktree for gap set"
fi

# ── 3. canonical-repo derivation from a linked worktree ──────────────────────
FIX="$(mktemp -d)"
(
    cd "$FIX"
    git init -q main-repo
    cd main-repo
    git commit -q --allow-empty -m init
    git worktree add -q ../linked -b linked-branch
) >/dev/null 2>&1
derived="$(cd "$FIX/linked" && git worktree list --porcelain | awk '/^worktree /{print $2; exit}')"
# macOS /tmp symlink: compare resolved paths
if [[ "$(cd "$derived" && pwd -P)" == "$(cd "$FIX/main-repo" && pwd -P)" ]]; then
    ok "worktree-list derivation returns MAIN repo from inside linked worktree"
else
    fail "derivation returned '$derived', expected $FIX/main-repo"
fi
rm -rf "$FIX"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
