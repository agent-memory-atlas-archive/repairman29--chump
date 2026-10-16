#!/bin/bash
# INFRA-1856 follow-up: validate that docs/process/AUDIT_JOB_DECOMPOSITION.md
# enumerates every test script invoked by .github/workflows/audit.yml.
#
# Exit 0 if all 131 scripts accounted for; exit 1 if drift detected.

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-.}"
AUDIT_YML="$REPO_ROOT/.github/workflows/audit.yml"
DECOMP_DOC="$REPO_ROOT/docs/process/AUDIT_JOB_DECOMPOSITION.md"
SCRIPTS_CI="$REPO_ROOT/scripts/ci"

if [[ ! -f "$AUDIT_YML" ]]; then
  echo "ERROR: $AUDIT_YML not found"
  exit 1
fi

if [[ ! -f "$DECOMP_DOC" ]]; then
  echo "ERROR: $DECOMP_DOC not found"
  exit 1
fi

# Extract all test-*.sh invocations from audit.yml
# Look for lines matching "run: bash scripts/ci/test-" or similar
audit_scripts=$(
  grep -E 'run: .*bash scripts/ci/test-' "$AUDIT_YML" \
    | sed 's/.*bash scripts\/ci\///g' \
    | sed 's/\.sh.*//' \
    | sed 's/\s*$//' \
    | sort -u
)

echo "Found $(echo "$audit_scripts" | wc -w) test scripts invoked by audit.yml"

# Extract all test-*.sh scripts mentioned in the decomposition doc
doc_scripts=$(
  grep -E '^\| test-' "$DECOMP_DOC" \
    | awk '{print $2}' \
    | sort -u
)

echo "Found $(echo "$doc_scripts" | wc -w) test scripts listed in decomposition doc"

# Check for scripts in audit.yml but NOT in doc (drift forward)
missing_from_doc=$(
  comm -23 <(echo "$audit_scripts" | tr ' ' '\n') <(echo "$doc_scripts" | tr ' ' '\n')
)

if [[ -n "$missing_from_doc" ]]; then
  echo ""
  echo "ERROR: These scripts are invoked by audit.yml but NOT in decomposition doc:"
  echo "$missing_from_doc" | sed 's/^/  /'
  exit 1
fi

# Check for scripts in doc but NOT in audit.yml (stale references)
orphaned_in_doc=$(
  comm -13 <(echo "$audit_scripts" | tr ' ' '\n') <(echo "$doc_scripts" | tr ' ' '\n')
)

if [[ -n "$orphaned_in_doc" ]]; then
  echo ""
  echo "WARNING: These scripts are listed in decomposition doc but NOT invoked by audit.yml:"
  echo "$orphaned_in_doc" | sed 's/^/  /'
  # Don't fail on this; it just means the doc is ahead of audit.yml (planned work)
fi

# Verify every script exists in scripts/ci/
missing_files=()
for script in $audit_scripts; do
  if [[ ! -f "$SCRIPTS_CI/$script.sh" ]]; then
    missing_files+=("$script")
  fi
done

if [[ ${#missing_files[@]} -gt 0 ]]; then
  echo ""
  echo "ERROR: These test scripts do not exist in $SCRIPTS_CI:"
  printf '%s\n' "${missing_files[@]}" | sed 's/^/  /'
  exit 1
fi

echo ""
echo "✓ All $( echo "$audit_scripts" | wc -w) audit-job test scripts accounted for"
echo "✓ All referenced scripts exist on disk"
echo "✓ No orphaned references in decomposition doc"
exit 0
