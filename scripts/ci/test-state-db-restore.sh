#!/usr/bin/env bash
# capability-guard-exempt: existing CHUMP_BIN check + exit-0 skip path covers missing-binary case (CREDIBLE-078)
# test-state-db-restore.sh — INFRA-538 + RESILIENT-1651 CI gate
#
# Verifies that 'chump gap restore --from-sql' and 'chump gap import --yaml <path>'
# work end-to-end with exit code 0:
#   1. Restore from .chump/state.sql exits 0 (no fallthrough rc=2) and populates state.db
#   2. closed_pr / closed_date / notes survive the round-trip
#   3. Corrupt state.db -> restore regenerates all rows and creates state.db.bak
#   4. Missing state.sql or missing --from-sql exits non-zero
#   5. chump gap dump -> chump gap restore --from-sql round-trips cleanly (RESILIENT-1651 AC1)
#   6. SQLite .dump format in state.sql restores cleanly (RESILIENT-1651 AC1)
#   7. chump gap import --yaml <path> reads ONLY the specified file (relative or absolute)
#      and ignores docs/gaps/*.yaml decoys (RESILIENT-1651 AC2)

set -euo pipefail

# shellcheck source=lib/gate-emit.sh
source "$(dirname "$0")/lib/gate-emit.sh" 2>/dev/null || true
gate_emit_start "INFRA-538" "$*"

REPO_ROOT_REAL="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=lib/resolve-cargo-target-dir.sh
source "$(dirname "$0")/lib/resolve-cargo-target-dir.sh"
TARGET_DIR="$(resolve_cargo_target_dir "$REPO_ROOT_REAL")"
CHUMP_BIN="${CHUMP_BIN:-$TARGET_DIR/debug/chump}" 

if [[ ! -x "$CHUMP_BIN" ]]; then
    echo "FAIL: chump binary not found at $CHUMP_BIN — run 'cargo build --bin chump' first"
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── Bootstrap a minimal repo environment ────────────────────────────────────
mkdir -p "$TMP/.chump" "$TMP/docs/gaps"
git -C "$TMP" init -q
git -C "$TMP" config user.email "test@test.com"
git -C "$TMP" config user.name "Test"

# Create a synthetic state.sql (YAML format) with 3 gaps, 1 with closed_pr.
cat > "$TMP/.chump/state.sql" <<'YAML'
gaps:
- id: TEST-001
  domain: TEST
  title: Test gap one
  status: open
  priority: P1
  effort: s
  notes: |
    some notes here

- id: TEST-002
  domain: TEST
  title: Test gap two
  status: done
  priority: P2
  effort: m
  closed_date: '2026-05-01'
  closed_pr: 999
  notes: shipped

- id: TEST-003
  domain: TEST
  title: Test gap three with acceptance criteria
  status: open
  priority: P1
  effort: xs
  acceptance_criteria:
    - criterion one
    - criterion two
YAML

PASS=0
FAIL=0

check() {
    local name="$1" result="$2" expected="$3"
    if [[ "$result" == "$expected" ]]; then
        echo "[OK] $name"
        PASS=$(( PASS + 1 ))
    else
        echo "FAIL $name: expected '$expected', got '$result'"
        FAIL=$(( FAIL + 1 ))
    fi
}

# ── Test 1: restore from state.sql into a fresh state.db (must exit 0!) ─────
restore_rc=0
CHUMP_REPO="$TMP" "$CHUMP_BIN" gap restore --from-sql >/dev/null 2>&1 || restore_rc=$?
check "test-1a (chump gap restore --from-sql exits 0)" "$restore_rc" "0"
row_count="$(sqlite3 "$TMP/.chump/state.db" "SELECT COUNT(*) FROM gaps")"
check "test-1b (row count = 3 after restore)" "$row_count" "3"

# ── Test 2: closed_pr survives the round-trip ───────────────────────────────
closed_pr="$(sqlite3 "$TMP/.chump/state.db" "SELECT closed_pr FROM gaps WHERE id='TEST-002'")"
check "test-2 (TEST-002 closed_pr = 999)" "$closed_pr" "999"

# ── Test 3: closed_date survives the round-trip ─────────────────────────────
closed_date="$(sqlite3 "$TMP/.chump/state.db" "SELECT closed_date FROM gaps WHERE id='TEST-002'")"
check "test-3 (TEST-002 closed_date = 2026-05-01)" "$closed_date" "2026-05-01"

# ── Test 4: notes survive the round-trip ───────────────────────────────────
notes="$(sqlite3 "$TMP/.chump/state.db" "SELECT notes FROM gaps WHERE id='TEST-001'")"
check "test-4 (TEST-001 notes preserved)" "$(echo "$notes" | head -1 | tr -d '\n')" "some notes here"

# ── Test 5: corrupt then restore, row count still correct ───────────────────
: > "$TMP/.chump/state.db"
restore_rc=0
CHUMP_REPO="$TMP" "$CHUMP_BIN" gap restore --from-sql >/dev/null 2>&1 || restore_rc=$?
check "test-5a (corrupt->restore exits 0)" "$restore_rc" "0"
row_count_after="$(sqlite3 "$TMP/.chump/state.db" "SELECT COUNT(*) FROM gaps")"
check "test-5b (corrupt→restore row count = 3)" "$row_count_after" "3"

# ── Test 6: backup is created as state.db.bak ────────────────────────────────
: > "$TMP/.chump/state.db"
CHUMP_REPO="$TMP" "$CHUMP_BIN" gap restore --from-sql >/dev/null 2>&1
if [[ -f "$TMP/.chump/state.db.bak" ]]; then
    echo "[OK] test-6 (state.db.bak created)"
    PASS=$(( PASS + 1 ))
else
    echo "FAIL test-6: state.db.bak not found"
    FAIL=$(( FAIL + 1 ))
fi

# ── Test 7: missing state.sql → exit non-zero ───────────────────────────────
mv "$TMP/.chump/state.sql" "$TMP/.chump/state.sql.moved"
exit_code=0
CHUMP_REPO="$TMP" "$CHUMP_BIN" gap restore --from-sql >/dev/null 2>&1 || exit_code=$?
mv "$TMP/.chump/state.sql.moved" "$TMP/.chump/state.sql"
if [[ "$exit_code" -ne 0 ]]; then
    echo "[OK] test-7 (exit non-zero when state.sql missing)"
    PASS=$(( PASS + 1 ))
else
    echo "FAIL test-7: expected non-zero exit when state.sql missing, got $exit_code"
    FAIL=$(( FAIL + 1 ))
fi

# ── Test 8: missing --from-sql flag → exit 2 ────────────────────────────────
exit_code=0
CHUMP_REPO="$TMP" "$CHUMP_BIN" gap restore >/dev/null 2>&1 || exit_code=$?
if [[ "$exit_code" -eq 2 ]]; then
    echo "[OK] test-8 (exit 2 when --from-sql missing)"
    PASS=$(( PASS + 1 ))
else
    echo "FAIL test-8: expected exit 2 without --from-sql, got $exit_code"
    FAIL=$(( FAIL + 1 ))
fi

# ── Test 9 (RESILIENT-1651 AC1): chump gap dump -> chump gap restore round-trip
dump_rc=0
CHUMP_REPO="$TMP" "$CHUMP_BIN" gap dump > "$TMP/.chump/state.sql" 2>/dev/null || dump_rc=$?
check "test-9a (chump gap dump exits 0)" "$dump_rc" "0"
rm -f "$TMP/.chump/state.db"
restore_rc=0
CHUMP_REPO="$TMP" "$CHUMP_BIN" gap restore --from-sql >/dev/null 2>&1 || restore_rc=$?
check "test-9b (restore from chump gap dump output exits 0)" "$restore_rc" "0"
row_count_dump="$(sqlite3 "$TMP/.chump/state.db" "SELECT COUNT(*) FROM gaps")"
check "test-9c (row count = 3 after dump->restore)" "$row_count_dump" "3"

# ── Test 10 (RESILIENT-1651 AC1): SQLite .dump SQL statements in state.sql ──
sqlite3 "$TMP/.chump/state.db" .dump > "$TMP/.chump/state.sql"
rm -f "$TMP/.chump/state.db"
restore_sql_rc=0
CHUMP_REPO="$TMP" "$CHUMP_BIN" gap restore --from-sql >/dev/null 2>&1 || restore_sql_rc=$?
check "test-10a (restore from SQL .dump exits 0)" "$restore_sql_rc" "0"
row_count_sql="$(sqlite3 "$TMP/.chump/state.db" "SELECT COUNT(*) FROM gaps")"
check "test-10b (row count = 3 after SQL .dump restore)" "$row_count_sql" "3"

# ── Test 11 (RESILIENT-1651 AC2): chump gap import --yaml <path> honours path
cat > "$TMP/docs/gaps/DEC-999.yaml" <<'YAML'
id: DEC-999
domain: DEC
title: Decoy gap in docs/gaps that must not be imported when --yaml is passed
status: open
priority: P2
effort: s
YAML

mkdir -p "$TMP/custom"
cat > "$TMP/custom/explicit.yaml" <<'YAML'
gaps:
- id: IMP-101
  domain: IMP
  title: Distinct explicit import gap one hundred one
  status: open
  priority: P1
  effort: s
YAML

import_rc=0
(cd "$TMP" && CHUMP_REPO="$TMP" "$CHUMP_BIN" gap import --yaml custom/explicit.yaml >/dev/null 2>&1) || import_rc=$?
check "test-11a (chump gap import --yaml relative-path exits 0)" "$import_rc" "0"
imp_present="$(sqlite3 "$TMP/.chump/state.db" "SELECT COUNT(*) FROM gaps WHERE id='IMP-101'")"
check "test-11b (IMP-101 imported from explicit file)" "$imp_present" "1"
dec_present="$(sqlite3 "$TMP/.chump/state.db" "SELECT COUNT(*) FROM gaps WHERE id='DEC-999'")"
check "test-11c (DEC-999 in docs/gaps ignored when --yaml <file> passed)" "$dec_present" "0"

missing_rc=0
CHUMP_REPO="$TMP" "$CHUMP_BIN" gap import --yaml "$TMP/custom/does-not-exist.yaml" >/dev/null 2>&1 || missing_rc=$?
if [[ "$missing_rc" -ne 0 ]]; then
    echo "[OK] test-11d (chump gap import --yaml nonexistent fails non-zero)"
    PASS=$(( PASS + 1 ))
else
    echo "FAIL test-11d: expected non-zero exit for nonexistent --yaml path"
    FAIL=$(( FAIL + 1 ))
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
if [[ $FAIL -eq 0 ]]; then
    echo "PASS: test-state-db-restore (${PASS}/${PASS} cases verified)"
    gate_emit_result "INFRA-538" "pass" "" ""
    exit 0
else
    echo "FAIL: ${FAIL} case(s) failed (${PASS} passed)"
    gate_emit_result "INFRA-538" "fail" "smoke-test-failure" "$FAIL case(s) failed"
    exit 1
fi
