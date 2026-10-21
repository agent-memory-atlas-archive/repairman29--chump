#!/usr/bin/env bash
# test-gap-outcome-migration.sh — MISSION-008
#
# Asserts:
#  (a) outcomes table + gaps.outcome_id FK exist via additive non-destructive migration
#      (idempotent: running migration twice leaves existing rows untouched)
#  (b) chump outcome new / list / status wired in binary
#  (c) chump gap reserve --outcome / chump gap set --outcome work
#  (d) a child gap with an outcome_id still closes normally (rollup is advisory)
#  (e) chump gap audit-priorities --json includes p0_outcomes fields
#  (f) META-067 outcome row can be created
set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"

echo "=== MISSION-008 gap outcome migration test ==="
echo

# 1. Binary wiring checks (static).
if grep -q '"outcome"' "$REPO_ROOT/src/main.rs"; then
    ok "outcome command arm in main.rs"
else
    fail "outcome command arm missing from main.rs"
fi

if grep -q 'chump outcome' "$REPO_ROOT/src/main.rs" || \
   grep -q '"outcome"' "$REPO_ROOT/src/main.rs"; then
    ok "outcome command referenced in main.rs"
else
    fail "outcome command not in main.rs"
fi

if grep -q 'CREATE TABLE IF NOT EXISTS outcomes' \
    "$REPO_ROOT/crates/chump-gap-store/src/lib.rs"; then
    ok "outcomes table DDL present in lib.rs"
else
    fail "outcomes table DDL missing from lib.rs"
fi

if grep -q 'ADD COLUMN outcome_id' \
    "$REPO_ROOT/crates/chump-gap-store/src/lib.rs"; then
    ok "ALTER TABLE gaps ADD COLUMN outcome_id present"
else
    fail "ALTER TABLE gaps ADD COLUMN outcome_id missing"
fi

if grep -q 'outcome_id' \
    "$REPO_ROOT/crates/chump-gap-store/src/lib.rs"; then
    ok "outcome_id referenced in gap store"
else
    fail "outcome_id not referenced in gap store"
fi

if grep -q 'list_p0_outcomes\|p0_outcomes' "$REPO_ROOT/src/main.rs"; then
    ok "outcome-aware P0 budget view in audit-priorities"
else
    fail "outcome-aware P0 budget view missing from audit-priorities"
fi

if grep -q 'use_outcome_join\|outcome_id' "$REPO_ROOT/src/roadmap_status.rs"; then
    ok "roadmap-status LEFT JOIN path present"
else
    fail "roadmap-status LEFT JOIN path missing"
fi

# 2. Functional tests: build binary and run against an isolated fixture DB.
BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
if [[ ! -f "$BIN" ]]; then
    echo "  [build] cargo build --bin chump (quiet)..."
    cargo build --bin chump --manifest-path "$REPO_ROOT/Cargo.toml" -q 2>&1 | tail -5
fi

if [[ ! -f "$BIN" ]]; then
    fail "chump binary not found after build — skipping functional tests"
    echo
    echo "=== Results: $PASS passed, $FAIL failed ==="
    [[ "$FAIL" -eq 0 ]]
    exit $?
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export CHUMP_REPO="$TMP"
export CHUMP_HOME="$TMP"
# RESILIENT-1652: run chump through the canonical sandbox primitive
# (chump_test_sandbox_setup, which now also pins CHUMP_STATE_DIR to the sandbox)
# and lay down a healthy-node fixture INSIDE it via the shared ~20-line function,
# so the RESILIENT-069 farmer readiness gate (consulted by `gap reserve`/`claim`)
# reads GREEN by evidence on a fresh Linux runner that has no
# ~/.chump/oauth-token.json. No gate loosening, no skip env var: a
# missing/expired token or a paused node.env on a real node still reds.
# shellcheck source=scripts/coord/lib/test-sandbox.sh
source "$REPO_ROOT/scripts/coord/lib/test-sandbox.sh"
# shellcheck source=scripts/ci/lib/sandbox-healthy-node.sh
source "$REPO_ROOT/scripts/ci/lib/sandbox-healthy-node.sh"
chump_test_sandbox_setup "$TMP"
export HOME="$TMP"   # isolate the .credentials.json read to the sandbox too
write_sandbox_healthy_node "$TMP"
export CHUMP_ALLOW_MAIN_WORKTREE=1
export FLEET_029_AMBIENT_GLANCE_SKIP=1
export CHUMP_RESERVE_NO_AUTOSTAGE=1
export CHUMP_RESERVE_VERIFY=0
DB="$TMP/.chump/state.db"

# (a) Migration is idempotent and non-destructive.
# Reserve a gap first so state.db has an existing row.
ID1=$("$BIN" gap reserve --domain INFRA --priority P1 --effort xs \
    --title "outcome-migration-test-fixture" --quiet 2>/dev/null)
if [[ -n "$ID1" ]]; then
    ok "reserved fixture gap $ID1 before migration idempotency check"
else
    fail "failed to reserve fixture gap"
fi

# Opening the store a second time re-runs migrate() — idempotent.
# We verify by reserving another gap; if state.db was corrupted both calls fail.
ID2=$("$BIN" gap reserve --domain INFRA --priority P1 --effort xs \
    --title "outcome-migration-test-fixture-2" --quiet 2>/dev/null)
if [[ -n "$ID2" ]]; then
    ok "second reserve after re-migrate still works (idempotent)"
else
    fail "second reserve failed — migration not idempotent"
fi

# Existing row still readable after second open.
DB="$TMP/.chump/state.db"
if sqlite3 "$DB" "SELECT title FROM gaps WHERE id='$ID1'" 2>/dev/null | \
        grep -q "outcome-migration-test-fixture"; then
    ok "existing row untouched after re-migrate"
else
    fail "existing row lost after re-migrate"
fi

# (b) chump outcome new / list / status.
if "$BIN" outcome new --id "META-067" \
    --title "2026 Outcome Framework" \
    --priority "P2" \
    --definition-of-done "Chump autonomously builds+deploys software 0→1" 2>/dev/null; then
    ok "chump outcome new META-067 succeeded"
else
    fail "chump outcome new META-067 failed"
fi

LIST_OUT=$("$BIN" outcome list 2>/dev/null)
if echo "$LIST_OUT" | grep -q "META-067"; then
    ok "chump outcome list shows META-067"
else
    fail "chump outcome list does not show META-067"
fi

STATUS_OUT=$("$BIN" outcome status META-067 2>/dev/null)
if echo "$STATUS_OUT" | grep -q "META-067"; then
    ok "chump outcome status META-067 succeeds"
else
    fail "chump outcome status META-067 failed"
fi

STATUS_JSON=$("$BIN" outcome status META-067 --json 2>/dev/null)
if echo "$STATUS_JSON" | grep -q '"advisory":true'; then
    ok "outcome status JSON includes advisory:true"
else
    fail "outcome status JSON missing advisory:true"
fi

# (c) chump gap reserve --outcome and chump gap set --outcome.
ID3=$("$BIN" gap reserve --domain INFRA --priority P1 --effort xs \
    --title "outcome-fk-test-gap" --outcome META-067 --quiet 2>/dev/null)
if [[ -n "$ID3" ]]; then
    ok "gap reserve --outcome succeeded, got $ID3"
else
    fail "gap reserve --outcome failed"
fi

# Check outcome_id directly in the DB (gap show renders YAML which may omit it
# when docs/gaps/ dir doesn't exist in the test's tmp CHUMP_REPO).
OID3=$(sqlite3 "$DB" "SELECT outcome_id FROM gaps WHERE id='$ID3'" 2>/dev/null || true)
if [[ "$OID3" == "META-067" ]]; then
    ok "gap $ID3 has outcome_id=META-067 in DB"
else
    fail "gap $ID3 outcome_id not set in DB (got '$OID3')"
fi

# chump gap set --outcome on a different gap.
"$BIN" gap set "$ID1" --outcome META-067 2>/dev/null
OID1=$(sqlite3 "$DB" "SELECT outcome_id FROM gaps WHERE id='$ID1'" 2>/dev/null || true)
if [[ "$OID1" == "META-067" ]]; then
    ok "gap set --outcome updated $ID1 in DB"
else
    fail "gap set --outcome did not update $ID1 (got '$OID1')"
fi

# (d) Child gap with outcome_id can still close normally (advisory-only, never gates).
# We set AC to satisfy the vague-pickable guard, then close with a fake PR.
"$BIN" gap set "$ID3" \
    --acceptance-criteria "migration test AC" \
    --closed-pr 9999 \
    --status done 2>/dev/null
# Check DB directly — gap show may render from YAML which may not exist in tmp dir.
CLOSE_ROWS=$(sqlite3 "$DB" "SELECT status FROM gaps WHERE id='$ID3'" 2>/dev/null || true)
if [[ "$CLOSE_ROWS" == "done" ]]; then
    ok "child gap $ID3 closed in DB (outcome_id is advisory, never gates close)"
else
    fail "child gap $ID3 did not close (status='$CLOSE_ROWS') — outcome must NOT gate close"
fi

# (e) audit-priorities --json includes outcome fields.
# Note: exits 1 when there are vague gaps — capture output regardless of exit code.
AUDIT_JSON=$("$BIN" gap audit-priorities --json 2>/dev/null || true)
if echo "$AUDIT_JSON" | grep -q '"p0_outcomes_count"'; then
    ok "audit-priorities JSON has p0_outcomes_count field"
else
    fail "audit-priorities JSON missing p0_outcomes_count field"
fi
if echo "$AUDIT_JSON" | grep -q '"p0_outcomes"'; then
    ok "audit-priorities JSON has p0_outcomes array"
else
    fail "audit-priorities JSON missing p0_outcomes array"
fi

# (f) META-067 outcome row readable via JSON API.
META_JSON=$("$BIN" outcome list --json 2>/dev/null)
if echo "$META_JSON" | grep -q '"META-067"'; then
    ok "META-067 outcome persisted in outcomes table"
else
    fail "META-067 outcome not in list --json output"
fi

# Rollup shows the two gaps assigned to it.
ROLLUP=$("$BIN" outcome status META-067 --json 2>/dev/null)
TOTAL=$(echo "$ROLLUP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('total',0))" 2>/dev/null || echo 0)
if [[ "$TOTAL" -ge 1 ]]; then
    ok "outcome status rollup reports total >= 1 child gaps (got $TOTAL)"
else
    fail "outcome status rollup total should be >=1 (got $TOTAL)"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
