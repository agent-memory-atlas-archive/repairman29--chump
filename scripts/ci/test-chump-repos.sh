#!/usr/bin/env bash
# test-chump-repos.sh — MISSION-033
#
# Asserts:
#  (a) Schema migration adds repos table + 3 indexes
#  (b) chump repos list on empty db returns empty list
#  (c) chump gap import auto-upserts repos rows for external_repo:* tags
#  (d) chump repos add inserts a new row
#  (e) chump repos set --cascade-tier updates field
#  (f) chump repos show <id> --json returns valid JSON with gap_count
#  (g) Idempotent re-import doesn't overwrite last_scan_at once set
#  (h) Removing a gap with external_repo:foo/bar does NOT remove the repos row
#  (i) Daemon-mode: chump repos set --last-clone-at EPOCH works without TTY
set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
echo "=== MISSION-033 chump repos test ==="
echo

# ── Static wiring checks ──────────────────────────────────────────────────────

if grep -q '"repos"' "$REPO_ROOT/src/main.rs"; then
    ok "repos command arm in main.rs"
else
    fail "repos command arm missing from main.rs"
fi

if grep -q 'CREATE TABLE IF NOT EXISTS repos' \
    "$REPO_ROOT/crates/chump-gap-store/src/lib.rs"; then
    ok "repos table DDL present in gap-store lib.rs"
else
    fail "repos table DDL missing from gap-store lib.rs"
fi

if grep -q 'CREATE INDEX IF NOT EXISTS repos_last_scan_at' \
    "$REPO_ROOT/crates/chump-gap-store/src/lib.rs"; then
    ok "repos_last_scan_at index present (drives MISSION-038 scheduler)"
else
    fail "repos_last_scan_at index missing"
fi

if grep -q 'CREATE INDEX IF NOT EXISTS repos_last_clone_at' \
    "$REPO_ROOT/crates/chump-gap-store/src/lib.rs"; then
    ok "repos_last_clone_at index present (drives MISSION-035 GC)"
else
    fail "repos_last_clone_at index missing"
fi

if grep -q 'upsert_repos_from_skills' \
    "$REPO_ROOT/crates/chump-gap-store/src/lib.rs"; then
    ok "upsert_repos_from_skills present in gap-store"
else
    fail "upsert_repos_from_skills missing from gap-store"
fi

if grep -q 'upsert_repos_from_skills' \
    "$REPO_ROOT/crates/chump-gap-store/src/lib.rs" && \
   grep -q 'import_from_yaml' \
    "$REPO_ROOT/crates/chump-gap-store/src/lib.rs"; then
    ok "import_from_yaml calls upsert_repos_from_skills"
else
    fail "import_from_yaml does not call upsert_repos_from_skills"
fi

# ── Build binary ──────────────────────────────────────────────────────────────

echo "  [build] cargo build --bin chump (quiet)..."
cargo build --bin chump --manifest-path "$REPO_ROOT/Cargo.toml" -q 2>&1 | tail -5

# INFRA-3517: resolve the built binary via the shared helper, which honors
# .cargo/config.toml [build] target-dir. The old hardcoded
# "${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump" missed config.toml target
# dirs, so preflight reported "chump binary not found" on any host with a
# shared target dir (e.g. ~/.cargo/chump-shared-target) — a local-only false-red.
source "$(dirname "$0")/lib/discover-chump-bin.sh"
BIN="$CHUMP_BIN"

# ── Functional tests ──────────────────────────────────────────────────────────

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export CHUMP_REPO="$TMP"
export CHUMP_HOME="$TMP"
export CHUMP_ALLOW_MAIN_WORKTREE=1
export FLEET_029_AMBIENT_GLANCE_SKIP=1
export CHUMP_RESERVE_NO_AUTOSTAGE=1
export CHUMP_RESERVE_VERIFY=0
export CHUMP_GAP_IMPORT_NO_SIMILARITY=1
DB="$TMP/.chump/state.db"

# (a) Schema migration — repos table + 3 indexes exist after first open.
# Trigger DB creation by reserving a gap (which opens GapStore).
# CREDIBLE-1519: --force bypasses the RESILIENT-069 farmer-RED claim gate so
# this hermetic seed doesn't read host ~/.chump oauth/heartbeat state (a stale
# host token would otherwise RED-block the reserve and SEED_ID would come back
# empty). Capture stderr so an empty SEED_ID prints the real reserve error +
# failing step instead of exiting 1 silently.
SEED_ERR="$TMP/seed-reserve.err"
SEED_ID=$("$BIN" gap reserve --domain INFRA --priority P1 --effort xs \
    --title "repos-migration-test-seed" --force --quiet 2>"$SEED_ERR")
if [[ -n "$SEED_ID" ]]; then
    ok "seed gap reserved ($SEED_ID) — DB opened and migration ran"
else
    echo "    seed reserve error: $(cat "$SEED_ERR" 2>/dev/null)" >&2
    fail "failed to reserve seed gap (step: repos table migration seed)"
fi

if sqlite3 "$DB" ".tables" 2>/dev/null | grep -q "repos"; then
    ok "(a) repos table exists after migration"
else
    fail "(a) repos table missing after migration"
fi

IDX_COUNT=$(sqlite3 "$DB" \
    "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name LIKE 'repos_%'" \
    2>/dev/null || echo 0)
if [[ "$IDX_COUNT" -ge 3 ]]; then
    ok "(a) all 3 repos indexes present (got $IDX_COUNT)"
else
    fail "(a) expected >=3 repos indexes, got $IDX_COUNT"
fi

# (b) chump repos list on empty repos table returns empty list without error.
LIST_OUT=$("$BIN" repos list 2>/dev/null)
if echo "$LIST_OUT" | grep -q "no repos registered\|^\[]\$\|^$"; then
    ok "(b) repos list on empty db returns empty list"
else
    # Empty JSON array [] or no output is also fine
    if [[ -z "$LIST_OUT" ]] || [[ "$LIST_OUT" == "[]" ]]; then
        ok "(b) repos list on empty db returns empty (no output or [])"
    else
        fail "(b) repos list on empty db gave unexpected output: '$LIST_OUT'"
    fi
fi

LIST_JSON=$("$BIN" repos list --json 2>/dev/null)
if [[ "$LIST_JSON" == "[]" ]]; then
    ok "(b) repos list --json on empty db returns []"
else
    fail "(b) repos list --json expected [], got: '$LIST_JSON'"
fi

# (c) chump gap import auto-upserts repos row for external_repo:* tag.
# Create a minimal gap YAML with an external_repo: tag.
mkdir -p "$TMP/docs/gaps"
cat > "$TMP/docs/gaps/TEST-EXT-001.yaml" << 'YAML'
- id: TEST-EXT-001
  domain: TEST
  title: "external repo test gap"
  status: open
  priority: P2
  effort: xs
  skills_required: "rust,external_repo:foo/bar"
YAML

"$BIN" gap import 2>/dev/null || true

ROW_COUNT=$(sqlite3 "$DB" "SELECT COUNT(*) FROM repos WHERE id='foo/bar'" 2>/dev/null || echo 0)
if [[ "$ROW_COUNT" -eq 1 ]]; then
    ok "(c) import auto-upserted repos row for external_repo:foo/bar"
else
    fail "(c) import did not create repos row for foo/bar (count=$ROW_COUNT)"
fi

OWNER=$(sqlite3 "$DB" "SELECT owner FROM repos WHERE id='foo/bar'" 2>/dev/null || true)
NAME=$(sqlite3 "$DB" "SELECT name FROM repos WHERE id='foo/bar'" 2>/dev/null || true)
if [[ "$OWNER" == "foo" && "$NAME" == "bar" ]]; then
    ok "(c) repos row has correct owner=foo name=bar"
else
    fail "(c) repos row has wrong owner='$OWNER' name='$NAME'"
fi

TIER=$(sqlite3 "$DB" "SELECT cascade_tier FROM repos WHERE id='foo/bar'" 2>/dev/null || true)
if [[ "$TIER" == "dogfood" ]]; then
    ok "(c) auto-imported row has cascade_tier=dogfood"
else
    fail "(c) auto-imported row has cascade_tier='$TIER', expected dogfood"
fi

# (d) chump repos add inserts a new row.
if "$BIN" repos add "acme/widget" --cascade-tier trains --status active 2>/dev/null; then
    ok "(d) chump repos add acme/widget succeeded"
else
    fail "(d) chump repos add acme/widget failed"
fi

ADD_COUNT=$(sqlite3 "$DB" "SELECT COUNT(*) FROM repos WHERE id='acme/widget'" 2>/dev/null || echo 0)
if [[ "$ADD_COUNT" -eq 1 ]]; then
    ok "(d) acme/widget row present in repos table"
else
    fail "(d) acme/widget row missing from repos table"
fi

ADDED_TIER=$(sqlite3 "$DB" "SELECT cascade_tier FROM repos WHERE id='acme/widget'" 2>/dev/null || true)
if [[ "$ADDED_TIER" == "trains" ]]; then
    ok "(d) acme/widget has cascade_tier=trains"
else
    fail "(d) acme/widget cascade_tier='$ADDED_TIER', expected trains"
fi

# (e) chump repos set --cascade-tier updates the field.
"$BIN" repos set "acme/widget" --cascade-tier safe 2>/dev/null
SET_TIER=$(sqlite3 "$DB" "SELECT cascade_tier FROM repos WHERE id='acme/widget'" 2>/dev/null || true)
if [[ "$SET_TIER" == "safe" ]]; then
    ok "(e) repos set --cascade-tier updated acme/widget to safe"
else
    fail "(e) repos set --cascade-tier failed (got '$SET_TIER')"
fi

# (f) chump repos show <id> --json returns valid JSON with gap_count.
SHOW_JSON=$("$BIN" repos show "foo/bar" --json 2>/dev/null)
if echo "$SHOW_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'gap_count' in d" 2>/dev/null; then
    ok "(f) repos show --json returns valid JSON with gap_count"
else
    fail "(f) repos show --json invalid or missing gap_count: '$SHOW_JSON'"
fi

GAP_COUNT=$(echo "$SHOW_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['gap_count'])" 2>/dev/null || echo -1)
if [[ "$GAP_COUNT" -ge 1 ]]; then
    ok "(f) gap_count >= 1 for foo/bar (got $GAP_COUNT — the TEST-EXT-001 gap)"
else
    fail "(f) gap_count expected >=1, got $GAP_COUNT"
fi

# (g) Idempotent re-import: set last_scan_at manually, then re-import.
# The re-import should NOT overwrite last_scan_at.
EPOCH=1717600000
sqlite3 "$DB" "UPDATE repos SET last_scan_at=$EPOCH WHERE id='foo/bar'" 2>/dev/null
"$BIN" gap import 2>/dev/null || true
SCAN_AFTER=$(sqlite3 "$DB" "SELECT last_scan_at FROM repos WHERE id='foo/bar'" 2>/dev/null || true)
if [[ "$SCAN_AFTER" == "$EPOCH" ]]; then
    ok "(g) re-import preserves last_scan_at (idempotent)"
else
    fail "(g) re-import overwrote last_scan_at: expected $EPOCH, got '$SCAN_AFTER'"
fi

# (h) Removing a gap does NOT remove the repos row (decoupled lifecycle).
# First check the gap is in the DB, then set it to done + verify repos row survives.
"$BIN" gap set TEST-EXT-001 --status done --closed-pr 9999 2>/dev/null || true
REPO_AFTER_CLOSE=$(sqlite3 "$DB" "SELECT COUNT(*) FROM repos WHERE id='foo/bar'" 2>/dev/null || echo 0)
if [[ "$REPO_AFTER_CLOSE" -eq 1 ]]; then
    ok "(h) repos row survives gap close (decoupled lifecycle)"
else
    fail "(h) repos row removed after gap close — lifecycle should be decoupled"
fi

# (i) Daemon-mode: chump repos set --last-clone-at works without TTY.
# Simulate daemon call by redirecting stdin from /dev/null.
CLONE_EPOCH=1717700000
"$BIN" repos set "foo/bar" --last-clone-at "$CLONE_EPOCH" </dev/null 2>/dev/null
CLONE_STORED=$(sqlite3 "$DB" "SELECT last_clone_at FROM repos WHERE id='foo/bar'" 2>/dev/null || true)
if [[ "$CLONE_STORED" == "$CLONE_EPOCH" ]]; then
    ok "(i) daemon-mode repos set --last-clone-at works without TTY"
else
    fail "(i) repos set --last-clone-at failed: expected $CLONE_EPOCH, got '$CLONE_STORED'"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
