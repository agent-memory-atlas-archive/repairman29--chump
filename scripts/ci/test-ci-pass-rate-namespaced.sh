#!/usr/bin/env bash
# CI test for INFRA-3847 (parent INFRA-3841 slice 4/9): the fleet has two
# distinct CI pass-rate metrics that must never collapse into a bare "CI
# pass rate":
#   - scripts/ops/vital-signs.sh sign #3 — success/decided CI *runs* in 24h.
#   - scripts/ops/ci-qa-score.sh (via dashboard.rs) — % of merged *PRs*
#     landed without a bypass signal.
#
# Without the fix, vital-signs.sh emits the run-level metric under the
# ambiguous key `ci_pass_rate` (no `ci_run_pass_rate` key exists) — this
# test fails on main pre-fix and passes once the sign is renamed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VITAL_SIGNS_SH="${REPO_ROOT}/scripts/ops/vital-signs.sh"

FAIL=0
ok()   { echo "  [ok] $*"; }
fail() { echo "  [FAIL] $*" >&2; FAIL=1; }

echo "[test-ci-pass-rate-namespaced] INFRA-3847 — the two CI pass-rates carry distinct column names"

if [[ ! -f "$VITAL_SIGNS_SH" ]]; then
    echo "  [FAIL] scripts/ops/vital-signs.sh not found" >&2
    exit 1
fi
command -v jq >/dev/null 2>&1 || { echo "  [FAIL] jq not found" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.chump-locks"
touch "$TMP/.chump-locks/ambient.jsonl"

out="$(CHUMP_REPO_ROOT="$TMP" CHUMP_AMBIENT_LOG="$TMP/.chump-locks/ambient.jsonl" \
       bash "$VITAL_SIGNS_SH" --dry-run 2>/dev/null)"

run_key_present="$(printf '%s' "$out" | jq -e '.signs[]|select(.key=="ci_run_pass_rate")' >/dev/null 2>&1 && echo yes || echo no)"
[[ "$run_key_present" == "yes" ]] && ok "vital-signs.sh sign carries the distinctly-named 'ci_run_pass_rate' key" \
  || fail "'ci_run_pass_rate' key missing from vital-signs.sh --dry-run output"

bare_key_present="$(printf '%s' "$out" | jq -e '.signs[]|select(.key=="ci_pass_rate")' >/dev/null 2>&1 && echo yes || echo no)"
[[ "$bare_key_present" == "no" ]] && ok "bare 'ci_pass_rate' key no longer present" \
  || fail "bare 'ci_pass_rate' key still present — must be renamed to 'ci_run_pass_rate'"

echo "[dashboard.rs CiQaScore carries the distinctly-named ci_clean_landing_pct field]"
if grep -q 'pub ci_clean_landing_pct: f64' "${REPO_ROOT}/crates/chump-fleet-server/src/dashboard.rs"; then
    ok "CiQaScore struct declares ci_clean_landing_pct"
else
    fail "CiQaScore struct missing ci_clean_landing_pct field"
fi

echo "[no bare 'CI pass rate' name label in vital-signs.sh]"
if grep -qi '"CI Pass Rate"' "$VITAL_SIGNS_SH"; then
    fail "vital-signs.sh still labels a sign the bare 'CI Pass Rate' — must say 'CI Run Pass Rate'"
else
    ok "no bare 'CI Pass Rate' label in vital-signs.sh"
fi

if [[ "$FAIL" -ne 0 ]]; then
    echo "[test-ci-pass-rate-namespaced] FAILED" >&2
    exit 1
fi
echo "[test-ci-pass-rate-namespaced] PASSED"
