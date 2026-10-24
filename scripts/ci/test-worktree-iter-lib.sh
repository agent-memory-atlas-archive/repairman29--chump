#!/usr/bin/env bash
# test-worktree-iter-lib.sh — INFRA-1211
#
# Exercises scripts/lib/worktree-iter.sh: verifies each exported function
# works correctly against synthetic fixtures and that all 5 refactored
# reapers source the lib.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/worktree-iter.sh"

echo "=== INFRA-1211 worktree-iter lib tests ==="

# ── (a) Library exists and is sourceable ─────────────────────────────────────
if [[ -f "$LIB" ]]; then
    ok "worktree-iter.sh exists"
else
    fail "worktree-iter.sh missing at $LIB"
    exit 1
fi

# Source it — also sources lease.sh transitively if needed.
# shellcheck source=../lib/worktree-iter.sh
source "$LIB"
ok "worktree-iter.sh sourceable without error"

# ── (b) scan_worktrees yields synthetic dirs ──────────────────────────────────
TMP="$(mktemp -d -t worktree-iter-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# Create two fake worktree dirs under a synthetic .claude/worktrees/
FAKE_WT_BASE="$TMP/.claude/worktrees"
mkdir -p "$FAKE_WT_BASE/wt-alpha"
mkdir -p "$FAKE_WT_BASE/wt-beta"

out="$(CHUMP_WORKTREE_BASE="$FAKE_WT_BASE" CHUMP_WT_SCAN_TMP=0 scan_worktrees)"
count=$(echo "$out" | grep -c "wt-" 2>/dev/null || true)
if [[ "$count" -ge 2 ]]; then
    ok "scan_worktrees yields worktree dirs from CHUMP_WORKTREE_BASE"
else
    fail "scan_worktrees missing dirs (got $count, want >=2)"
fi

# ── (c) scan_worktrees --no-tmp excludes /tmp/chump-* ─────────────────────────
# This is hard to test without creating actual /tmp dirs; test that the flag
# doesn't error and returns only managed dirs.
out2="$(CHUMP_WORKTREE_BASE="$FAKE_WT_BASE" scan_worktrees --no-tmp 2>&1)"
if echo "$out2" | grep -q "wt-alpha"; then
    ok "scan_worktrees --no-tmp includes managed dirs"
else
    fail "scan_worktrees --no-tmp missing managed dirs"
fi

# ── (d) wt_has_active_lease: no lease → return 1 ─────────────────────────────
FAKE_LOCKS="$TMP/.chump-locks"
mkdir -p "$FAKE_LOCKS"
CHUMP_LOCK_DIR="$FAKE_LOCKS" REAPER_REPO_ROOT="$TMP" \
    wt_has_active_lease "$FAKE_WT_BASE/wt-alpha" 900 \
    && fail "wt_has_active_lease returned 0 with no leases" \
    || ok "wt_has_active_lease returns 1 when no leases present"

# ── (e) wt_has_active_lease: stale lease → return 1 ──────────────────────────
STALE_TS="2000-01-01T00:00:00Z"
cat > "$FAKE_LOCKS/claim-stale.json" <<EOF
{
  "gap_id": "TEST-001",
  "worktree": "$FAKE_WT_BASE/wt-alpha",
  "heartbeat_at": "$STALE_TS",
  "expires_at": "2000-01-02T00:00:00Z"
}
EOF
CHUMP_LOCK_DIR="$FAKE_LOCKS" REAPER_REPO_ROOT="$TMP" \
    wt_has_active_lease "$FAKE_WT_BASE/wt-alpha" 900 \
    && fail "wt_has_active_lease returned 0 for stale lease" \
    || ok "wt_has_active_lease returns 1 for stale (2000) heartbeat"

# ── (f) wt_has_active_lease: fresh lease → return 0 ──────────────────────────
NOW_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$FAKE_LOCKS/claim-fresh.json" <<EOF
{
  "gap_id": "TEST-002",
  "worktree": "$FAKE_WT_BASE/wt-beta",
  "heartbeat_at": "$NOW_TS",
  "expires_at": "2099-01-01T00:00:00Z"
}
EOF
CHUMP_LOCK_DIR="$FAKE_LOCKS" REAPER_REPO_ROOT="$TMP" \
    wt_has_active_lease "$FAKE_WT_BASE/wt-beta" 900 \
    && ok "wt_has_active_lease returns 0 for fresh heartbeat" \
    || fail "wt_has_active_lease returned 1 for fresh lease"

# ── (g) wt_is_dirty: empty dir → 1 (not a git repo; treated as clean) ─────────
mkdir -p "$TMP/clean-wt"
wt_is_dirty "$TMP/clean-wt" \
    && fail "wt_is_dirty returned 0 for empty non-git dir" \
    || ok "wt_is_dirty returns 1 for non-git dir (safe default)"

# ── (h) emit_reaper_event writes valid JSON to ambient.jsonl ─────────────────
AMBIENT="$FAKE_LOCKS/ambient.jsonl"
CHUMP_AMBIENT_LOG="$AMBIENT" REAPER_NAME="test-reaper" REAPER_REPO_ROOT="$TMP" \
    emit_reaper_event "worktree_reaper_skipped_active" "/tmp/wt-test" "test_reason"

if [[ -f "$AMBIENT" ]]; then
    python3 -c "import json; json.loads(open('$AMBIENT').read().strip())" \
        && ok "emit_reaper_event writes valid JSON to ambient.jsonl" \
        || fail "emit_reaper_event produced invalid JSON"
    if grep -q '"kind":"worktree_reaper_skipped_active"' "$AMBIENT"; then
        ok "emit_reaper_event includes correct kind field"
    else
        fail "emit_reaper_event missing kind field"
    fi
    if grep -q '"reaper":"test-reaper"' "$AMBIENT"; then
        ok "emit_reaper_event includes REAPER_NAME"
    else
        fail "emit_reaper_event missing reaper field"
    fi
else
    fail "emit_reaper_event did not create ambient.jsonl"
fi

# ── (i) All refactored reapers source worktree-iter.sh ───────────────────────
reapers=(
    "scripts/ops/active-target-reaper.sh"
    "scripts/ops/stale-worktree-reaper.sh"
    "scripts/ops/prune-worktrees.sh"
    "scripts/ops/queue-health-monitor.sh"
    "scripts/coord/worktree-prune.sh"
    "scripts/coord/branch-reaper.sh"
)
for r in "${reapers[@]}"; do
    path="$REPO_ROOT/$r"
    if [[ -f "$path" ]]; then
        if grep -q "worktree-iter.sh" "$path"; then
            ok "$r sources worktree-iter.sh"
        else
            fail "$r does NOT source worktree-iter.sh"
        fi
    else
        fail "$r not found"
    fi
done

# ── (j) No reaper defines its own worktree scanning loop ─────────────────────
# Check that none of the refactored reapers have the old inline
# _emit_reaper_skipped() function definition (replaced by emit_reaper_event).
for r in "${reapers[@]}"; do
    path="$REPO_ROOT/$r"
    [[ -f "$path" ]] || continue
    # stale-worktree-reaper.sh keeps thin wrappers — that's allowed.
    if [[ "$r" == *"stale-worktree"* ]]; then
        continue
    fi
    if grep -q "^_emit_reaper_skipped()" "$path" 2>/dev/null; then
        fail "$r still defines its own _emit_reaper_skipped() — not migrated"
    else
        ok "$r has no inline _emit_reaper_skipped() definition"
    fi
done

echo
# ── (k..q) RESILIENT-1638: shared unpushed/unsaved predicates & reaper safety ─
R1638_DIR="$TMP/r1638"
mkdir -p "$R1638_DIR"
git init --bare -q "$R1638_DIR/origin.git"
git clone -q "$R1638_DIR/origin.git" "$R1638_DIR/repo" 2>/dev/null || true
(
    cd "$R1638_DIR/repo"
    git config user.email "t@t.t"
    git config user.name "t"
    echo "base" > base.txt
    git add base.txt
    git commit -q -m "base"
    git branch -M main
    git push -q origin main
)
R1638_REPO="$R1638_DIR/repo"
mkdir -p "$R1638_REPO/scripts/lib" "$R1638_REPO/scripts/coord/lib"
ln -s "$REPO_ROOT/scripts/lib/lease.sh" "$R1638_REPO/scripts/lib/lease.sh"
ln -s "$REPO_ROOT/scripts/lib/worktree-iter.sh" "$R1638_REPO/scripts/lib/worktree-iter.sh"
ln -s "$REPO_ROOT/scripts/coord/lib/state-store.sh" "$R1638_REPO/scripts/coord/lib/state-store.sh"
cat > "$R1638_REPO/scripts/lib/reaper-instrumentation.sh" <<'LIB'
reaper_setup()               { REAPER_LOCK_DIR="${LOCKS_DIR:-/tmp}"; }
reaper_check_disk_headroom() { :; }
reaper_rotate_log()          { :; }
reaper_finish()              { :; }
LIB
mkdir -p "$R1638_REPO/.chump-locks" "$R1638_REPO/.chump" "$R1638_REPO/.claude/worktrees" "$R1638_REPO/scripts/ops"
cp "$REPO_ROOT/scripts/ops/stale-worktree-reaper.sh" "$R1638_REPO/scripts/ops/stale-worktree-reaper.sh"

# (k) Never-pushed branch with 1 commit (DOC-161 incident shape) -> wt_has_unpushed_commits=0
WT_DOC161="$R1638_REPO/.claude/worktrees/chump-doc-161"
git -C "$R1638_REPO" worktree add -q -b "claude/doc-161" "$WT_DOC161" main
(
    cd "$WT_DOC161"
    git config user.email "t@t.t"
    git config user.name "t"
    echo "doc-161 work" > doc161.md
    git add doc161.md
    git commit -q -m "docs: doc-161 local commit"
)
if REAPER_REPO_ROOT="$R1638_REPO" wt_has_unpushed_commits "$WT_DOC161" "origin"; then
    ok "RESILIENT-1638 (k): wt_has_unpushed_commits detects never-pushed branch (count=$WT_UNPUSHED_COUNT, detail=$WT_UNPUSHED_DETAIL)"
else
    fail "RESILIENT-1638 (k): wt_has_unpushed_commits MISSED never-pushed branch with 1 commit"
fi

if REAPER_REPO_ROOT="$R1638_REPO" wt_has_unsaved_work "$WT_DOC161" "origin" && [[ "$WT_UNSAVED_REASON" == "unpushed_commits" ]]; then
    ok "RESILIENT-1638 (l): wt_has_unsaved_work reports reason=unpushed_commits"
else
    fail "RESILIENT-1638 (l): wt_has_unsaved_work wrong for unpushed branch (reason=${WT_UNSAVED_REASON:-none})"
fi

# Age index & files past any freshness threshold so only the RESILIENT-1638 guard protects WT_DOC161
find "$WT_DOC161" -exec touch -t 202001010000 {} + 2>/dev/null || true
if [[ -f "$WT_DOC161/.git" ]]; then
    _gd="$(sed 's/^gitdir: //' "$WT_DOC161/.git" 2>/dev/null || true)"
    [[ -n "$_gd" && -f "$_gd/index" ]] && touch -t 202001010000 "$_gd/index" 2>/dev/null || true
fi

# (m) Live stale-worktree-reaper.sh --execute with default CHUMP_REAPER_SAFETY_CHECK=1
# MUST keep WT_DOC161 (list it, never delete it) and emit worktree_reaper_skipped_active.
(
    cd "$R1638_REPO"
    CHUMP_REPO_ROOT_OVERRIDE="$R1638_REPO" \
    CHUMP_WORKTREE_BASE="$R1638_REPO/.claude/worktrees" \
    CHUMP_REAPER_NEW_WORKTREE_GRACE_MIN=0 \
        bash "$R1638_REPO/scripts/ops/stale-worktree-reaper.sh" --execute --age-min 0
) >/dev/null 2>&1 || true

if [[ -d "$WT_DOC161" ]]; then
    ok "RESILIENT-1638 (m): stale-worktree-reaper KEPT never-pushed DOC-161 worktree under default safety check"
else
    fail "RESILIENT-1638 (m): stale-worktree-reaper DELETED never-pushed DOC-161 worktree"
fi

if grep -q '"reason":"unpushed_commits"' "$R1638_REPO/.chump-locks/ambient.jsonl" 2>/dev/null &&    grep -q "chump-doc-161" "$R1638_REPO/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "RESILIENT-1638 (n): ambient event names WT_DOC161 with reason=unpushed_commits"
else
    fail "RESILIENT-1638 (n): missing worktree_reaper_skipped_active reason=unpushed_commits for WT_DOC161"
fi

# (o) Squash-merged branch whose origin ref was deleted, recorded as merged in github_cache.db:
# wt_branch_merged_in_cache returns 0, wt_has_unpushed_commits returns 1, and reaper reaps it.
WT_MERGED="$R1638_REPO/.claude/worktrees/chump-squash-merged"
git -C "$R1638_REPO" worktree add -q -b "claude/squash-merged" "$WT_MERGED" main
(
    cd "$WT_MERGED"
    git config user.email "t@t.t"
    git config user.name "t"
    echo "feature" > feat.txt
    git add feat.txt
    git commit -q -m "feat: squash-merged commit"
)
MERGED_SHA="$(git -C "$WT_MERGED" rev-parse HEAD)"
sqlite3 "$R1638_REPO/.chump/github_cache.db" <<SQL
CREATE TABLE IF NOT EXISTS pr_state (
    number INTEGER PRIMARY KEY,
    head_ref TEXT, head_sha TEXT, base_ref TEXT, base_sha TEXT,
    mergeable_state TEXT,
    auto_merge_enabled INTEGER NOT NULL DEFAULT 0,
    draft INTEGER NOT NULL DEFAULT 0,
    merged_at TEXT, title TEXT, user_login TEXT,
    updated_at_api TEXT NOT NULL, fetched_at_local TEXT NOT NULL,
    raw_payload_json TEXT, merge_state_status TEXT
);
INSERT INTO pr_state (number, head_ref, head_sha, merged_at, updated_at_api, fetched_at_local, raw_payload_json)
VALUES (5999, 'claude/squash-merged', '$MERGED_SHA', '2026-10-24T00:00:00Z', '2026-10-24T00:00:00Z', '2026-10-24T00:00:00Z', '{"state":"closed","merged":true}');
SQL

if REAPER_REPO_ROOT="$R1638_REPO" wt_branch_merged_in_cache "$WT_MERGED" "claude/squash-merged" &&    ! REAPER_REPO_ROOT="$R1638_REPO" wt_has_unpushed_commits "$WT_MERGED" "origin"; then
    ok "RESILIENT-1638 (o): cache-first merged PR at HEAD distinguishes deleted-after-merge from never-pushed"
else
    fail "RESILIENT-1638 (o): wt_branch_merged_in_cache / wt_has_unpushed_commits failed on merged cache entry"
fi

# Add a post-merge local commit on WT_MERGED -> must now be detected as unpushed!
(
    cd "$WT_MERGED"
    echo "post-merge local edit" > post.txt
    git add post.txt
    git commit -q -m "post-merge unpushed commit"
)
if REAPER_REPO_ROOT="$R1638_REPO" wt_has_unpushed_commits "$WT_MERGED" "origin"; then
    ok "RESILIENT-1638 (p): commit added AFTER merged PR's head_sha is still protected as unpushed"
else
    fail "RESILIENT-1638 (p): post-merge unpushed commit was misclassified as merged"
fi

# Reset WT_MERGED back to MERGED_SHA, age it, and verify stale-worktree-reaper reaps it.
git -C "$WT_MERGED" reset -q --hard "$MERGED_SHA"
find "$WT_MERGED" -exec touch -t 202001010000 {} + 2>/dev/null || true
if [[ -f "$WT_MERGED/.git" ]]; then
    _gd2="$(sed 's/^gitdir: //' "$WT_MERGED/.git" 2>/dev/null || true)"
    [[ -n "$_gd2" && -f "$_gd2/index" ]] && touch -t 202001010000 "$_gd2/index" 2>/dev/null || true
fi
(
    cd "$R1638_REPO"
    CHUMP_REPO_ROOT_OVERRIDE="$R1638_REPO" \
    CHUMP_WORKTREE_BASE="$R1638_REPO/.claude/worktrees" \
    CHUMP_REAPER_NEW_WORKTREE_GRACE_MIN=0 \
        bash "$R1638_REPO/scripts/ops/stale-worktree-reaper.sh" --execute --age-min 0
) >/dev/null 2>&1 || true

if [[ ! -d "$WT_MERGED" ]]; then
    ok "RESILIENT-1638 (q): deleted-after-merge worktree (verified in cache) WAS reaped"
else
    fail "RESILIENT-1638 (q): deleted-after-merge worktree was NOT reaped"
fi

echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
