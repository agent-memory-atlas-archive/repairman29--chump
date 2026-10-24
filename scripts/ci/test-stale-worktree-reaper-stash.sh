#!/usr/bin/env bash
# test-stale-worktree-reaper-stash.sh — RESILIENT-029
#
# Verifies that stale-worktree-reaper.sh stashes uncommitted/unpushed work to
# a wip/ branch before reaping, rather than silently destroying it.
#
# Tests:
#   T1: clean worktree (no uncommitted, no unpushed) → reaped normally, no wip branch
#   T2: worktree with uncommitted changes → wip/<gap>-<ts> branch created LOCALLY
#       (RESILIENT-1507: never pushed to origin), ambient event emitted, then
#       worktree reaped
#   T3: worktree with unpushed commits → wip/<gap>-<ts> branch with the commits
#       preserved locally, never pushed to origin, ambient event emitted, then reaped
#   T4: worktree with both uncommitted + unpushed → both preserved in a LOCAL wip
#       branch, then reaped
#   T5 (RESILIENT-1507): even with REMOTE=origin explicitly set, no wip/* ref is
#       ever pushed to origin; the log says the ref is kept local, no "offline?"
#   T6 (RESILIENT-1507): with WIP_PUSH_REMOTE set to a different, non-origin
#       remote, the wip branch IS pushed there — and still never to origin.
#
# Uses a file:// local git remote — no GitHub hits.
#
# Run:
#   ./scripts/ci/test-stale-worktree-reaper-stash.sh
# Exits non-zero on any failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REAL_REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REAPER="$REAL_REPO_ROOT/scripts/ops/stale-worktree-reaper.sh"

[[ -x "$REAPER" ]] || { echo "FAIL: reaper not executable: $REAPER"; exit 1; }

PASS=0
FAIL=0
ok()   { echo "  PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL+1)); }

echo "=== RESILIENT-029: stale-worktree-reaper wip-stash tests ==="

# ── Scaffold: self-contained fake repo hierarchy ──────────────────────────────
TMPBASE=$(mktemp -d)
trap 'rm -rf "$TMPBASE"' EXIT

FAKE_ORIGIN="$TMPBASE/origin.git"          # bare "remote"
FAKE_REPO="$TMPBASE/repo"                  # simulated Chump repo root
LOCKS_DIR="$FAKE_REPO/.chump-locks"
AMBIENT="$LOCKS_DIR/ambient.jsonl"
ARCHIVE_DIR="$FAKE_REPO/docs/archive/eval-runs"
WT_BASE="$FAKE_REPO/.claude/worktrees"

mkdir -p "$FAKE_ORIGIN" "$LOCKS_DIR" "$ARCHIVE_DIR" "$WT_BASE"
touch "$AMBIENT"

# Stub out the lib files the reaper sources.  They use functions that are
# called on every run; we replace them with no-ops so the reaper stays
# fully self-contained against our fake repo.
mkdir -p "$FAKE_REPO/scripts/lib"

cat > "$FAKE_REPO/scripts/lib/reaper-instrumentation.sh" <<'LIB'
reaper_setup()             { REAPER_LOCK_DIR="${LOCKS_DIR:-/tmp}"; }
reaper_check_disk_headroom() { :; }
reaper_rotate_log()        { :; }
reaper_finish()            { :; }
LIB

cat > "$FAKE_REPO/scripts/lib/lease.sh" <<'LIB'
lease_iter()       { true; }
lease_worktree()   { echo ""; }
lease_is_fresh()   { return 1; }
lease_heartbeat_age_s() { echo 9999; }
LIB

cat > "$FAKE_REPO/scripts/lib/worktree-iter.sh" <<'LIB'
emit_reaper_event() {
    local kind="$1" wt_path="$2" reason="${3:-}" extra="${4:-}"
    printf '{"ts":"%s","kind":"%s","worktree":"%s","reason":"%s"%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$kind" "$wt_path" "$reason" \
        "${extra:+,$extra}" \
        >> "${LOCKS_DIR}/ambient.jsonl" 2>/dev/null || true
}
LIB

# Bare origin.
git init --bare "$FAKE_ORIGIN" -b main >/dev/null 2>&1

# Init FAKE_REPO directly (cloning an empty bare repo exits non-zero on some git).
git init -b main "$FAKE_REPO" >/dev/null 2>&1
git -C "$FAKE_REPO" remote add origin "file://$FAKE_ORIGIN"
git -C "$FAKE_REPO" config user.email "test@test.local"
git -C "$FAKE_REPO" config user.name "Test"

# Seed main with an initial commit so HEAD exists.
echo "init" > "$FAKE_REPO/README"
git -C "$FAKE_REPO" add README
git -C "$FAKE_REPO" commit -m "init" >/dev/null 2>&1
git -C "$FAKE_REPO" push -u origin main >/dev/null 2>&1

# Helper: create a linked worktree from a branch that has "merged" into main.
# The branch tip is an ancestor of origin/main — reapable by merge-ancestor check.
# Args: <branch-name>  →  sets WT path to $WT_BASE/<branch-name>
make_merged_worktree() {
    local branch="$1"
    local wt="$WT_BASE/$branch"
    mkdir -p "$WT_BASE"
    git -C "$FAKE_REPO" checkout -b "$branch" >/dev/null 2>&1
    echo "work-$branch" > "$FAKE_REPO/work-$branch.txt"
    git -C "$FAKE_REPO" add "work-$branch.txt"
    git -C "$FAKE_REPO" commit -m "work on $branch" >/dev/null 2>&1
    git -C "$FAKE_REPO" push origin "$branch" >/dev/null 2>&1
    # Merge branch into main (simulates a merged PR).
    git -C "$FAKE_REPO" checkout main >/dev/null 2>&1
    git -C "$FAKE_REPO" merge --ff-only "$branch" >/dev/null 2>&1
    git -C "$FAKE_REPO" push origin main >/dev/null 2>&1
    # Create linked worktree pointing at the now-merged branch.
    git -C "$FAKE_REPO" worktree add "$wt" "$branch" >/dev/null 2>&1
    git -C "$wt" config user.email "test@test.local"
    git -C "$wt" config user.name "Test"
    echo "$wt"
}

# Run the reaper against FAKE_REPO with full env isolation.
# WORKTREE_SCAN_PATHS is scoped to just the fake WT base so the reaper never
# touches /tmp/chump-* worktrees from the real fleet running alongside CI.
run_reaper() {
    CHUMP_SKIP_INSTRUMENTATION=1 \
    CHUMP_REAPER_SAFETY_CHECK=0 \
    CHUMP_REAPER_NEW_WORKTREE_GRACE_MIN=0 \
    CHUMP_REPO_ROOT_OVERRIDE="$FAKE_REPO" \
    CHUMP_WORKTREE_BASE="$WT_BASE" \
    WORKTREE_SCAN_PATHS="$WT_BASE" \
    REMOTE=origin \
    BASE=main \
    LOCKS_DIR="$LOCKS_DIR" \
    REAPER_LOCK_DIR="$LOCKS_DIR" \
    WIP_PUSH_REMOTE="${WIP_PUSH_REMOTE:-}" \
        bash "$REAPER" \
            --execute \
            --age-min 0 \
            --force-skip-process-check
}

# ─── T1: clean worktree → reaped normally, no wip branch ────────────────────
echo ""
echo "T1: clean worktree → reaped normally, no wip branch"
WT1=$(make_merged_worktree "t1-clean")

run_reaper || true

if [[ ! -d "$WT1" ]]; then
    ok "T1: clean worktree was reaped"
else
    fail "T1: clean worktree was NOT reaped (still at $WT1)"
fi

if ! git -C "$FAKE_REPO" ls-remote --heads origin 'wip/t1*' 2>/dev/null | grep -q .; then
    ok "T1: no wip branch created for clean worktree"
else
    fail "T1: unexpected wip branch created for clean worktree"
fi

if ! grep -q 'worktree_work_stashed_before_reap' "$AMBIENT" 2>/dev/null; then
    ok "T1: no stash ambient event for clean worktree"
else
    # Accept only if the event is clearly not for t1-clean.
    if grep 'worktree_work_stashed_before_reap' "$AMBIENT" | grep -q 't1'; then
        fail "T1: stash event incorrectly references t1-clean"
    else
        ok "T1: stash event is not for t1-clean"
    fi
fi
truncate -s 0 "$AMBIENT"

# ─── T2: uncommitted changes → wip branch created, event emitted, reaped ───
echo ""
echo "T2: worktree with uncommitted changes → wip branch + event"
WT2=$(make_merged_worktree "t2-uncommitted")
# Drop a staged (uncommitted) file.
echo "uncommitted work" > "$WT2/uncommitted.txt"
git -C "$WT2" add uncommitted.txt

run_reaper || true

if [[ ! -d "$WT2" ]]; then
    ok "T2: worktree with uncommitted changes was reaped"
else
    fail "T2: worktree with uncommitted changes was NOT reaped"
fi

WIP_T2=$(git -C "$FAKE_REPO" for-each-ref --format='%(refname:short)' 'refs/heads/wip/*' 2>/dev/null | head -1 || true)
if [[ -n "$WIP_T2" ]]; then
    ok "T2: wip branch created LOCALLY: $WIP_T2"
else
    fail "T2: no local wip branch found after uncommitted-change reap"
fi
if ! git -C "$FAKE_REPO" ls-remote --heads origin 'wip/*' 2>/dev/null | grep -q .; then
    ok "T2 (RESILIENT-1507): wip branch was NOT pushed to origin"
else
    fail "T2 (RESILIENT-1507): wip branch was pushed to origin — must stay local-only by default"
fi

if grep -q 'worktree_work_stashed_before_reap' "$AMBIENT" 2>/dev/null; then
    ok "T2: worktree_work_stashed_before_reap event emitted"
    if grep 'worktree_work_stashed_before_reap' "$AMBIENT" | grep -q '"uncommitted_lines"'; then
        ok "T2: event contains uncommitted_lines field"
    else
        fail "T2: event missing uncommitted_lines field"
    fi
else
    fail "T2: worktree_work_stashed_before_reap event NOT emitted"
fi
truncate -s 0 "$AMBIENT"
# Clean up local wip branches for isolation between tests.
for _ref in $(git -C "$FAKE_REPO" for-each-ref --format='%(refname:short)' 'refs/heads/wip/*' 2>/dev/null); do
    git -C "$FAKE_REPO" branch -D "$_ref" >/dev/null 2>&1 || true
done

# ─── T3: unpushed commits → wip branch with commits pushed, event emitted ──
echo ""
echo "T3: worktree with unpushed commits → wip branch preserves them"
WT3=$(make_merged_worktree "t3-unpushed")
# Simulate the scenario: origin branch was deleted (PR auto-cleanup after merge),
# then agent added a commit locally that was never pushed.  The reaper sees
# remote_exists=0 → reapable.  But there is a local commit ahead that must
# be preserved before removal.
git -C "$FAKE_REPO" push origin --delete t3-unpushed >/dev/null 2>&1 || true
# Now add an unpushed commit in the worktree on top.
echo "unpushed work" > "$WT3/unpushed.txt"
git -C "$WT3" add unpushed.txt
git -C "$WT3" commit -m "unpushed commit" --no-verify >/dev/null 2>&1

run_reaper || true

if [[ ! -d "$WT3" ]]; then
    ok "T3: worktree with unpushed commits was reaped"
else
    fail "T3: worktree with unpushed commits was NOT reaped"
fi

WIP_T3=$(git -C "$FAKE_REPO" for-each-ref --format='%(refname:short)' 'refs/heads/wip/*' 2>/dev/null | head -1 || true)
if [[ -n "$WIP_T3" ]]; then
    ok "T3: wip branch created LOCALLY: $WIP_T3"
else
    fail "T3: no local wip branch found after unpushed-commit reap"
fi
if ! git -C "$FAKE_REPO" ls-remote --heads origin 'wip/*' 2>/dev/null | grep -q .; then
    ok "T3 (RESILIENT-1507): wip branch was NOT pushed to origin"
else
    fail "T3 (RESILIENT-1507): wip branch was pushed to origin — must stay local-only by default"
fi

if grep -q 'worktree_work_stashed_before_reap' "$AMBIENT" 2>/dev/null; then
    ok "T3: worktree_work_stashed_before_reap event emitted"
    if grep 'worktree_work_stashed_before_reap' "$AMBIENT" | grep -q '"unpushed_commits"'; then
        ok "T3: event contains unpushed_commits field"
    else
        fail "T3: event missing unpushed_commits field"
    fi
else
    fail "T3: worktree_work_stashed_before_reap event NOT emitted"
fi
truncate -s 0 "$AMBIENT"
for _ref in $(git -C "$FAKE_REPO" for-each-ref --format='%(refname:short)' 'refs/heads/wip/*' 2>/dev/null); do
    git -C "$FAKE_REPO" branch -D "$_ref" >/dev/null 2>&1 || true
done

# ─── T4: both uncommitted + unpushed → all preserved, then reaped ───────────
echo ""
echo "T4: worktree with both uncommitted + unpushed → all preserved in wip branch"
WT4=$(make_merged_worktree "t4-both")
# Delete remote branch so reaper sees remote_exists=0 → reapable.
git -C "$FAKE_REPO" push origin --delete t4-both >/dev/null 2>&1 || true
# Unpushed commit on top.
echo "unpushed work" > "$WT4/unpushed2.txt"
git -C "$WT4" add unpushed2.txt
git -C "$WT4" commit -m "unpushed work" --no-verify >/dev/null 2>&1
# Plus staged (uncommitted) change on top.
echo "also uncommitted" > "$WT4/also-uncommitted.txt"
git -C "$WT4" add also-uncommitted.txt

run_reaper || true

if [[ ! -d "$WT4" ]]; then
    ok "T4: worktree with both changes was reaped"
else
    fail "T4: worktree with both changes was NOT reaped"
fi

WIP_T4=$(git -C "$FAKE_REPO" for-each-ref --format='%(refname:short)' 'refs/heads/wip/*' 2>/dev/null | head -1 || true)
if [[ -n "$WIP_T4" ]]; then
    ok "T4: wip branch created LOCALLY: $WIP_T4"
else
    fail "T4: no local wip branch found after both-changes reap"
fi
if ! git -C "$FAKE_REPO" ls-remote --heads origin 'wip/*' 2>/dev/null | grep -q .; then
    ok "T4 (RESILIENT-1507): wip branch was NOT pushed to origin"
else
    fail "T4 (RESILIENT-1507): wip branch was pushed to origin — must stay local-only by default"
fi

if grep -q 'worktree_work_stashed_before_reap' "$AMBIENT" 2>/dev/null; then
    ok "T4: worktree_work_stashed_before_reap event emitted"
    EVENT_LINE=$(grep 'worktree_work_stashed_before_reap' "$AMBIENT" | tail -1)
    if echo "$EVENT_LINE" | grep -q '"uncommitted_lines"' \
       && echo "$EVENT_LINE" | grep -q '"unpushed_commits"'; then
        ok "T4: event contains both uncommitted_lines and unpushed_commits fields"
    else
        fail "T4: event missing one or more required fields (got: $EVENT_LINE)"
    fi
else
    fail "T4: worktree_work_stashed_before_reap event NOT emitted"
fi
truncate -s 0 "$AMBIENT"
for _ref in $(git -C "$FAKE_REPO" for-each-ref --format='%(refname:short)' 'refs/heads/wip/*' 2>/dev/null); do
    git -C "$FAKE_REPO" branch -D "$_ref" >/dev/null 2>&1 || true
done

# ─── T5 (RESILIENT-1507): log says kept-local, no misleading "offline?" ─────
# Mirrors T3/T4's shape (origin branch deleted -> reapable via "origin branch
# deleted", bypassing the RESILIENT-267 new-worktree grace window that a
# still-live origin branch would trip).
echo ""
echo "T5: WIP_PUSH_REMOTE unset → log says kept local, no 'offline?' warning"
WT5=$(make_merged_worktree "t5-logtext")
git -C "$FAKE_REPO" push origin --delete t5-logtext >/dev/null 2>&1 || true
# An unpushed commit makes the branch tip diverge from origin/main so the
# RESILIENT-267 merge-ancestor/grace-window path is bypassed (same shape as T3).
echo "unpushed work" > "$WT5/unpushed.txt"
git -C "$WT5" add unpushed.txt
git -C "$WT5" commit -m "unpushed commit" --no-verify >/dev/null 2>&1
echo "uncommitted work" > "$WT5/uncommitted.txt"
git -C "$WT5" add uncommitted.txt

OUT5=$(run_reaper 2>&1 || true)

if [[ ! -d "$WT5" ]]; then
    ok "T5: worktree was reaped"
else
    fail "T5: worktree was NOT reaped"
fi

if echo "$OUT5" | grep -qi 'offline'; then
    fail "T5: log still contains misleading 'offline?' warning"
else
    ok "T5: log does not contain misleading 'offline?' warning"
fi

if echo "$OUT5" | grep -qi 'WIP_PUSH_REMOTE unset'; then
    ok "T5: log explicitly states the ref is kept local (WIP_PUSH_REMOTE unset)"
else
    fail "T5: log does not explain that the ref was kept local"
fi
truncate -s 0 "$AMBIENT"
for _ref in $(git -C "$FAKE_REPO" for-each-ref --format='%(refname:short)' 'refs/heads/wip/*' 2>/dev/null); do
    git -C "$FAKE_REPO" branch -D "$_ref" >/dev/null 2>&1 || true
done

# ─── T6 (RESILIENT-1507): WIP_PUSH_REMOTE=<other remote> pushes there, never origin
echo ""
echo "T6: WIP_PUSH_REMOTE=<other remote> → pushed there, never to origin"
OTHER_REMOTE_DIR="$TMPBASE/backup-remote.git"
git init --bare "$OTHER_REMOTE_DIR" -b main >/dev/null 2>&1
git -C "$FAKE_REPO" remote add backup "file://$OTHER_REMOTE_DIR" >/dev/null 2>&1 || true

WT6=$(make_merged_worktree "t6-otherremote")
git -C "$FAKE_REPO" push origin --delete t6-otherremote >/dev/null 2>&1 || true
echo "unpushed work" > "$WT6/unpushed.txt"
git -C "$WT6" add unpushed.txt
git -C "$WT6" commit -m "unpushed commit" --no-verify >/dev/null 2>&1
echo "uncommitted work" > "$WT6/uncommitted.txt"
git -C "$WT6" add uncommitted.txt

WIP_PUSH_REMOTE=backup run_reaper || true

if [[ ! -d "$WT6" ]]; then
    ok "T6: worktree was reaped"
else
    fail "T6: worktree was NOT reaped"
fi

WIP_T6_BACKUP=$(git -C "$FAKE_REPO" ls-remote --heads backup 'wip/*' 2>/dev/null | head -1 || true)
if [[ -n "$WIP_T6_BACKUP" ]]; then
    ok "T6: wip branch was pushed to the configured non-origin remote (backup)"
else
    fail "T6: wip branch was NOT pushed to the configured non-origin remote"
fi

if ! git -C "$FAKE_REPO" ls-remote --heads origin 'wip/*' 2>/dev/null | grep -q .; then
    ok "T6: wip branch was NOT pushed to origin even with WIP_PUSH_REMOTE set"
else
    fail "T6: wip branch leaked to origin despite WIP_PUSH_REMOTE pointing elsewhere"
fi
truncate -s 0 "$AMBIENT"

# ─── DOC-164: stash-manifest.sh generates the STASHED_WORK.md table ─────────────
# The stash-manifest generator is the read side of this same refs/stash/* surface
# (the reaper writes stash refs; stash-manifest.sh lists them into the doc). Feed
# it a STUBBED `git ls-remote` fixture via its --input seam and assert the table
# lists every input ref — so a mutant that drops a ref from the generated table
# fails here.
echo ""
echo "DOC-164: stash-manifest.sh regenerates the table from a stubbed ls-remote"
MANIFEST="$REAL_REPO_ROOT/scripts/coord/stash-manifest.sh"

[[ -x "$MANIFEST" ]] && ok "DOC-164: stash-manifest.sh is executable" \
    || fail "DOC-164: stash-manifest.sh not executable: $MANIFEST"

# Stubbed `git ls-remote origin 'refs/stash/*'` output: one sha<TAB>ref per line,
# covering every reason/date/gap shape the generator must parse.
FIX="$TMPBASE/ls-remote.txt"
cat > "$FIX" <<'LSREMOTE'
11faca97ec3c0ea39b2f73947f3d1c2b93619b76	refs/stash/2026-07-27/almanac-integration
7a98fcf194602151b8eb2649dc1419492e613490	refs/stash/2026-07-27/infra-2248-mesh-localprocess-transport
bb9a10bf0c01987f8cb21774df00090b4dd19e19	refs/stash/ceo-bench-2026-08-15
65508d78f72721b35980a1b14acedd2c494fc4ef	refs/stash/chump/resilient-1494-fleet-1-20261013-034319
debd3626f29de5df4ef7e1c571c0657dd3ecbf12	refs/stash/credible-1551-wip
4411da09c8a02acf10be2555ea4db0c8e58f65ba	refs/stash/credible-1578-wip-20261021T0030Z
bfa5547a3d0b05237c227d64aca303fa3bd9a285	refs/stash/credible-1554-uncommitted-5605
c1b61662af3be951467c3beae347ae86cc0b6a29	refs/stash/resilient-1652-wip-20261020T1302Z
LSREMOTE
EXPECTED_ROWS=$(grep -c 'refs/stash/' "$FIX")

MANIFEST_OUT=$(bash "$MANIFEST" --print --input "$FIX" 2>&1) || true

# Every input ref must appear as a row in the generated table (mutant that drops
# any ref fails this).
GEN_ROWS=$(printf '%s\n' "$MANIFEST_OUT" | grep -c '^| `refs/stash/' || true)
if [[ "$GEN_ROWS" == "$EXPECTED_ROWS" ]]; then
    ok "DOC-164: table has one row per input ref ($GEN_ROWS of $EXPECTED_ROWS)"
else
    fail "DOC-164: row count $GEN_ROWS != input ref count $EXPECTED_ROWS (a ref was dropped)"
fi

MANIFEST_MISSING=0
while IFS=$'\t' read -r _sha _ref; do
    [[ -z "${_ref:-}" ]] && continue
    if ! printf '%s\n' "$MANIFEST_OUT" | grep -qF "| \`$_ref\` |"; then
        fail "DOC-164: generated table is missing ref $_ref"
        MANIFEST_MISSING=1
    fi
done < "$FIX"
[[ "$MANIFEST_MISSING" == "0" ]] && ok "DOC-164: every stubbed ref is present in the table"

# Parsing spot-checks: gap, date, and reason inferred from the ref shape.
if printf '%s\n' "$MANIFEST_OUT" | grep -qE '`refs/stash/credible-1578-wip-20261021T0030Z` \| CREDIBLE-1578 \| 2026-10-21 \|'; then
    ok "DOC-164: wip ref parsed to gap+date (CREDIBLE-1578 / 2026-10-21)"
else
    fail "DOC-164: wip ref gap/date parse wrong"
fi
if printf '%s\n' "$MANIFEST_OUT" | grep -q 'stash-wip.sh WIP snapshot'; then
    ok "DOC-164: stash-wip reason inferred"
else
    fail "DOC-164: stash-wip reason not inferred"
fi
if printf '%s\n' "$MANIFEST_OUT" | grep -qE '`refs/stash/chump/resilient-1494-fleet-1-20261013-034319` \| RESILIENT-1494 \| 2026-10-13 \|.*fleet worktree-reaper salvage'; then
    ok "DOC-164: fleet-reaper ref parsed to gap+date+reason"
else
    fail "DOC-164: fleet-reaper ref parse wrong"
fi

# ─── RESILIENT-1639: non-worktree vs real-worktree classification ───────────
echo ""
echo "RESILIENT-1639: non-worktree plain dir vs real worktree + cooldown state dir"
R1639_SCAN="$TMPBASE/r1639-scan"
R1639_RESCUE="$TMPBASE/r1639-rescue"
R1639_STAMPS="$TMPBASE/r1639-stamps"
mkdir -p "$R1639_SCAN" "$R1639_RESCUE" "$R1639_STAMPS"

# 1. Fixture plain dir (not in git worktree list, not an allow-listed scratch pattern)
PLAIN_DIR="$R1639_SCAN/chump-plain-state"
mkdir -p "$PLAIN_DIR"
echo "keep-me" > "$PLAIN_DIR/state.txt"

# 2. Fixture cooldown state dir (/tmp/chump-pr-watch-cooldown shape)
COOLDOWN_DIR="$R1639_SCAN/chump-pr-watch-cooldown"
mkdir -p "$COOLDOWN_DIR"
echo "cooldown-marker" > "$COOLDOWN_DIR/pr-123"
touch -t 202001010000 "$COOLDOWN_DIR" 2>/dev/null || true

# 3. Fixture allow-listed scratch dir (not in git worktree list, matches *-fix, past age threshold)
SCRATCH_FIX_DIR="$R1639_RESCUE/meta197-fix"
mkdir -p "$SCRATCH_FIX_DIR"
touch -t 202001010000 "$SCRATCH_FIX_DIR" 2>/dev/null || true

# 4. Fixture real git worktree (in git worktree list, branch merged)
REAL_WT=$(make_merged_worktree "t7-real-wt")

run_r1639_reaper() {
    CHUMP_REAPER_SAFETY_CHECK=0 \
    CHUMP_REAPER_NEW_WORKTREE_GRACE_MIN=0 \
    CHUMP_REPO_ROOT_OVERRIDE="$FAKE_REPO" \
    CHUMP_WORKTREE_BASE="$WT_BASE" \
    WORKTREE_SCAN_PATHS="$WT_BASE $R1639_SCAN/chump-*" \
    CHUMP_RESCUE_SCAN_BASE="$R1639_RESCUE" \
    CHUMP_REAPER_STAMP_DIR="$R1639_STAMPS" \
    ORPHAN_AGE_MIN_HOURS=12 \
    REMOTE=origin \
    BASE=main \
    LOCKS_DIR="$LOCKS_DIR" \
    REAPER_LOCK_DIR="$LOCKS_DIR" \
        bash "$REAPER" --execute --age-min 0 --force-skip-process-check 2>&1
}

OUT_R1639_1=$(run_r1639_reaper || true)

# Real worktree was reaped via git worktree remove
if [[ ! -d "$REAL_WT" ]]; then
    ok "RESILIENT-1639: fixture real worktree reaped"
else
    fail "RESILIENT-1639: fixture real worktree was NOT reaped"
fi

# Plain non-worktree dir was skipped with reason=not_a_worktree and kept intact
if [[ -d "$PLAIN_DIR" && -f "$PLAIN_DIR/state.txt" ]]; then
    ok "RESILIENT-1639: fixture plain dir kept intact (never passed to git worktree remove)"
else
    fail "RESILIENT-1639: fixture plain dir was modified or deleted"
fi
if printf '%s\n' "$OUT_R1639_1" | grep -qF "SKIP: $PLAIN_DIR reason=not_a_worktree"; then
    ok "RESILIENT-1639: first run logged reason=not_a_worktree for plain dir"
else
    fail "RESILIENT-1639: first run did NOT log reason=not_a_worktree for plain dir"
fi

# Second run on same day: reason=not_a_worktree is NOT logged again (stamp file rate-limit)
OUT_R1639_2=$(run_r1639_reaper || true)
if printf '%s\n' "$OUT_R1639_2" | grep -qF "SKIP: $PLAIN_DIR reason=not_a_worktree"; then
    fail "RESILIENT-1639: second run on same day logged reason=not_a_worktree again (stamp rate-limit broken)"
else
    ok "RESILIENT-1639: second run suppressed duplicate reason=not_a_worktree via daily stamp"
fi

# chump-pr-watch-cooldown state dir is never touched
if [[ -d "$COOLDOWN_DIR" && -f "$COOLDOWN_DIR/pr-123" ]]; then
    ok "RESILIENT-1639: chump-pr-watch-cooldown state dir untouched"
else
    fail "RESILIENT-1639: chump-pr-watch-cooldown state dir was touched or deleted!"
fi

# Allow-listed scratch dir (meta197-fix) past age threshold is removed via safe-delete (rm -rf), no REAP_FAIL
if [[ ! -d "$SCRATCH_FIX_DIR" ]] && ! printf '%s\n' "$OUT_R1639_1" | grep -q "FAILED to remove.*meta197-fix"; then
    ok "RESILIENT-1639: allow-listed scratch dir (meta197-fix) removed via safe-delete without git worktree remove failure"
else
    fail "RESILIENT-1639: allow-listed scratch dir (meta197-fix) was not cleanly safe-deleted"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
    echo "FAIL: $FAIL test(s) failed" >&2
    exit 1
fi
echo "PASS: all RESILIENT-029 stash tests"
exit 0
