#!/usr/bin/env bash
# scripts/ci/test-no-coe-pr-reporting.sh — CREDIBLE-1522 (PHASE-R R3, CREDIBLE-1492 AC1)
#
# Fails when .github/workflows/ci.yml grows a NEW top-level job that carries
# `continue-on-error: true` at the JOB level — such a job posts a check-run to
# the PR whose conclusion is ALWAYS success regardless of what its steps did (a
# green check carrying no information — the R3 "honest ship gate" defect).
#
# A job may stay continue-on-error ONLY if it is listed in
# scripts/ci/coe-pr-reporting-allowlist.txt with a recorded decision (and the
# matching row in docs/process/CI_GATES_INVENTORY.md). Any job-level
# continue-on-error job NOT on the allowlist fails this test.
#
# Scope is deliberately JOB-LEVEL only: a workflow STEP with
# continue-on-error:true does not post its own PR check-run (the job does), so
# step-level continue-on-error is out of scope — it is the sanctioned INFRA-1869
# advisory-demotion mechanism and does not make a PR check lie.
#
# Mirrored in `chump preflight` (crates/chump-preflight/src/preflight.rs) and run
# in ci.yml's fast-checks job (which feeds the required `verified` lane).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CI_YML="${CHUMP_COE_CI_YML:-$REPO_ROOT/.github/workflows/ci.yml}"
ALLOWLIST="${CHUMP_COE_ALLOWLIST:-$REPO_ROOT/scripts/ci/coe-pr-reporting-allowlist.txt}"

fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
pass() { printf '[PASS] %s\n' "$*"; }

[ -f "$CI_YML" ] || fail "ci.yml not found at $CI_YML"
[ -f "$ALLOWLIST" ] || fail "allowlist not found at $ALLOWLIST"

command -v python3 >/dev/null 2>&1 || fail "python3 required to parse ci.yml"

# Emit the set of job-level continue-on-error job keys, one per line. PyYAML is a
# hard requirement across this repo's CI (EVENT_REGISTRY parity gate), so parse
# the real structure rather than grep — step-level continue-on-error must NOT be
# counted, and only a parser can tell job-level from step-level reliably.
coe_jobs="$(
  CHUMP_COE_CI_YML="$CI_YML" python3 - <<'PY'
import os, sys
try:
    import yaml
except ImportError:
    sys.stderr.write("PyYAML not importable\n")
    sys.exit(3)
path = os.environ["CHUMP_COE_CI_YML"]
with open(path) as fh:
    doc = yaml.safe_load(fh)
jobs = (doc or {}).get("jobs", {}) or {}
for name, spec in jobs.items():
    if not isinstance(spec, dict):
        continue
    coe = spec.get("continue-on-error")
    if coe is True or (isinstance(coe, str) and coe.strip().lower() == "true"):
        print(name)
PY
)" || fail "failed to parse ci.yml for job-level continue-on-error"

# Load the allowlist (strip comments + blanks).
allow="$(grep -vE '^[[:space:]]*(#|$)' "$ALLOWLIST" | sed 's/[[:space:]].*$//' || true)"

# Any job-level continue-on-error job NOT on the allowlist is a violation.
violations=""
while IFS= read -r job; do
  [ -n "$job" ] || continue
  if ! printf '%s\n' "$allow" | grep -qxF "$job"; then
    violations="${violations}${job}\n"
  fi
done <<< "$coe_jobs"

if [ -n "$violations" ]; then
  printf '%b' "$violations" >&2
  fail "the above ci.yml job(s) carry job-level continue-on-error: true and report a PR check but are not in $ALLOWLIST.
Make the job required-and-green (remove continue-on-error) or delete it; if it must stay non-blocking, add it to the allowlist with a decision AND a row in docs/process/CI_GATES_INVENTORY.md (CREDIBLE-1492 AC1)."
fi

# Hygiene: an allowlist entry that no longer matches a job-level continue-on-error
# job is stale (the list may only shrink). Warn — do not fail — so a legitimate
# removal/promotion is never blocked by a dangling line.
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  if ! printf '%s\n' "$coe_jobs" | grep -qxF "$entry"; then
    printf '[warn] allowlist entry %q no longer matches a job-level continue-on-error job — drop it from %s\n' \
      "$entry" "$ALLOWLIST" >&2
  fi
done <<< "$allow"

n_jobs="$(printf '%s\n' "$coe_jobs" | grep -cvE '^$' || true)"
pass "no un-allowlisted job-level continue-on-error PR-reporting job in ci.yml ($n_jobs allowlisted)"
