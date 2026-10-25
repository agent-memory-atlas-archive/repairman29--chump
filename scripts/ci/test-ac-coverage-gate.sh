#!/usr/bin/env bash
# INFRA-1541: Smoke test for chump pr ac-coverage
# Exercises 3 fixtures: full-coverage pass, missing-bullet fail, waiver bypass
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHUMP="${CARGO_TARGET_DIR:-$ROOT/target}/debug/chump"
if [[ ! -x "$CHUMP" ]] && [[ -x "/Users/jeffadkins/Projects/Chump/target/debug/chump" ]]; then
  CHUMP="/Users/jeffadkins/Projects/Chump/target/debug/chump"
elif [[ ! -x "$CHUMP" ]] && command -v chump >/dev/null 2>&1; then
  CHUMP="$(command -v chump)"
fi
PASS=0 FAIL=0

emit() { printf '[%s] %s\n' "$1" "$2"; }
pass() { emit PASS "$1"; PASS=$((PASS+1)); }
fail() { emit FAIL "$1"; FAIL=$((FAIL+1)); }

# ─── fixture helper ───────────────────────────────────────────────────────────
# We inject a mock 'gh' and a fake gap YAML to avoid real API calls.

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Fake gap YAML + stub chump gap show (CREDIBLE-178 reads via CHUMP_REAL_BINARY)
mkdir -p "$TMP/docs/gaps"
cat > "$TMP/docs/gaps/INFRA-9999.yaml" <<'YAML'
- id: INFRA-9999
  acceptance_criteria:
    - "File src/pr_ac_coverage.rs must exist and implement run()"
    - "Shell wrapper scripts/ci/test-pr-ac-coverage.sh must be a 3-line exec"
YAML
cat > "$TMP/chump-stub" <<'SH'
#!/usr/bin/env bash
echo '{"acceptance_criteria":"[\"File src/pr_ac_coverage.rs must exist and implement run()\",\"Shell wrapper scripts/ci/test-pr-ac-coverage.sh must be a 3-line exec\"]"}'
SH
chmod +x "$TMP/chump-stub"
export CHUMP_REAL_BINARY="$TMP/chump-stub"

# ─── Fixture 1: full-coverage pass ───────────────────────────────────────────
# Add a diff that covers BOTH bullets
cat > "$TMP/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"pr view"*)
    echo '{"title":"INFRA-9999: test PR","body":"","commits":[{"messageHeadline":"feat","messageBody":""}]}';;
  *"pr diff"*)
    echo '+++ b/src/pr_ac_coverage.rs'
    echo '+pub fn run() {}'
    echo '+++ b/scripts/ci/test-pr-ac-coverage.sh'
    echo '+exec chump pr ac-coverage "$@"';;
  *) echo "mock-gh: unhandled: $*" >&2; exit 1;;
esac
SH
chmod +x "$TMP/gh"

if CHUMP_GH="$TMP/gh" CHUMP_REPO_ROOT="$TMP" "$CHUMP" pr ac-coverage 9999 > "$TMP/f1.json" 2>&1; then
  pass "fixture-1: full-coverage exits 0"
else
  fail "fixture-1: full-coverage expected exit 0, got $?"
fi
if grep -q '"status":"pass"' "$TMP/f1.json" 2>/dev/null; then
  pass "fixture-1: JSON status=pass"
else
  fail "fixture-1: JSON status=pass not found in: $(cat "$TMP/f1.json" 2>/dev/null)"
fi

# ─── Fixture 2: missing-bullet fail ──────────────────────────────────────────
cat > "$TMP/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"pr view"*)
    echo '{"title":"INFRA-9999: test PR","body":"","commits":[{"messageHeadline":"feat","messageBody":""}]}';;
  *"pr diff"*)
    echo '+++ b/src/unrelated.rs'
    echo '+some unrelated code';;
  *) echo "mock-gh: unhandled: $*" >&2; exit 1;;
esac
SH
chmod +x "$TMP/gh"

if CHUMP_AC_GATE_ADVISORY=false CHUMP_GH="$TMP/gh" CHUMP_REPO_ROOT="$TMP" "$CHUMP" pr ac-coverage 9999 > "$TMP/f2.json" 2>"$TMP/f2.err"; then
  fail "fixture-2: missing-bullet should exit non-zero, got 0"
else
  pass "fixture-2: missing-bullet exits non-zero"
fi

# ─── Fixture 3: waiver bypass ─────────────────────────────────────────────────
cat > "$TMP/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"pr view"*)
    echo '{"title":"INFRA-9999: test PR","body":"AC-Coverage-Waive: 0: legacy path\nAC-Coverage-Waive: 1: not applicable","commits":[{"messageHeadline":"feat","messageBody":""}]}';;
  *"pr diff"*)
    echo '+++ b/src/unrelated.rs'
    echo '+nothing relevant';;
  *) echo "mock-gh: unhandled: $*" >&2; exit 1;;
esac
SH
chmod +x "$TMP/gh"

if CHUMP_GH="$TMP/gh" CHUMP_REPO_ROOT="$TMP" "$CHUMP" pr ac-coverage 9999 > "$TMP/f3.json" 2>&1; then
  pass "fixture-3: waiver-bypass exits 0"
else
  fail "fixture-3: waiver-bypass expected exit 0"
fi
if grep -q '"status":"pass"' "$TMP/f3.json" 2>/dev/null; then
  pass "fixture-3: JSON status=pass (waiver)"
else
  fail "fixture-3: JSON status=pass not found"
fi

# ─── Fixture 4 (CREDIBLE-1409): blocking by default when CHUMP_AC_GATE_ADVISORY is unset ───
cat > "$TMP/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"pr view"*)
    echo '{"title":"INFRA-9999: test PR","body":"","commits":[{"messageHeadline":"feat","messageBody":""}]}';;
  *"pr diff"*)
    echo '+++ b/src/other_file.rs'
    echo '+some unrelated code';;
  *) echo "mock-gh: unhandled: $*" >&2; exit 1;;
esac
SH
chmod +x "$TMP/gh"

if (unset CHUMP_AC_GATE_ADVISORY; CHUMP_GH="$TMP/gh" CHUMP_REPO_ROOT="$TMP" "$CHUMP" pr ac-coverage 9999 > "$TMP/f4.json" 2>"$TMP/f4.err"); then
  fail "fixture-4 (CREDIBLE-1409): missing-bullet with CHUMP_AC_GATE_ADVISORY unset should exit non-zero"
else
  pass "fixture-4 (CREDIBLE-1409): blocking by default when CHUMP_AC_GATE_ADVISORY is unset"
fi
if grep -q 'CHUMP_AC_GATE_ADVISORY:-false' "$ROOT/scripts/coord/bot-merge.sh"; then
  pass "fixture-4b (CREDIBLE-1409): bot-merge.sh auto-close enforces pr ac-coverage blocking by default"
else
  fail "fixture-4b (CREDIBLE-1409): bot-merge.sh missing default blocking ac-coverage gate"
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
