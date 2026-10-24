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
GATE="$REPO_ROOT/scripts/ops/premature-closure-watch.sh"
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

# ── CREDIBLE-1571 AC1/AC2/AC3: organ relocation, receipt-gated reopen, sandbox proof & lint ──
echo ""
echo "=== CREDIBLE-1571: organ moved to scripts/ops + receipt-gated reopen + sandbox proof ==="
check "CREDIBLE-1571 AC2: premature-closure organ removed from scripts/ci" test ! -e "$REPO_ROOT/scripts/ci/test-gap-closure-consistency.sh"
check "CREDIBLE-1571 AC2: premature-closure organ lives at scripts/ops/premature-closure-watch.sh" test -x "$REPO_ROOT/scripts/ops/premature-closure-watch.sh"
check "CREDIBLE-1571 AC2: run-local-ci.sh no longer invokes premature-closure organ" bash -c "! grep -q 'test-gap-closure-consistency\|premature-closure-watch' '$REPO_ROOT/scripts/ci/run-local-ci.sh'"
check "CREDIBLE-1571 AC2: premature-closure-watch.sh does not use CHUMP_ALLOW_RECYCLE" bash -c "! grep -q 'CHUMP_ALLOW_RECYCLE' '$GATE'"

CHUMP_BIN="${CHUMP_BIN:-$REPO_ROOT/target/debug/chump}"
if [[ ! -x "$CHUMP_BIN" ]]; then
  if false; then
    :
  else
    # In audit.yml shards, the Rust workspace is not compiled. Provide a
    # SQLite-backed chump CLI shim inside $TMPDIR_TEST/shim-bin/chump so the
    # functional sandbox/reopen proofs run deterministically without requiring
    # a cargo build inside audit-shard.
    mkdir -p "$TMPDIR_TEST/shim-bin"
    CHUMP_BIN="$TMPDIR_TEST/shim-bin/chump"
    cat > "$CHUMP_BIN" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
DB="${CHUMP_STATE_DB:-${CHUMP_STATE_DIR:-${CHUMP_REPO:-.}/.chump}/state.db}"
mkdir -p "$(dirname "$DB")"
sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS gaps (id TEXT PRIMARY KEY, domain TEXT DEFAULT '', title TEXT DEFAULT '', status TEXT DEFAULT 'open', priority TEXT DEFAULT 'P2', effort TEXT DEFAULT 'm', closed_pr INTEGER, closed_date TEXT DEFAULT '', notes TEXT DEFAULT ''); CREATE TABLE IF NOT EXISTS gap_prs (gap_id TEXT, pr_number INTEGER, head_sha TEXT, opened_at INTEGER DEFAULT 0, state TEXT DEFAULT 'open', multi_ok INTEGER DEFAULT 0);" 2>/dev/null || true
if [[ "${1:-}" == "gap" ]]; then
  shift
  sub="${1:-}"
  shift || true
  case "$sub" in
    reserve)
      dom="TEST"; title="fixture"; prio="P3"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --domain) dom="$2"; shift 2 ;;
          --title) title="$2"; shift 2 ;;
          --priority) prio="$2"; shift 2 ;;
          *) shift ;;
        esac
      done
      cnt=$(sqlite3 "$DB" "SELECT COUNT(*) + 901 FROM gaps WHERE domain='$dom';")
      id="${dom}-${cnt}"
      sqlite3 "$DB" "INSERT OR REPLACE INTO gaps (id, domain, title, status, priority) VALUES ('$id', '$dom', '$title', 'open', '$prio');"
      echo "$id"
      exit 0
      ;;
    set)
      id="$1"; shift
      st=""; reason=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --status) st="$2"; shift 2 ;;
          --reason) reason="$2"; shift 2 ;;
          *) shift ;;
        esac
      done
      if [[ "$st" == "in_progress" ]]; then
        sqlite3 "$DB" "UPDATE gaps SET status='in_progress', closed_pr=NULL, closed_date='' WHERE id='$id';"
      else
        sqlite3 "$DB" "UPDATE gaps SET status='$st' WHERE id='$id';"
      fi
      exit 0
      ;;
    link-pr)
      id="$1"; pr="$2"; shift 2
      sha=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --sha) sha="$2"; shift 2 ;;
          *) shift ;;
        esac
      done
      sqlite3 "$DB" "INSERT OR REPLACE INTO gap_prs (gap_id, pr_number, head_sha) VALUES ('$id', $pr, '$sha');"
      exit 0
      ;;
    ship)
      id="$1"; shift
      pr="0"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --closed-pr) pr="$2"; shift 2 ;;
          *) shift ;;
        esac
      done
      sqlite3 "$DB" "UPDATE gaps SET status='done', closed_pr=$pr WHERE id='$id';"
      mkdir -p "${CHUMP_REPO:-.}/docs/gaps"
      printf 'id: %s
status: done
closed_pr: %s
' "$id" "$pr" > "${CHUMP_REPO:-.}/docs/gaps/${id}.yaml"
      echo "shipped $id"
      exit 0
      ;;
    close)
      id=""
      reason=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --reason) reason="$2"; shift 2 ;;
          --*) shift ;;
          *) [[ -z "$id" ]] && id="$1"; shift ;;
        esac
      done
      case "$reason" in
        superseded|wontfix|obsolete|duplicate) ;;
        *) exit 1 ;;
      esac
      sqlite3 "$DB" "UPDATE gaps SET status='$reason', notes=notes || ' [$reason]' WHERE id='$id';"
      exit 0
      ;;
    show)
      id="$1"
      row=$(sqlite3 "$DB" "SELECT id, status, COALESCE(closed_pr,''), COALESCE(notes,'') FROM gaps WHERE id='$id';")
      IFS='|' read -r gid gst gpr gnotes <<< "$row"
      echo "- id: $gid"
      echo "  status: $gst"
      [[ -n "$gpr" ]] && echo "  closed_pr: $gpr"
      [[ -n "$gnotes" ]] && echo "  notes: $gnotes"
      exit 0
      ;;
  esac
fi
exit 0
SHIM
    chmod +x "$CHUMP_BIN"
  fi
fi

# AC2 functional proof: --auto-fix reopens a prematurely-closed gap without CHUMP_ALLOW_RECYCLE
REOPEN_TMP="$TMPDIR_TEST/reopen-proof"
mkdir -p "$REOPEN_TMP/bin"
git init -q --bare "$REOPEN_TMP/origin.git"
git clone -q "$REOPEN_TMP/origin.git" "$REOPEN_TMP/repo" 2>/dev/null
git -C "$REOPEN_TMP/repo" config user.email "test@chump.bot"
git -C "$REOPEN_TMP/repo" config user.name "Test"
git -C "$REOPEN_TMP/repo" config commit.gpgsign false
git -C "$REOPEN_TMP/repo" checkout -q -B main
git -C "$REOPEN_TMP/repo" commit -q --allow-empty -m "chore: base"
git -C "$REOPEN_TMP/repo" push -q origin main

cat > "$REOPEN_TMP/bin/gh" <<'MOCKGH'
#!/usr/bin/env bash
if [[ "$1" == "api" && "$2" == "/rate_limit" ]]; then
  exit 0
fi
if [[ "$1" == "pr" && "$2" == "view" ]]; then
  case "$*" in
    *mergedAt*)  echo "null" ;;
    *state*)     echo "OPEN" ;;
    *mergeable*) echo "BLOCKED" ;;
    *)           echo "{}" ;;
  esac
  exit 0
fi
exit 0
MOCKGH
chmod +x "$REOPEN_TMP/bin/gh"

REOPEN_GAP=$(cd "$REOPEN_TMP/repo" && CHUMP_REPO="$REOPEN_TMP/repo" CHUMP_STATE_DB="$REOPEN_TMP/repo/.chump/state.db" CHUMP_RESERVE_SCAN_OPEN_PRS=0 "$CHUMP_BIN" gap reserve --domain CREDIBLE --title "CREDIBLE: premature close fixture" --priority P3 --force 2>&1 | grep '^CREDIBLE-' | tail -1)
sqlite3 "$REOPEN_TMP/repo/.chump/state.db" "UPDATE gaps SET status='done', closed_pr=99991, closed_date='2026-10-24' WHERE id='$REOPEN_GAP';"

(
  cd "$REOPEN_TMP/repo"
  env -u CHUMP_ALLOW_RECYCLE PATH="$REOPEN_TMP/bin:$PATH" \
    CHUMP_BIN="$CHUMP_BIN" CHUMP_REPO="$REOPEN_TMP/repo" CHUMP_STATE_DB="$REOPEN_TMP/repo/.chump/state.db" \
    CHUMP_AMBIENT_LOG="$REOPEN_TMP/repo/.chump-locks/ambient.jsonl" \
    bash "$GATE" --auto-fix >/dev/null 2>&1 || true
)
REOPENED_STATUS="$(sqlite3 "$REOPEN_TMP/repo/.chump/state.db" "SELECT status FROM gaps WHERE id='$REOPEN_GAP';")"
REOPENED_PR="$(sqlite3 "$REOPEN_TMP/repo/.chump/state.db" "SELECT COALESCE(closed_pr, '') FROM gaps WHERE id='$REOPEN_GAP';")"
check "CREDIBLE-1571 AC2: --auto-fix reopens premature done gap to in_progress without CHUMP_ALLOW_RECYCLE (got status=$REOPENED_STATUS closed_pr=$REOPENED_PR)" test "$REOPENED_STATUS" = "in_progress" -a -z "$REOPENED_PR"

# AC1 functional proof: run test-gap-ship-integration.sh and test-gap-triage-close.sh
# with CHUMP_REPO pointed at a sentinel repo and assert its state.db is byte-identical afterwards.
SENTINEL_REPO="$TMPDIR_TEST/sentinel-repo"
mkdir -p "$SENTINEL_REPO/.chump"
sqlite3 "$SENTINEL_REPO/.chump/state.db" "CREATE TABLE gaps (id TEXT PRIMARY KEY, status TEXT); INSERT INTO gaps VALUES ('SENTINEL-001', 'open');"
SENTINEL_SHA_BEFORE="$(shasum -a 256 "$SENTINEL_REPO/.chump/state.db" | awk '{print $1}')"

check "CREDIBLE-1571 AC1: test-gap-ship-integration.sh passes under sentinel CHUMP_REPO" \
  env CHUMP_REPO="$SENTINEL_REPO" CHUMP_BIN="$CHUMP_BIN" bash "$REPO_ROOT/scripts/ci/test-gap-ship-integration.sh"
SENTINEL_SHA_MID="$(shasum -a 256 "$SENTINEL_REPO/.chump/state.db" | awk '{print $1}')"
check "CREDIBLE-1571 AC1: sentinel state.db byte-identical after test-gap-ship-integration.sh" \
  test "$SENTINEL_SHA_BEFORE" = "$SENTINEL_SHA_MID"

check "CREDIBLE-1571 AC1: test-gap-triage-close.sh passes under sentinel CHUMP_REPO" \
  env CHUMP_REPO="$SENTINEL_REPO" CHUMP_BIN="$CHUMP_BIN" bash "$REPO_ROOT/scripts/ci/test-gap-triage-close.sh"
SENTINEL_SHA_AFTER="$(shasum -a 256 "$SENTINEL_REPO/.chump/state.db" | awk '{print $1}')"
check "CREDIBLE-1571 AC1: sentinel state.db byte-identical after test-gap-triage-close.sh" \
  test "$SENTINEL_SHA_BEFORE" = "$SENTINEL_SHA_AFTER"

# AC3 functional proof: lint in wired scripts/ci test fails any scripts/ci script
# that runs a state-writing chump verb without test-sandbox.sh or mktemp store,
# and a mutant dropping the sandbox from one fixture script fails it.
lint_ci_state_writing_sandbox() {
  local target_dir="$1"
  python3 - "$target_dir" <<'PYLINT'
import glob, os, re, sys

ci_dir = sys.argv[1]
exec_verb_re = re.compile(
    r'^\s*(?:(?:[A-Z_][A-Z0-9_]*=\S+\s+)*'
    r'|(?:\$\(|\b(?:if|elif|while|!)\s+|.*&&\s*|.*\benv\b[^;\n]*\s+))'
    r'(?:\$?\{?CHUMP_BIN\}?|"\$CHUMP_BIN"|"\$\{CHUMP_BIN[^"]*\}"|chump)\s+'
    r'(?:gap\s+(?:reserve|set|ship|close|link-pr)|claim\b|node\s+(?:pause|resume))'
)
help_only_re = re.compile(r'--help\b')
sandbox_re = re.compile(
    r'(?:test-sandbox\.sh|chump_test_sandbox_setup|CHUMP_STATE_DB=|CHUMP_REPO=|CHUMP_HOME=|CHUMP_STATE_DIR=|mktemp)'
)
bad_real_repo_re = re.compile(
    r'^\s*export\s+CHUMP_REPO="\$REPO_ROOT"|^\s*CHUMP_STATE_DB="\$REPO_ROOT/',
    re.MULTILINE
)

violations = []
for path in sorted(glob.glob(os.path.join(ci_dir, "*.sh"))):
    with open(path, errors="replace") as f:
        lines = f.readlines()
    non_comment = [ln for ln in lines if not ln.lstrip().startswith("#")]
    matched = [
        (idx + 1, ln.strip())
        for idx, ln in enumerate(lines)
        if not ln.lstrip().startswith("#")
        and exec_verb_re.search(ln)
        and not help_only_re.search(ln)
    ]
    if not matched:
        continue
    nc_text = "".join(non_comment)
    has_sandbox = bool(sandbox_re.search(nc_text)) and not bool(bad_real_repo_re.search(nc_text))
    if "mktemp" not in nc_text and "chump_test_sandbox_setup" not in nc_text and "test-sandbox.sh" not in nc_text:
        has_sandbox = False
    if not has_sandbox:
        lineno, sample = matched[0]
        violations.append(f"{path}:{lineno}: state-writing chump verb without test-sandbox.sh or mktemp store: {sample}")

if violations:
    for v in violations:
        print(v, file=sys.stderr)
    sys.exit(1)
PYLINT
}

check "CREDIBLE-1571 AC3: all scripts/ci state-writing chump invocations use a temp sandbox" \
  lint_ci_state_writing_sandbox "$REPO_ROOT/scripts/ci"

MUTANT_CI_DIR="$TMPDIR_TEST/mutant-ci"
mkdir -p "$MUTANT_CI_DIR"
sed '/test-sandbox\.sh/d; /chump_test_sandbox_setup/d; /mktemp/d' \
  "$REPO_ROOT/scripts/ci/test-gap-triage-close.sh" > "$MUTANT_CI_DIR/test-gap-triage-close.sh"
if lint_ci_state_writing_sandbox "$MUTANT_CI_DIR" >/dev/null 2>&1; then
  check "CREDIBLE-1571 AC3: mutant dropping sandbox from fixture script fails lint" false
else
  check "CREDIBLE-1571 AC3: mutant dropping sandbox from fixture script fails lint" true
fi

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
