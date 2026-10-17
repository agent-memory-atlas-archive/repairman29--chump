#!/usr/bin/env bash
# test-gap-doctor-safe-sweep.sh — INFRA-308 regression test.
#
# Verifies scripts/coord/gap-doctor.py safe-sweep:
#   1. Dry-run never mutates state.db or YAMLs
#   2. Real run auto-fixes Bucket 1 (DB done / YAML open) by regen YAML
#   3. Bucket 2 (DB open / YAML done) goes ONLY through the single writer
#      (PHASE-R R1, CREDIBLE-1491): gap-doctor shells `chump gap ship <ID>
#      --closed-pr <N>` and never writes gaps.status itself. A refusal from
#      the writer leaves the row open and is reported loudly with the
#      writer's reason; it is not counted as auto-fixed.
#   4. Bucket 3 (DB-only orphans) emits ALERT to ambient.jsonl
#   5. Bucket 4 (YAML-only) emits ALERT to ambient.jsonl
#
# Strategy: create a temp git repo with a fake state.db + fake docs/gaps/
# tree containing each bucket case, run safe-sweep, assert outcomes.
# Avoids touching the real repo's state.db.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/scripts/coord/gap-doctor.py"

if [[ ! -f "$SCRIPT" ]]; then
    echo "[FAIL] gap-doctor.py not found at $SCRIPT"
    exit 1
fi

TMP="$(cd "$(mktemp -d)" && pwd -P)"
# Stub `chump` binaries live OUTSIDE the fixture repo. They stand in for the
# single writer so the test proves what gap-doctor CALLS, never what a real
# binary happens to do to a throwaway DB. Each records its argv.
STUBS="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP" "$STUBS"' EXIT
STUB_LOG="$STUBS/chump-calls.log"
: > "$STUB_LOG"
mkdir -p "$STUBS/refuse" "$STUBS/accept"
cat > "$STUBS/refuse/chump" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$STUB_LOG"
echo "refused: R1 single writer found no merged receipt for closed_pr" >&2
exit 1
STUB
cat > "$STUBS/accept/chump" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$STUB_LOG"
exit 0
STUB
chmod +x "$STUBS/refuse/chump" "$STUBS/accept/chump"
BASE_PATH="$PATH"

cd "$TMP"
git init -q -b main
git config user.email "test@chump.local"
git config user.name "Chump Test"
mkdir -p docs/gaps .chump scripts/coord
cp "$SCRIPT" scripts/coord/gap-doctor.py

# Create a minimal SQLite state.db schema mirroring gap_store.rs.
sqlite3 .chump/state.db <<'SQL'
CREATE TABLE gaps (
  id TEXT PRIMARY KEY,
  domain TEXT,
  title TEXT,
  description TEXT,
  priority TEXT,
  effort TEXT,
  status TEXT,
  acceptance_criteria TEXT,
  depends_on TEXT,
  notes TEXT,
  source_doc TEXT,
  created_at INTEGER,
  closed_at INTEGER,
  opened_date TEXT,
  closed_date TEXT,
  closed_pr INTEGER
);
SQL

# Helper: insert a row
db_insert() {
    sqlite3 .chump/state.db "INSERT INTO gaps (id, domain, title, status, priority, effort, created_at) VALUES ('$1', 'INFRA', 'test', '$2', 'P2', 's', strftime('%s','now'));"
}

# Helper: write a YAML file
yaml_write() {
    cat > "docs/gaps/$1.yaml" <<EOF
- id: $1
  domain: INFRA
  title: test
  status: $2
  priority: P2
  effort: s
EOF
}

# Bucket 1 (DB done / YAML open): create both, DB says done, YAML says open
db_insert "INFRA-B1" "done"
yaml_write "INFRA-B1" "open"

# Bucket 2 (DB open / YAML done): create both, DB says open, YAML says done
# with a closed_pr receipt that must be forwarded to the single writer.
db_insert "INFRA-B2" "open"
yaml_write "INFRA-B2" "done"
echo "  closed_pr: 4242" >> docs/gaps/INFRA-B2.yaml

# Bucket 3 (DB-only): row in DB, NO YAML file
db_insert "INFRA-B3" "open"

# Bucket 4 (YAML-only): YAML file, NO DB row
yaml_write "INFRA-B4" "open"

git add -A && git commit -qm "fixture"

# ── Test 1: dry-run does not mutate ──────────────────────────────────────────
echo "Test 1: --dry-run leaves state untouched"
DB_BEFORE=$(sqlite3 .chump/state.db "SELECT id, status FROM gaps ORDER BY id;")
YAML_BEFORE=$(cat docs/gaps/*.yaml)
PATH="$STUBS/refuse:$BASE_PATH" python3 scripts/coord/gap-doctor.py safe-sweep --dry-run >/tmp/sweep-dry.out 2>&1
DB_AFTER=$(sqlite3 .chump/state.db "SELECT id, status FROM gaps ORDER BY id;")
YAML_AFTER=$(cat docs/gaps/*.yaml)
[[ "$DB_BEFORE" == "$DB_AFTER" ]] || { echo "[FAIL] dry-run mutated state.db"; exit 1; }
[[ "$YAML_BEFORE" == "$YAML_AFTER" ]] || { echo "[FAIL] dry-run mutated YAML"; exit 1; }
[[ ! -s "$STUB_LOG" ]] || { echo "[FAIL] dry-run invoked the single writer: $(cat "$STUB_LOG")"; exit 1; }
echo "[PASS] --dry-run is read-only"

# ── Test 2: real safe-sweep auto-fixes Bucket 1 + 2 ──────────────────────────
echo ""
echo "Test 2: real safe-sweep fixes Bucket 1; Bucket 2 refused by the single writer stays open"
# INFRA-343 diagnostic: previous version silently dropped stderr on
# python failure (set -e killed script before assertions printed).
# Now we capture rc + always cat output if non-zero so CI failures
# are diagnosable from the workflow log. (Diagnostic was independently
# arrived at by another agent; merged here together with the actual
# bug fix in scripts/coord/gap-doctor.py — INFRA-308 chump-binary
# FileNotFoundError on CI runners.)
set +e
PATH="$STUBS/refuse:$BASE_PATH" python3 scripts/coord/gap-doctor.py safe-sweep >/tmp/sweep-real.out 2>&1
SWEEP_RC=$?
set -e
if [[ $SWEEP_RC -ne 0 ]]; then
    echo "[FAIL] safe-sweep returned non-zero ($SWEEP_RC); python output follows:"
    echo "--- stdout/stderr ---"
    cat /tmp/sweep-real.out
    echo "--- env diagnostics ---"
    python3 --version
    python3 -c "import yaml; print(f'PyYAML: {yaml.__version__}')" 2>&1 || echo "yaml import failed"
    python3 -c "import sqlite3; print(f'sqlite: {sqlite3.sqlite_version}')" 2>&1 || true
    sqlite3 .chump/state.db "SELECT id, status FROM gaps;" 2>&1 || true
    ls -la docs/gaps/ 2>&1 || true
    exit 1
fi

# Bucket 1: YAML should now say done (regenerated from DB)
B1_YAML=$(grep "^  status:" docs/gaps/INFRA-B1.yaml | awk '{print $2}')
[[ "$B1_YAML" == "done" ]] || { echo "[FAIL] Bucket 1: YAML status=$B1_YAML expected done"; cat /tmp/sweep-real.out; exit 1; }
echo "[PASS] Bucket 1: YAML synced from DB (now done)"

# Bucket 2 (R1): the flip went through the single writer with the receipt...
grep -qx "gap ship INFRA-B2 --closed-pr 4242" "$STUB_LOG" \
    || { echo "[FAIL] Bucket 2: gap-doctor did not call 'chump gap ship INFRA-B2 --closed-pr 4242'; calls: $(cat "$STUB_LOG")"; cat /tmp/sweep-real.out; exit 1; }
echo "[PASS] Bucket 2: routed through the single writer (chump gap ship INFRA-B2 --closed-pr 4242)"
# ...the writer refused, and gap-doctor did NOT write around it.
B2_DB=$(sqlite3 .chump/state.db "SELECT status FROM gaps WHERE id = 'INFRA-B2';")
[[ "$B2_DB" == "open" ]] || { echo "[FAIL] Bucket 2: DB status=$B2_DB after a refused ship; gap-doctor wrote around the single writer"; cat /tmp/sweep-real.out; exit 1; }
echo "[PASS] Bucket 2: refused ship left the row open (no direct status write)"
# ...and the refusal is loud, with the writer's own reason, not counted as fixed.
grep -q "applied: 0 rows, refused: 1" /tmp/sweep-real.out \
    || { echo "[FAIL] Bucket 2: refusal not counted"; cat /tmp/sweep-real.out; exit 1; }
grep -q "REFUSED INFRA-B2: .*no merged receipt for closed_pr" /tmp/sweep-real.out \
    || { echo "[FAIL] Bucket 2: refusal reason from the single writer not surfaced"; cat /tmp/sweep-real.out; exit 1; }
grep -q "auto-fixed: 1, refused-by-single-writer: 1" /tmp/sweep-real.out \
    || { echo "[FAIL] safe-sweep summary counts a refused row as auto-fixed"; cat /tmp/sweep-real.out; exit 1; }
echo "[PASS] Bucket 2: refusal reported with the writer's reason; summary does not count it as fixed"

# ── Test 2b: an accepting single writer gets exactly one call, no side write ─
echo ""
echo "Test 2b: accepted ship is one call to the single writer; gap-doctor writes nothing itself"
: > "$STUB_LOG"
set +e
PATH="$STUBS/accept:$BASE_PATH" python3 scripts/coord/gap-doctor.py sync-from-yaml --apply >/tmp/sweep-accept.out 2>&1
ACCEPT_RC=$?
set -e
[[ $ACCEPT_RC -eq 0 ]] || { echo "[FAIL] sync-from-yaml --apply rc=$ACCEPT_RC"; cat /tmp/sweep-accept.out; exit 1; }
CALLS=$(wc -l < "$STUB_LOG" | tr -d ' ')
[[ "$CALLS" == "1" ]] || { echo "[FAIL] expected exactly 1 single-writer call, got $CALLS: $(cat "$STUB_LOG")"; exit 1; }
grep -qx "gap ship INFRA-B2 --closed-pr 4242" "$STUB_LOG" \
    || { echo "[FAIL] accepted path called: $(cat "$STUB_LOG")"; exit 1; }
grep -q "applied: 1 rows, refused: 0" /tmp/sweep-accept.out \
    || { echo "[FAIL] accepted ship not reported as applied"; cat /tmp/sweep-accept.out; exit 1; }
# The stub writer persists nothing, so a status change here could only come
# from gap-doctor writing the DB itself.
B2_DB=$(sqlite3 .chump/state.db "SELECT status FROM gaps WHERE id = 'INFRA-B2';")
[[ "$B2_DB" == "open" ]] || { echo "[FAIL] gap-doctor wrote gaps.status itself (status=$B2_DB)"; exit 1; }
echo "[PASS] accepted ship: one 'chump gap ship' call with receipt, zero direct status writes"

# ── Test 3: Bucket 3 + 4 emit ALERT events to ambient.jsonl ──────────────────
echo ""
echo "Test 3: Bucket 3 + 4 emit ALERT events to ambient.jsonl"
AMBIENT=".chump-locks/ambient.jsonl"
[[ -f "$AMBIENT" ]] || { echo "[FAIL] ambient.jsonl not created at $AMBIENT"; exit 1; }
ORPHAN_ALERT=$(grep '"kind":"gap_drift_orphan"' "$AMBIENT" | head -1 || true)
YAML_ONLY_ALERT=$(grep '"kind":"gap_drift_yaml_only"' "$AMBIENT" | head -1 || true)
[[ -n "$ORPHAN_ALERT" ]] || { echo "[FAIL] no gap_drift_orphan ALERT in ambient.jsonl"; exit 1; }
[[ -n "$YAML_ONLY_ALERT" ]] || { echo "[FAIL] no gap_drift_yaml_only ALERT in ambient.jsonl"; exit 1; }
echo "$ORPHAN_ALERT" | grep -q "INFRA-B3" || { echo "[FAIL] orphan ALERT missing INFRA-B3"; exit 1; }
echo "$YAML_ONLY_ALERT" | grep -q "INFRA-B4" || { echo "[FAIL] yaml-only ALERT missing INFRA-B4"; exit 1; }
echo "[PASS] gap_drift_orphan ALERT names INFRA-B3"
echo "[PASS] gap_drift_yaml_only ALERT names INFRA-B4"

# ── Test 4: idempotent — second run finds 0 of each (Bucket 1+2 fixed) ─────
echo ""
echo "Test 4: second run is idempotent (Bucket 1 stays fixed; refused Bucket 2 stays reported)"
PATH="$STUBS/refuse:$BASE_PATH" python3 scripts/coord/gap-doctor.py safe-sweep >/tmp/sweep-2nd.out 2>&1
B1_SECOND=$(grep "Bucket 1" /tmp/sweep-2nd.out | grep -oE '[0-9]+ →' | grep -oE '[0-9]+')
B2_SECOND=$(grep "Bucket 2" /tmp/sweep-2nd.out | grep -oE '[0-9]+ →' | grep -oE '[0-9]+')
[[ "$B1_SECOND" == "0" ]] || { echo "[FAIL] Bucket 1 still has $B1_SECOND drifts after first sweep"; exit 1; }
# R1: a row the single writer refused is still drift, and still reported.
[[ "$B2_SECOND" == "1" ]] || { echo "[FAIL] Bucket 2 has $B2_SECOND drifts; expected the 1 refused row to remain open"; exit 1; }
grep -q "refused-by-single-writer: 1" /tmp/sweep-2nd.out || { echo "[FAIL] second sweep did not re-report the refusal"; cat /tmp/sweep-2nd.out; exit 1; }
echo "[PASS] safe-sweep is idempotent (Bucket 1 stays 0; refused Bucket 2 stays open and reported)"

# ── Test 5: CREDIBLE-012 — done DB-only gaps do NOT trigger alert ────────────
# Pre-rescope, every done/superseded gap in state.db without a YAML mirror
# triggered the gap_drift_orphan alert — 92% noise. CREDIBLE-012 rescoped
# the alert to OPEN gaps only. This test seeds a done DB-only gap and
# asserts no new alert fires for it.
echo ""
echo "Test 5: CREDIBLE-012 — done DB-only gaps do not trigger gap_drift_orphan alert"
db_insert "INFRA-B5-DONE" "done"
# Rotate ambient log so the prior INFRA-B3 alert from Test 3 isn't counted.
> "$AMBIENT"
PATH="$STUBS/refuse:$BASE_PATH" python3 scripts/coord/gap-doctor.py safe-sweep >/tmp/sweep-credible012.out 2>&1
DONE_ALERT=$(grep '"kind":"gap_drift_orphan"' "$AMBIENT" | grep "INFRA-B5-DONE" || true)
if [[ -n "$DONE_ALERT" ]]; then
    echo "[FAIL] CREDIBLE-012 regression: done DB-only gap INFRA-B5-DONE triggered alert: $DONE_ALERT"
    exit 1
fi
echo "[PASS] CREDIBLE-012: done DB-only gap correctly suppressed from alert"

# Also verify the print summary distinguishes total from open.
if ! grep -qE "Bucket 3 \(DB-only orphans\).*[0-9]+ total / [0-9]+ OPEN" /tmp/sweep-credible012.out; then
    echo "[FAIL] CREDIBLE-012: print summary missing 'total / OPEN' breakdown"
    cat /tmp/sweep-credible012.out
    exit 1
fi
echo "[PASS] CREDIBLE-012: print summary distinguishes total vs OPEN"

echo ""
echo "[OK] all INFRA-308 safe-sweep cases passed (incl. CREDIBLE-012 rescope, PHASE-R R1 single writer)"
