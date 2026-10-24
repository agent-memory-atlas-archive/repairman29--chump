#!/usr/bin/env bash
# scripts/ci/test-node-main-sync.sh — RESILIENT-491 (slice of RESILIENT-345)
#
# Proves scripts/ops/node-main-sync.sh:
#   1. Static: script present/executable, syntax clean.
#   2. no-op path: local HEAD already == origin/main -> no reset attempted.
#   3. main_moved=true path: `git fetch` + `git reset --hard origin/main`
#      actually run and bring the local checkout to the new origin/main SHA.
#   4. Fetch failure: a failing `git` aborts the rebuild sequence (non-zero
#      exit, clear error emitted) WITHOUT attempting a reset.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SCRIPT="$REPO_ROOT/scripts/ops/node-main-sync.sh"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# ── 1. Static checks ────────────────────────────────────────────────────────
[[ -x "$SCRIPT" ]] || fail "node-main-sync.sh missing or not executable"
bash -n "$SCRIPT" || fail "syntax error in node-main-sync.sh"
ok "bash -n passes"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ORIGIN="$TMP/origin.git"
MIRROR="$TMP/mirror"
git init --bare -q "$ORIGIN"
git clone -q "$ORIGIN" "$MIRROR"
git -C "$MIRROR" config user.email test@example.com
git -C "$MIRROR" config user.name "Test"
echo v1 > "$MIRROR/f.txt"
git -C "$MIRROR" add f.txt
git -C "$MIRROR" commit -q -m "c1"
git -C "$MIRROR" push -q origin HEAD:main

# ── 2. no-op path: local HEAD already == origin/main ───────────────────────
AMBIENT1="$TMP/ambient1.jsonl"
CHUMP_REPO_ROOT="$MIRROR" \
CHUMP_NODE_SYNC_AMBIENT="$AMBIENT1" \
CHUMP_NODE_SYNC_LOGDIR="$TMP/logs1" \
    bash "$SCRIPT" > "$TMP/out1.log" 2>&1
rc=$?
[[ "$rc" -eq 0 ]] || fail "no-op run exited $rc (expected 0): $(cat "$TMP/out1.log")"
grep -q '"kind":"node_main_sync_noop"' "$AMBIENT1" \
    || fail "expected node_main_sync_noop emitted; ambient: $(cat "$AMBIENT1" 2>/dev/null)"
ok "no-op path: main not moved -> no reset attempted, noop emitted"

# ── 3. main_moved=true: fetch + reset --hard bring the checkout current ────
echo v2 > "$MIRROR/f.txt"
git -C "$MIRROR" commit -q -am "c2 (advances origin/main)"
git -C "$MIRROR" push -q origin HEAD:main
NEW_SHA="$(git -C "$MIRROR" rev-parse HEAD)"
# Roll the mirror's local main back + dirty the working tree so the test
# proves a REAL `git fetch` + `git reset --hard` ran (a `--hard` reset must
# also discard the uncommitted local edit below).
git -C "$MIRROR" reset --hard HEAD~1 -q
echo "uncommitted local edit" > "$MIRROR/f.txt"
OLD_SHA="$(git -C "$MIRROR" rev-parse HEAD)"
[[ "$OLD_SHA" != "$NEW_SHA" ]] || fail "test setup broken: mirror already at NEW_SHA"

AMBIENT2="$TMP/ambient2.jsonl"
CHUMP_REPO_ROOT="$MIRROR" \
CHUMP_NODE_SYNC_AMBIENT="$AMBIENT2" \
CHUMP_NODE_SYNC_LOGDIR="$TMP/logs2" \
    bash "$SCRIPT" > "$TMP/out2.log" 2>&1
rc=$?
[[ "$rc" -eq 0 ]] || fail "main_moved run exited $rc (expected 0): $(cat "$TMP/out2.log")"

ACTUAL_SHA="$(git -C "$MIRROR" rev-parse HEAD)"
[[ "$ACTUAL_SHA" == "$NEW_SHA" ]] \
    || fail "expected local HEAD reset to $NEW_SHA, got $ACTUAL_SHA — git reset --hard did not run"
ok "main_moved=true: git fetch + git reset --hard origin/main brought HEAD to $NEW_SHA"

DIRTY_CONTENT="$(cat "$MIRROR/f.txt")"
[[ "$DIRTY_CONTENT" == "v2" ]] \
    || fail "expected working tree content 'v2' after --hard reset, got '$DIRTY_CONTENT' — uncommitted edit was not discarded"
ok "reset --hard discarded the uncommitted local edit (proves --hard, not a soft/mixed reset)"

grep -q '"kind":"node_main_sync_main_moved"' "$AMBIENT2" \
    || fail "expected node_main_sync_main_moved emitted; ambient: $(cat "$AMBIENT2" 2>/dev/null)"
grep -q "\"to\":\"$NEW_SHA\"" "$AMBIENT2" \
    || fail "expected main_moved event to record the new SHA; ambient: $(cat "$AMBIENT2" 2>/dev/null)"
grep -q '"kind":"node_main_sync_synced"' "$AMBIENT2" \
    || fail "expected node_main_sync_synced emitted after successful reset; ambient: $(cat "$AMBIENT2" 2>/dev/null)"
ok "output + exit code are logged (ambient events + logfile) for the main-moved sync"

LOGFILE2="$(ls -t "$TMP/logs2"/*.log 2>/dev/null | head -1)"
[[ -n "$LOGFILE2" ]] || fail "expected a per-run logfile in $TMP/logs2"
grep -q 'git fetch origin main exited 0' "$LOGFILE2" \
    || fail "expected fetch exit-code line logged; log: $(cat "$LOGFILE2")"
grep -q 'git reset --hard origin/main exited 0' "$LOGFILE2" \
    || fail "expected reset exit-code line logged; log: $(cat "$LOGFILE2")"
ok "logfile records fetch and reset exit codes"

# ── 4. Fetch failure aborts the rebuild sequence before any reset ──────────
REAL_GIT="$(command -v git)"
export REAL_GIT
FAKE_GIT_DIR="$TMP/fakebin"
mkdir -p "$FAKE_GIT_DIR"
cat > "$FAKE_GIT_DIR/git" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "fetch" ]]; then
    echo "fatal: unable to access origin: simulated network failure" >&2
    exit 1
fi
exec "$REAL_GIT" "$@"
EOF
chmod +x "$FAKE_GIT_DIR/git"

# Dirty the mirror again so a wrongly-attempted reset would be observable.
echo "should not be touched" > "$MIRROR/f.txt"

AMBIENT3="$TMP/ambient3.jsonl"
CHUMP_REPO_ROOT="$MIRROR" \
CHUMP_NODE_SYNC_AMBIENT="$AMBIENT3" \
CHUMP_NODE_SYNC_LOGDIR="$TMP/logs3" \
CHUMP_NODE_SYNC_GIT_BIN="$FAKE_GIT_DIR/git" \
    bash "$SCRIPT" > "$TMP/out3.log" 2>&1
rc=$?
[[ "$rc" -ne 0 ]] || fail "expected non-zero exit when git fetch fails, got 0: $(cat "$TMP/out3.log")"
ok "git fetch failure aborts the rebuild sequence (non-zero exit)"

grep -q '"kind":"node_main_sync_fetch_failed"' "$AMBIENT3" \
    || fail "expected node_main_sync_fetch_failed emitted; ambient: $(cat "$AMBIENT3" 2>/dev/null)"
ok "clear error emitted on fetch failure"

grep -q '"kind":"node_main_sync_synced"' "$AMBIENT3" \
    && fail "reset must NOT run when fetch fails, but a synced event was emitted"
POST_FAIL_CONTENT="$(cat "$MIRROR/f.txt")"
[[ "$POST_FAIL_CONTENT" == "should not be touched" ]] \
    || fail "working tree was modified despite fetch failure — reset ran when it must not have"
ok "reset is never attempted after a fetch failure"

echo "=== test-node-main-sync.sh: ALL PASS ==="
