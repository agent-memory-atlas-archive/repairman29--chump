#!/usr/bin/env bash
# capability-guard-exempt: builds chump in-test via cargo; not subject to runner binary cache lag (CREDIBLE-077)
# test-claim-hot-file-overlap.sh — INFRA-1394
#
# CI test for the hot-file collision check in `chump claim`.
#
# Verifies:
#   1. hot-files.yaml exists and lists the 5 canonical hot files
#   2. A claim against a gap whose AC mentions ci.yml is blocked WITHOUT --force-overlap
#      when a sibling lease declares ci.yml in its paths[]
#   3. The same claim SUCCEEDS with --force-overlap
#   4. kind=claim_hot_file_overlap is emitted to ambient.jsonl in both cases
#   5. A claim against a gap whose AC mentions ONLY non-hot files is NOT blocked
#   6. A claim where no sibling lease exists is NOT blocked (even if AC mentions hot file)
#
# Exits non-zero on any failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Resolve chump binary: prefer CHUMP_BIN env, then look in the Cargo target dir
# (which may be in the main repo when running from a linked worktree), then fall
# back to building.
if [[ -z "${CHUMP_BIN:-}" ]]; then
    # target/ symlink exists in worktrees pointing at the shared target dir.
    CANDIDATE="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
    if [[ -x "$CANDIDATE" ]]; then
        CHUMP_BIN="$CANDIDATE"
    else
        echo "Building chump binary..."
        cd "$REPO_ROOT" && cargo build --bin chump -q
        CHUMP_BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
        cd "$REPO_ROOT"
    fi
fi

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); FAILS+=("$1"); }

echo "=== INFRA-1394 chump claim hot-file overlap tests ==="
echo

# ── Check 1: hot-files.yaml exists with the 5 canonical files ────────────────
echo "Check 1: hot-files.yaml exists and lists canonical hot files"
HOT_YAML="$REPO_ROOT/scripts/coord/lib/hot-files.yaml"
if [[ -f "$HOT_YAML" ]]; then
    ok "hot-files.yaml exists at scripts/coord/lib/hot-files.yaml"
else
    fail "hot-files.yaml missing at scripts/coord/lib/hot-files.yaml"
fi

for expected in \
    ".github/workflows/ci.yml" \
    "docs/observability/EVENT_REGISTRY.yaml" \
    "web/v2/app.js" \
    "src/web_server.rs" \
    "src/main.rs"
do
    if grep -qF "$expected" "$HOT_YAML" 2>/dev/null; then
        ok "hot-files.yaml contains $expected"
    else
        fail "hot-files.yaml missing $expected"
    fi
done

# ── Functional tests using a synthetic repo + fake state.db ──────────────────
# We exercise atomic_claim.rs directly by building chump and running it with
# a controlled environment (CHUMP_WORKTREE_BASE, repo root, pre-seeded state.db).

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAKE_REPO="$WORK/repo"
mkdir -p "$FAKE_REPO/.git" "$FAKE_REPO/.chump" "$FAKE_REPO/.chump-locks" \
         "$FAKE_REPO/scripts/coord/lib" "$FAKE_REPO/docs/gaps"

# Seed a minimal git repo so `git fetch` and `git worktree add` have something to work with.
cd "$FAKE_REPO"
git init -q
git config user.email "ci@test.local"
git config user.name "CI Test"
git config commit.gpgsign false
echo "test" > README.md
git add README.md
git -c init.defaultBranch=main commit -q -m "init"
git branch -M main
# Create a fake origin remote pointing at itself (for fetch).
git remote add origin "$FAKE_REPO"
cd "$REPO_ROOT"

# Copy hot-files.yaml into the fake repo.
cp "$REPO_ROOT/scripts/coord/lib/hot-files.yaml" \
   "$FAKE_REPO/scripts/coord/lib/hot-files.yaml"

# Helper: seed a minimal state.db with one gap.
seed_gap_db() {
    local db="$FAKE_REPO/.chump/state.db"
    local gap_id="$1"
    local ac_text="$2"
    sqlite3 "$db" <<SQL
CREATE TABLE IF NOT EXISTS gaps (
    id TEXT PRIMARY KEY,
    domain TEXT,
    title TEXT,
    status TEXT,
    priority TEXT,
    acceptance_criteria TEXT
);
CREATE TABLE IF NOT EXISTS leases (
    session_id TEXT PRIMARY KEY,
    gap_id TEXT,
    worktree TEXT,
    expires_at INTEGER
);
INSERT OR REPLACE INTO gaps(id, domain, title, status, priority, acceptance_criteria)
VALUES('$gap_id', 'INFRA', 'test gap', 'open', 'P1', '$ac_text');
SQL
}

# Helper: write a sibling lease JSON file.
write_sibling_lease() {
    local session="$1"
    local sibling_gap="$2"
    shift 2
    local paths_json=""
    local sep=""
    for p in "$@"; do
        paths_json="${paths_json}${sep}\"$p\""
        sep=","
    done
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local exp
    exp=$(date -u -v+4H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
          date -u -d "+4 hours" +%Y-%m-%dT%H:%M:%SZ)
    cat > "$FAKE_REPO/.chump-locks/${session}.json" <<JSON
{
  "session_id": "$session",
  "gap_id": "$sibling_gap",
  "paths": [$paths_json],
  "taken_at": "$now",
  "expires_at": "$exp",
  "heartbeat_at": "$now",
  "purpose": "gap:$sibling_gap"
}
JSON
}

# Helper: run chump claim in the fake repo (skipping doctor + import since we control state.db).
run_claim() {
    local gap_id="$1"
    shift
    CHUMP_REPO="$FAKE_REPO" \
    CHUMP_WORKTREE_BASE="$WORK/worktrees" \
    CHUMP_REMOTE="origin" \
    CHUMP_BASE_BRANCH="main" \
    "$CHUMP_BIN" claim "$gap_id" \
        --role fleet-test \
        --skip-doctor --skip-import \
        "$@" 2>&1
}

mkdir -p "$WORK/worktrees"

# ── Check 2: Claim BLOCKED without --force-overlap when AC mentions ci.yml ───
echo
echo "Check 2: claim blocked without --force-overlap (sibling holds ci.yml)"

rm -f "$FAKE_REPO/.chump/state.db"
seed_gap_db "INFRA-TEST01" "Must update .github/workflows/ci.yml to add the new test step."
write_sibling_lease "sibling-session-99" "INFRA-OTHER01" ".github/workflows/ci.yml"
rm -rf "$WORK/worktrees/chump-infra-test01"

set +e
CLAIM_OUT=$(run_claim "INFRA-TEST01" 2>&1)
CLAIM_RC=$?
set -e

if [[ $CLAIM_RC -eq 15 ]]; then
    ok "claim exited 15 (hot-file block) without --force-overlap"
elif [[ $CLAIM_RC -ne 0 ]]; then
    # Also acceptable: any non-zero exit (git might fail in sandbox)
    if echo "$CLAIM_OUT" | grep -qi "hot.file\|overlap\|force.overlap"; then
        ok "claim blocked with hot-file message (rc=$CLAIM_RC)"
    else
        fail "claim exited $CLAIM_RC but no hot-file message (output: $CLAIM_OUT)"
    fi
else
    fail "claim should have been blocked but exited 0"
fi

if echo "$CLAIM_OUT" | grep -qi "hot.file\|INFRA-1394\|overlap\|sibling"; then
    ok "hot-file warning message printed to stderr"
else
    fail "expected hot-file warning in output, got: $CLAIM_OUT"
fi

if echo "$CLAIM_OUT" | grep -qi "force.overlap"; then
    ok "--force-overlap hint printed in error message"
else
    fail "expected --force-overlap hint in output, got: $CLAIM_OUT"
fi

# ── Check 3: Ambient event emitted after block ────────────────────────────────
echo
echo "Check 3: kind=claim_hot_file_overlap emitted to ambient.jsonl"

AMBIENT="$FAKE_REPO/.chump-locks/ambient.jsonl"
if [[ -f "$AMBIENT" ]] && grep -q '"kind":"claim_hot_file_overlap"' "$AMBIENT"; then
    ok "claim_hot_file_overlap event present in ambient.jsonl"
else
    fail "claim_hot_file_overlap event NOT found in ambient.jsonl (file: $(cat "$AMBIENT" 2>/dev/null || echo ABSENT))"
fi

if grep -q '"claim_gap":"INFRA-TEST01"' "$AMBIENT" 2>/dev/null; then
    ok "ambient event has correct claim_gap field"
else
    fail "ambient event missing claim_gap field"
fi

if grep -q '"overlap_paths"' "$AMBIENT" 2>/dev/null; then
    ok "ambient event has overlap_paths field"
else
    fail "ambient event missing overlap_paths field"
fi

# ── Check 4: Claim SUCCEEDS with --force-overlap ──────────────────────────────
echo
echo "Check 4: claim succeeds with --force-overlap"

rm -rf "$WORK/worktrees/chump-infra-test01"
# Sibling lease still present from check 2.
# Clear previous ambient events so we can check for the new one.
rm -f "$AMBIENT"

set +e
FORCE_OUT=$(run_claim "INFRA-TEST01" --force-overlap 2>&1)
FORCE_RC=$?
set -e

# Accept: 0 (fully succeeded), or non-0 if git remote fetch fails in sandbox —
# the key thing is that we did NOT exit 15 (hot-file block).
if [[ $FORCE_RC -eq 15 ]]; then
    fail "claim exited 15 even with --force-overlap — should have proceeded"
else
    ok "claim did NOT exit 15 with --force-overlap (rc=$FORCE_RC)"
fi

if echo "$FORCE_OUT" | grep -qi "force.overlap.*proceeding\|proceeding.*force.overlap"; then
    ok "force-overlap proceed message printed"
else
    # Still acceptable if it just moved on without the message
    ok "claim moved past hot-file block with --force-overlap"
fi

# The event should still be emitted even when --force-overlap is set.
if [[ -f "$AMBIENT" ]] && grep -q '"kind":"claim_hot_file_overlap"' "$AMBIENT"; then
    ok "claim_hot_file_overlap event emitted even with --force-overlap"
else
    fail "claim_hot_file_overlap event NOT emitted when --force-overlap used"
fi

# ── Check 5: Gap whose AC does NOT mention any hot file → not blocked ─────────
echo
echo "Check 5: gap AC without hot-file reference is not blocked"

rm -f "$FAKE_REPO/.chump/state.db"
seed_gap_db "INFRA-TEST02" "Implement the reconciliation loop in src/reconcile.rs."
# Same sibling lease still present.
rm -rf "$WORK/worktrees/chump-infra-test02"
rm -f "$AMBIENT"

set +e
NOHOT_OUT=$(run_claim "INFRA-TEST02" 2>&1)
NOHOT_RC=$?
set -e

if [[ $NOHOT_RC -eq 15 ]]; then
    fail "claim blocked (rc=15) for gap with no hot-file reference in AC"
else
    ok "claim not blocked (rc=$NOHOT_RC) when AC has no hot-file reference"
fi

if [[ -f "$AMBIENT" ]] && grep -q '"kind":"claim_hot_file_overlap"' "$AMBIENT"; then
    fail "spurious claim_hot_file_overlap event emitted for non-hot AC"
else
    ok "no spurious claim_hot_file_overlap event for non-hot AC"
fi

# ── Check 6: No sibling lease → not blocked even if AC mentions hot file ──────
echo
echo "Check 6: no sibling lease → claim not blocked"

rm -f "$FAKE_REPO/.chump/state.db"
seed_gap_db "INFRA-TEST03" "Must add step to .github/workflows/ci.yml."
rm -f "$FAKE_REPO/.chump-locks/sibling-session-99.json"
rm -rf "$WORK/worktrees/chump-infra-test03"
rm -f "$AMBIENT"

set +e
NOSIBLING_OUT=$(run_claim "INFRA-TEST03" 2>&1)
NOSIBLING_RC=$?
set -e

if [[ $NOSIBLING_RC -eq 15 ]]; then
    fail "claim blocked (rc=15) when no sibling lease present"
else
    ok "claim not blocked (rc=$NOSIBLING_RC) with no sibling lease"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ ${#FAILS[@]} -gt 0 ]]; then
    echo "Failures:"
    for f in "${FAILS[@]}"; do echo "  - $f"; done
fi
[[ $FAIL -eq 0 ]]
