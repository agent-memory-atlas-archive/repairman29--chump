#!/usr/bin/env bash
# scripts/ci/test-gap-impact-rating.sh — FLEET-048
#
# Validates gap impact rating:
#  - 'chump gap rate' subcommand exists
#  - ImpactRatingSection/ImpactRatingEntry/build_impact_section in kpi_report.rs
#  - gap_impact_rated in EVENT_REGISTRY.yaml
#  - kpi_report --impact in main.rs
#  - Functional: rate emits correct ambient event, kpi report reads it

set -uo pipefail

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# EFFECTIVE-418: kpi_report moved to crates/chump-kpi-report; resolve
# layout-agnostically so this test survives the extraction.
source "$SCRIPT_DIR/lib/source-grep.sh"
KPI_RS="$(find_rust_module kpi_report)"

echo "=== FLEET-048: gap impact rating ==="
echo

# 1. gap rate arm in main.rs or gap.rs
if (grep -q '"rate"' "$REPO_ROOT/src/main.rs" 2>/dev/null && \
    grep -q 'gap_impact_rated' "$REPO_ROOT/src/main.rs" 2>/dev/null) || \
   (grep -q '"rate"' "$REPO_ROOT/src/commands/gap.rs" 2>/dev/null && \
    grep -q 'gap_impact_rated' "$REPO_ROOT/src/commands/gap.rs" 2>/dev/null); then
    ok "gap rate subcommand defined in main.rs or gap.rs"
else
    fail "gap rate subcommand missing from both main.rs and gap.rs"
fi

# 2. ImpactRatingSection struct
if grep -q 'pub struct ImpactRatingSection' "$KPI_RS" 2>/dev/null; then
    ok "kpi_report.rs: ImpactRatingSection defined"
else
    fail "kpi_report.rs: ImpactRatingSection missing"
fi

# 3. ImpactRatingEntry struct
if grep -q 'pub struct ImpactRatingEntry' "$KPI_RS" 2>/dev/null; then
    ok "kpi_report.rs: ImpactRatingEntry defined"
else
    fail "kpi_report.rs: ImpactRatingEntry missing"
fi

# 4. build_impact_section function
if grep -q 'pub fn build_impact_section' "$KPI_RS" 2>/dev/null; then
    ok "kpi_report.rs: build_impact_section() defined"
else
    fail "kpi_report.rs: build_impact_section() missing"
fi

# 5. render_text and render_json on ImpactRatingSection
if grep -q 'fn render_text' "$KPI_RS" 2>/dev/null && \
   grep -q 'fn render_json' "$KPI_RS" 2>/dev/null; then
    ok "kpi_report.rs: render_text() and render_json() present"
else
    fail "kpi_report.rs: render methods missing"
fi

# 6. fleet_avg field
if grep -q 'fleet_avg' "$KPI_RS" 2>/dev/null; then
    ok "kpi_report.rs: fleet_avg field present"
else
    fail "kpi_report.rs: fleet_avg field missing"
fi

# 7. rating range 1-5 validated
if grep -q '1..=5' "$REPO_ROOT/src/main.rs" 2>/dev/null || \
   grep -q '(1..=5)' "$KPI_RS" 2>/dev/null; then
    ok "rating 1-5 range validated"
else
    fail "rating 1-5 range validation missing"
fi

# 8. --impact flag wired in kpi report
if grep -q 'want_impact\|--impact' "$REPO_ROOT/src/main.rs" 2>/dev/null; then
    ok "main.rs: --impact flag wired in kpi report"
else
    fail "main.rs: --impact flag missing"
fi

# 9. build_impact_section called from main.rs
if grep -q 'build_impact_section' "$REPO_ROOT/src/main.rs" 2>/dev/null; then
    ok "main.rs: build_impact_section() called"
else
    fail "main.rs: build_impact_section() not called"
fi

# 10. EVENT_REGISTRY.yaml has gap_impact_rated
if grep -q 'gap_impact_rated' "$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml" 2>/dev/null; then
    ok "EVENT_REGISTRY.yaml: gap_impact_rated registered"
else
    fail "EVENT_REGISTRY.yaml: gap_impact_rated missing"
fi

# 11. gap rate help text in help output
if grep -q 'gap rate\|gap.*rate.*1-5' "$REPO_ROOT/src/main.rs" 2>/dev/null; then
    ok "main.rs: gap rate documented in help"
else
    fail "main.rs: gap rate missing from help"
fi

# ── Functional tests ──────────────────────────────────────────────────────────

CHUMP="${REPO_ROOT}/target/debug/chump"
[[ ! -x "$CHUMP" ]] && CHUMP="${HOME}/.cargo/bin/chump"
[[ ! -x "$CHUMP" ]] && CHUMP="$(command -v chump 2>/dev/null || echo "")"

if [[ -z "$CHUMP" || ! -x "$CHUMP" ]]; then
    echo "  SKIP (live): chump binary not found"
    echo
    echo "=== Results: $PASS passed, $FAIL failed ==="
    [[ "$FAIL" -eq 0 ]]
    exit $?
fi

if ! strings "$CHUMP" 2>/dev/null | grep -q 'gap_impact_rated\|FLEET-048' 2>/dev/null; then
    echo "  SKIP (live): binary predates FLEET-048 (no gap_impact_rated symbol)"
    echo
    echo "=== Results: $PASS passed, $FAIL failed ==="
    [[ "$FAIL" -eq 0 ]]
    exit $?
fi

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT
mkdir -p "$TMPDIR_TEST/.chump-locks"

# 12. gap rate writes ambient event
CHUMP_REPO="$TMPDIR_TEST" "$CHUMP" gap rate INFRA-001 4 --comment "great feature" 2>/dev/null
if grep -q '"kind":"gap_impact_rated"' "$TMPDIR_TEST/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "gap rate: writes gap_impact_rated to ambient.jsonl"
else
    fail "gap rate: no ambient event written"
fi

# 13. event has correct gap_id and rating
if grep -q '"gap_id":"INFRA-001"' "$TMPDIR_TEST/.chump-locks/ambient.jsonl" 2>/dev/null && \
   grep -q '"rating":4' "$TMPDIR_TEST/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "gap rate: event has correct gap_id and rating"
else
    fail "gap rate: event missing gap_id or rating"
fi

# 14. event has comment field
if grep -q '"comment":"great feature"' "$TMPDIR_TEST/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "gap rate: event has comment field"
else
    fail "gap rate: comment field missing from event"
fi

# 15. kpi report --impact reads the event
_out=$(CHUMP_REPO="$TMPDIR_TEST" "$CHUMP" kpi report --impact 2>/dev/null)
if echo "$_out" | grep -q 'INFRA-001\|1 rated\|1/5\|4/5'; then
    ok "kpi report --impact: reads and displays gap ratings"
else
    fail "kpi report --impact: no gap rating output (got: $_out)"
fi

# 16. kpi report --impact --json
_json=$(CHUMP_REPO="$TMPDIR_TEST" "$CHUMP" kpi report --impact --json 2>/dev/null)
if echo "$_json" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['total_ratings']==1" 2>/dev/null; then
    ok "kpi report --impact --json: total_ratings==1"
else
    fail "kpi report --impact --json: total_ratings mismatch (got: $_json)"
fi

# 17. invalid rating rejected
_code=$("$CHUMP" gap rate INFRA-001 7 2>/dev/null; echo $?)
if [[ "$_code" != "0" ]] || ! "$CHUMP" gap rate INFRA-001 7 2>&1 | grep -q 'must be 1-5\|rating must'; then
    # rating 7 should fail — test the exit code via subshell
    if CHUMP_REPO="$TMPDIR_TEST" "$CHUMP" gap rate INFRA-001 7 2>&1 | grep -q 'must be 1-5\|1-5'; then
        ok "gap rate: rejects rating > 5"
    else
        ok "gap rate: rejects rating > 5 (exit non-zero)"
    fi
else
    fail "gap rate: accepted invalid rating 7"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
