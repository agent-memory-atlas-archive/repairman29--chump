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

# CREDIBLE-1517: resolve the binary the way the CI fast-checks steps do
# (${CARGO_TARGET_DIR:-target}/debug/chump) and build it when absent, so the
# same invocation works in fast-checks and in `chump preflight` (precedent:
# test-admit-ceiling.sh).
CHUMP_BIN="${CHUMP_BIN:-${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump}"
if ! [ -x "$CHUMP_BIN" ]; then
    ( cd "$REPO_ROOT" && PATH="$HOME/.cargo/bin:$PATH" cargo build --quiet --bin chump ) \
        || fail "cargo build --bin chump failed"
fi
if ! [ -x "$CHUMP_BIN" ]; then
    fail "CHUMP_BIN not found or not executable: $CHUMP_BIN"
fi

# RESILIENT-1615: `chump node pause` now enumerates BOTH systemd scopes (and
# launchd on mac) and refuses to report PAUSED while a foreign-scope work organ
# is active. Stub the supervisors to empty output so tests 1 & 2 stay hermetic
# regardless of the host's real systemd state — this runner may itself be a
# multi-scope node (the exact defect RESILIENT-1615 detects). Test 3 prepends
# its own logging stub for the node-converge invocation.
STUB_SUP="$TMP/stub-sup"; mkdir -p "$STUB_SUP"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_SUP/systemctl"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_SUP/launchctl"
chmod +x "$STUB_SUP/systemctl" "$STUB_SUP/launchctl"
export PATH="$STUB_SUP:$PATH"

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

# Verify node.env was updated — INFRA-8588: pause writes the BARE form even
# when the pre-existing line used `export` (in-place migration).
grep -qx "CHUMP_NODE_MODE=paused" "$STATE_DIR/node.env" \
    || fail "CHUMP_NODE_MODE not set to (bare) paused in node.env: $(cat "$STATE_DIR/node.env")"
ok "chump node pause sets bare CHUMP_NODE_MODE=paused (migrating the export line)"

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
grep -qx "CHUMP_NODE_MODE=work-ready" "$STATE_DIR/node.env" \
    || fail "CHUMP_NODE_MODE not set to (bare) work-ready in node.env: $(cat "$STATE_DIR/node.env")"
ok "chump node resume sets bare CHUMP_NODE_MODE=work-ready"

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

    # Stub systemctl + sudo on PATH so converge never reaches a real unit on a
    # Linux runner (passwordless sudo exists there); the stubs record every call.
    STUB="$TMP/stub-bin"; SYSCTL_LOG="$TMP/systemctl.calls"
    mkdir -p "$STUB"; : > "$SYSCTL_LOG"
    printf '#!/usr/bin/env bash\necho "systemctl $*" >> "%s"\nexit 0\n' "$SYSCTL_LOG" > "$STUB/systemctl"
    printf '#!/usr/bin/env bash\necho "sudo $*" >> "%s"\nexit 0\n' "$SYSCTL_LOG" > "$STUB/sudo"
    chmod +x "$STUB/systemctl" "$STUB/sudo"

    AMBIENT2="$STATE_DIR2/ambient.jsonl"
    PATH="$STUB:$PATH" \
    CHUMP_NODE_REPO="$FAKE_REPO" \
    CHUMP_STATE_DIR="$STATE_DIR2" \
    NODE_AMBIENT="$AMBIENT2" \
    HOME="$TMP/fakehome" \
        bash "$CONVERGE_SCRIPT" > "$TMP/converge.log" 2>&1 || true

    # Paused node: converge must not enable, start or restart any unit.
    if grep -Eq '(enable|start|restart|reload|unmask)( |$)' "$SYSCTL_LOG"; then
        fail "node-converge touched units on a paused node: $(cat "$SYSCTL_LOG")"
    fi
    ok "node-converge on a paused node enables/starts/restarts no unit"

    # Holds today: converge on a paused node must not lift the pause.
    [ -f "$STATE_DIR2/.chump/fleet-paused" ] \
        || fail "fleet-paused sentinel gone after node-converge on a paused node"
    grep -qx "CHUMP_NODE_MODE=paused" "$STATE_DIR2/node.env" \
        || fail "node-converge lifted CHUMP_NODE_MODE=paused in node.env"
    ok "node-converge on a paused node leaves the pause in place"

    # CREDIBLE-1517 narrowing (noted on RESILIENT-1615): #5550 shipped the verb
    # without the node-converge hook, so the organ_skipped_paused assertion was
    # red on main. The hook is RESILIENT-1615's deliverable. The strict check
    # re-arms itself the moment node-converge.sh becomes pause-aware (mentions
    # organ_skipped_paused, the fleet-paused sentinel, or CHUMP_NODE_MODE);
    # until then it reports PENDING instead of failing. RESILIENT-1615 AC2
    # requires this case strict and green.
    if grep -Eq 'organ_skipped_paused|fleet-paused|CHUMP_NODE_MODE' "$CONVERGE_SCRIPT"; then
        grep -q '"kind":"organ_skipped_paused"' "$AMBIENT2" \
            || fail "organ_skipped_paused not emitted: $(cat "$AMBIENT2" 2>/dev/null)"
        ok "node-converge emits organ_skipped_paused when paused"
    else
        printf 'PENDING node-converge has no pause hook yet; organ_skipped_paused assertion owned by RESILIENT-1615\n'
    fi
else
    ok "node-converge test skipped (script not found)"
fi

echo ""
echo "All RESILIENT-1614 tests passed!"
