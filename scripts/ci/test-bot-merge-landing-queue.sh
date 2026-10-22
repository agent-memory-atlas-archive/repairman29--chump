#!/usr/bin/env bash
# test-bot-merge-landing-queue.sh — RESILIENT-1643 (PHASE-R R3 slice b)
#
# Pins the merge-queue landing-provider behaviour of bot-merge.sh:
#   (1) landing_queue_mode is OFF by default (CHUMP_LANDING_PROVIDER unset) →
#       the current rebase/arm behaviour is unchanged.
#   (2) landing_queue_mode is ON only when CHUMP_LANDING_PROVIDER=github AND a
#       merge queue is active (CHUMP_MERGE_QUEUE_ENABLED=1 or live detect).
#   (3) the live-detect probe uses ONLY `gh api graphql` — never `gh pr
#       update-branch` or `gh pr reopen` (a stubbed gh records every call).
#   (4) bot-merge.sh, in queue mode, skips BOTH the §1 rebase and the
#       RESILIENT-325 pre-push rebase, and the script never calls
#       `gh pr update-branch` or `gh pr reopen` anywhere.
#
# Logic is exercised through the sourceable lib + structural assertions on
# bot-merge.sh (the full script needs a real git repo + GitHub auth, so we do
# not run it end-to-end — same idiom as test-bot-merge-skip-rebase.sh).

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
LIB="$REPO_ROOT/scripts/coord/lib/landing-provider.sh"
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"

PASS=0; FAIL=0; FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== RESILIENT-1643 bot-merge merge-queue landing tests ==="

# A recording gh stub: logs every invocation to $GH_CALLS and answers the
# merge-queue GraphQL probe as "true". Prepended to PATH so the lib picks it up.
STUBDIR="$(mktemp -d)"
GH_CALLS="$STUBDIR/gh-calls.log"
trap 'rm -rf "$STUBDIR"' EXIT
cat > "$STUBDIR/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GH_CALLS"
# Answer the mergeQueue GraphQL probe with the --jq-evaluated boolean.
if [[ "$1" == "api" && "$2" == "graphql" ]]; then
    echo "true"
    exit 0
fi
exit 0
STUB
chmod +x "$STUBDIR/gh"
export GH_CALLS
: > "$GH_CALLS"

# shellcheck disable=SC1090
source "$LIB"

# ── 1. default OFF (provider unset) ──────────────────────────────────────────
echo "--- Test 1: provider unset → queue mode OFF (behaviour unchanged) ---"
out="$(CHUMP_LANDING_PROVIDER='' CHUMP_MERGE_QUEUE_ENABLED=1 landing_queue_mode)"
[[ "$out" == "false" ]] && ok "unset provider → false" || fail "unset provider should be false (got '$out')"

# ── 2. ON: provider=github + merge queue enabled ─────────────────────────────
echo "--- Test 2: provider=github + CHUMP_MERGE_QUEUE_ENABLED=1 → ON ---"
out="$(CHUMP_LANDING_PROVIDER=github CHUMP_MERGE_QUEUE_ENABLED=1 landing_queue_mode)"
[[ "$out" == "true" ]] && ok "github + mq=1 → true" || fail "github + mq=1 should be true (got '$out')"

echo "--- Test 2b: case-insensitive provider (GitHub) ---"
out="$(CHUMP_LANDING_PROVIDER=GitHub CHUMP_MERGE_QUEUE_ENABLED=1 landing_queue_mode)"
[[ "$out" == "true" ]] && ok "GitHub + mq=1 → true" || fail "GitHub + mq=1 should be true (got '$out')"

# ── 3. OFF: provider=github but queue disabled ───────────────────────────────
echo "--- Test 3: provider=github + CHUMP_MERGE_QUEUE_ENABLED=0 → OFF ---"
out="$(CHUMP_LANDING_PROVIDER=github CHUMP_MERGE_QUEUE_ENABLED=0 landing_queue_mode)"
[[ "$out" == "false" ]] && ok "github + mq=0 → false" || fail "github + mq=0 should be false (got '$out')"

echo "--- Test 3b: provider=local never enables queue mode ---"
out="$(CHUMP_LANDING_PROVIDER=local CHUMP_MERGE_QUEUE_ENABLED=1 landing_queue_mode)"
[[ "$out" == "false" ]] && ok "local provider → false" || fail "local provider should be false (got '$out')"

# ── 4. live-detect uses ONLY gh api graphql — no update-branch / reopen ──────
echo "--- Test 4: live detect probes gh api graphql only (stubbed gh) ---"
: > "$GH_CALLS"
out="$(CHUMP_LANDING_PROVIDER=github PATH="$STUBDIR:$PATH" landing_queue_mode "owner/repo")"
[[ "$out" == "true" ]] && ok "live detect → true via stubbed gh" || fail "live detect should be true (got '$out')"
if grep -q 'api graphql' "$GH_CALLS"; then
    ok "probe called gh api graphql"
else
    fail "probe did not call gh api graphql (log: $(cat "$GH_CALLS"))"
fi
if grep -qE 'update-branch|reopen' "$GH_CALLS"; then
    fail "queue detection called a forbidden gh subcommand (update-branch/reopen): $(cat "$GH_CALLS")"
else
    ok "queue detection never called update-branch/reopen"
fi

# ── 5. bot-merge.sh never calls gh pr update-branch or gh pr reopen ──────────
echo "--- Test 5: bot-merge.sh issues no update-branch / reopen calls ---"
# Match real invocations only (ignore comments/doc lines). Strip comments first.
code_only="$(grep -vE '^\s*#' "$BOT_MERGE" || true)"
if printf '%s\n' "$code_only" | grep -qE 'gh +pr +update-branch'; then
    fail "bot-merge.sh calls gh pr update-branch"
else
    ok "no gh pr update-branch call"
fi
if printf '%s\n' "$code_only" | grep -qE 'gh +pr +reopen'; then
    fail "bot-merge.sh calls gh pr reopen"
else
    ok "no gh pr reopen call"
fi

# ── 6. bot-merge.sh gates BOTH rebase sites on queue mode ────────────────────
echo "--- Test 6: both rebase sites gated on _BM_LANDING_QUEUE ---"
if grep -q 'BEHIND" -gt 0 && "\$_BM_LANDING_QUEUE" == "true"' "$BOT_MERGE"; then
    ok "§1 rebase gated on queue mode"
else
    fail "§1 rebase not gated on _BM_LANDING_QUEUE"
fi
if grep -q 'BEHIND_NOW" -gt 0 && "\${_BM_LANDING_QUEUE:-false}" == "true"' "$BOT_MERGE"; then
    ok "pre-push rebase gated on queue mode"
else
    fail "pre-push rebase not gated on _BM_LANDING_QUEUE"
fi

# ── 7. R2 gap_prs link write is independent of the rebase path ───────────────
echo "--- Test 7: R2 gap_prs link (_bm_link_pr) still present ---"
if grep -q '_bm_link_pr "\$_bm_linked_pr"' "$BOT_MERGE"; then
    ok "R2 gap_prs link write preserved"
else
    fail "R2 gap_prs link write (_bm_link_pr) missing"
fi

echo
echo "=== Summary: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
    printf '  - %s\n' "${FAILS[@]}"
    exit 1
fi
exit 0
