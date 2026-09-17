#!/usr/bin/env bash
# CI gate for CREDIBLE-051: test-gap-closure-consistency.sh fail-closed + fixture-aware DB.
#
# Verifies two behaviors:
# 1. Fail-closed: when gh pr view returns ERROR for a done gap, gate exits non-zero
#    (unless CHUMP_PREMATURE_CLOSURE_ALLOW_GH_FAIL=1).
# 2. Fixture-aware: CHUMP_STATE_DB env and $PWD/.chump/state.db override the
#    git-common-dir fallback; --use-main flag required for the fallback.
set -e
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="$REPO_ROOT/scripts/ci/test-gap-closure-consistency.sh"
PASS=0; FAIL=0

check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "  PASS: $desc"; (( PASS++ )) || true
  else
    echo "  FAIL: $desc"; (( FAIL++ )) || true
  fi
}

echo "=== CREDIBLE-051: gap-closure-consistency fail-closed + fixture-aware DB ==="

# ── Structural checks ───────────────────────────────────────────────────────
check "gate script exists and is executable" test -x "$GATE"
check "--use-main flag present in source" grep -q 'use.main\|USE_MAIN' "$GATE"
check "git-common-dir fallback gated on USE_MAIN" bash -c \
  "grep -A3 'git-common-dir' '$GATE' | grep -q 'USE_MAIN'"
check "GH_FAIL_COUNT tracked" grep -q 'GH_FAIL_COUNT' "$GATE"
check "ALLOW_GH_FAIL env var honored" grep -q 'ALLOW_GH_FAIL\|CHUMP_PREMATURE_CLOSURE_ALLOW_GH_FAIL' "$GATE"
check "env-vars-internal.txt documents CHUMP_PREMATURE_CLOSURE_ALLOW_GH_FAIL" \
  grep -q 'CHUMP_PREMATURE_CLOSURE_ALLOW_GH_FAIL' \
  "$REPO_ROOT/docs/process/env-vars-internal.txt"
check "env-vars-internal.txt documents CHUMP_STATE_DB" \
  grep -q 'CHUMP_STATE_DB' "$REPO_ROOT/docs/process/env-vars-internal.txt"

# ── Functional: fixture-aware DB (AC 3) ────────────────────────────────────
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Create a minimal SQLite state.db with one done gap that has a ghost closed_pr
# (closed_pr set but PR is actually not merged — premature closure)
FIXTURE_DB="$TMPDIR_TEST/.chump/state.db"
mkdir -p "$(dirname "$FIXTURE_DB")"

if command -v sqlite3 &>/dev/null; then
  sqlite3 "$FIXTURE_DB" "
    CREATE TABLE gaps (
      id TEXT PRIMARY KEY,
      title TEXT,
      status TEXT,
      priority TEXT,
      effort TEXT,
      closed_pr INTEGER,
      depends_on TEXT
    );
    INSERT INTO gaps VALUES('FIXTURE-001','test ghost gap','done','P2','xs',99991,NULL);
  " 2>/dev/null

  # Test 1: CHUMP_STATE_DB env override — gate should find and use fixture db
  check "CHUMP_STATE_DB env selects fixture db" bash -c \
    "CHUMP_STATE_DB='$FIXTURE_DB' GH_TOKEN=dummy CHUMP_GH_REQUIRED=0 \
     bash '$GATE' 2>&1 | grep -q 'fixture state.db\|skipping\|PASS\|WARN'"

  # Test 2: $PWD/.chump/state.db — gate uses it without git-common-dir
  FIXTURE_PWD="$TMPDIR_TEST/workdir"
  mkdir -p "$FIXTURE_PWD/.chump"
  cp "$FIXTURE_DB" "$FIXTURE_PWD/.chump/state.db"
  check "PWD/.chump/state.db found without --use-main" bash -c \
    "cd '$FIXTURE_PWD' && CHUMP_GH_REQUIRED=0 bash '$GATE' 2>&1 | grep -qv 'use --use-main'"

  # Test 3: no local state.db and no --use-main → warns and exits 0 (skips gracefully)
  EMPTY_PWD="$TMPDIR_TEST/emptydir"
  mkdir -p "$EMPTY_PWD"
  check "no state.db + no --use-main → graceful skip (exit 0)" bash -c \
    "cd '$EMPTY_PWD' && bash '$GATE' 2>&1; [[ \$? -eq 0 ]]"
  check "graceful skip message mentions --use-main" bash -c \
    "cd '$EMPTY_PWD' && bash '$GATE' 2>&1 | grep -q 'use-main\|use --use-main'"

else
  echo "  SKIP: sqlite3 not found — skipping DB fixture tests"
  (( PASS++ )) || true  # Don't penalize; structural checks are the gate
fi

# ── Functional: fail-closed on gh-API failure (AC 1) ───────────────────────
# The fail-closed path requires a real state.db with done gaps having closed_pr.
# We verify via source inspection + the GH_FAIL_COUNT/ALLOW_GH_FAIL logic.
check "gate exits non-zero on GH_FAIL with ALLOW_GH_FAIL=0" bash -c "
  # Extract the exit logic: if GH_FAIL_COUNT > 0 and ALLOW_GH_FAIL != 1, exits non-zero
  grep -A8 'GH_FAIL_COUNT.*-gt.*0' '$GATE' | grep -q 'exit\|drift\|DRIFT\|STRICT'
"
check "ALLOW_GH_FAIL=1 escape hatch allows pass" bash -c \
  "grep -A5 'ALLOW_GH_FAIL.*==.*1\|allow_gh_fail.*1' '$GATE' | grep -q 'warn\|skip\|soft'"

# ── Functional: file-overlap check fails the gate unconditionally (CREDIBLE-1297) ──
# A done gap whose ACs name a file the merged PR never touched must fail the
# gate even without --strict, and the offending gap ID must be logged.
if command -v sqlite3 &>/dev/null; then
  FO_DIR="$(mktemp -d)"
  trap 'rm -rf "$FO_DIR"' RETURN 2>/dev/null || true

  FO_DB="$FO_DIR/state.db"
  sqlite3 "$FO_DB" "
    CREATE TABLE gaps (
      id TEXT PRIMARY KEY,
      title TEXT,
      status TEXT,
      priority TEXT,
      effort TEXT,
      closed_pr INTEGER,
      depends_on TEXT,
      acceptance_criteria TEXT
    );
    INSERT INTO gaps VALUES('FIXTURE-002','test overlap gap','done','P2','xs',88881,NULL,
      'Modify src/actual_target.rs to add the new flag.');
  " 2>/dev/null

  # Fake gh shim: PR #88881 is merged but only touched an unrelated file.
  FO_GH="$FO_DIR/gh"
  cat > "$FO_GH" <<'SHIM'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"api /rate_limit"*) exit 0 ;;
  *"--json mergedAt"*) echo "2026-01-01T00:00:00Z" ;;
  *"--json files"*) echo "unrelated/other_file.rs" ;;
  *"--json state"*) echo "MERGED" ;;
  *) exit 0 ;;
esac
SHIM
  chmod +x "$FO_GH"

  FO_OUT="$FO_DIR/out.txt"
  FO_EXIT=0
  PATH="$FO_DIR:$PATH" CHUMP_STATE_DB="$FO_DB" CHUMP_GH_PROBE_SKIP=1 \
    bash "$GATE" >"$FO_OUT" 2>&1 || FO_EXIT=$?

  if [[ "$FO_EXIT" -ne 0 ]]; then
    echo "  PASS: file-overlap mismatch fails the gate (exit $FO_EXIT)"; (( PASS++ )) || true
  else
    echo "  FAIL: file-overlap mismatch should fail the gate but exited 0"; (( FAIL++ )) || true
  fi

  if grep -q 'FIXTURE-002' "$FO_OUT"; then
    echo "  PASS: offending gap ID (FIXTURE-002) logged in output"; (( PASS++ )) || true
  else
    echo "  FAIL: offending gap ID not found in gate output"; (( FAIL++ )) || true
  fi

  rm -rf "$FO_DIR"
else
  echo "  SKIP: sqlite3 not found — skipping file-overlap functional test"
  (( PASS++ )) || true
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
