#!/usr/bin/env bash
# CI test: INFRA-1450 / ZERO-WASTE-136 — orphan-branch-sweeper.sh
#   Covers pagination (two-page fake gh), merged-into-main fast path,
#   and stash-before-delete of unmerged stale branches.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SWEEPER="$REPO_ROOT/scripts/coord/orphan-branch-sweeper.sh"
PASS=0; FAIL=0

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== INFRA-1450 / ZERO-WASTE-136 orphan-branch-sweeper test ==="
echo

# ── 1. Structural checks ─────────────────────────────────────────────────────
[[ -x "$SWEEPER" ]] && ok "sweeper script is executable" || fail "sweeper not executable"

grep -q 'CHUMP_ORPHAN_BRANCH_AGE_DAYS' "$SWEEPER" \
    && ok "configurable age threshold via env" || fail "missing CHUMP_ORPHAN_BRANCH_AGE_DAYS"

grep -q 'CHUMP_ORPHAN_BRANCH_PROTECT_REGEX' "$SWEEPER" \
    && ok "custom protect regex env var present" || fail "missing CHUMP_ORPHAN_BRANCH_PROTECT_REGEX"

grep -q 'per_page=100&page=' "$SWEEPER" \
    && ok "explicit page-param pagination loop present" || fail "missing paginated branch listing"

grep -q 'compare/\$BASE_BRANCH\.\.\.\$branch' "$SWEEPER" \
    && ok "merged-into-base compare fast path present" || fail "missing merged compare fast path"

grep -q 'refs/stash/\$branch' "$SWEEPER" \
    && ok "refs/stash/<branch> stash ref present" || fail "missing refs/stash stash ref"

grep -qE '\-X DELETE' "$SWEEPER" \
    && ok "DELETE call present" || fail "missing -X DELETE"

grep -q 'orphan_branch_deleted' "$SWEEPER" \
    && ok "kind=orphan_branch_deleted ambient event" || fail "missing orphan_branch_deleted"

grep -q 'orphan_branch_stashed' "$SWEEPER" \
    && ok "kind=orphan_branch_stashed ambient event" || fail "missing orphan_branch_stashed"

grep -q 'orphan_branch_sweep_run' "$SWEEPER" \
    && ok "kind=orphan_branch_sweep_run summary event" || fail "missing orphan_branch_sweep_run"

grep -q '\-\-dry-run' "$SWEEPER" && grep -q '\-\-apply' "$SWEEPER" \
    && ok "dry-run (default) and --apply flags" || fail "missing --dry-run or --apply flags"

grep -q 'DRY_RUN=1' "$SWEEPER" \
    && ok "dry-run is default" || fail "dry-run should be default"

# ── Shared two-page fake gh ───────────────────────────────────────────────────
# Page 1 is 100 filler branches (protected via regex so they never hit the API);
# the four branches under test only appear on PAGE 2. A single-page reader would
# therefore see candidates=0 — this is the pagination regression guard.
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

OLD_DATE="2025-01-01T00:00:00Z"
RECENT_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

make_gh() {  # $1 = log path
    local log="$1"
    cat > "$TMPDIR_TEST/gh" <<GHSTUB
#!/usr/bin/env bash
echo "\$@" >> "$log"
case "\$*" in
  *"-X DELETE"*)
    echo deleted ;;
  *"git/refs"*"-X POST"*)
    echo stash-created ;;
  *"branches?per_page=100&page=1"*)
    for i in \$(seq 1 100); do printf 'chump/filler-%03d\n' "\$i"; done ;;
  *"branches?per_page=100&page=2"*)
    printf 'chump/merged-branch\nchump/unmerged-old\nchump/recent-branch\nchump/open-pr-branch\nmain\n' ;;
  *"branches?per_page=100&page="*)
    echo "" ;;
  *"pulls?state=open"*)
    echo "chump/open-pr-branch" ;;
  *"compare/main...chump/merged-branch"*)
    echo "0" ;;   # ahead_by 0 → fully merged → fast-path delete
  *"compare/"*)
    echo "3" ;;    # any other branch is ahead → unmerged
  *"branches/chump/unmerged-old"*)
    printf 'deadbeefsha\t%s\n' "$OLD_DATE" ;;   # @tsv: sha<TAB>date
  *"branches/chump/recent-branch"*)
    printf 'cafed00dsha\t%s\n' "$RECENT_DATE" ;;
  *) echo "" ;;
esac
GHSTUB
    chmod +x "$TMPDIR_TEST/gh"
}

# ── 2. Dry-run: candidates found ONLY via page 2 (pagination proof) ──────────
echo
echo "--- Dry-run: two-page listing, merged + stash candidates ---"
AMB="$TMPDIR_TEST/ambient.jsonl"; : > "$AMB"
GH_LOG="$TMPDIR_TEST/gh.log"; : > "$GH_LOG"
make_gh "$GH_LOG"

OUTPUT=$(CHUMP_AMBIENT_LOG="$AMB" CHUMP_ORPHAN_BRANCH_AGE_DAYS=14 \
    CHUMP_ORPHAN_BRANCH_PROTECT_REGEX='^chump/filler-' \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$SWEEPER" --dry-run 2>&1 || true)

grep -q "page=2" "$GH_LOG" \
    && ok "pagination: fetched page 2 (would be missed by one-page reader)" \
    || fail "pagination: never fetched page 2"

echo "$OUTPUT" | grep -q "CANDIDATE (merged): chump/merged-branch" \
    && ok "dry-run: merged branch flagged (merged candidate)" \
    || fail "dry-run: merged branch not flagged"

echo "$OUTPUT" | grep -q "CANDIDATE (unmerged, stash): chump/unmerged-old" \
    && ok "dry-run: unmerged stale branch flagged (stash candidate)" \
    || fail "dry-run: unmerged stale branch not flagged"

echo "$OUTPUT" | grep -q "candidates=2 (merged=1 stash=1)" \
    && ok "dry-run: summary counts candidates=2 (merged=1 stash=1)" \
    || fail "dry-run: wrong candidate counts (got: $(echo "$OUTPUT" | grep done))"

! echo "$OUTPUT" | grep -q "recent-branch" \
    && ok "dry-run: recent branch below threshold not flagged" \
    || fail "dry-run: recent branch incorrectly flagged"

! echo "$OUTPUT" | grep -q "open-pr-branch" \
    && ok "dry-run: branch with open PR not flagged" \
    || fail "dry-run: open-PR branch incorrectly flagged"

! grep -q "\-X DELETE" "$GH_LOG" \
    && ok "dry-run: no DELETE call issued" \
    || fail "dry-run: DELETE should not fire in dry-run"

! grep -q "git/refs.*-X POST" "$GH_LOG" \
    && ok "dry-run: no stash-ref POST issued" \
    || fail "dry-run: stash POST should not fire in dry-run"

! grep -q "orphan_branch_deleted\|orphan_branch_stashed" "$AMB" \
    && ok "dry-run: no deleted/stashed ambient events" \
    || fail "dry-run: mutation events should not fire in dry-run"

# ── 3. Apply: merged fast-path delete + stash-before-delete ──────────────────
echo
echo "--- Apply: merged deleted immediately; unmerged stale stashed then deleted ---"
AMB2="$TMPDIR_TEST/ambient2.jsonl"; : > "$AMB2"
GH_LOG2="$TMPDIR_TEST/gh2.log"; : > "$GH_LOG2"
MANIFEST="$TMPDIR_TEST/stash-manifest.md"; rm -f "$MANIFEST"
make_gh "$GH_LOG2"

OUTPUT2=$(CHUMP_AMBIENT_LOG="$AMB2" CHUMP_ORPHAN_BRANCH_AGE_DAYS=14 \
    CHUMP_ORPHAN_BRANCH_PROTECT_REGEX='^chump/filler-' \
    CHUMP_STASH_MANIFEST="$MANIFEST" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$SWEEPER" --apply 2>&1 || true)

grep -q "git/refs/heads/chump/merged-branch -X DELETE" "$GH_LOG2" \
    && ok "apply: merged branch deleted via API" \
    || fail "apply: merged branch not deleted"

grep -q '"kind":"orphan_branch_deleted".*"branch":"chump/merged-branch".*"reason":"merged"' "$AMB2" \
    && ok "apply: orphan_branch_deleted reason=merged emitted" \
    || fail "apply: missing merged deletion event"

grep -q "git/refs -X POST .*ref=refs/stash/chump/unmerged-old" "$GH_LOG2" \
    && ok "apply: unmerged tip pushed to refs/stash/<branch>" \
    || fail "apply: stash ref not created"

grep -q '"kind":"orphan_branch_stashed".*"branch":"chump/unmerged-old".*"stash_ref":"refs/stash/chump/unmerged-old"' "$AMB2" \
    && ok "apply: orphan_branch_stashed emitted" \
    || fail "apply: missing stash event"

grep -q "chump/unmerged-old" "$MANIFEST" 2>/dev/null \
    && ok "apply: stash manifest row appended" \
    || fail "apply: manifest not appended"

grep -q '"kind":"orphan_branch_deleted".*"branch":"chump/unmerged-old".*"reason":"stashed"' "$AMB2" \
    && ok "apply: orphan_branch_deleted reason=stashed emitted" \
    || fail "apply: missing stashed-then-deleted event"

# Stash POST must precede the DELETE for the same branch (never destroy first).
POST_LINE=$(grep -n "ref=refs/stash/chump/unmerged-old" "$GH_LOG2" | head -1 | cut -d: -f1)
DEL_LINE=$(grep -n "git/refs/heads/chump/unmerged-old -X DELETE" "$GH_LOG2" | head -1 | cut -d: -f1)
if [[ -n "$POST_LINE" && -n "$DEL_LINE" && "$POST_LINE" -lt "$DEL_LINE" ]]; then
    ok "apply: stash happens BEFORE delete (no destroy-first)"
else
    fail "apply: delete must not precede stash (post=$POST_LINE del=$DEL_LINE)"
fi

! grep -q "recent-branch -X DELETE" "$GH_LOG2" \
    && ok "apply: recent branch left untouched" \
    || fail "apply: recent branch should not be deleted"

echo "$OUTPUT2" | grep -q "deleted=2 (merged=1 stashed=1)" \
    && ok "apply: summary deleted=2 (merged=1 stashed=1)" \
    || fail "apply: wrong deletion counts (got: $(echo "$OUTPUT2" | grep done))"

# ── 3b. CREDIBLE-1604 (AC2): DEFAULT (unset-manifest) path records the stash rows
# via an ephemeral worktree + PR, so the live/node checkout gains NO tracked edit ─
# Production runs the sweeper FROM the node checkout (~/.chumpnode/repo) with
# CHUMP_STASH_MANIFEST UNSET, so STASH_MANIFEST defaults to the TRACKED in-tree
# docs/process/STASHED_BRANCHES.md. Appending to it in place is exactly the
# standing ` M docs/process/STASHED_BRANCHES.md` that blocked `chump gap ship`'s
# INFRA-2423 auto-fetch (cuphead 2026-10-21). The sweeper must instead carve an
# ephemeral worktree off origin/main, commit the rows there, and open a PR —
# leaving the live checkout pristine. Section 3 above forces the in-place seam via
# CHUMP_STASH_MANIFEST, so it can NEVER exercise this path; this section runs the
# production default against a real local origin+clone (git for real, gh stubbed).
# MUTANT (killed here): force MANIFEST_VIA_PR=0 always (revert to the in-place
# write) → the clone gains a tracked edit to docs/process/STASHED_BRANCHES.md AND
# no orphan_branch_manifest_pr is emitted; both assertions below fail.
echo
echo "--- CREDIBLE-1604 AC2: default manifest path writes via worktree+PR, live checkout stays clean ---"
WT_DIR="$TMPDIR_TEST/wt"; mkdir -p "$WT_DIR"
ORIGIN="$WT_DIR/origin.git"
SEED="$WT_DIR/seed"
CLONE="$WT_DIR/clone"
git init -q --bare "$ORIGIN"
git init -q "$SEED"
mkdir -p "$SEED/docs/process"
printf '# Stashed branches manifest\n\n| stashed_at | stash_ref | branch | sha | last_commit_days |\n|---|---|---|---|---|\n' \
    > "$SEED/docs/process/STASHED_BRANCHES.md"
git -C "$SEED" add -A >/dev/null 2>&1
git -C "$SEED" -c user.email=t@t -c user.name=t commit -q -m seed >/dev/null 2>&1
git -C "$SEED" branch -M main >/dev/null 2>&1
git -C "$SEED" remote add origin "$ORIGIN" >/dev/null 2>&1
git -C "$SEED" push -q origin main >/dev/null 2>&1
git clone -q "$ORIGIN" "$CLONE" >/dev/null 2>&1
git -C "$CLONE" config user.email t@t >/dev/null 2>&1
git -C "$CLONE" config user.name t >/dev/null 2>&1

# gh stub for the PR path: one unmerged stale branch, stub stash-POST / DELETE /
# pr-create so flush_manifest_via_pr's `gh pr create` succeeds (git push is REAL,
# to the local bare origin). pr-create success is what emits orphan_branch_manifest_pr.
AMB3="$WT_DIR/ambient3.jsonl"; : > "$AMB3"
GH_LOG3="$WT_DIR/gh3.log"; : > "$GH_LOG3"
cat > "$WT_DIR/gh" <<GHSTUB3
#!/usr/bin/env bash
echo "\$@" >> "$GH_LOG3"
case "\$*" in
  "pr create"*)                      echo "https://example/pr/1"; exit 0 ;;
  *"-X DELETE"*)                     echo deleted; exit 0 ;;
  *"git/refs"*"-X POST"*)            echo stash-created; exit 0 ;;
  *"branches?per_page=100&page=1"*)  printf 'chump/unmerged-old\n'; exit 0 ;;
  *"branches?per_page=100&page="*)   echo ""; exit 0 ;;
  *"pulls?state=open"*)              echo ""; exit 0 ;;
  *"compare/"*)                      echo "3"; exit 0 ;;
  *"branches/chump/unmerged-old"*)   printf 'deadbeefsha\t%s\n' "$OLD_DATE"; exit 0 ;;
  *) echo ""; exit 0 ;;
esac
GHSTUB3
chmod +x "$WT_DIR/gh"

# Run the sweeper FROM the clone (the "node checkout"), CHUMP_STASH_MANIFEST UNSET
# so the production default in-tree manifest path is taken.
( cd "$CLONE" && CHUMP_AMBIENT_LOG="$AMB3" CHUMP_ORPHAN_BRANCH_AGE_DAYS=14 \
    PATH="$WT_DIR:$PATH" bash "$SWEEPER" --apply ) >/dev/null 2>&1 || true

# AC2 assert 1: the live/node checkout gained NO tracked edit — the default
# in-tree manifest was NOT written in place (it went through the worktree+PR).
if [[ -z "$(git -C "$CLONE" status --porcelain 2>/dev/null)" ]]; then
    ok "AC2: default path left the live checkout clean (no in-place manifest edit)"
else
    fail "AC2: live checkout dirtied by the sweep: $(git -C "$CLONE" status --porcelain 2>/dev/null | tr '\n' '|')"
fi
git -C "$CLONE" diff --quiet -- docs/process/STASHED_BRANCHES.md 2>/dev/null \
    && ok "AC2: tracked docs/process/STASHED_BRANCHES.md unchanged in the live checkout" \
    || fail "AC2: tracked STASHED_BRANCHES.md was modified in place in the live checkout"

# AC2 assert 2: the rows were recorded via a worktree+PR — orphan_branch_manifest_pr emitted.
grep -q '"kind":"orphan_branch_manifest_pr"' "$AMB3" 2>/dev/null \
    && ok "AC2: orphan_branch_manifest_pr emitted (rows recorded via worktree+PR)" \
    || fail "AC2: no orphan_branch_manifest_pr emitted (amb: $(tr '\n' '|' <"$AMB3" 2>/dev/null))"
grep -q "pr create" "$GH_LOG3" 2>/dev/null \
    && ok "AC2: sweeper opened a PR (gh pr create) for the manifest rows" \
    || fail "AC2: sweeper never called gh pr create for the manifest rows"

# ── 4. Event registry check ──────────────────────────────────────────────────
echo
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
if grep -q "orphan_branch_deleted" "$REGISTRY" \
    && grep -q "orphan_branch_stashed" "$REGISTRY" \
    && grep -q "orphan_branch_sweep_run" "$REGISTRY"; then
    ok "all three ambient kinds registered in EVENT_REGISTRY.yaml"
else
    fail "one or more kinds missing from EVENT_REGISTRY.yaml"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
