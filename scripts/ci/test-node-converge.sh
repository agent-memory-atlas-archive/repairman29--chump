#!/usr/bin/env bash
# scripts/ci/test-node-converge.sh — RESILIENT-1189
#
# Proves the node auto-converge organ (scripts/ops/node-converge.sh) does the
# one job it exists for, safely:
#   1. a checkout BEHIND origin/main converges to origin/main (merged reaches
#      the iron), emitting node_converged;
#   2. a gitignored runtime file (.chump/state.db) SURVIVES the converge — the
#      converge is a `git reset --hard`, never a `git clean -x`, so a live DB /
#      lease dir is never wiped (RESILIENT-001 preserve-gitignored contract);
#   3. an already-current tree is an idempotent no-op (node_converge_skipped),
#      not a needless reset;
#   4. a rebase-in-progress DEFERS (node_converge_skipped, no reset) — never
#      yanks the tree out from under an in-flight operation.
#
# Fails without node-converge.sh: there is no other organ that unconditionally
# converges the SOURCE checkout (node-refresh-chump.sh skips the source reset
# whenever the binary SHA already matches green-main — the exact bash-only-merge
# hole this organ closes).

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SCRIPT="$REPO_ROOT/scripts/ops/node-converge.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[ -f "$SCRIPT" ] || fail "missing $SCRIPT"
bash -n "$SCRIPT" || fail "syntax error in $SCRIPT"
ok "bash -n passes"

# ── Fixture: bare origin + a checkout clone, origin advanced ahead ──────────
ORIGIN="$TMP/origin.git"
CHECKOUT="$TMP/checkout"
git init --bare -q "$ORIGIN"
git clone -q "$ORIGIN" "$CHECKOUT"
git -C "$CHECKOUT" config user.email test@example.com
git -C "$CHECKOUT" config user.name "Test"

# Commit a .gitignore that ignores .chump/ (mirrors the real repo) + a tracked
# organ script, then push as the base main the checkout starts on.
printf '.chump/\n' > "$CHECKOUT/.gitignore"
mkdir -p "$CHECKOUT/scripts/ops"
printf 'echo OLD\n' > "$CHECKOUT/scripts/ops/organ.sh"
git -C "$CHECKOUT" add .gitignore scripts/ops/organ.sh
git -C "$CHECKOUT" commit -q -m "base"
git -C "$CHECKOUT" push -q origin HEAD:main
BASE_SHA="$(git -C "$CHECKOUT" rev-parse HEAD)"

# Advance origin/main with a merged BASH-organ fix (the #4637 class): the
# checkout is now BEHIND by one commit.
printf 'echo NEW\n' > "$CHECKOUT/scripts/ops/organ.sh"
git -C "$CHECKOUT" commit -q -am "merged bash-organ fix"
git -C "$CHECKOUT" push -q origin HEAD:main
NEW_SHA="$(git -C "$CHECKOUT" rev-parse HEAD)"

# Roll the checkout's working tree back to base so it is genuinely behind
# origin/main (as a stale node would be), and drop a gitignored runtime DB.
git -C "$CHECKOUT" reset --hard -q "$BASE_SHA"
mkdir -p "$CHECKOUT/.chump"
printf 'LIVE-DB-BYTES' > "$CHECKOUT/.chump/state.db"

AMBIENT="$TMP/.chump-locks/ambient.jsonl"
mkdir -p "$TMP/.chump-locks"

run_converge() {
    CHUMP_NODE_REPO="$CHECKOUT" \
    NODE_AMBIENT="$AMBIENT" \
    CHUMP_NODE_CONVERGE_LOGDIR="$TMP/logs" \
    HOME="$TMP/fakehome" \
        bash "$SCRIPT" > "$1" 2>&1
}

# ── Test 1: behind checkout converges to origin/main ───────────────────────
run_converge "$TMP/out1.log" || fail "converge run 1 exited non-zero: $(cat "$TMP/out1.log")"
LANDED="$(git -C "$CHECKOUT" rev-parse HEAD)"
[ "$LANDED" = "$NEW_SHA" ] \
    || fail "checkout landed on $LANDED, expected origin/main $NEW_SHA (base was $BASE_SHA)"
grep -q 'echo NEW' "$CHECKOUT/scripts/ops/organ.sh" \
    || fail "converged tree still has the OLD organ script body"
ok "behind checkout converged to origin/main (merged bash-organ fix reached the tree)"

grep -q '"kind":"node_converged"' "$AMBIENT" \
    || fail "expected a node_converged ambient event: $(cat "$AMBIENT" 2>/dev/null)"
ok "emitted node_converged"

# ── Test 2: gitignored runtime file survived the converge ──────────────────
[ -f "$CHECKOUT/.chump/state.db" ] \
    || fail ".chump/state.db was WIPED by the converge (must survive a reset --hard)"
[ "$(cat "$CHECKOUT/.chump/state.db")" = "LIVE-DB-BYTES" ] \
    || fail ".chump/state.db content changed across the converge"
ok "gitignored .chump/state.db survived the converge intact"

# ── Test 3: idempotent no-op on an already-current tree ────────────────────
: > "$AMBIENT"
run_converge "$TMP/out3.log" || fail "converge run 2 (idempotent) exited non-zero: $(cat "$TMP/out3.log")"
[ "$(git -C "$CHECKOUT" rev-parse HEAD)" = "$NEW_SHA" ] \
    || fail "idempotent run moved HEAD off origin/main"
grep -q '"kind":"node_converge_skipped"' "$AMBIENT" \
    || fail "expected node_converge_skipped on an already-current tree: $(cat "$AMBIENT" 2>/dev/null)"
grep -q '"reason":"already_current"' "$AMBIENT" \
    || fail "expected reason=already_current on the idempotent skip"
ok "already-current tree is an idempotent no-op skip (no needless reset)"

# ── Test 4: defers when a rebase is in progress ────────────────────────────
# Simulate an in-flight operation by creating the rebase-merge state dir, and
# put the checkout behind again so a reset WOULD move HEAD if not deferred.
git -C "$CHECKOUT" reset --hard -q "$BASE_SHA"
GITDIR="$(git -C "$CHECKOUT" rev-parse --git-dir)"
[ "${GITDIR#/}" = "$GITDIR" ] && GITDIR="$CHECKOUT/$GITDIR"
mkdir -p "$GITDIR/rebase-merge"
: > "$AMBIENT"
run_converge "$TMP/out4.log" || fail "converge run 3 (defer) exited non-zero: $(cat "$TMP/out4.log")"
[ "$(git -C "$CHECKOUT" rev-parse HEAD)" = "$BASE_SHA" ] \
    || fail "converge did NOT defer during a rebase-in-progress (HEAD moved off base)"
grep -q '"reason":"operation_in_progress"' "$AMBIENT" \
    || fail "expected reason=operation_in_progress skip during a rebase: $(cat "$AMBIENT" 2>/dev/null)"
rmdir "$GITDIR/rebase-merge"
ok "defers cleanly while a rebase is in progress (never yanks the tree mid-op)"

printf '\033[0;32mALL PASS\033[0m scripts/ci/test-node-converge.sh\n'
