#!/usr/bin/env bash
# test-triage-cargo-test-failure.sh — Smoke test for CREDIBLE-013 triage script.
#
# Tests 5 fixture cargo output scenarios:
#   1. all-flake    — all failures are known flakes  → verdict: flake
#   2. all-real     — failures not in flake catalog  → verdict: real
#   3. mixed        — some flakes, some real         → verdict: real (mixed)
#   4. empty        — no input                       → verdict: unknown
#   5. malformed    — non-cargo output               → verdict: unknown
#
# Uses a synthetic KNOWN_FLAKES.yaml and isolated AMBIENT_LOG.
# Does NOT touch the real KNOWN_FLAKES.yaml or real ambient.jsonl.
#
# Exit 0 = all assertions pass. Exit 1 = at least one failure.

set -uo pipefail

# RESILIENT-090: scrub GIT_DIR / GIT_WORK_TREE so isolated git inits in tmp
# don't inherit the caller's worktree context.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/scrub-git-env.sh"

# ── Test harness ──────────────────────────────────────────────────────────────
PASS=0
FAIL=0
_FAILURES=()

pass() { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); _FAILURES+=("$1"); printf '[FAIL] %s\n' "$1"; }

assert_verdict() {
  local label="$1"
  local expected_prefix="$2"
  local input="$3"
  local actual
  actual="$(printf '%s' "$input" | bash "$TRIAGE_SCRIPT" 2>/dev/null | head -1)"
  if [[ "$actual" == "$expected_prefix"* ]]; then
    pass "$label: got expected verdict '$expected_prefix'"
  else
    fail "$label: expected verdict starting with '$expected_prefix', got: '$actual'"
  fi
}

# ── Setup synthetic workspace ─────────────────────────────────────────────────
WORK_DIR="$(mktemp -d /tmp/chump-triage-test.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

SYNTHETIC_FLAKES="$WORK_DIR/KNOWN_FLAKES.yaml"
SYNTHETIC_AMBIENT="$WORK_DIR/ambient.jsonl"
touch "$SYNTHETIC_AMBIENT"

TRIAGE_SCRIPT="$REPO_ROOT/scripts/ci/triage-cargo-test-failure.sh"

# Synthetic KNOWN_FLAKES.yaml with a subset of flake test names for testing.
cat > "$SYNTHETIC_FLAKES" <<'EOF'
schema_version: 1
last_audit: "2026-06-04"

flakes:
  - test: known_flake_module::tests::test_env_race
    reason: "env-var contention under parallel execution"
    tracking_gap: INFRA-0001
    added: "2026-06-04"
    last_observed: "2026-06-04"
    max_reruns: 1

  - test: another_flake::tests::timing_sensitive
    reason: "timing-dependent test fails under load"
    tracking_gap: INFRA-0002
    added: "2026-06-04"
    last_observed: "2026-06-04"
    max_reruns: 1
EOF

# Export env so triage script uses synthetic files
export KNOWN_FLAKES_YAML="$SYNTHETIC_FLAKES"
export CHUMP_AMBIENT_LOG="$SYNTHETIC_AMBIENT"
export CHUMP_TRIAGE_OFFLINE=1   # skip gap DB lookup in unit test

# ── Fixture 1: all-flake ─────────────────────────────────────────────────────
# All failures are in the synthetic KNOWN_FLAKES.yaml.
ALL_FLAKE_INPUT='running 12 tests
test known_flake_module::tests::test_env_race ... FAILED
test another_flake::tests::timing_sensitive ... FAILED
test regular_module::tests::passes_fine ... ok
test other::tests::also_fine ... ok

failures:

---- known_flake_module::tests::test_env_race stdout ----
thread panicked at env var race

---- another_flake::tests::timing_sensitive stdout ----
thread panicked at timing assertion

failures:
    known_flake_module::tests::test_env_race
    another_flake::tests::timing_sensitive

test result: FAILED. 10 passed; 2 failed; 0 ignored; 0 measured; 0 filtered out'

assert_verdict "fixture-1 all-flake" "TRIAGE: flake" "$ALL_FLAKE_INPUT"

# ── Fixture 2: all-real ──────────────────────────────────────────────────────
# Failures are NOT in the flake catalog — these are genuine bugs.
ALL_REAL_INPUT='running 8 tests
test real_bug_module::tests::broken_calculation ... FAILED
test other_real::tests::assertion_fails ... FAILED
test working::tests::fine ... ok

failures:

---- real_bug_module::tests::broken_calculation stdout ----
left: 42
right: 0

---- other_real::tests::assertion_fails stdout ----
Expected Some(x) but got None

test result: FAILED. 6 passed; 2 failed; 0 ignored; 0 measured; 0 filtered out'

assert_verdict "fixture-2 all-real" "TRIAGE: real" "$ALL_REAL_INPUT"

# ── Fixture 3: mixed (some flake, some real) ──────────────────────────────────
# Mixed failures: verdict should be "real" because there are non-flake failures.
MIXED_INPUT='running 10 tests
test known_flake_module::tests::test_env_race ... FAILED
test real_bug_module::tests::logic_error ... FAILED
test fine::tests::passes ... ok

failures:

---- known_flake_module::tests::test_env_race stdout ----
env var race

---- real_bug_module::tests::logic_error stdout ----
assertion failed

test result: FAILED. 8 passed; 2 failed; 0 ignored; 0 measured; 0 filtered out'

assert_verdict "fixture-3 mixed" "TRIAGE: real" "$MIXED_INPUT"

# ── Fixture 4: empty input ────────────────────────────────────────────────────
assert_verdict "fixture-4 empty" "TRIAGE: unknown" ""

# ── Fixture 5: malformed (non-cargo output) ───────────────────────────────────
MALFORMED_INPUT='Lorem ipsum dolor sit amet, consectetur adipiscing elit.
This is not cargo test output.
No FAILED lines here.
No test names at all.'

assert_verdict "fixture-5 malformed" "TRIAGE: unknown" "$MALFORMED_INPUT"

# ── Fixture 6 (CREDIBLE-1532): ANSI-colored nextest + top-level integration test ─
NEXTEST_TOPLEVEL_INPUT="$(printf '\x1b[31m        FAIL\x1b[0m [   0.553s] (15/15) chump-coord::a2a_layer1a_nats \x1b[1mfile_fallback_delivers_event_within_500ms\x1b[0m\n')"
assert_verdict "fixture-6 nextest-ansi-toplevel" "TRIAGE: real" "$NEXTEST_TOPLEVEL_INPUT"


# ── Ambient emit check ────────────────────────────────────────────────────────
# Verify that the ambient.jsonl received at least one ci_triage_verdict event.
if grep -q '"kind":"ci_triage_verdict"' "$SYNTHETIC_AMBIENT" 2>/dev/null; then
  pass "ambient.jsonl: ci_triage_verdict events emitted"
else
  fail "ambient.jsonl: no ci_triage_verdict events found (expected at least 1)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  echo "Failed assertions:"
  for f in "${_FAILURES[@]}"; do
    echo "  - $f"
  done
  exit 1
fi
exit 0
