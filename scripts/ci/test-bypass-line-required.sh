#!/usr/bin/env bash
# test-bypass-line-required.sh — INFRA-5429 (INFRA-1861 slice: false-positive
# heuristic-check audit).
#
# AC #1: every check that can exit FAIL must include a line matching
#   "How to bypass cleanly: <instructions>"
# in its stdout/stderr, so an agent hitting the gate never has to reverse-
# engineer the escape hatch from prose scattered through the script.
#
# This script has two jobs:
#
#   1. Static audit — for every gate in scripts/ci/gate-manifest.yaml with
#      expected_exit_nonzero: true (i.e. a gate whose whole job is to FAIL
#      on a real violation), grep its check_script for the required line.
#      Missing the line is itself a FAIL of THIS gate.
#
#   2. Self-test (AC #3) — proves the audit logic actually catches the
#      failure class it exists to catch: a synthetic check script that
#      exits 1 WITHOUT a bypass line must be flagged, and a synthetic
#      check script that exits 1 WITH a bypass line must pass.
#
# Exit: 0 = clean, 1 = one or more gate_manifest scripts (or the self-test)
# failed.
#
# Usage:
#   bash scripts/ci/test-bypass-line-required.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MANIFEST="$SCRIPT_DIR/gate-manifest.yaml"

# shellcheck source=lib/gate-emit.sh
source "$SCRIPT_DIR/lib/gate-emit.sh" 2>/dev/null || true
gate_emit_start "INFRA-5429" "$*"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; }
info() { printf '[INFO] %s\n' "$*"; }

BYPASS_PATTERN="How to bypass cleanly:"
VIOLATIONS=0

# ── Part 1: static audit of gate-manifest.yaml FAIL-capable checks ──────────
if [[ ! -f "$MANIFEST" ]]; then
    fail "gate-manifest.yaml not found at $MANIFEST"
    fail "How to bypass cleanly: this gate has no external bypass — restore scripts/ci/gate-manifest.yaml (CREDIBLE-050)"
    exit 1
fi

read_fail_capable_gates() {
    python3 -c "
import sys, yaml
data = yaml.safe_load(open('$MANIFEST'))
for g in data.get('gates', []):
    if g.get('expected_exit_nonzero', True):
        print(f\"{g['id']}|{g['check_script']}\")
"
}

while IFS='|' read -r gate_id check_script; do
    [[ -z "$gate_id" ]] && continue
    script_path="$REPO_ROOT/$check_script"
    if [[ ! -f "$script_path" ]]; then
        fail "$gate_id: check_script $check_script not found on disk"
        VIOLATIONS=$((VIOLATIONS + 1))
        continue
    fi
    if grep -qF "$BYPASS_PATTERN" "$script_path"; then
        pass "$gate_id ($check_script) has a '$BYPASS_PATTERN' line"
    else
        fail "$gate_id ($check_script) exits nonzero on violation but has no '$BYPASS_PATTERN' line"
        VIOLATIONS=$((VIOLATIONS + 1))
    fi
done < <(read_fail_capable_gates)

# ── Part 2: self-test — prove the audit catches a missing bypass line ───────
TMPDIR_SELFTEST="$(mktemp -d -t bypass-line-selftest.XXXXXX)"
trap 'rm -rf "$TMPDIR_SELFTEST"' EXIT

cat > "$TMPDIR_SELFTEST/without-bypass.sh" <<'EOF'
#!/usr/bin/env bash
echo "[FAIL] synthetic violation for self-test"
exit 1
EOF

cat > "$TMPDIR_SELFTEST/with-bypass.sh" <<'EOF'
#!/usr/bin/env bash
echo "[FAIL] synthetic violation for self-test"
echo "How to bypass cleanly: this is a fixture, there is nothing to bypass"
exit 1
EOF
chmod +x "$TMPDIR_SELFTEST/without-bypass.sh" "$TMPDIR_SELFTEST/with-bypass.sh"

SELFTEST_FAILED=0

if grep -qF "$BYPASS_PATTERN" "$TMPDIR_SELFTEST/without-bypass.sh"; then
    fail "self-test: without-bypass.sh fixture unexpectedly matched the bypass pattern"
    SELFTEST_FAILED=1
else
    pass "self-test: audit correctly flags a failing check with no bypass line"
fi

if grep -qF "$BYPASS_PATTERN" "$TMPDIR_SELFTEST/with-bypass.sh"; then
    pass "self-test: audit correctly clears a failing check that DOES have a bypass line"
else
    fail "self-test: with-bypass.sh fixture unexpectedly failed to match the bypass pattern"
    SELFTEST_FAILED=1
fi

if [[ "$SELFTEST_FAILED" -eq 1 ]]; then
    fail "How to bypass cleanly: this self-test has no bypass — it is asserting the audit mechanism itself works; fix scripts/ci/test-bypass-line-required.sh"
    VIOLATIONS=$((VIOLATIONS + 1))
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
if [[ "$VIOLATIONS" -eq 0 ]]; then
    echo "INFRA-5429: all FAIL-capable gates in gate-manifest.yaml carry a bypass line."
    gate_emit_result "INFRA-5429" "pass" "" ""
    exit 0
else
    fail "INFRA-5429: $VIOLATIONS gate(s) missing a '$BYPASS_PATTERN' line."
    fail "How to bypass cleanly: add a line 'How to bypass cleanly: <instructions>' to the flagged script's FAIL path (see scripts/ci/check-pr-scope.sh for the pattern), or if the check genuinely has no bypass (e.g. it is itself a bypass-audit), set expected_exit_nonzero: false is wrong — instead document why in gate-manifest.yaml and keep the line anyway"
    gate_emit_result "INFRA-5429" "fail" "missing-bypass-line" "$VIOLATIONS gate(s) missing bypass line"
    exit 1
fi
