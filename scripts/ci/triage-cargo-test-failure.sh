#!/usr/bin/env bash
# scripts/ci/triage-cargo-test-failure.sh — CREDIBLE-013 (2026-06-04)
#
# Classify cargo test / cargo nextest failures as flake / real / known-bug / unknown.
#
# Usage:
#   bash scripts/ci/triage-cargo-test-failure.sh < cargo-test-output.txt
#   bash scripts/ci/triage-cargo-test-failure.sh --file path/to/output.txt
#
# Exit 0 ALWAYS. Verdict on stdout. Diagnostics on stderr.
#
# Verdict logic:
#   ALL failed tests in KNOWN_FLAKES.yaml  →  flake
#   ANY failed test matches open known-bug gap title  →  known-bug
#   failed tests NOT in KNOWN_FLAKES  →  real
#   empty / unparseable input  →  unknown
#
# Environment overrides:
#   KNOWN_FLAKES_YAML    path to KNOWN_FLAKES.yaml (default: docs/process/KNOWN_FLAKES.yaml)
#   CHUMP_AMBIENT_LOG    path to ambient.jsonl (default: .chump-locks/ambient.jsonl)
#   CHUMP_GAP_DB         path to state.db (default: .chump/state.db)
#   CHUMP_TRIAGE_OFFLINE=1         skip known-bug gap lookup (faster in offline / no-DB envs)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

KNOWN_FLAKES="${KNOWN_FLAKES_YAML:-$REPO_ROOT/docs/process/KNOWN_FLAKES.yaml}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

# ── Parse arguments ────────────────────────────────────────────────────────────
INPUT_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --file) INPUT_FILE="$2"; shift 2 ;;
    --file=*) INPUT_FILE="${1#*=}"; shift ;;
    *) shift ;;
  esac
done

# ── Read cargo test output ─────────────────────────────────────────────────────
if [[ -n "$INPUT_FILE" ]]; then
  if [[ ! -r "$INPUT_FILE" ]]; then
    echo "TRIAGE: unknown — input file not readable: $INPUT_FILE"
    exit 0
  fi
  RAW_INPUT="$(cat "$INPUT_FILE")"
else
  # Read from stdin (non-blocking; may already be closed)
  RAW_INPUT="$(cat || true)"
fi

if [[ -z "$RAW_INPUT" ]]; then
  echo "TRIAGE: unknown — empty input (no cargo test output received)"
  _emit_verdict "unknown" 0 0 0
  exit 0
fi

# ── Extract failed test names ──────────────────────────────────────────────────
# Handles three cargo test output formats:
#   (1)  test module::sub::name ... FAILED
#   (2)  ---- module::sub::name stdout ----
#   (3)  failures: block listing test paths
#
# We produce a deduplicated set: one test path per line, stored in FAILED_TESTS.

_extract_failed_tests() {
  local raw
  # CREDIBLE-1532: strip ANSI SGR escape sequences before matching so colorized
  # nextest / cargo test logs parse identically to plain text.
  raw="$(printf '%s\n' "$1" | sed -E 's/\x1b\[[0-9;]*[mGKH]//g')"
  {
    # Format 1: "test foo::bar ... FAILED"
    printf '%s\n' "$raw" \
      | grep -E '^test [a-zA-Z0-9_:]+[[:space:]]+\.\.\..*FAILED' \
      | sed -E 's/^test ([a-zA-Z0-9_:]+)[[:space:]]+\.\.\..*FAILED.*$/\1/'

    # Format 2: "---- foo::bar stdout ----"
    printf '%s\n' "$raw" \
      | grep -E '^---- [a-zA-Z0-9_:]+ stdout ----' \
      | sed -E 's/^---- ([a-zA-Z0-9_:]+) stdout ----.*$/\1/'

    # Format 3: "failures:" block — lines after "failures:" that look like paths
    # until a blank line or "test result:" line (includes top-level integration
    # tests without a `::` module prefix).
    printf '%s\n' "$raw" \
      | awk '/^failures:[[:space:]]*$/{in_block=1; next}
             in_block && /^[[:space:]]*$/{in_block=0; next}
             in_block && /^test result:/{in_block=0; next}
             in_block{
               sub(/^[[:space:]]+/, "")
               sub(/[[:space:]]+$/, "")
               if ($0 ~ /^[a-zA-Z_][a-zA-Z0-9_]*(::[a-zA-Z0-9_]+)*$/) print $0
             }'

    # Format 4: nextest output "FAIL [  xxx s] (N/M) crate::bin test_name"
    # Capture the LAST identifier/path token on each FAIL [...] line so
    # progress columns, hyphenated crate names, and top-level integration test
    # names (without `::`) are all extracted accurately.
    printf '%s\n' "$raw" \
      | grep -E '(^|[[:space:]])FAIL \[[^]]*\]' \
      | sed -E 's/.*[[:space:]]([a-zA-Z_][a-zA-Z0-9_:]*)[[:space:]]*$/\1/'
  } | grep -E '^[a-zA-Z_][a-zA-Z0-9_:]*$' | sort -u
}

FAILED_TESTS="$(_extract_failed_tests "$RAW_INPUT")"

if [[ -z "$FAILED_TESTS" ]]; then
  # Output present but no parseable test failures; treat as unknown
  echo "TRIAGE: unknown — cargo output present but no FAILED test names parsed"
  _emit_verdict "unknown" 0 0 0
  exit 0
fi

FAILED_COUNT="$(printf '%s\n' "$FAILED_TESTS" | grep -c .)"

# ── Load known flakes ──────────────────────────────────────────────────────────
# We need the list of test names from KNOWN_FLAKES.yaml flakes[].test
# Try python3 first; fall back to grep.

_load_known_flakes() {
  if [[ ! -f "$KNOWN_FLAKES" ]]; then
    echo ""
    return
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - <<'PYEOF' 2>/dev/null || true
import sys, yaml
try:
    with open(sys.argv[1]) as f:
        data = yaml.safe_load(f) or {}
    for entry in data.get('flakes', []):
        test = entry.get('test', '') if isinstance(entry, dict) else ''
        if test:
            print(test)
except Exception:
    pass
PYEOF
    # Pass the filename to the heredoc via positional arg trick
    python3 -c "
import yaml, sys
try:
    with open('$KNOWN_FLAKES') as f:
        data = yaml.safe_load(f) or {}
    for entry in data.get('flakes', []):
        if isinstance(entry, dict) and entry.get('test'):
            print(entry['test'])
except Exception:
    pass
" 2>/dev/null || true
  else
    # grep-based fallback: look for lines matching "  - test: "
    grep -E '^[[:space:]]+- test:' "$KNOWN_FLAKES" \
      | sed -E 's/^[[:space:]]+-[[:space:]]+test:[[:space:]]+"?([^"#]+)"?[[:space:]]*(#.*)?$/\1/' \
      | sed 's/[[:space:]]*$//' \
      | grep -v '^$' || true
  fi
}

KNOWN_FLAKE_TESTS="$(_load_known_flakes)"

# ── Cross-reference: classify each failed test ─────────────────────────────────
FLAKE_COUNT=0
REAL_COUNT=0
FLAKE_NAMES=()
REAL_NAMES=()

while IFS= read -r test_name; do
  [[ -z "$test_name" ]] && continue
  if printf '%s\n' "$KNOWN_FLAKE_TESTS" | grep -qxF "$test_name"; then
    FLAKE_COUNT=$((FLAKE_COUNT + 1))
    FLAKE_NAMES+=("$test_name")
  else
    REAL_COUNT=$((REAL_COUNT + 1))
    REAL_NAMES+=("$test_name")
  fi
done < <(printf '%s\n' "$FAILED_TESTS")

# ── Known-bug gap lookup ───────────────────────────────────────────────────────
# If there are real (non-flake) failures, search open gap titles for matching
# test name fragments. Uses chump gap list --status open --json when available.
#
# Skip if CHUMP_TRIAGE_OFFLINE=1 (offline environments).

_find_known_bug_gap() {
  local test_name="$1"
  local gap_db="${CHUMP_GAP_DB:-$REPO_ROOT/.chump/state.db}"

  # Method 1: SQLite direct query (fastest, no chump CLI needed)
  if command -v sqlite3 >/dev/null 2>&1 && [[ -f "$gap_db" ]]; then
    local fragment
    # Extract the last two components (e.g. "module::test_fn" → search for "test_fn")
    fragment="$(printf '%s' "$test_name" | rev | cut -d: -f1 | rev)"
    sqlite3 "$gap_db" \
      "SELECT id FROM gaps WHERE status='open' AND LOWER(title) LIKE LOWER('%${fragment}%') LIMIT 1;" \
      2>/dev/null || true
    return
  fi

  # Method 2: chump CLI JSON output
  if command -v chump >/dev/null 2>&1 && [[ "${CHUMP_TRIAGE_OFFLINE:-0}" != "1" ]]; then
    local fragment
    fragment="$(printf '%s' "$test_name" | rev | cut -d: -f1 | rev)"
    chump gap list --status open --json 2>/dev/null \
      | python3 -c "
import json, sys
data = json.load(sys.stdin)
frag = '$fragment'.lower()
for g in (data if isinstance(data, list) else data.get('gaps', [])):
    title = str(g.get('title', '')).lower()
    if frag in title:
        print(g.get('id', ''))
        break
" 2>/dev/null || true
    return
  fi
}

KNOWN_BUG_GAP=""
KNOWN_BUG_TEST=""
if [[ $REAL_COUNT -gt 0 && "${CHUMP_TRIAGE_OFFLINE:-0}" != "1" ]]; then
  for test_name in "${REAL_NAMES[@]:-}"; do
    [[ -z "$test_name" ]] && continue
    gap_id="$(_find_known_bug_gap "$test_name")"
    if [[ -n "$gap_id" ]]; then
      KNOWN_BUG_GAP="$gap_id"
      KNOWN_BUG_TEST="$test_name"
      break
    fi
  done
fi

# ── Emit verdict ───────────────────────────────────────────────────────────────
_emit_verdict() {
  local verdict="$1"
  local failed_count="$2"
  local flake_count="$3"
  local real_count="$4"
  local commit="${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null || echo "unknown")}"
  local job="${GITHUB_JOB:-local}"
  local pr_number="${GITHUB_PR_NUMBER:-${PR_NUMBER:-}}"

  mkdir -p "$(dirname "$AMBIENT_LOG")" 2>/dev/null || true
  printf '{"ts":"%s","kind":"ci_triage_verdict","verdict":"%s","failed_test_count":%d,"flake_test_count":%d,"real_test_count":%d,"commit":"%s","job":"%s","pr_number":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$verdict" \
    "$failed_count" \
    "$flake_count" \
    "$real_count" \
    "$commit" \
    "$job" \
    "$pr_number" \
    >> "$AMBIENT_LOG" 2>/dev/null || true
}

# ── Determine final verdict ────────────────────────────────────────────────────
if [[ $FAILED_COUNT -eq 0 ]]; then
  echo "TRIAGE: unknown — no failed tests found in input"
  _emit_verdict "unknown" 0 0 0
  exit 0
fi

if [[ -n "$KNOWN_BUG_GAP" ]]; then
  echo "TRIAGE: known-bug — $KNOWN_BUG_TEST matches open gap $KNOWN_BUG_GAP; $FLAKE_COUNT flake / $REAL_COUNT real of $FAILED_COUNT total"
  _emit_verdict "known-bug" "$FAILED_COUNT" "$FLAKE_COUNT" "$REAL_COUNT"
elif [[ $REAL_COUNT -eq 0 && $FLAKE_COUNT -gt 0 ]]; then
  FLAKE_LIST="$(printf '%s ' "${FLAKE_NAMES[@]:-}" | sed 's/ $//')"
  echo "TRIAGE: flake — all $FLAKE_COUNT failed test(s) are registered flakes: $FLAKE_LIST"
  _emit_verdict "flake" "$FAILED_COUNT" "$FLAKE_COUNT" 0
elif [[ $REAL_COUNT -gt 0 ]]; then
  REAL_LIST="$(printf '%s ' "${REAL_NAMES[@]:-}" | sed 's/ $//')"
  echo "TRIAGE: real — $REAL_COUNT test(s) not in flake catalog (need fix): $REAL_LIST"
  if [[ $FLAKE_COUNT -gt 0 ]]; then
    FLAKE_LIST="$(printf '%s ' "${FLAKE_NAMES[@]:-}" | sed 's/ $//')"
    echo "         ($FLAKE_COUNT known-flake also present: $FLAKE_LIST)"
  fi
  _emit_verdict "real" "$FAILED_COUNT" "$FLAKE_COUNT" "$REAL_COUNT"
else
  echo "TRIAGE: unknown — $FAILED_COUNT failure(s) but classification logic fell through"
  _emit_verdict "unknown" "$FAILED_COUNT" 0 0
fi
