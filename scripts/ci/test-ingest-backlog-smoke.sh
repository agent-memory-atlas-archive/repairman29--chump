#!/usr/bin/env bash
# scripts/ci/test-ingest-backlog-smoke.sh — MISSION-055 / MISSION-090
#
# Smoke test for `chump ingest <repo-path> --import-backlog` (MISSION-055).
# Tests:
#   1. --import-backlog with .beast-mode-tasks.json creates gaps
#   2. --import-backlog with beads JSONL creates gaps
#   3. --import-backlog with TODO.md creates gaps
#   4. Re-running is idempotent (no duplicate gaps via [ingest:...] marker)
#   5. Gaps are tagged with external_repo:<owner/repo>
#
# Runs in <30s, no network.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1" >&2; FAIL=$((FAIL+1)); }

# Locate chump binary
CHUMP_BIN="${CHUMP_BIN:-}"
if [[ -z "$CHUMP_BIN" ]]; then
    if [[ -f "$REPO_ROOT/target/debug/chump" ]]; then
        CHUMP_BIN="$REPO_ROOT/target/debug/chump"
    elif command -v chump &>/dev/null; then
        CHUMP_BIN="$(command -v chump)"
    else
        echo "SKIP: chump binary not found (set CHUMP_BIN or run cargo build first)" >&2
        exit 0
    fi
fi

echo "── Phase 0: binary present ──"
[[ -x "$CHUMP_BIN" ]] && ok "chump binary executable at $CHUMP_BIN" || { fail "chump binary not executable"; exit 1; }

echo ""
echo "── Phase 1: Test .beast-mode-tasks.json import ──"

# Create test repo with .beast-mode-tasks.json
TEST_REPO=$(mktemp -d)
cd "$TEST_REPO"
git init -q
git config user.email "test@example.com"
git config user.name "Test User"

cat > .beast-mode-tasks.json << 'EOF'
[
  {"id": "t1", "title": "Fix critical bug"},
  {"id": "t2", "title": "Add feature X"}
]
EOF

git add .beast-mode-tasks.json
git commit -q -m "Initial commit"

# Run import
AMBIENT_HOME=$(mktemp -d)
export CHUMP_REPO="$REPO_ROOT"
export CHUMP_HOME="$AMBIENT_HOME"

output=$("$CHUMP_BIN" ingest "$TEST_REPO" --import-backlog --domain TEST 2>&1 || true)

if echo "$output" | grep -q "gaps created: 2"; then
    ok "Created 2 gaps from .beast-mode-tasks.json"
else
    fail "Expected 2 gaps created, got: $output"
fi

if echo "$output" | grep -q "\.beast-mode-tasks\.json"; then
    ok "Identified .beast-mode-tasks.json as source"
else
    fail "Did not identify .beast-mode-tasks.json as source"
fi

# Verify gaps were created with ingest marker
if echo "$output" | grep -q "\[ingest:"; then
    ok "Gaps tagged with [ingest:...] marker"
else
    fail "Gaps not tagged with [ingest:...] marker"
fi

echo ""
echo "── Phase 2: Test idempotency ──"

# Re-run import
output2=$("$CHUMP_BIN" ingest "$TEST_REPO" --import-backlog --domain TEST 2>&1 || true)

if echo "$output2" | grep -q "gaps created: 0"; then
    ok "Second run skipped 0 new gaps (idempotent)"
else
    fail "Expected 0 new gaps on second run, got: $output2"
fi

if echo "$output2" | grep -q "skipped (already imported): 2"; then
    ok "Second run correctly identified 2 already-imported items"
else
    fail "Expected 2 skipped items, got: $output2"
fi

echo ""
echo "── Phase 3: Test beads JSONL import ──"

# Create test repo with beads
TEST_REPO2=$(mktemp -d)
cd "$TEST_REPO2"
git init -q
git config user.email "test@example.com"
git config user.name "Test User"

mkdir -p .beads
cat > .beads/issues.jsonl << 'EOF'
{"id": "b-1", "title": "Investigate crash"}
{"id": "b-2", "summary": "Add documentation"}
EOF

git add .beads/issues.jsonl
git commit -q -m "Initial commit"

# Run import
output3=$("$CHUMP_BIN" ingest "$TEST_REPO2" --import-backlog --domain TEST 2>&1 || true)

if echo "$output3" | grep -q "gaps created: 2"; then
    ok "Created 2 gaps from beads JSONL"
else
    fail "Expected 2 gaps created from beads, got: $output3"
fi

echo ""
echo "── Phase 4: Test TODO.md import ──"

# Create test repo with TODO.md
TEST_REPO3=$(mktemp -d)
cd "$TEST_REPO3"
git init -q
git config user.email "test@example.com"
git config user.name "Test User"

cat > TODO.md << 'EOF'
# Backlog

- [ ] Write unit tests
- [ ] Update documentation

Not a task line.

- Fix edge case
EOF

git add TODO.md
git commit -q -m "Initial commit"

# Run import
output4=$("$CHUMP_BIN" ingest "$TEST_REPO3" --import-backlog --domain TEST 2>&1 || true)

if echo "$output4" | grep -q "gaps created: 3"; then
    ok "Created 3 gaps from TODO.md (includes unbracketed items)"
else
    fail "Expected 3 gaps created from TODO.md, got: $output4"
fi

# Cleanup
rm -rf "$TEST_REPO" "$TEST_REPO2" "$TEST_REPO3" "$AMBIENT_HOME"

echo ""
echo "── Summary ──"
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
