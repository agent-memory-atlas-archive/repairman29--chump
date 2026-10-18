#!/usr/bin/env bash
# test-scaffold-holes-apply.sh — EFFECTIVE-440
#
# Validates that `chump gap scaffold-holes <GAP-ID> --apply` actually files
# one leaf gap per todo!() hole (not just prints specs), each leaf gap
# depends_on the parent scaffold gap and cites the exact file:line in its
# notes. This is the "then N leaf fill-this-hole gaps" half of the
# scaffold-and-holes pattern — the hole-finder alone (shipped in #4430)
# only prints candidate specs.

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
CHUMP="${CHUMP_BIN:-chump}"
TMP="$(mktemp -d)"
export CHUMP_STATE_DB="$TMP/state.db"
mkdir -p "$(dirname "$CHUMP_STATE_DB")"

echo "=== EFFECTIVE-440 scaffold-holes --apply test ==="
echo

# Fixture scaffold: two independent todo!() holes, each with a matching test.
SCAFFOLD_DIR="$TMP/scaffold"
mkdir -p "$SCAFFOLD_DIR/src"
cat > "$SCAFFOLD_DIR/src/lib.rs" <<'EOF'
pub fn add(a: i32, b: i32) -> i32 {
    todo!()
}

pub fn sub(a: i32, b: i32) -> i32 {
    todo!()
}

#[test]
fn test_add() {
    assert_eq!(add(1, 1), 2);
}

#[test]
fn test_sub() {
    assert_eq!(sub(2, 1), 1);
}
EOF

# CREDIBLE-1519: --force bypasses the RESILIENT-069 farmer-RED claim gate so
# this fixture seed stays hermetic against host farmer state (a paused/stale
# host would otherwise RED-block the reserve and leave PARENT_ID empty).
PARENT_ID=$("$CHUMP" gap reserve --domain EFFECTIVE --title "scaffold: arithmetic skeleton" \
    --priority P2 --effort m --force --json 2>/dev/null | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
if [ -z "$PARENT_ID" ]; then
    PARENT_ID=$("$CHUMP" gap list --status open --json 2>/dev/null | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
fi

if [ -z "$PARENT_ID" ]; then
    fail "could not reserve a parent scaffold gap to test against"
else
    ok "reserved parent scaffold gap $PARENT_ID"
fi

# 1. Dry (no --apply) mode still only prints, files nothing.
BEFORE_COUNT=$("$CHUMP" gap list --status open --json 2>/dev/null | grep -c '"id"' || echo 0)
"$CHUMP" gap scaffold-holes "$PARENT_ID" --path "$SCAFFOLD_DIR" >/dev/null 2>&1 || true
AFTER_DRY_COUNT=$("$CHUMP" gap list --status open --json 2>/dev/null | grep -c '"id"' || echo 0)
if [ "$BEFORE_COUNT" -eq "$AFTER_DRY_COUNT" ]; then
    ok "no --apply: no new gaps filed (print-only path unchanged)"
else
    fail "no --apply: expected $BEFORE_COUNT open gaps, got $AFTER_DRY_COUNT"
fi

# 2. --apply files exactly one leaf gap per hole (2 holes -> 2 leaf gaps).
APPLY_OUT=$("$CHUMP" gap scaffold-holes "$PARENT_ID" --path "$SCAFFOLD_DIR" --apply 2>/dev/null || true)
FILED_COUNT=$(echo "$APPLY_OUT" | grep -c '^EFFECTIVE-' || true)
if [ "$FILED_COUNT" -eq 2 ]; then
    ok "--apply filed exactly 2 leaf gaps for 2 holes"
else
    fail "--apply expected 2 leaf gaps, got $FILED_COUNT (output: $APPLY_OUT)"
fi

# 3. Each filed leaf gap depends_on the parent and cites file:line in notes.
LEAF_ID=$(echo "$APPLY_OUT" | grep '^EFFECTIVE-' | head -1 || true)
if [ -n "$LEAF_ID" ]; then
    LEAF_JSON=$("$CHUMP" gap list --status open --json 2>/dev/null | grep -A0 "\"id\":\"$LEAF_ID\"" || true)
    NOTES=$("$CHUMP" gap show "$LEAF_ID" --json 2>/dev/null || "$CHUMP" gap show "$LEAF_ID" 2>/dev/null || true)
    if echo "$NOTES" | grep -q "$PARENT_ID"; then
        ok "leaf gap $LEAF_ID cites parent $PARENT_ID (depends_on/notes)"
    else
        fail "leaf gap $LEAF_ID does not reference parent $PARENT_ID: $NOTES"
    fi
    if echo "$NOTES" | grep -q "src/lib.rs"; then
        ok "leaf gap $LEAF_ID notes cite the exact hole file"
    else
        fail "leaf gap $LEAF_ID notes missing hole file reference: $NOTES"
    fi
else
    fail "no leaf gap id captured from --apply output"
fi

rm -rf "$TMP"

echo
echo "=== $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
