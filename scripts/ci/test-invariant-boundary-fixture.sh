#!/usr/bin/env bash
# test-invariant-boundary-fixture.sh — INFRA-8218 AC #3
#
# Synthetic fixture test: prove that
#   (a) a new sqlite3 UPDATE in a scratch script is flagged
#   (b) an allowlisted file is not flagged
#   (c) mode=enforce works correctly

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_SCRIPT="$REPO_ROOT/scripts/ci/test-invariant-boundary.sh"
ALLOWLIST_FILE="$REPO_ROOT/scripts/ci/invariant-boundary-allowlist.txt"

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== INFRA-8218 Invariant-boundary fixture test ==="
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Test (a): New script with sqlite3 UPDATE is flagged in shadow mode
# ─────────────────────────────────────────────────────────────────────────────
echo "Test (a): New script with sqlite3 UPDATE is flagged"
TMP_A="$(mktemp -d)"
mkdir -p "$TMP_A/scripts/test-scripts"

# Create a scratch script that violates the boundary
cat > "$TMP_A/scripts/test-scripts/bad-script.sh" << 'EOF'
#!/bin/bash
# This script violates the boundary by writing directly to state.db
sqlite3 ~/.chump/state.db "UPDATE gaps SET status='done' WHERE id='TEST-001'" 2>/dev/null || true
EOF

# Temporarily copy the test script and allowlist to the temp dir
cp "$TEST_SCRIPT" "$TMP_A/test-invariant-boundary.sh"
cp "$ALLOWLIST_FILE" "$TMP_A/invariant-boundary-allowlist.txt"

# Patch the script to use temp paths
sed -i.bak 's|REPO_ROOT="$(cd.*|REPO_ROOT="'"$TMP_A"'"|' "$TMP_A/test-invariant-boundary.sh"
sed -i.bak 's|ALLOWLIST_FILE=.*|ALLOWLIST_FILE="'"$TMP_A"'/invariant-boundary-allowlist.txt"|' "$TMP_A/test-invariant-boundary.sh"

# Run in shadow mode and check that bad-script.sh is detected
output="$(CHUMP_BOUNDARY_GATE=shadow bash "$TMP_A/test-invariant-boundary.sh" 2>&1)"
if echo "$output" | grep -q "bad-script.sh"; then
    ok "(a) New script with sqlite3 UPDATE flagged in shadow mode"
else
    fail "(a) Bad script not flagged (expected to see 'bad-script.sh' in output)"
    echo "$output" | head -20
fi

rm -rf "$TMP_A"

# ─────────────────────────────────────────────────────────────────────────────
# Test (b): Allowlisted file does not appear as violation in enforce mode
# ─────────────────────────────────────────────────────────────────────────────
echo "Test (b): Allowlisted file is not flagged in enforce mode"

# Check that bot-merge.sh is in the allowlist
if grep -q "^bot-merge.sh$" "$ALLOWLIST_FILE"; then
    ok "(b) bot-merge.sh is in allowlist"
else
    fail "(b) bot-merge.sh not found in allowlist"
fi

# Run enforce mode and verify it exits 0 (no violations)
if CHUMP_BOUNDARY_GATE=enforce bash "$TEST_SCRIPT" > /dev/null 2>&1; then
    ok "(b) Enforce mode exits 0 for all allowlisted files"
else
    fail "(b) Enforce mode exited non-zero"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test (c): Enforce mode detects unapproved violators
# ─────────────────────────────────────────────────────────────────────────────
echo "Test (c): Enforce mode detects unapproved violators"
TMP_C="$(mktemp -d)"
mkdir -p "$TMP_C/scripts/test-scripts"

# Create a bad script that's NOT in the allowlist
cat > "$TMP_C/scripts/test-scripts/unauthorized-writer.sh" << 'EOF'
#!/bin/bash
# This script is not allowlisted
sqlite3 ~/.chump/state.db "INSERT INTO gaps (id, status) VALUES ('TEST', 'open')" 2>/dev/null || true
EOF

# Copy and patch the test script and use empty allowlist
cp "$TEST_SCRIPT" "$TMP_C/test-invariant-boundary.sh"
echo "# Empty allowlist for this test" > "$TMP_C/invariant-boundary-allowlist.txt"

sed -i.bak 's|REPO_ROOT="$(cd.*|REPO_ROOT="'"$TMP_C"'"|' "$TMP_C/test-invariant-boundary.sh"
sed -i.bak 's|ALLOWLIST_FILE=.*|ALLOWLIST_FILE="'"$TMP_C"'/invariant-boundary-allowlist.txt"|' "$TMP_C/test-invariant-boundary.sh"

# Run in enforce mode and check that it exits 1
if ! CHUMP_BOUNDARY_GATE=enforce bash "$TMP_C/test-invariant-boundary.sh" > /dev/null 2>&1; then
    ok "(c) Enforce mode exits 1 for unapproved violators"
else
    fail "(c) Enforce mode did not exit 1 for unapproved violators"
fi

rm -rf "$TMP_C"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
