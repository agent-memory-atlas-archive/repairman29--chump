#!/usr/bin/env bash
# scripts/ci/test-rollup-not-blocked-by-flaky-job.sh — INFRA-1348
#
# Parses .github/workflows/ci.yml and asserts that every non-required CI job is
# either:
#   (a) continue-on-error: true  — failure becomes neutral in rollup state, OR
#   (b) PR-trigger excluded     — its `if:` condition never fires on pull_request
#
# Any job that fails (FAILURE conclusion) while NOT required by branch protection
# will flip statusCheckRollup.state → FAILURE, blocking auto-merge even when all
# required checks passed (the INFRA-1342 rollup-FAILURE trap).
#
# Branch-protection required checks (from .github/branch-protection-main.json or
# hardcoded below — update if branch protection changes):
#   test, audit, ACP protocol smoke test (Zed / JetBrains compatible)
# Plus the per-shard required rollups that feed into `test`:
#   clippy-required, cargo-test-required, fast-checks-required,
#   fast-checks-heavy-required, audit-required
#
# Acceptable statuses:
#   REQUIRED     — in branch protection; should fail loud, no change needed
#   COE          — continue-on-error: true; failure → neutral, not FAILURE
#   PR-EXCLUDED  — if: condition excludes pull_request events (e.g. push-only)
#   CORRECTNESS  — feeds into a required rollup (e.g. clippy → test); must fail
#
# Exit non-zero if any non-required job lacks both COE and PR-exclusion.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CI_YML="$REPO_ROOT/.github/workflows/ci.yml"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33mWARN\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; FAILURES=$((FAILURES+1)); }

FAILURES=0

[[ -f "$CI_YML" ]] || { echo "ERROR: $CI_YML not found"; exit 1; }

# Branch-protection required checks — jobs that MUST fail loud
REQUIRED_JOBS=(
    test
    audit
    # ACP protocol smoke test is an external check (Zed/JetBrains), not a ci.yml job
)

# Jobs that feed required rollups — correctness gates, must also fail loud
CORRECTNESS_GATES=(
    fast-checks
    fast-checks-heavy
    clippy
    cargo-test
    pr-hygiene
    clippy-required
    cargo-test-required
    fast-checks-required
    fast-checks-heavy-required
    audit-required
)

# Parse ci.yml with Python for reliability
python3 - "$CI_YML" <<'PYEOF'
import sys, re

yml_path = sys.argv[1]
with open(yml_path) as f:
    content = f.read()

# Find jobs: section
jobs_start = content.index('\njobs:\n')
jobs_section = content[jobs_start + 7:]

job_pattern = re.compile(r'^  ([a-z][a-z0-9_-]+):\s*$', re.MULTILINE)
positions = [(m.start(), m.group(1)) for m in job_pattern.finditer(jobs_section)]

required = {'test', 'audit', 'fast-checks', 'fast-checks-heavy', 'clippy',
            'cargo-test', 'pr-hygiene',
            'clippy-required', 'cargo-test-required',
            'fast-checks-required', 'fast-checks-heavy-required', 'audit-required'}

issues = []
audited = 0

for i, (pos, name) in enumerate(positions):
    end = positions[i+1][0] if i+1 < len(positions) else len(jobs_section)
    block = jobs_section[pos:end]

    if name in required:
        continue  # correctness gate — skip

    audited += 1
    has_coe = 'continue-on-error: true' in block

    # PR-excluded: if: condition mentions neither 'pull_request' nor lacks event gate
    if_match = re.search(r'\n    if:\s*(.*)', block)
    if_cond = if_match.group(1).strip() if if_match else ''
    # Check for multi-line if: block
    if if_cond.endswith('|'):
        ml = re.search(r'\n    if:\s*\|\n((?:      .*\n?)*)', block)
        if ml:
            if_cond = ml.group(1)
    pr_excluded = (
        'pull_request' not in if_cond and
        ('push' in if_cond or 'merge_group' in if_cond or 'workflow_dispatch' in if_cond)
    )

    if has_coe or pr_excluded:
        status = 'COE' if has_coe else 'PR-excluded'
        print(f"OK    {name:<30} [{status}]")
    else:
        issues.append(name)
        print(f"FAIL  {name:<30} [no COE, not PR-excluded — rollup-FAILURE trap risk]")

print(f"\nAudited {audited} non-required jobs.")
if issues:
    print(f"\nFAILING jobs ({len(issues)}): {', '.join(issues)}")
    sys.exit(1)
else:
    print("All non-required jobs are protected against rollup-FAILURE trap.")
PYEOF

if [[ $? -ne 0 ]]; then
    FAILURES=$((FAILURES+1))
fi

if [[ $FAILURES -eq 0 ]]; then
    ok "ALL INFRA-1348 rollup-FAILURE trap checks passed"
else
    echo ""
    fail "INFRA-1348: $FAILURES check(s) failed"
    echo "Fix: add 'continue-on-error: true' to each failing job, or restrict"
    echo "     its trigger to push/merge_group only (not pull_request)."
    exit 1
fi
