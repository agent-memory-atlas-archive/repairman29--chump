#!/usr/bin/env bash
# test-state-db-yaml-sync.sh — INFRA-1495
#
# Verifies scripts/coord/state-db-yaml-sync.sh:
#   1. --dry-run reports the orphan count without writing files or committing
#   2. --apply writes exactly the missing YAML mirrors for OPEN gaps
#   3. --apply commits the batch via chump-commit.sh (stubbed here) with the
#      "chore(state-db-yaml-sync): backfill N YAML mirrors per CREDIBLE-012"
#      message
#   4. a `done` gap with no YAML mirror is NEVER backfilled (CREDIBLE-012
#      hygiene rule — only OPEN gaps are eligible)
#   5. kind=state_db_yaml_orphan is emitted per missing YAML, in both modes

set -uo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/scripts/coord/state-db-yaml-sync.sh"

[[ -f "$SCRIPT" ]] || { echo "[FAIL] $SCRIPT missing"; exit 1; }

echo "=== INFRA-1495 state-db-yaml-sync test ==="
echo

BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
if [[ ! -f "$BIN" ]]; then
    echo "  [build] cargo build --bin chump (quiet)..."
    cargo build --bin chump --manifest-path "$REPO_ROOT/Cargo.toml" -q 2>&1 | tail -5
fi
if [[ ! -f "$BIN" ]]; then
    fail "chump binary not found after build — cannot run functional tests"
    echo
    echo "=== Results: $PASS passed, $FAIL failed ==="
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# RESILIENT-1652: route this fixture repo through the canonical sandbox primitive
# so `chump gap reserve` below sees a HEALTHY node instead of RED-ing on a CI
# runner that has no ~/.chump/oauth-token.json (the farmer readiness gate that
# `gap reserve` consults correctly reds without one). chump_test_sandbox_setup
# exports the isolation env (CHUMP_HOME/REPO/REPO_ROOT/STATE_DB/LOCK_DIR/STATE_DIR
# + marker) all pinned at $TMP; write_sandbox_healthy_node lays the positive node
# evidence (content-valid oauth token, not-paused node.env, fresh farmer
# heartbeat) under $TMP/.chump WITHOUT loosening the gate. Neither reads an
# inherited env. This is the hermetic seam the standing rule mandates.
# shellcheck source=../coord/lib/test-sandbox.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/coord/lib/test-sandbox.sh"
# shellcheck source=lib/sandbox-healthy-node.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/ci/lib/sandbox-healthy-node.sh"
chump_test_sandbox_setup "$TMP"
write_sandbox_healthy_node "$TMP"

# Isolated fixture repo — never touches the real state.db / docs/gaps.
mkdir -p "$TMP/scripts/coord/lib" "$TMP/docs/gaps" "$TMP/.chump-locks"
cp "$SCRIPT" "$TMP/scripts/coord/state-db-yaml-sync.sh"
cp "$REPO_ROOT/scripts/coord/lib/ambient-write.sh" "$TMP/scripts/coord/lib/ambient-write.sh"
chmod +x "$TMP/scripts/coord/state-db-yaml-sync.sh"

# Stub chump-commit.sh: records its invocation instead of doing a real git
# commit (chump-commit.sh's hook/trailer machinery is out of scope for this
# test — AC3 only requires state-db-yaml-sync.sh to *call* it correctly).
cat > "$TMP/scripts/coord/chump-commit.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$(dirname "$0")/../../commit-invocation.txt"
exit 0
STUB
chmod +x "$TMP/scripts/coord/chump-commit.sh"

BIN_DIR="$(dirname "$BIN")"
export PATH="$BIN_DIR:$PATH"
# CHUMP_REPO / CHUMP_HOME / CHUMP_REPO_ROOT / CHUMP_LOCK_DIR / CHUMP_STATE_DIR
# are exported by chump_test_sandbox_setup above (all pinned at $TMP). Only the
# non-isolation test flags remain here.
export CHUMP_ALLOW_MAIN_WORKTREE=1
export FLEET_029_AMBIENT_GLANCE_SKIP=1
export CHUMP_RESERVE_NO_AUTOSTAGE=1

(cd "$TMP" && git init -q -b main && git config user.email "test@chump.local" && git config user.name "Chump Test")

reserve() {
    "$BIN" gap reserve --domain SYNCTEST --priority P2 --effort xs \
        --title "$1" --skip-obs-acs --quiet 2>/dev/null
}

# Seed two OPEN gaps (no YAML mirror — `gap reserve` no longer writes one)
# and one gap that gets shipped to `done` before the sweep runs.
OPEN_A="$(reserve "sync-fixture-open-a")"
OPEN_B="$(reserve "sync-fixture-open-b")"
DONE_C="$(reserve "sync-fixture-done-c")"

[[ -n "$OPEN_A" && -n "$OPEN_B" && -n "$DONE_C" ]] || {
    fail "gap reserve did not return IDs (OPEN_A=$OPEN_A OPEN_B=$OPEN_B DONE_C=$DONE_C)"
    echo; echo "=== Results: $PASS passed, $FAIL failed ==="; exit 1
}

"$BIN" gap set "$DONE_C" --status done --closed-pr 1 >/dev/null 2>&1 || true

AMBIENT="$TMP/.chump-locks/ambient.jsonl"

echo "Test 1: --dry-run reports orphans, writes nothing"
"$TMP/scripts/coord/state-db-yaml-sync.sh" --dry-run --gaps-dir "$TMP/docs/gaps" >/tmp/sync-dry.out 2>&1
[[ ! -f "$TMP/docs/gaps/$OPEN_A.yaml" ]] && ok "no file written for $OPEN_A in dry-run" || fail "dry-run wrote $OPEN_A.yaml"
[[ ! -f "$TMP/docs/gaps/$OPEN_B.yaml" ]] && ok "no file written for $OPEN_B in dry-run" || fail "dry-run wrote $OPEN_B.yaml"
[[ ! -f "$TMP/commit-invocation.txt" ]] && ok "dry-run did not commit" || fail "dry-run invoked chump-commit.sh"
grep -q "2 orphan(s)" /tmp/sync-dry.out && ok "dry-run output reports orphan count" || fail "dry-run output missing orphan count line: $(cat /tmp/sync-dry.out)"

echo
echo "Test 2: dry-run still emits kind=state_db_yaml_orphan per missing YAML"
[[ -f "$AMBIENT" ]] || { fail "ambient.jsonl not created"; }
grep -q "\"kind\":\"state_db_yaml_orphan\".*\"gap_id\":\"$OPEN_A\"" "$AMBIENT" \
    && ok "orphan event emitted for $OPEN_A in dry-run" \
    || fail "no orphan event for $OPEN_A in dry-run: $(cat "$AMBIENT" 2>/dev/null)"
grep -q "\"kind\":\"state_db_yaml_orphan\".*\"gap_id\":\"$OPEN_B\"" "$AMBIENT" \
    && ok "orphan event emitted for $OPEN_B in dry-run" \
    || fail "no orphan event for $OPEN_B in dry-run"
# Scope to orphan events: the done flip itself legitimately emits
# kind=gap_status_done_written for $DONE_C (CREDIBLE-1508).
grep -q "\"kind\":\"state_db_yaml_orphan\".*\"gap_id\":\"$DONE_C\"" "$AMBIENT" \
    && fail "orphan event emitted for done gap $DONE_C (must never fire for terminal statuses)" \
    || ok "no orphan event for done gap $DONE_C"

echo
echo "Test 3: --apply backfills exactly the OPEN orphans, never the done gap"
rm -f "$AMBIENT"
"$TMP/scripts/coord/state-db-yaml-sync.sh" --apply --gaps-dir "$TMP/docs/gaps" >/tmp/sync-apply.out 2>&1
[[ -f "$TMP/docs/gaps/$OPEN_A.yaml" ]] && ok "$OPEN_A.yaml written by --apply" || { fail "$OPEN_A.yaml NOT written"; cat /tmp/sync-apply.out; }
[[ -f "$TMP/docs/gaps/$OPEN_B.yaml" ]] && ok "$OPEN_B.yaml written by --apply" || { fail "$OPEN_B.yaml NOT written"; cat /tmp/sync-apply.out; }
[[ ! -f "$TMP/docs/gaps/$DONE_C.yaml" ]] && ok "done gap $DONE_C.yaml NOT written (CREDIBLE-012)" || fail "done gap $DONE_C.yaml was written — hygiene violation"
grep -q "id: $OPEN_A" "$TMP/docs/gaps/$OPEN_A.yaml" 2>/dev/null && ok "$OPEN_A.yaml content looks like a gap mirror" || fail "$OPEN_A.yaml content malformed: $(cat "$TMP/docs/gaps/$OPEN_A.yaml" 2>/dev/null)"

echo
echo "Test 4: --apply commits the batch via chump-commit.sh with the expected message"
[[ -f "$TMP/commit-invocation.txt" ]] || fail "chump-commit.sh was never invoked by --apply"
if [[ -f "$TMP/commit-invocation.txt" ]]; then
    grep -q "docs/gaps/$OPEN_A.yaml" "$TMP/commit-invocation.txt" && ok "commit invocation includes $OPEN_A.yaml" || fail "commit invocation missing $OPEN_A.yaml: $(cat "$TMP/commit-invocation.txt")"
    grep -q "docs/gaps/$OPEN_B.yaml" "$TMP/commit-invocation.txt" && ok "commit invocation includes $OPEN_B.yaml" || fail "commit invocation missing $OPEN_B.yaml"
    grep -q "chore(state-db-yaml-sync): backfill 2 YAML mirrors per CREDIBLE-012" "$TMP/commit-invocation.txt" \
        && ok "commit message matches AC3 spec" \
        || fail "commit message wrong: $(cat "$TMP/commit-invocation.txt")"
fi

echo
echo "Test 5: re-running --dry-run after --apply reports zero orphans"
rm -f "$AMBIENT"
"$TMP/scripts/coord/state-db-yaml-sync.sh" --dry-run --gaps-dir "$TMP/docs/gaps" >/tmp/sync-dry2.out 2>&1
if [[ -f "$AMBIENT" ]] && grep -q "\"kind\":\"state_db_yaml_orphan\"" "$AMBIENT"; then
    fail "orphan events still firing after full backfill: $(cat "$AMBIENT")"
else
    ok "no orphan events after full backfill (converged)"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
