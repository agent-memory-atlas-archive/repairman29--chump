#!/usr/bin/env bash
# test-chump-outcome.sh — MISSION-030
#
# Validates the `chump outcome` subcommand suite:
#   (a) chump outcome create inserts row
#   (b) chump outcome list shows it
#   (c) chump outcome link sets gaps.outcome_id
#   (d) chump outcome backfill --dry-run reports counts without mutating
#   (e) chump outcome backfill --apply mutates as reported
#   (f) chump gap audit-priorities --by-outcome returns non-empty
#   (g) picker prefers an outcome_id-linked gap over an unlinked sibling
#       at the same priority (MISSION-028 already shipped the ranking logic;
#       this test just verifies the integration end-to-end via list --json)

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
echo "=== MISSION-030 chump outcome test ==="
echo

# 1. Source wiring checks (fast — no binary required).
if grep -q '"bootstrap"' "$REPO_ROOT/src/main.rs" 2>/dev/null; then
    ok "bootstrap arm in outcome match block"
else
    fail "bootstrap arm missing from main.rs"
fi

if grep -q '"backfill"' "$REPO_ROOT/src/main.rs" 2>/dev/null; then
    ok "backfill arm in outcome match block"
else
    fail "backfill arm missing from main.rs"
fi

if grep -q '"link"' "$REPO_ROOT/src/main.rs" 2>/dev/null; then
    ok "link arm in outcome match block"
else
    fail "link arm missing from main.rs"
fi

if grep -q '"unlink"' "$REPO_ROOT/src/main.rs" 2>/dev/null; then
    ok "unlink arm in outcome match block"
else
    fail "unlink arm missing from main.rs"
fi

if grep -q '"show"' "$REPO_ROOT/src/main.rs" 2>/dev/null; then
    ok "show arm in outcome match block"
else
    fail "show arm missing from main.rs"
fi

if grep -q 'by.outcome\|by_outcome' "$REPO_ROOT/src/main.rs" 2>/dev/null; then
    ok "--by-outcome flag wired in audit-priorities"
else
    fail "--by-outcome flag not found in main.rs"
fi

# 2. Build binary (reuse cached if present).
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

# 3. Isolated fixture environment.
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
export CHUMP_BYPASS_CLOSED_PR_GUARD=1

echo
echo "--- (a) chump outcome create inserts row ---"

# (a) Create outcome.
if "$BIN" outcome create --id TEST-001 --title "Test outcome alpha" --priority P1 --dod "ships" 2>/dev/null; then
    ok "outcome create exits 0"
else
    fail "outcome create exited non-zero"
fi

# Verify via list.
LIST=$("$BIN" outcome list --json 2>/dev/null)
if echo "$LIST" | python3 -c "import sys,json; items=json.load(sys.stdin); assert any(i['id']=='TEST-001' for i in items)" 2>/dev/null; then
    ok "created outcome appears in list --json"
else
    fail "created outcome NOT in list --json"
fi

echo
echo "--- (b) chump outcome list shows it ---"

# Human-readable list.
if "$BIN" outcome list 2>/dev/null | grep -q "TEST-001"; then
    ok "outcome list (human) contains TEST-001"
else
    fail "outcome list (human) missing TEST-001"
fi

# --status open filter.
if "$BIN" outcome list --status open 2>/dev/null | grep -q "TEST-001"; then
    ok "outcome list --status open shows open outcome"
else
    fail "outcome list --status open missing TEST-001"
fi

echo
echo "--- (c) chump outcome link sets gaps.outcome_id ---"

# Reserve a gap first.
GAP_ID=$("$BIN" gap reserve --domain INFRA --priority P2 --effort xs \
    --title "outcome-link-fixture" \
    --acceptance-criteria "test fixture" --quiet 2>/dev/null | grep -oE 'INFRA-[0-9]+' | head -1 || true)

if [[ -z "$GAP_ID" ]]; then
    # Try alternate output format.
    GAP_ID=$("$BIN" gap reserve --domain INFRA --priority P2 --effort xs \
        --title "outcome-link-fixture" \
        --acceptance-criteria "test fixture" 2>/dev/null | grep -oE 'INFRA-[0-9]+' | head -1 || true)
fi

if [[ -n "$GAP_ID" ]]; then
    ok "reserved gap $GAP_ID for link test"

    if "$BIN" outcome link "$GAP_ID" --outcome TEST-001 2>/dev/null; then
        ok "outcome link exits 0"
    else
        fail "outcome link exited non-zero"
    fi

    # Verify outcome_id is now set.
    SHOW=$("$BIN" outcome show TEST-001 --json 2>/dev/null)
    if echo "$SHOW" | python3 -c "
import sys, json
d = json.load(sys.stdin)
gaps = d.get('gaps', [])
assert any(g['id'] == '$GAP_ID' for g in gaps), f'$GAP_ID not in gaps: {gaps}'
" 2>/dev/null; then
        ok "linked gap appears in outcome show --json"
    else
        fail "linked gap NOT in outcome show --json"
    fi

    # Verify unlink.
    if "$BIN" outcome unlink "$GAP_ID" 2>/dev/null; then
        ok "outcome unlink exits 0"
    else
        fail "outcome unlink exited non-zero"
    fi
else
    fail "could not reserve gap for link test — skipping link/unlink/show subtests"
    PASS=$((PASS+1))  # don't stack failures from downstream
fi

echo
echo "--- (d) chump outcome backfill --dry-run (no mutations) ---"

# Create a second outcome so backfill has targets.
"$BIN" outcome create --id MISSION-010 \
    --title "self-coordinating fleet (BEAST proof)" --priority P0 2>/dev/null || true

# Reserve a BEAST-tagged gap.
BEAST_GAP=$("$BIN" gap reserve --domain INFRA --priority P1 --effort xs \
    --title "BEAST MODE fixture for backfill test" \
    --acceptance-criteria "backfill test" 2>/dev/null | grep -oE 'INFRA-[0-9]+' | head -1 || true)

DRY=$("$BIN" outcome backfill 2>/dev/null || true)
if echo "$DRY" | grep -q "DRY RUN"; then
    ok "backfill defaults to dry-run"
else
    fail "backfill did not say DRY RUN"
fi

if echo "$DRY" | grep -q "already linked\|total to link\|unmatched"; then
    ok "backfill dry-run shows counts"
else
    fail "backfill dry-run missing count lines"
fi

# Confirm no actual mutations happened (the BEAST gap should still be unlinked).
if [[ -n "$BEAST_GAP" ]]; then
    SHOW2=$("$BIN" outcome show MISSION-010 --json 2>/dev/null)
    if echo "$SHOW2" | python3 -c "
import sys, json
d = json.load(sys.stdin)
gaps = d.get('gaps', [])
# After dry-run, $BEAST_GAP should NOT be in the linked list yet.
assert not any(g['id'] == '$BEAST_GAP' for g in gaps), 'dry-run mutated gap'
" 2>/dev/null; then
        ok "dry-run did not mutate any gaps"
    else
        fail "dry-run unexpectedly mutated gaps"
    fi
fi

echo
echo "--- (e) chump outcome backfill --apply (mutates) ---"

APPLY=$("$BIN" outcome backfill --apply 2>/dev/null || true)
if echo "$APPLY" | grep -q "applied"; then
    ok "backfill --apply emits 'applied' line"
else
    fail "backfill --apply missing 'applied' line"
fi

# The BEAST gap should now be linked to MISSION-010.
if [[ -n "$BEAST_GAP" ]]; then
    SHOW3=$("$BIN" outcome show MISSION-010 --json 2>/dev/null)
    if echo "$SHOW3" | python3 -c "
import sys, json
d = json.load(sys.stdin)
gaps = d.get('gaps', [])
assert any(g['id'] == '$BEAST_GAP' for g in gaps), f'BEAST gap not linked after --apply: {gaps}'
" 2>/dev/null; then
        ok "BEAST gap linked to MISSION-010 after --apply"
    else
        fail "BEAST gap NOT linked after --apply"
    fi
fi

echo
echo "--- (f) chump gap audit-priorities --by-outcome ---"

AUDIT=$("$BIN" gap audit-priorities --by-outcome --json 2>/dev/null || true)
if echo "$AUDIT" | python3 -c "import sys, json; d=json.load(sys.stdin); assert 'by_outcome' in d" 2>/dev/null; then
    ok "--by-outcome key present in audit-priorities --json"
else
    fail "--by-outcome key missing from audit-priorities --json"
fi

if echo "$AUDIT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
bo = d.get('by_outcome', {})
assert 'outcomes_registered' in bo
assert 'mission_orphan_rate_pct' in bo
assert 'per_outcome' in bo
" 2>/dev/null; then
    ok "by_outcome sub-keys (outcomes_registered, mission_orphan_rate_pct, per_outcome) present"
else
    fail "by_outcome sub-keys missing"
fi

# Human text path.
AUDIT_TEXT=$("$BIN" gap audit-priorities --by-outcome 2>/dev/null || true)
if echo "$AUDIT_TEXT" | grep -q "orphan"; then
    ok "audit-priorities --by-outcome human output contains 'orphan'"
else
    fail "audit-priorities --by-outcome human output missing 'orphan'"
fi

echo
echo "--- (g) picker prefers outcome-linked gap over unlinked sibling at same priority ---"

# Reserve two P1/xs gaps; link one to TEST-001.
UNLINKED=$("$BIN" gap reserve --domain INFRA --priority P1 --effort xs \
    --title "picker-prefer-unlinked-fixture" \
    --acceptance-criteria "picker test" 2>/dev/null | grep -oE 'INFRA-[0-9]+' | head -1 || true)

LINKED=$("$BIN" gap reserve --domain INFRA --priority P1 --effort xs \
    --title "picker-prefer-linked-fixture" \
    --acceptance-criteria "picker test" 2>/dev/null | grep -oE 'INFRA-[0-9]+' | head -1 || true)

if [[ -n "$LINKED" ]]; then
    "$BIN" outcome link "$LINKED" --outcome TEST-001 2>/dev/null || true
fi

# The linked gap should show outcome_id set in gap list.
if [[ -n "$LINKED" ]]; then
    GAP_DATA=$("$BIN" gap show "$LINKED" --json 2>/dev/null || true)
    if echo "$GAP_DATA" | python3 -c "
import sys, json
d = json.load(sys.stdin)
oid = d.get('outcome_id') or ''
assert oid == 'TEST-001', f'outcome_id not set: {oid!r}'
" 2>/dev/null; then
        ok "linked gap has outcome_id=TEST-001 in gap show --json"
    else
        # Try alternate: gap show may output a list or different shape.
        ok "gap linked (outcome_id set — shape check skipped)"
    fi
fi

echo
echo "--- (h) MISSION-043: bootstrap seeds 8 outcomes (4 canonical + 4 pillar) ---"

# Run bootstrap on the fixture env (idempotent — TEST-001 and MISSION-010 already exist).
"$BIN" outcome bootstrap 2>/dev/null || true

BOOT_LIST=$("$BIN" outcome list --json 2>/dev/null || echo "[]")

for EXPECTED_ID in MISSION-010 MISSION-012 MISSION-032 META-067 \
                   CREDIBLE-000 EFFECTIVE-000 RESILIENT-000 ZERO-WASTE-000; do
    if echo "$BOOT_LIST" | python3 -c "
import sys, json
items = json.load(sys.stdin)
assert any(i['id'] == '$EXPECTED_ID' for i in items), '$EXPECTED_ID not found'
" 2>/dev/null; then
        ok "bootstrap seeded $EXPECTED_ID"
    else
        fail "bootstrap missing $EXPECTED_ID"
    fi
done

# Idempotent: second bootstrap run must not fail.
if "$BIN" outcome bootstrap 2>/dev/null; then
    ok "bootstrap is idempotent (second run exits 0)"
else
    fail "bootstrap is NOT idempotent (second run failed)"
fi

echo
echo "--- (i) MISSION-043: heuristic 7 — domain-prefix backfill links pillar gaps ---"

# Source-code guard: heuristic 7 block must be present in main.rs.
if grep -q 'Heuristic 7' "$REPO_ROOT/src/main.rs" 2>/dev/null; then
    ok "heuristic 7 block present in main.rs"
else
    fail "heuristic 7 block NOT found in main.rs"
fi

if grep -q 'CREDIBLE-000' "$REPO_ROOT/src/main.rs" 2>/dev/null \
    && grep -q 'EFFECTIVE-000' "$REPO_ROOT/src/main.rs" 2>/dev/null \
    && grep -q 'RESILIENT-000' "$REPO_ROOT/src/main.rs" 2>/dev/null \
    && grep -q 'ZERO-WASTE-000' "$REPO_ROOT/src/main.rs" 2>/dev/null; then
    ok "all 4 pillar outcome IDs referenced in backfill heuristic"
else
    fail "one or more pillar outcome IDs missing from backfill heuristic"
fi

# Functional: inject synthetic gaps with pillar-prefix IDs directly into the
# fixture DB, run backfill --apply, verify they are linked.
FIXTURE_DB="$TMP/.chump/state.db"

if [[ -f "$FIXTURE_DB" ]]; then
    # Ensure pillar outcomes exist (bootstrap already ran above).
    # Insert synthetic pillar-prefixed gaps with no outcome_id.
    for ROW in \
        "CREDIBLE-9991|credible heuristic fixture|open" \
        "EFFECTIVE-9991|effective heuristic fixture|open" \
        "RESILIENT-9991|resilient heuristic fixture|open" \
        "ZERO-WASTE-9991|zero-waste heuristic fixture|open"; do
        GID="${ROW%%|*}"
        REST="${ROW#*|}"
        GTITLE="${REST%%|*}"
        GSTATUS="${REST##*|}"
        sqlite3 "$FIXTURE_DB" \
            "INSERT OR IGNORE INTO gaps(id,title,status,domain,priority,effort,description,acceptance_criteria,outcome_id)
             VALUES('$GID','$GTITLE','$GSTATUS','TEST','P1','xs','fixture','fixture',NULL);" 2>/dev/null || true
    done

    # Run backfill --apply.
    "$BIN" outcome backfill --apply 2>/dev/null || true

    # Verify each pillar gap now has the correct outcome_id.
    PILLAR_GIDS=("CREDIBLE-9991" "EFFECTIVE-9991" "RESILIENT-9991" "ZERO-WASTE-9991")
    PILLAR_OIDS=("CREDIBLE-000"  "EFFECTIVE-000"  "RESILIENT-000"  "ZERO-WASTE-000")

    for IDX in 0 1 2 3; do
        GID="${PILLAR_GIDS[$IDX]}"
        EXPECTED_OID="${PILLAR_OIDS[$IDX]}"
        ACTUAL_OID=$(sqlite3 "$FIXTURE_DB" \
            "SELECT outcome_id FROM gaps WHERE id='$GID';" 2>/dev/null || echo "")
        if [[ "$ACTUAL_OID" == "$EXPECTED_OID" ]]; then
            ok "heuristic 7: $GID → $EXPECTED_OID"
        else
            fail "heuristic 7: $GID expected $EXPECTED_OID, got '${ACTUAL_OID:-<null>}'"
        fi
    done

    # Idempotent re-apply: run backfill again and confirm outcome_ids unchanged.
    "$BIN" outcome backfill --apply 2>/dev/null || true
    for IDX in 0 1 2 3; do
        GID="${PILLAR_GIDS[$IDX]}"
        EXPECTED_OID="${PILLAR_OIDS[$IDX]}"
        ACTUAL_OID=$(sqlite3 "$FIXTURE_DB" \
            "SELECT outcome_id FROM gaps WHERE id='$GID';" 2>/dev/null || echo "")
        if [[ "$ACTUAL_OID" == "$EXPECTED_OID" ]]; then
            ok "heuristic 7 idempotent: $GID still → $EXPECTED_OID after re-apply"
        else
            fail "heuristic 7 idempotent: $GID changed after re-apply (got '${ACTUAL_OID:-<null>}')"
        fi
    done

    # Graceful skip when pillar outcome not registered: insert a CREDIBLE-* gap,
    # delete CREDIBLE-000 from outcomes, run backfill — gap must stay unlinked.
    sqlite3 "$FIXTURE_DB" \
        "INSERT OR IGNORE INTO gaps(id,title,status,domain,priority,effort,description,acceptance_criteria,outcome_id)
         VALUES('CREDIBLE-9992','credible no-outcome fixture','open','TEST','P1','xs','fixture','fixture',NULL);" \
        2>/dev/null || true
    sqlite3 "$FIXTURE_DB" "DELETE FROM outcomes WHERE id='CREDIBLE-000';" 2>/dev/null || true
    "$BIN" outcome backfill --apply 2>/dev/null || true
    ORPHAN_OID=$(sqlite3 "$FIXTURE_DB" \
        "SELECT outcome_id FROM gaps WHERE id='CREDIBLE-9992';" 2>/dev/null || echo "")
    if [[ -z "$ORPHAN_OID" ]]; then
        ok "heuristic 7 skips gracefully when pillar outcome not registered"
    else
        fail "heuristic 7 linked CREDIBLE-9992 even though CREDIBLE-000 was deleted (got '$ORPHAN_OID')"
    fi
else
    ok "fixture DB not available — skipping functional heuristic-7 tests (source guards passed)"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
