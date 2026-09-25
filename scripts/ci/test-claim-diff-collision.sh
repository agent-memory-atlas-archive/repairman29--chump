#!/usr/bin/env bash
# capability-guard-exempt: builds chump in-test via cargo; not subject to runner binary cache lag (CREDIBLE-077)
# test-claim-diff-collision.sh — INFRA-1763
#
# CI test for the lease-time predictive diff-collision check in `chump claim`.
# Unlike INFRA-1394 (hot-file overlap, which matches AC text against declared
# lease paths[]), this check runs a REAL `git diff` inside each sibling
# lease's worktree and intersects the actual changed-file set against the
# claim's paths.
#
# Verifies (per INFRA-1763 acceptance criteria):
#   1. kind=collision_predicted fires when a sibling's real git diff
#      intersects the claim paths (schema per COLLISION_PREDICTION_SCHEMA.md)
#      AND kind=claim_diff_collision_checked fires on every checked claim.
#   2. claim_diff_collision_checked carries duration_ms + siblings_checked +
#      matches_found, and the duration is also printed to operator stderr.
#   3. kind=claim_diff_collision_check_failed carries failure_class
#      (transient for an unprovisioned sibling worktree).
#
# Exits non-zero on any failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [[ -z "${CHUMP_BIN:-}" ]]; then
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

echo "=== INFRA-1763 chump claim diff-collision tests ==="
echo

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAKE_REPO="$WORK/repo"
mkdir -p "$FAKE_REPO/.git" "$FAKE_REPO/.chump" "$FAKE_REPO/.chump-locks" \
         "$FAKE_REPO/scripts/coord/lib" "$FAKE_REPO/docs/gaps"

cd "$FAKE_REPO"
git init -q
git config user.email "ci@test.local"
git config user.name "CI Test"
git config commit.gpgsign false
echo "test" > README.md
git add README.md
git -c init.defaultBranch=main commit -q -m "init"
git branch -M main
git remote add origin "$FAKE_REPO"
cd "$REPO_ROOT"

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
INSERT OR REPLACE INTO gaps(id, domain, title, status, priority, acceptance_criteria)
VALUES('$gap_id', 'INFRA', 'test gap', 'open', 'P1', '$ac_text');
SQL
}

write_sibling_lease() {
    local session="$1"
    local sibling_gap="$2"
    local now exp
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    exp=$(date -u -v+4H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
          date -u -d "+4 hours" +%Y-%m-%dT%H:%M:%SZ)
    cat > "$FAKE_REPO/.chump-locks/${session}.json" <<JSON
{
  "session_id": "$session",
  "gap_id": "$sibling_gap",
  "paths": [],
  "taken_at": "$now",
  "expires_at": "$exp",
  "heartbeat_at": "$now",
  "purpose": "gap:$sibling_gap"
}
JSON
}

# Build a REAL sibling worktree (its own tiny git repo is enough — the
# scanner only runs `git diff HEAD --name-only` / `git ls-files --others`
# inside it) with a genuine uncommitted edit to a tracked file.
make_sibling_worktree_with_edit() {
    local sibling_gap="$1"
    local edit_path="$2"
    local wt="$WORK/worktrees/chump-$(echo "$sibling_gap" | tr '[:upper:]' '[:lower:]')"
    mkdir -p "$wt/$(dirname "$edit_path")"
    (
        cd "$wt"
        git init -q
        git config user.email "ci@test.local"
        git config user.name "CI Test"
        git config commit.gpgsign false
        echo "original" > "$edit_path"
        git add "$edit_path"
        git commit -q -m "seed $edit_path"
        # Real uncommitted edit.
        echo "sibling's in-flight change" >> "$edit_path"
    )
}

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
AMBIENT="$FAKE_REPO/.chump-locks/ambient.jsonl"

# ── Check 1+2: real diff intersection → collision_predicted +
#               claim_diff_collision_checked (with cost fields) ─────────────
echo "Check 1+2: sibling's real uncommitted edit intersects claim paths"

EDIT_PATH="src/shared_module.rs"
make_sibling_worktree_with_edit "INFRA-SIBLING01" "$EDIT_PATH"
write_sibling_lease "sibling-session-77" "INFRA-SIBLING01"

rm -f "$FAKE_REPO/.chump/state.db"
seed_gap_db "INFRA-TEST01" "Refactor the shared module."
rm -rf "$WORK/worktrees/chump-infra-test01"
rm -f "$AMBIENT"

set +e
CLAIM_OUT=$(run_claim "INFRA-TEST01" --paths "$EDIT_PATH" 2>&1)
CLAIM_RC=$?
set -e

# Non-blocking check — claim should proceed (rc may still be non-zero for
# unrelated sandbox reasons, e.g. no upstream to push to; that's fine).
if echo "$CLAIM_OUT" | grep -qi "INFRA-1763"; then
    ok "diff-collision check ran and printed to stderr"
else
    fail "expected INFRA-1763 stderr output, got: $CLAIM_OUT"
fi

if [[ -f "$AMBIENT" ]] && grep -q '"kind":"collision_predicted"' "$AMBIENT"; then
    ok "kind=collision_predicted emitted"
else
    fail "collision_predicted NOT found in ambient.jsonl (file: $(cat "$AMBIENT" 2>/dev/null || echo ABSENT))"
fi

if grep -q '"schema_version":"collision-prediction-v1"' "$AMBIENT" 2>/dev/null; then
    ok "collision_predicted carries schema_version=collision-prediction-v1"
else
    fail "collision_predicted missing schema_version field"
fi

if grep -q "\"shared_paths\":\[\"$EDIT_PATH\"\]" "$AMBIENT" 2>/dev/null; then
    ok "collision_predicted shared_paths includes the real edited file"
else
    fail "collision_predicted shared_paths missing $EDIT_PATH"
fi

if [[ -f "$AMBIENT" ]] && grep -q '"kind":"claim_diff_collision_checked"' "$AMBIENT"; then
    ok "kind=claim_diff_collision_checked emitted"
else
    fail "claim_diff_collision_checked NOT found in ambient.jsonl"
fi

if grep -q '"duration_ms"' "$AMBIENT" 2>/dev/null && \
   grep -q '"siblings_checked"' "$AMBIENT" 2>/dev/null && \
   grep -q '"matches_found"' "$AMBIENT" 2>/dev/null; then
    ok "claim_diff_collision_checked carries duration_ms + siblings_checked + matches_found"
else
    fail "claim_diff_collision_checked missing one of duration_ms/siblings_checked/matches_found"
fi

if echo "$CLAIM_OUT" | grep -qi "diff-collision check done in [0-9]*ms"; then
    ok "duration printed to operator stderr at claim time"
else
    fail "expected duration printed to stderr, got: $CLAIM_OUT"
fi

if grep -q '"matches_found":1' "$AMBIENT" 2>/dev/null; then
    ok "matches_found=1 for the real intersection"
else
    fail "expected matches_found=1, ambient: $(cat "$AMBIENT" 2>/dev/null)"
fi

# ── Check 3: unprovisioned sibling worktree → claim_diff_collision_check_failed
echo
echo "Check 3: unprovisioned sibling worktree yields a transient check failure"

rm -f "$FAKE_REPO/.chump-locks/sibling-session-77.json"
write_sibling_lease "sibling-session-88" "INFRA-SIBLING02"
rm -rf "$WORK/worktrees/chump-infra-sibling02"   # deliberately absent

rm -f "$FAKE_REPO/.chump/state.db"
seed_gap_db "INFRA-TEST02" "Some other gap."
rm -rf "$WORK/worktrees/chump-infra-test02"
rm -f "$AMBIENT"

set +e
FAILED_OUT=$(run_claim "INFRA-TEST02" --paths "src/whatever.rs" 2>&1)
FAILED_RC=$?
set -e

if [[ -f "$AMBIENT" ]] && grep -q '"kind":"claim_diff_collision_check_failed"' "$AMBIENT"; then
    ok "kind=claim_diff_collision_check_failed emitted for unprovisioned sibling worktree"
else
    fail "claim_diff_collision_check_failed NOT found in ambient.jsonl (file: $(cat "$AMBIENT" 2>/dev/null || echo ABSENT))"
fi

if grep -q '"failure_class":"transient"' "$AMBIENT" 2>/dev/null; then
    ok "failure_class=transient for unprovisioned worktree"
else
    fail "expected failure_class=transient, ambient: $(cat "$AMBIENT" 2>/dev/null)"
fi

if [[ -f "$AMBIENT" ]] && grep -q '"kind":"claim_diff_collision_checked"' "$AMBIENT"; then
    ok "claim_diff_collision_checked still emitted alongside the failure"
else
    fail "claim_diff_collision_checked missing when a sibling check failed"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ ${#FAILS[@]} -gt 0 ]]; then
    echo "Failures:"
    for f in "${FAILS[@]}"; do
        echo "  - $f"
    done
    exit 1
fi
exit 0
