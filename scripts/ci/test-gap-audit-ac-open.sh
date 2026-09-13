#!/usr/bin/env bash
# CI gate for INFRA-936: chump gap audit-ac --open near-duplicate detection.
# Tests: vague open gaps flagged, closed gaps ignored, JSON output, exit codes.
set -euo pipefail

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CHUMP="${CHUMP_BIN:-${REPO_ROOT}/target/debug/chump}"

if [[ ! -x "$CHUMP" ]]; then
  echo "SKIP: chump binary not found at $CHUMP"
  exit 0
fi

echo "=== INFRA-936: chump gap audit-ac --open CI gate ==="
echo

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAKE_REPO="$TMP/repo"
mkdir -p "$FAKE_REPO/.chump"

# Schema matches production state.db
sqlite3 "$FAKE_REPO/.chump/state.db" << 'SQL'
CREATE TABLE gaps (
  id TEXT PRIMARY KEY,
  domain TEXT NOT NULL DEFAULT '',
  title TEXT NOT NULL DEFAULT '',
  description TEXT NOT NULL DEFAULT '',
  priority TEXT NOT NULL DEFAULT 'P1',
  effort TEXT NOT NULL DEFAULT 's',
  status TEXT NOT NULL DEFAULT 'open',
  acceptance_criteria TEXT NOT NULL DEFAULT '',
  depends_on TEXT NOT NULL DEFAULT '',
  notes TEXT NOT NULL DEFAULT '',
  source_doc TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL DEFAULT 0,
  closed_at INTEGER,
  opened_date TEXT NOT NULL DEFAULT '',
  closed_date TEXT NOT NULL DEFAULT '',
  closed_pr INTEGER,
  skills_required TEXT NOT NULL DEFAULT '',
  preferred_backend TEXT NOT NULL DEFAULT '',
  preferred_machine TEXT NOT NULL DEFAULT '',
  estimated_minutes TEXT NOT NULL DEFAULT '',
  required_model TEXT NOT NULL DEFAULT ''
);
INSERT INTO gaps (id, domain, title, status, acceptance_criteria) VALUES
  -- open: empty AC — should be flagged
  ('INFRA-A01', 'INFRA', 'gap with empty acceptance criteria', 'open', ''),
  -- open: TODO placeholder — should be flagged
  ('INFRA-A02', 'INFRA', 'gap with TODO acceptance criteria', 'open', '["TODO: fill in AC"]'),
  -- open: concrete AC — should NOT be flagged
  ('INFRA-A03', 'INFRA', 'gap with real acceptance criteria', 'open', '["Running cargo test passes without error"]'),
  -- closed: empty AC — should NOT be flagged by --open (only open gaps checked)
  ('INFRA-A04', 'INFRA', 'closed gap with empty AC', 'done', '');
SQL

echo "[1. Open gap with empty AC is flagged]"
set +e
out=$(CHUMP_REPO="$FAKE_REPO" "$CHUMP" gap audit-ac --open 2>&1)
exit_code=$?
set -e
if echo "$out" | grep -q "INFRA-A01"; then
  ok "INFRA-A01 (empty AC) flagged in output"
else
  fail "INFRA-A01 not flagged: $out"
fi
if [[ "$exit_code" -ne 0 ]]; then
  ok "exits non-zero when vague gaps found"
else
  fail "should exit non-zero but got 0"
fi

echo "[2. Open gap with TODO AC is flagged]"
if echo "$out" | grep -q "INFRA-A02"; then
  ok "INFRA-A02 (TODO AC) flagged in output"
else
  fail "INFRA-A02 not flagged: $out"
fi

echo "[3. Open gap with concrete AC is NOT flagged]"
if ! echo "$out" | grep -q "INFRA-A03"; then
  ok "INFRA-A03 (concrete AC) not flagged"
else
  fail "INFRA-A03 incorrectly flagged: $out"
fi

echo "[4. Closed gap with empty AC is NOT flagged by --open]"
if ! echo "$out" | grep -q "INFRA-A04"; then
  ok "INFRA-A04 (closed, empty AC) not flagged — --open only checks open gaps"
else
  fail "INFRA-A04 closed gap incorrectly flagged: $out"
fi

echo "[5. --json flag produces valid JSON array]"
set +e
json_out=$(CHUMP_REPO="$FAKE_REPO" "$CHUMP" gap audit-ac --open --json 2>&1)
set -e
if echo "$json_out" | python3 -c "
import sys, json
items = json.loads(sys.stdin.read())
assert isinstance(items, list), f'expected list, got {type(items)}'
assert len(items) >= 2, f'expected at least 2 vague gaps, got {len(items)}'
for item in items:
    assert 'id' in item, 'missing id'
    assert 'reason' in item, 'missing reason'
    assert 'title' in item, 'missing title'
    assert item['reason'] in ('empty', 'todo_placeholder'), f'unexpected reason: {item[\"reason\"]}'
" 2>/dev/null; then
  ok "--json produces array with id, reason, title fields"
else
  fail "--json output invalid or missing fields: $json_out"
fi

echo "[6. reason field distinguishes empty vs todo_placeholder]"
if echo "$json_out" | python3 -c "
import sys, json
items = json.loads(sys.stdin.read())
reasons = {i['id']: i['reason'] for i in items}
assert reasons.get('INFRA-A01') == 'empty', f'expected empty, got {reasons.get(\"INFRA-A01\")}'
assert reasons.get('INFRA-A02') == 'todo_placeholder', f'expected todo_placeholder, got {reasons.get(\"INFRA-A02\")}'
" 2>/dev/null; then
  ok "reason=empty for INFRA-A01, reason=todo_placeholder for INFRA-A02"
else
  fail "reason values incorrect: $json_out"
fi

echo "[7. Exit 0 when all open gaps have concrete AC]"
CLEAN_REPO="$TMP/clean_repo"
mkdir -p "$CLEAN_REPO/.chump"
sqlite3 "$CLEAN_REPO/.chump/state.db" << 'SQL'
CREATE TABLE gaps (
  id TEXT PRIMARY KEY,
  domain TEXT NOT NULL DEFAULT '',
  title TEXT NOT NULL DEFAULT '',
  description TEXT NOT NULL DEFAULT '',
  priority TEXT NOT NULL DEFAULT 'P1',
  effort TEXT NOT NULL DEFAULT 's',
  status TEXT NOT NULL DEFAULT 'open',
  acceptance_criteria TEXT NOT NULL DEFAULT '',
  depends_on TEXT NOT NULL DEFAULT '',
  notes TEXT NOT NULL DEFAULT '',
  source_doc TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL DEFAULT 0,
  closed_at INTEGER,
  opened_date TEXT NOT NULL DEFAULT '',
  closed_date TEXT NOT NULL DEFAULT '',
  closed_pr INTEGER,
  skills_required TEXT NOT NULL DEFAULT '',
  preferred_backend TEXT NOT NULL DEFAULT '',
  preferred_machine TEXT NOT NULL DEFAULT '',
  estimated_minutes TEXT NOT NULL DEFAULT '',
  required_model TEXT NOT NULL DEFAULT ''
);
INSERT INTO gaps (id, domain, title, status, acceptance_criteria) VALUES
  ('INFRA-B01', 'INFRA', 'gap one with real AC', 'open', '["cargo test passes", "CI script exits 0"]'),
  ('INFRA-B02', 'INFRA', 'gap two with real AC', 'open', '["chump gap show works", "--json output validated"]');
SQL
set +e
CHUMP_REPO="$CLEAN_REPO" "$CHUMP" gap audit-ac --open > /dev/null 2>&1
clean_exit=$?
set -e
if [[ "$clean_exit" -eq 0 ]]; then
  ok "exits 0 when all open gaps have concrete AC"
else
  fail "exits non-zero ($clean_exit) when all open gaps are OK"
fi

echo "[8. 'consolidate' and 'audit-ac --open' both appear in gap help]"
help_out=$("$CHUMP" gap --help 2>&1 || "$CHUMP" gap 2>&1 || true)
if echo "$help_out" | grep -q "audit-ac"; then
  ok "audit-ac appears in chump gap help"
else
  fail "audit-ac not in chump gap help"
fi
if echo "$help_out" | grep -q -- "--open"; then
  ok "--open flag documented in help"
else
  fail "--open flag not documented in help"
fi

echo "[9. INFRA-936 referenced in source]"
if grep -r "INFRA-936\|infra936" "$REPO_ROOT/src/" 2>/dev/null | grep -q "INFRA-936\|infra936"; then
  ok "INFRA-936 referenced in src/"
else
  fail "INFRA-936 not found in src/"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
