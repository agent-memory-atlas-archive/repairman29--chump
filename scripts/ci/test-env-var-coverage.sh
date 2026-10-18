#!/usr/bin/env bash
# Asserts that every env var read by Chump's Rust source is either:
#   (a) mentioned in .env.example, OR
#   (b) listed in scripts/ci/env-vars-internal.txt
#
# Run: bash scripts/ci/test-env-var-coverage.sh
# Exit 0 = pass.  Exit 1 = gaps found (prints offenders to stderr).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INTERNAL_LIST="$REPO_ROOT/scripts/ci/env-vars-internal.txt"
ENV_EXAMPLE="$REPO_ROOT/.env.example"
DEBT_LIST="$REPO_ROOT/scripts/ci/env-vars-crates-debt.txt"

if [[ ! -f "$INTERNAL_LIST" ]]; then
  echo "ERROR: $INTERNAL_LIST not found" >&2
  exit 1
fi
if [[ ! -f "$ENV_EXAMPLE" ]]; then
  echo "ERROR: $ENV_EXAMPLE not found" >&2
  exit 1
fi
if [[ ! -f "$DEBT_LIST" ]]; then
  echo "ERROR: $DEBT_LIST not found" >&2
  exit 1
fi

# Extract all var names from src/ AND crates/**/src/ (CREDIBLE-239 — the gate
# used to scan src/ only, so any var read exclusively from a workspace crate
# was invisible and the fleet has been actively extracting code into crates/).
crate_src_dirs=$(find "$REPO_ROOT/crates" -type d -name src)
# shellcheck disable=SC2086
src_vars=$(grep -rn 'std::env::var\b\|env::var(' "$REPO_ROOT/src/" $crate_src_dirs \
  | grep -oE '"[A-Z][A-Z0-9_]+"' | tr -d '"' | sort -u)

# Build lookup sets
env_example_vars=$(grep -oE '[A-Z][A-Z0-9_]{3,}' "$ENV_EXAMPLE" | sort -u)
# RESILIENT-1618: new internal vars land as per-entry fragments under
# scripts/ci/env-vars.d/ (new files never conflict on GitHub, unlike appends to
# the monolith). Audit the COMPLETE generated view (frozen base + fragments).
internal_vars=$(bash "$REPO_ROOT/scripts/ci/gen-registries.sh" env-vars | grep -v '^#' | grep -v '^$' | sort -u)
debt_vars=$(grep -v '^#' "$DEBT_LIST" | grep -v '^$' | sort -u)

fail=0
missing=()
debt=0

while IFS= read -r var; do
  in_example=$(echo "$env_example_vars" | grep -Fx "$var" || true)
  in_internal=$(echo "$internal_vars" | grep -Fx "$var" || true)
  in_debt=$(echo "$debt_vars" | grep -Fx "$var" || true)
  if [[ -z "$in_example" && -z "$in_internal" && -n "$in_debt" ]]; then
    debt=$((debt + 1))
    continue
  fi
  if [[ -z "$in_example" && -z "$in_internal" ]]; then
    missing+=("$var")
    fail=1
  fi
done <<< "$src_vars"

if [[ $fail -eq 0 ]]; then
  total=$(echo "$src_vars" | wc -l | tr -d ' ')
  echo "PASS: all $total env vars (src/ + crates/) are documented, allowlisted, or tracked debt."
  if [[ $debt -gt 0 ]]; then
    echo "NOTE: $debt var(s) are known documentation debt — see scripts/ci/env-vars-crates-debt.txt" >&2
  fi
  exit 0
fi

echo "FAIL: ${#missing[@]} env var(s) are neither in .env.example, scripts/ci/env-vars-internal.txt, nor scripts/ci/env-vars-crates-debt.txt:" >&2
for v in "${missing[@]}"; do
  echo "  $v" >&2
done
echo "" >&2
echo "Fix by either:" >&2
echo "  1. Adding to .env.example (Tier 1 — operator-tunable)" >&2
echo "  2. Adding to scripts/ci/env-vars-internal.txt (Tier 2/3 — debug/runtime/test)" >&2
echo "  3. If this is pre-existing crates/ debt you can't triage right now, add to scripts/ci/env-vars-crates-debt.txt (temporary — must be triaged out, see file header)" >&2
exit 1
