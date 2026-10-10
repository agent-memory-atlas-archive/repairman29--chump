#!/usr/bin/env bash
# test-preflight-ci-parity-synthetic-pr.sh — RESILIENT-550 (RESILIENT-545 slice)
#
# Builds a throwaway git repo (with a local bare "origin"), commits a baseline
# ci.yml, then commits a synthetic PR that adds a NEW job with an unmirrored
# gate and NO exceptions entry. Runs a copy of test-preflight-ci-parity.sh
# inside that repo and asserts it exits 0 (the new job is auto-recognized) and
# prints the auto-recognition message, not an "Unmirrored gate" failure.
# Control: a gate added to an EXISTING job must still be blocked (exit 1).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PARITY_SRC="$REPO_ROOT/scripts/ci/test-preflight-ci-parity.sh"

PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

T="$(mktemp -d -t test-pf-parity-synth-pr.XXXXXX)"
trap 'rm -rf "$T"' EXIT

git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/repo" 2>/dev/null
cd "$T/repo"
git config user.email t@example.com; git config user.name t
git checkout -q -b main
mkdir -p .github/workflows scripts/ci crates/chump-preflight/src docs/process
cp "$PARITY_SRC" scripts/ci/test-preflight-ci-parity.sh
echo "// fixture preflight.rs" > crates/chump-preflight/src/preflight.rs
printf '# fixture\n\n## Tier D\n\n| Gate | Reason |\n|---|---|\n' > docs/process/CI_GATES_INVENTORY.md
echo 'noop  # reason: baseline fixture' > scripts/ci/preflight-ci-parity-exceptions.txt
cat > .github/workflows/ci.yml <<'YML'
name: ci
on: [push]
jobs:
  existing:
    runs-on: ubuntu-latest
    steps:
      - name: noop
        run: echo hi
YML
git add -A; git commit -q -m baseline
git push -q origin main 2>/dev/null
git fetch -q origin main

export CHUMP_AMBIENT_LOG="$T/ambient.jsonl"

# ── Scenario 1: new job, unmirrored gate, no exceptions entry ────────────────
git checkout -q -b synthetic-pr
cat >> .github/workflows/ci.yml <<'YML'
  brand-new-job:
    runs-on: ubuntu-latest
    steps:
      - name: brand new gate
        run: bash scripts/ci/test-brand-new-gate-RESILIENT-550.sh
YML
git commit -qam "add new job"
bash scripts/ci/test-preflight-ci-parity.sh >"$T/out1.log" 2>&1
rc=$?
[[ $rc -eq 0 ]] && ok "new job without exceptions entry passes (exit 0)" || { bad "expected exit 0, got $rc"; cat "$T/out1.log"; }
grep -q "Auto-recognized gate in ci.yml job='brand-new-job'" "$T/out1.log" \
  && ok "output reports auto-recognition of the new job" || bad "missing auto-recognition message"
grep -q "Unmirrored gate.*brand new gate" "$T/out1.log" && bad "newly added gate still reported as unmirrored" || ok "no unmirrored-gate failure for new gate"

# ── Scenario 2 (control): step added to an existing job is still blocked ─────
git checkout -q main
git checkout -q -b synthetic-pr-existing-job
cat >> .github/workflows/ci.yml <<'YML'
      - name: sneaky gate
        run: bash scripts/ci/test-sneaky-gate-RESILIENT-550.sh
YML
git commit -qam "add step to existing job"
bash scripts/ci/test-preflight-ci-parity.sh >"$T/out2.log" 2>&1
rc=$?
[[ $rc -eq 1 ]] && ok "step added to existing job is blocked (exit 1)" || { bad "expected exit 1, got $rc"; cat "$T/out2.log"; }
grep -q "Unmirrored gate in ci.yml job='existing': step='sneaky gate'" "$T/out2.log" \
  && ok "block message names the unmirrored gate" || bad "block message missing"

echo; echo "test-preflight-ci-parity-synthetic-pr: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
