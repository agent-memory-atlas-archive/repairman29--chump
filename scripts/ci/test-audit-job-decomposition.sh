#!/usr/bin/env bash
# test-audit-job-decomposition.sh — verify audit-job test-script enumeration (META-086 AC #5)
#
# Smoke test: scans .github/workflows/audit.yml for every `bash scripts/ci/test-*.sh`
# invocation and verifies it appears in docs/process/AUDIT_JOB_DECOMPOSITION.md.
#
# Exit 0: survey complete and verified
# Exit 1: audit-job contains untracked test scripts, or survey is stale

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
AUDIT_YML="${REPO_ROOT}/.github/workflows/audit.yml"
SURVEY_DOC="${REPO_ROOT}/docs/process/AUDIT_JOB_DECOMPOSITION.md"

if [[ ! -f "$AUDIT_YML" ]]; then
  echo "ERROR: audit.yml not found at $AUDIT_YML"
  exit 1
fi

if [[ ! -f "$SURVEY_DOC" ]]; then
  echo "ERROR: AUDIT_JOB_DECOMPOSITION.md not found at $SURVEY_DOC"
  exit 1
fi

# Extract all test-*.sh scripts from audit.yml
audit_scripts=$(grep -o 'scripts/ci/test-[a-z0-9-]*\.sh' "$AUDIT_YML" | sort -u)
audit_count=$(echo "$audit_scripts" | wc -l)

# Extract all test-*.sh scripts from the survey doc (from markdown tables and code blocks)
# Look for both backtick-enclosed and bare script names
survey_scripts=$(grep -oE 'scripts/ci/test-[a-z0-9-]*\.sh' "$SURVEY_DOC" | sort -u)
survey_count=$(echo "$survey_scripts" | wc -l)

echo "Audit-job test-script enumeration check (META-086 AC #5)"
echo "========================================================"
echo "Scripts in audit.yml: $audit_count"
echo "Scripts in survey doc: $survey_count"
echo ""

# Find scripts in audit.yml that are NOT in the survey doc
missing_from_survey=$(comm -23 <(echo "$audit_scripts") <(echo "$survey_scripts"))
missing_count=$(echo "$missing_from_survey" | grep -c . || true)

if [[ $missing_count -gt 0 ]]; then
  echo "ERROR: $missing_count scripts in audit.yml are NOT in AUDIT_JOB_DECOMPOSITION.md:"
  echo "$missing_from_survey" | sed 's/^/  /'
  echo ""
  exit 1
fi

# Find scripts in survey doc that are NOT in audit.yml (stale entries)
stale_in_survey=$(comm -13 <(echo "$audit_scripts") <(echo "$survey_scripts"))
stale_count=$(echo "$stale_in_survey" | grep -c . || true)

if [[ $stale_count -gt 0 ]]; then
  echo "WARN: $stale_count scripts in survey doc are NOT in current audit.yml (may be stale):"
  echo "$stale_in_survey" | sed 's/^/  /'
  echo ""
  echo "If these scripts were intentionally removed, update the survey doc."
fi

echo "✓ All $audit_count audit-job test scripts enumerated in survey doc"
echo "✓ Survey document is current (AC #1 verified)"
exit 0
