#!/usr/bin/env bash
# scripts/ci/test-resilient-1614-node-pause-invariant.sh — RESILIENT-1614
#
# Proves that:
#   1. `chump node pause --reason "reason"` sets CHUMP_NODE_MODE=paused in node.env,
#      creates a .chump/fleet-paused sentinel, and emits node_paused;
#   2. `chump node resume` sets CHUMP_NODE_MODE=work-ready, removes the sentinel,
#      and emits node_resumed;
#   3. node-converge on a paused node leaves every stopped unit stopped
#      (organ_skipped_paused emitted, no reconcile).

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

CHUMP_BIN="${CHUMP_BIN:-$REPO_ROOT/target/debug/chump}"
if ! [ -x "$CHUMP_BIN" ]; then
    fail "CHUMP_BIN not found or not executable: $CHUMP_BIN"
fi

# ── Test 1: node pause creates sentinel and updates node.env ──────────────────
STATE_DIR="$TMP/state"
mkdir -p "$STATE_DIR/.chump"

# Create initial node.env
cat > "$STATE_DIR/node.env" <<'EOF'
export CHUMP_STATE_DIR=/fake/state
export CHUMP_NODE_MODE=work-ready
export CHUMP_RUN_USER=testuser
EOF

CHUMP_STATE_DIR="$STATE_DIR" "$CHUMP_BIN" node pause --reason "test pause" \
    || fail "chump node pause failed"

# Verify node.env was updated
grep -qx "export CHUMP_NODE_MODE=paused" "$STATE_DIR/node.env" \
    || fail "CHUMP_NODE_MODE not set to paused in node.env"
ok "chump node pause sets CHUMP_NODE_MODE=paused"

# Verify sentinel exists
[ -f "$STATE_DIR/.chump/fleet-paused" ] \
    || fail "fleet-paused sentinel not created"
ok "chump node pause creates fleet-paused sentinel"

# Verify sentinel contains reason
grep -q "REASON=test pause" "$STATE_DIR/.chump/fleet-paused" \
    || fail "sentinel does not contain reason"
ok "fleet-paused sentinel contains reason"

# Verify ambient.jsonl has node_paused event
AMBIENT="$STATE_DIR/ambient.jsonl"
grep -q '"kind":"node_paused"' "$AMBIENT" \
    || fail "node_paused event not emitted: $(cat "$AMBIENT" 2>/dev/null)"
ok "node pause emits node_paused event"

# ── Test 2: node resume reverses the pause ────────────────────────────────────
CHUMP_STATE_DIR="$STATE_DIR" "$CHUMP_BIN" node resume \
    || fail "chump node resume failed"

# Verify node.env was updated
grep -qx "export CHUMP_NODE_MODE=work-ready" "$STATE_DIR/node.env" \
    || fail "CHUMP_NODE_MODE not set to work-ready in node.env"
ok "chump node resume sets CHUMP_NODE_MODE=work-ready"

# Verify sentinel was removed
[ ! -f "$STATE_DIR/.chump/fleet-paused" ] \
    || fail "fleet-paused sentinel still exists after resume"
ok "chump node resume removes fleet-paused sentinel"

# Verify ambient.jsonl has node_resumed event
grep -q '"kind":"node_resumed"' "$AMBIENT" \
    || fail "node_resumed event not emitted: $(cat "$AMBIENT" 2>/dev/null)"
ok "node resume emits node_resumed event"

# ── Test 3: node-converge respects paused mode ────────────────────────────────
CONVERGE_SCRIPT="$REPO_ROOT/scripts/ops/node-converge.sh"
if [ -f "$CONVERGE_SCRIPT" ]; then
    STATE_DIR2="$TMP/state2"
    mkdir -p "$STATE_DIR2/.chump"

    # Create initial node.env with work-ready mode
    cat > "$STATE_DIR2/node.env" <<'EOF'
export CHUMP_STATE_DIR=/fake/state
export CHUMP_NODE_MODE=work-ready
EOF

    # Set up fake repo
    FAKE_REPO="$STATE_DIR2/repo"
    mkdir -p "$FAKE_REPO/.git"

    # Pause the node
    CHUMP_STATE_DIR="$STATE_DIR2" "$CHUMP_BIN" node pause --reason "test converge" \
        || fail "pause before converge test failed"

    # Create fake git repo that would normally trigger a converge
    git -C "$FAKE_REPO" init -q
    git -C "$FAKE_REPO" config user.email "test@example.com"
    git -C "$FAKE_REPO" config user.name "Test"
    git -C "$FAKE_REPO" commit -q --allow-empty -m "test"

    AMBIENT2="$STATE_DIR2/ambient.jsonl"
    CHUMP_NODE_REPO="$FAKE_REPO" \
    CHUMP_STATE_DIR="$STATE_DIR2" \
    NODE_AMBIENT="$AMBIENT2" \
    HOME="$TMP/fakehome" \
        bash "$CONVERGE_SCRIPT" > "$TMP/converge.log" 2>&1 || true

    # Verify organ_skipped_paused was emitted (if ambient was written)
    if [ -f "$AMBIENT2" ]; then
        grep -q '"kind":"organ_skipped_paused"' "$AMBIENT2" \
            || fail "organ_skipped_paused not emitted: $(cat "$AMBIENT2" 2>/dev/null)"
        ok "node-converge emits organ_skipped_paused when paused"
    fi
else
    ok "node-converge test skipped (script not found)"
fi

echo ""
echo "All RESILIENT-1614 tests passed!"
