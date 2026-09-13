#!/usr/bin/env bash
# scripts/ci/test-apex-watchdog.sh — RESILIENT-1098
#
# Proves the apex watchdog-of-the-watchdog is a node-external cross-node
# check, not the operator session: given a peer that fails its health probe
# for CHUMP_APEX_WATCHDOG_MISS_THRESHOLD consecutive cycles, it must emit
# kind=node_unreachable with no human step. Given a peer that then recovers,
# it must emit kind=node_reachable_again. Every cycle, healthy or not, it
# must emit the kind=apex_watchdog_tick heartbeat proving the watchdog itself
# is alive — this test fails without RESILIENT-1098's script.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

WATCHDOG="$REPO_ROOT/scripts/ops/apex-watchdog.sh"

pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; exit 1; }

echo "=== test-apex-watchdog.sh (RESILIENT-1098) ==="

# ── 1. Source contract ───────────────────────────────────────────────────────
[[ -f "$WATCHDOG" ]] || fail "watchdog script missing: $WATCHDOG"
[[ -x "$WATCHDOG" ]] || fail "watchdog script not executable: $WATCHDOG"
bash -n "$WATCHDOG" || fail "watchdog bash -n failed"
for unit in service timer; do
    f="$REPO_ROOT/scripts/dispatch/chump-apex-watchdog.$unit"
    [[ -f "$f" ]] || fail "missing $f"
done
grep -q 'chump-apex-watchdog.timer' "$REPO_ROOT/scripts/setup/install-helsinki-atc.sh" \
    || fail "chump-apex-watchdog.timer not wired into install-helsinki-atc.sh roster"
grep -q 'chump-apex-watchdog.timer' "$REPO_ROOT/scripts/ops/organ-manifest.txt" \
    || fail "chump-apex-watchdog.timer not declared in organ-manifest.txt (RESILIENT-366 roll-call would fail)"
pass "script + unit files + roster wiring present, syntax clean"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

NODES_DIR="$TMP/nodes"
mkdir -p "$NODES_DIR"
cat > "$NODES_DIR/self.json" <<'EOF'
{"node_id": "self", "tailnet_ip": "10.0.0.1"}
EOF
cat > "$NODES_DIR/peer-a.json" <<'EOF'
{"node_id": "peer-a", "tailnet_ip": "10.0.0.2"}
EOF

# ── 2. Peer unreachable: must NOT page before the miss threshold ───────────
DOWN_CURL="$TMP/curl-down"
cat > "$DOWN_CURL" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
chmod +x "$DOWN_CURL"

STATE_DIR="$TMP/state"
AMB="$TMP/ambient.jsonl"
: > "$AMB"

for i in 1 2; do
    CHUMP_APEX_WATCHDOG_NODES_DIR="$NODES_DIR" \
    CHUMP_APEX_WATCHDOG_SELF="self" \
    CHUMP_APEX_WATCHDOG_CURL_BIN="$DOWN_CURL" \
    CHUMP_APEX_WATCHDOG_STATE_DIR="$STATE_DIR" \
    CHUMP_APEX_WATCHDOG_MISS_THRESHOLD=3 \
    CHUMP_AMBIENT_LOG="$AMB" \
    "$WATCHDOG" >/dev/null 2>&1
    rc=$?
    [[ "$rc" -eq 0 ]] || fail "watchdog exited $rc on cycle $i"
done
grep -q '"kind":"node_unreachable"' "$AMB" \
    && fail "must NOT page before miss threshold is crossed (2 misses < threshold 3); ambient: $(cat "$AMB")"
pass "sub-threshold misses do not page (flap protection)"

# ── 3. Third consecutive miss crosses threshold: must page, no human step ──
CHUMP_APEX_WATCHDOG_NODES_DIR="$NODES_DIR" \
CHUMP_APEX_WATCHDOG_SELF="self" \
CHUMP_APEX_WATCHDOG_CURL_BIN="$DOWN_CURL" \
CHUMP_APEX_WATCHDOG_STATE_DIR="$STATE_DIR" \
CHUMP_APEX_WATCHDOG_MISS_THRESHOLD=3 \
CHUMP_AMBIENT_LOG="$AMB" \
"$WATCHDOG" >/dev/null 2>&1
rc=$?
[[ "$rc" -eq 0 ]] || fail "watchdog exited $rc on the paging cycle"
grep -q '"kind":"node_unreachable"' "$AMB" \
    || fail "expected node_unreachable after 3 consecutive misses; ambient: $(cat "$AMB")"
grep -q '"peer":"peer-a"' "$AMB" \
    || fail "expected peer field naming the unreachable node; ambient: $(cat "$AMB")"
grep -q '"consecutive_misses":"3"' "$AMB" \
    || fail "expected consecutive_misses=3; ambient: $(cat "$AMB")"
pass "3rd consecutive miss pages node_unreachable with no human step"

# ── 4. Peer recovers: must emit node_reachable_again and stop paging ───────
UP_CURL="$TMP/curl-up"
cat > "$UP_CURL" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$UP_CURL"

AMB2="$TMP/ambient2.jsonl"
: > "$AMB2"
CHUMP_APEX_WATCHDOG_NODES_DIR="$NODES_DIR" \
CHUMP_APEX_WATCHDOG_SELF="self" \
CHUMP_APEX_WATCHDOG_CURL_BIN="$UP_CURL" \
CHUMP_APEX_WATCHDOG_STATE_DIR="$STATE_DIR" \
CHUMP_APEX_WATCHDOG_MISS_THRESHOLD=3 \
CHUMP_AMBIENT_LOG="$AMB2" \
"$WATCHDOG" >/dev/null 2>&1
rc=$?
[[ "$rc" -eq 0 ]] || fail "watchdog exited $rc on the recovery cycle"
grep -q '"kind":"node_reachable_again"' "$AMB2" \
    || fail "expected node_reachable_again after recovery; ambient: $(cat "$AMB2")"
pass "peer recovery emits node_reachable_again"

# ── 5. Heartbeat: apex_watchdog_tick emitted every cycle (self-observable) ──
grep -q '"kind":"apex_watchdog_tick"' "$AMB2" \
    || fail "expected apex_watchdog_tick heartbeat; ambient: $(cat "$AMB2")"
grep -q '"self":"self"' "$AMB2" \
    || fail "expected self field in heartbeat; ambient: $(cat "$AMB2")"
pass "apex_watchdog_tick heartbeat emitted every cycle — the watchdog is itself observable"

# ── 6. Self-heal escalation (RESILIENT-1112): exhausted self-heal must page
#      the operator automatically — no human step to *notice* the failure ──
FAIL_SSH="$TMP/ssh-fail"
cat > "$FAIL_SSH" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$FAIL_SSH"

RECALL_STUB="$TMP/operator-recall-stub.sh"
RECALL_CALLS="$TMP/recall-calls.log"
: > "$RECALL_CALLS"
cat > "$RECALL_STUB" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$RECALL_CALLS"
exit 0
EOF
chmod +x "$RECALL_STUB"

STATE_DIR3="$TMP/state3"
AMB3="$TMP/ambient3.jsonl"
: > "$AMB3"

# Default REMOTE_HEAL must now be on (no CHUMP_APEX_WATCHDOG_REMOTE_HEAL set)
# — drive the peer down for enough cycles to cross both the miss threshold
# (3) and the heal-escalate threshold (default 2 consecutive heal failures).
for i in 1 2 3 4 5; do
    CHUMP_APEX_WATCHDOG_NODES_DIR="$NODES_DIR" \
    CHUMP_APEX_WATCHDOG_SELF="self" \
    CHUMP_APEX_WATCHDOG_CURL_BIN="$DOWN_CURL" \
    CHUMP_APEX_WATCHDOG_SSH_BIN="$FAIL_SSH" \
    CHUMP_APEX_WATCHDOG_STATE_DIR="$STATE_DIR3" \
    CHUMP_APEX_WATCHDOG_MISS_THRESHOLD=3 \
    CHUMP_APEX_WATCHDOG_HEAL_ESCALATE=2 \
    CHUMP_APEX_WATCHDOG_RECALL_SCRIPT="$RECALL_STUB" \
    CHUMP_AMBIENT_LOG="$AMB3" \
    "$WATCHDOG" >/dev/null 2>&1
    rc=$?
    [[ "$rc" -eq 0 ]] || fail "watchdog exited $rc on escalation cycle $i"
done

grep -q '"kind":"node_remote_heal_attempted".*"result":"failed"' "$AMB3" \
    || fail "expected remote heal to be attempted (and fail) with no opt-in flag set — remote heal must default on; ambient: $(cat "$AMB3")"
pass "remote self-heal attempted automatically by default (no opt-in flag needed)"

grep -q '"kind":"node_heal_exhausted_recall"' "$AMB3" \
    || fail "expected node_heal_exhausted_recall once heal failures crossed HEAL_ESCALATE; ambient: $(cat "$AMB3")"
grep -q '"peer":"peer-a"' "$AMB3" \
    || fail "expected peer field on node_heal_exhausted_recall; ambient: $(cat "$AMB3")"
pass "self-heal exhaustion emits node_heal_exhausted_recall"

[[ -s "$RECALL_CALLS" ]] \
    || fail "operator-recall.sh was never invoked — the apex-human catch was not removed, a human still has to notice by hand"
grep -q -- '--condition NODE_UNREACHABLE_UNHEALED' "$RECALL_CALLS" \
    || fail "expected operator-recall.sh --condition NODE_UNREACHABLE_UNHEALED; calls: $(cat "$RECALL_CALLS")"
pass "watchdog pages the operator itself via operator-recall.sh once self-heal is exhausted (apex-human catch removed)"

echo "=== all apex-watchdog checks passed ==="
