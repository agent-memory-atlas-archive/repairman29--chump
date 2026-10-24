#!/usr/bin/env bash
# INFRA-2258 AC6 + CREDIBLE-1544 (Phase R R4): test-voice-subcommand.sh
# Smoke test for `chump voice` subcommand:
#   1. Invoke with anonymized flags -> assert row in state.db + docs/voice/VOA-NNNN-FULL.yaml written, no docs/gaps/*.yaml written directly
#   2. Assert no opt-in slug leak in state.db row, full report, or ambient event
#   3. Assert --ship --dry-run prints PR body without opening a PR
#   4. Assert refusal to overwrite an existing docs/voice/VOA-NNNN-FULL.yaml (CREDIBLE-1544 AC2)
#   5. Assert next_voa_id allocates past state.db, docs/gaps, and docs/voice (CREDIBLE-1544 AC1)
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
CHUMP_BIN="${CHUMP_BIN:-$REPO_ROOT/target/debug/chump}"

if [[ ! -x "$CHUMP_BIN" ]]; then
    echo "[test-voice-subcommand] building chump binary..."
    cargo build --manifest-path "$REPO_ROOT/Cargo.toml" --bin chump --quiet
fi

# ── Isolated test environment ──────────────────────────────────────────────────
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Fake repo root: contains docs/gaps/ and docs/voice/ and .chump-locks/
FAKE_ROOT="$TMPDIR_TEST/repo"
mkdir -p "$FAKE_ROOT/docs/gaps"
mkdir -p "$FAKE_ROOT/docs/voice"
mkdir -p "$FAKE_ROOT/.chump-locks"

# Bootstrap a fake Cargo.toml with [workspace] so repo_root() detection works.
cat > "$FAKE_ROOT/Cargo.toml" << 'EOF'
[workspace]
members = []
EOF

AMBIENT_LOG="$FAKE_ROOT/.chump-locks/ambient.jsonl"
STATE_DB="$FAKE_ROOT/.chump/state.db"

export CHUMP_REPO_ROOT="$FAKE_ROOT"
export CHUMP_AMBIENT_LOG="$AMBIENT_LOG"
export CHUMP_SESSION_ID="test-voice-$$"
# Force a known VOA ID for Test 1.
export CHUMP_VOICE_TEST_ID="VOA-002"

FAIL=0

# ── Test 1: anonymous filing, store-first + correct YAML shape ─────────────────
echo "[test-voice-subcommand] Test 1: anonymous filing (store-first, no direct docs/gaps write)"

"$CHUMP_BIN" voice \
    --wedge-class "fmt-drift-queue-wide" \
    --minutes-lost 30 \
    --workaround "ran cargo fmt --all sweep" \
    --fix-shape "gate" \
    --fix "chump preflight mirrors CI parity (INFRA-2120)" \
    --target-repo "anonymous" \
    --evidence "PR #2769,INFRA-2120"

GAP_FILE="$FAKE_ROOT/docs/gaps/VOA-002.yaml"
FULL_FILE="$FAKE_ROOT/docs/voice/VOA-002-FULL.yaml"

if [[ -f "$GAP_FILE" ]]; then
    echo "FAIL: docs/gaps/VOA-002.yaml was written directly (violates R4 export-only)"
    FAIL=1
else
    echo "  PASS: docs/gaps/VOA-002.yaml not written directly (R4 export-only)"
fi

if [[ ! -f "$FULL_FILE" ]]; then
    echo "FAIL: docs/voice/VOA-002-FULL.yaml not written"
    FAIL=1
else
    echo "  PASS: docs/voice/VOA-002-FULL.yaml exists"
fi

# Assert VOA-002 row exists in state.db with correct fields.
DB_ROW="$(sqlite3 "$STATE_DB" "SELECT id || '|' || domain || '|' || status || '|' || title || '|' || acceptance_criteria FROM gaps WHERE id='VOA-002';" 2>/dev/null || true)"
if [[ "$DB_ROW" != *"VOA-002|VOA|open|"* ]]; then
    echo "FAIL: state.db missing open VOA-002 row (got: $DB_ROW)"
    FAIL=1
else
    echo "  PASS: state.db contains open VOA-002 row"
fi

if [[ "$DB_ROW" != *"fmt-drift-queue-wide"* ]]; then
    echo "FAIL: state.db row missing wedge_class"
    FAIL=1
else
    echo "  PASS: state.db row contains wedge_class"
fi

if [[ "$DB_ROW" != *"minutes_lost=30"* ]]; then
    echo "FAIL: state.db row missing minutes_lost=30"
    FAIL=1
else
    echo "  PASS: state.db row contains minutes_lost=30"
fi

# Assert correct fields in full report.
if ! grep -q "wedge_class: fmt-drift-queue-wide" "$FULL_FILE" 2>/dev/null; then
    echo "FAIL: full report missing wedge_class"
    FAIL=1
else
    echo "  PASS: full report has wedge_class"
fi

if ! grep -q "minutes_lost: 30" "$FULL_FILE" 2>/dev/null; then
    echo "FAIL: full report missing minutes_lost"
    FAIL=1
else
    echo "  PASS: full report has minutes_lost"
fi

if ! grep -q "target_repo: \"anonymous\"" "$FULL_FILE" 2>/dev/null; then
    echo "FAIL: full report does not have target_repo: anonymous"
    FAIL=1
else
    echo "  PASS: full report target_repo is anonymous"
fi

if ! grep -q "target_repo_disclosure: anonymous" "$FULL_FILE" 2>/dev/null; then
    echo "FAIL: full report missing anonymous disclosure"
    FAIL=1
else
    echo "  PASS: full report disclosure is anonymous"
fi

# ── Test 1b (CREDIBLE-1544 AC2): Refuses to overwrite existing docs/voice file ─
echo "[test-voice-subcommand] Test 1b: refuses to overwrite existing docs/voice/VOA-002-FULL.yaml"
ORIG_SHA="$(shasum -a 256 "$FULL_FILE" | awk '{print $1}')"
if "$CHUMP_BIN" voice \
    --wedge-class "clobber-attempt" \
    --minutes-lost 99 \
    --fix-shape "doc" \
    --fix "should fail" \
    --target-repo "anonymous" >/dev/null 2>&1; then
    echo "FAIL: chump voice succeeded when docs/voice/VOA-002-FULL.yaml already existed"
    FAIL=1
else
    echo "  PASS: chump voice refused to overwrite existing docs/voice/VOA-002-FULL.yaml"
fi
AFTER_SHA="$(shasum -a 256 "$FULL_FILE" | awk '{print $1}')"
if [[ "$ORIG_SHA" != "$AFTER_SHA" ]]; then
    echo "FAIL: existing docs/voice/VOA-002-FULL.yaml was modified"
    FAIL=1
else
    echo "  PASS: existing docs/voice/VOA-002-FULL.yaml remained byte-identical"
fi

# ── Test 2: No opt-in slug leak in anonymous mode (auto-allocated ID VOA-003) ──
echo "[test-voice-subcommand] Test 2: no opt-in slug leak in anonymous mode (auto-allocates VOA-003 from state.db)"
unset CHUMP_VOICE_TEST_ID

FAKE_HOME="$TMPDIR_TEST/home"
mkdir -p "$FAKE_HOME/.chump"
cat > "$FAKE_HOME/.chump/voice-opt-in.toml" << 'EOF'
mode = "opt-in:slug"
github_identity = "testuser"
EOF
export HOME="$FAKE_HOME"

"$CHUMP_BIN" voice \
    --wedge-class "some-wedge" \
    --minutes-lost 10 \
    --fix-shape "doc" \
    --fix "update docs" \
    --target-repo "anonymous"

FULL_FILE_3="$FAKE_ROOT/docs/voice/VOA-003-FULL.yaml"
if [[ ! -f "$FULL_FILE_3" ]]; then
    echo "FAIL: expected auto-allocated docs/voice/VOA-003-FULL.yaml"
    FAIL=1
else
    echo "  PASS: auto-allocated VOA-003 from state.db max(VOA-002)+1"
fi

# Ambient log must NOT contain a real repo slug.
if grep -q '"target_repo":"opt-in:slug\|repairman29\|example-corp' "$AMBIENT_LOG" 2>/dev/null; then
    echo "FAIL: ambient log leaks slug in anonymous mode"
    FAIL=1
else
    echo "  PASS: ambient log does not leak slug"
fi

# Full report must not contain target slug either.
if grep -q "repairman29\|example-corp" "$FULL_FILE" "$FULL_FILE_3" 2>/dev/null; then
    echo "FAIL: YAML files leak slug in anonymous mode"
    FAIL=1
else
    echo "  PASS: YAML files do not leak slug"
fi

# ── Test 3: ambient event shape ───────────────────────────────────────────────
echo "[test-voice-subcommand] Test 3: ambient event kind=voice_of_agent_filed"

if ! grep -q '"kind":"voice_of_agent_filed"' "$AMBIENT_LOG" 2>/dev/null; then
    echo "FAIL: ambient.jsonl missing kind=voice_of_agent_filed"
    FAIL=1
else
    echo "  PASS: ambient.jsonl has kind=voice_of_agent_filed"
fi

if ! grep -q '"wedge_class"' "$AMBIENT_LOG" 2>/dev/null; then
    echo "FAIL: ambient event missing wedge_class field"
    FAIL=1
else
    echo "  PASS: ambient event has wedge_class"
fi

if ! grep -q '"minutes_lost"' "$AMBIENT_LOG" 2>/dev/null; then
    echo "FAIL: ambient event missing minutes_lost field"
    FAIL=1
else
    echo "  PASS: ambient event has minutes_lost"
fi

# ── Test 4: --ship --dry-run prints PR body without opening PR ─────────────────
echo "[test-voice-subcommand] Test 4: --ship --dry-run (auto-allocates past docs/voice/VOA-010-FULL.yaml)"
printf 'id: VOA-010\n' > "$FAKE_ROOT/docs/voice/VOA-010-FULL.yaml"

SHIP_OUTPUT="$TMPDIR_TEST/ship-output.txt"
"$CHUMP_BIN" voice \
    --wedge-class "bot-merge-silent-wedge" \
    --minutes-lost 60 \
    --workaround "manual recovery" \
    --fix-shape "tooling" \
    --fix "wall-clock progress monitor with auto-bail" \
    --target-repo "anonymous" \
    --ship \
    --dry-run > "$SHIP_OUTPUT" 2>&1

if ! grep -q "VOA-011" "$SHIP_OUTPUT" 2>/dev/null; then
    echo "FAIL: --ship --dry-run output missing VOA-011 (expected allocation past VOA-010-FULL.yaml)"
    FAIL=1
else
    echo "  PASS: --ship --dry-run output contains VOA-011"
fi

if ! grep -q "PR BODY" "$SHIP_OUTPUT" 2>/dev/null; then
    echo "FAIL: --ship --dry-run did not print PR body marker"
    FAIL=1
else
    echo "  PASS: --ship --dry-run printed PR body"
fi

if ! grep -q "bot-merge-silent-wedge" "$SHIP_OUTPUT" 2>/dev/null; then
    echo "FAIL: --ship --dry-run PR body missing wedge class"
    FAIL=1
else
    echo "  PASS: --ship --dry-run PR body has wedge class"
fi

# Confirm no actual git branch was created (dry-run should not mutate).
if git -C "$REPO_ROOT" branch --list "voice/voa-011" | grep -q "voice/voa-011" 2>/dev/null; then
    echo "FAIL: --ship --dry-run created a real git branch"
    FAIL=1
else
    echo "  PASS: --ship --dry-run did not create a git branch"
fi

# ── Result ────────────────────────────────────────────────────────────────────
echo ""
if [[ "$FAIL" -eq 0 ]]; then
    echo "[test-voice-subcommand] ALL TESTS PASSED"
    exit 0
else
    echo "[test-voice-subcommand] SOME TESTS FAILED"
    exit 1
fi
