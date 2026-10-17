#!/usr/bin/env bash
# scripts/ci/test-resilient-1615-two-scope-refuse.sh — RESILIENT-1615
#
# Proves, with a STUB systemctl that answers for BOTH supervisor scopes
# (`systemctl --user` and system), that:
#   1. `chump node scopes` enumerates work organs in BOTH scopes and exits 3
#      (two-scope node) when an install exists in more than one scope;
#   2. `chump node pause` refuses to report PAUSED (exit 3) while a work organ
#      is still active in EITHER scope — the cuphead trap where a user-scope
#      pause left the root/system-scope organs running;
#   3. the installer's second-scope guard (refuse_second_scope, which defers to
#      `chump node scopes --install-guard`) refuses with exit 2 and emits
#      kind=node_second_scope_refused when the OTHER scope already has an install.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# Resolve the binary the way the fast-checks steps do (precedent:
# test-resilient-1614-node-pause-invariant.sh).
CHUMP_BIN="${CHUMP_BIN:-${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump}"
if ! [ -x "$CHUMP_BIN" ]; then
    ( cd "$REPO_ROOT" && PATH="$HOME/.cargo/bin:$PATH" cargo build --quiet --bin chump ) \
        || fail "cargo build --bin chump failed"
fi
[ -x "$CHUMP_BIN" ] || fail "CHUMP_BIN not found or not executable: $CHUMP_BIN"

# ── Stub systemctl answering for both scopes ──────────────────────────────────
# $STUB/systemctl inspects its args: a `--user` query answers for the user
# scope, otherwise the system scope. CHUMP_TEST_SCOPE_MODE selects the topology:
#   both        — a work organ enabled+active in EACH scope (two-scope node)
#   system-only — a work organ enabled+active ONLY in the system scope
STUB="$TMP/stub-bin"
mkdir -p "$STUB"
cat > "$STUB/systemctl" <<'STUBEOF'
#!/usr/bin/env bash
# args include: [--user] (list-units|list-unit-files) ... chump-*
is_user=0
for a in "$@"; do [ "$a" = "--user" ] && is_user=1; done
subcmd=""
for a in "$@"; do case "$a" in list-units|list-unit-files) subcmd="$a"; break;; esac; done
mode="${CHUMP_TEST_SCOPE_MODE:-both}"

emit_user=0; emit_system=0
case "$mode" in
    both)        emit_user=1; emit_system=1 ;;
    system-only) emit_user=0; emit_system=1 ;;
esac

want=0
if [ "$is_user" = 1 ]; then want="$emit_user"; else want="$emit_system"; fi
[ "$want" = 1 ] || exit 0

if [ "$is_user" = 1 ]; then unit="chump-node1-worker.service"; else unit="chump-reviver.service"; fi
case "$subcmd" in
    list-units)      printf '%s        loaded active running organ\n' "$unit" ;;
    list-unit-files) printf '%s        enabled enabled\n' "$unit" ;;
esac
exit 0
STUBEOF
# A no-op sudo so any (unexpected) privileged call is harmless.
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/sudo"
# Expose the real binary as `chump` on the stub PATH (installer resolves it via
# `command -v chump`).
ln -sf "$CHUMP_BIN" "$STUB/chump"
chmod +x "$STUB/systemctl" "$STUB/sudo"

STUB_PATH="$STUB:$PATH"

# ── Test 1: `chump node scopes` sees BOTH scopes and flags two-scope ──────────
JSON="$(PATH="$STUB_PATH" CHUMP_TEST_SCOPE_MODE=both HOME="$TMP/home1" \
    "$CHUMP_BIN" node scopes --json 2>/dev/null)"
rc_scopes=0
PATH="$STUB_PATH" CHUMP_TEST_SCOPE_MODE=both HOME="$TMP/home1" \
    "$CHUMP_BIN" node scopes >/dev/null 2>&1 || rc_scopes=$?

[ "$rc_scopes" = 3 ] || fail "node scopes should exit 3 on a two-scope node, got $rc_scopes"
ok "chump node scopes exits 3 on a two-scope node"

printf '%s' "$JSON" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["two_scope"] is True, "two_scope should be true: %r" % d
assert d["work_active_total"] >= 2, "both scopes should report active work organs: %r" % d
scopes = {s["scope"]: s for s in d["scopes"]}
assert "user" in scopes and "system" in scopes, "both scopes enumerated: %r" % d
assert len(scopes["user"]["active_work_organs"]) >= 1, "user scope active organ: %r" % d
assert len(scopes["system"]["active_work_organs"]) >= 1, "system scope active organ: %r" % d
' 2>/dev/null || fail "node scopes --json did not enumerate both scopes with active work organs: $JSON"
ok "chump node scopes --json enumerates active work organs in BOTH scopes"

# ── Test 2: `chump node pause` refuses PAUSED while organs active in both ─────
STATE_DIR="$TMP/state"
mkdir -p "$STATE_DIR/.chump"
cat > "$STATE_DIR/node.env" <<'EOF'
export CHUMP_NODE_MODE=work-ready
EOF
rc_pause=0
PATH="$STUB_PATH" CHUMP_TEST_SCOPE_MODE=both HOME="$TMP/home2" \
    CHUMP_STATE_DIR="$STATE_DIR" \
    "$CHUMP_BIN" node pause --reason "two-scope test" > "$TMP/pause.log" 2>&1 || rc_pause=$?

[ "$rc_pause" = 3 ] || fail "node pause should exit 3 while work organs are active, got $rc_pause: $(cat "$TMP/pause.log")"
grep -q "NOT FULLY PAUSED" "$TMP/pause.log" \
    || fail "pause should print NOT FULLY PAUSED: $(cat "$TMP/pause.log")"
ok "chump node pause refuses to report PAUSED while organs are active in either scope"

# The sentinel + mode are still written (the user-scope pause is honored) even
# though the command refuses to claim the node fully PAUSED.
grep -qx "export CHUMP_NODE_MODE=paused" "$STATE_DIR/node.env" \
    || fail "pause did not write CHUMP_NODE_MODE=paused"
[ -f "$STATE_DIR/.chump/fleet-paused" ] || fail "pause did not write the fleet-paused sentinel"
ok "chump node pause still writes the sentinel + CHUMP_NODE_MODE=paused"

# ── Test 3: installer refuses a second scope + emits node_second_scope_refused ─
# Source the installer (INFRA-3710 sourcing guard means no install runs) to get
# its real refuse_second_scope function, then drive it with the stub showing an
# install ONLY in the system scope (the OTHER scope from this non-root process).
AMBIENT="$TMP/install-ambient.jsonl"
: > "$AMBIENT"
rc_guard=0
(
    set +u
    HOME="$TMP/home3"
    NODE_REPO="$REPO_ROOT"
    export NODE_AMBIENT="$AMBIENT"
    # shellcheck disable=SC1090
    source "$REPO_ROOT/scripts/setup/chump-node-install.sh" >/dev/null 2>&1
    PATH="$STUB_PATH" CHUMP_TEST_SCOPE_MODE=system-only NODE_AMBIENT="$AMBIENT" \
        refuse_second_scope
) > "$TMP/guard.log" 2>&1 || rc_guard=$?

[ "$rc_guard" = 2 ] || fail "installer refuse_second_scope should exit 2, got $rc_guard: $(cat "$TMP/guard.log")"
grep -q "REFUSING INSTALL" "$TMP/guard.log" \
    || fail "installer should print REFUSING INSTALL: $(cat "$TMP/guard.log")"
ok "installer refuses a second-scope install (exit 2)"

grep -q '"kind":"node_second_scope_refused"' "$AMBIENT" \
    || fail "node_second_scope_refused not emitted: $(cat "$AMBIENT" 2>/dev/null)"
ok "installer guard emits kind=node_second_scope_refused"

# ── Control: a single-scope node passes clean ─────────────────────────────────
rc_single=0
PATH="$STUB_PATH" CHUMP_TEST_SCOPE_MODE=system-only HOME="$TMP/home4" \
    "$CHUMP_BIN" node scopes >/dev/null 2>&1 || rc_single=$?
[ "$rc_single" = 0 ] || fail "a single-scope node should exit 0, got $rc_single"
ok "chump node scopes exits 0 on a single-scope node"

echo ""
echo "All RESILIENT-1615 two-scope tests passed!"
