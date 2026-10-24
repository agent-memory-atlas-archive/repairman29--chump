#!/usr/bin/env bash
# scripts/ci/test-audit-lanes-green.sh — CREDIBLE-1532 / CREDIBLE-1533 / CREDIBLE-1536 / CREDIBLE-1540
#
# Regression gate for the 4 remaining PHASE-R R3 CI/audit workflow slices:
#   1. CREDIBLE-1532: crates/chump-coord/src/events.rs captures initial EOF offset
#      synchronously at subscribe time + FILE_POLL_INTERVAL_MS <= 100, and
#      scripts/ci/test-triage-cargo-test-failure.sh passes (including ANSI + top-level nextest).
#   2. CREDIBLE-1533: scripts/ci/test-tauri-filter-scope.sh passes (no bare src/** in tauri filter).
#   3. CREDIBLE-1536: .cargo/audit.toml, deny.toml, and .github/workflows/cargo-audit-nightly.yml
#      carry synchronized RUSTSEC ignore lists documented in docs/security/RUSTSEC-AUDIT.md.
#   4. CREDIBLE-1540: scripts/audit/run-all.sh invokes `cargo deny --format human check advisories bans`
#      (not the broken `cargo deny check --format human`) and .github/workflows/audit-weekly.yml
#      captures `exit=$rc` under `set +e`.
#   5. docs/process/CI_GATES_INVENTORY.md records rows 2, 3, 6, 10 as Resolved.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

PASS=0
FAIL=0

pass() {
  echo "  [PASS] $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "  [FAIL] $1" >&2
  FAIL=$((FAIL + 1))
}

echo "=== test-audit-lanes-green (CREDIBLE-1532 / 1533 / 1536 / 1540) ==="

# 1. CREDIBLE-1532 checks
if grep -q 'const FILE_POLL_INTERVAL_MS: u64 = 100;' crates/chump-coord/src/events.rs &&
   grep -q 'run_file_subscriber_with_start(filter, tx, log_path, initial_offset)' crates/chump-coord/src/events.rs; then
  pass "CREDIBLE-1532: events.rs captures initial_offset synchronously and polls at 100ms"
else
  fail "CREDIBLE-1532: events.rs missing synchronous initial_offset capture or 100ms poll interval"
fi

if bash scripts/ci/test-triage-cargo-test-failure.sh >/dev/null 2>&1; then
  pass "CREDIBLE-1532: scripts/ci/test-triage-cargo-test-failure.sh passes"
else
  fail "CREDIBLE-1532: scripts/ci/test-triage-cargo-test-failure.sh failed"
fi

# 2. CREDIBLE-1533 checks
if bash scripts/ci/test-tauri-filter-scope.sh >/dev/null 2>&1; then
  pass "CREDIBLE-1533: scripts/ci/test-tauri-filter-scope.sh passes"
else
  fail "CREDIBLE-1533: scripts/ci/test-tauri-filter-scope.sh failed"
fi

# 3. CREDIBLE-1536 checks: synchronized RUSTSEC ignore sets across .cargo/audit.toml, deny.toml, cargo-audit-nightly.yml
if [[ -f .cargo/audit.toml ]] && [[ -f deny.toml ]] && [[ -f .github/workflows/cargo-audit-nightly.yml ]]; then
  audit_ids="$(grep -oE 'RUSTSEC-[0-9]{4}-[0-9]{4}' .cargo/audit.toml | sort -u)"
  deny_ids="$(grep -oE 'RUSTSEC-[0-9]{4}-[0-9]{4}' deny.toml | sort -u)"
  nightly_ids="$(grep -oE 'RUSTSEC-[0-9]{4}-[0-9]{4}' .github/workflows/cargo-audit-nightly.yml | sort -u)"
  if [[ -n "$audit_ids" && "$audit_ids" == "$deny_ids" && "$audit_ids" == "$nightly_ids" ]]; then
    pass "CREDIBLE-1536: .cargo/audit.toml, deny.toml, and cargo-audit-nightly.yml have identical RUSTSEC ignore sets"
  else
    fail "CREDIBLE-1536: RUSTSEC ignore sets differ across .cargo/audit.toml, deny.toml, and cargo-audit-nightly.yml"
  fi
else
  fail "CREDIBLE-1536: missing .cargo/audit.toml, deny.toml, or cargo-audit-nightly.yml"
fi

if grep -q 'CREDIBLE-1536 / CREDIBLE-1540' docs/security/RUSTSEC-AUDIT.md; then
  pass "CREDIBLE-1536: docs/security/RUSTSEC-AUDIT.md documents 2026-10-24 triage"
else
  fail "CREDIBLE-1536: docs/security/RUSTSEC-AUDIT.md missing 2026-10-24 triage section"
fi

# 4. CREDIBLE-1540 checks: run-all.sh and audit-weekly.yml
if grep -q 'cargo deny --format human check advisories bans' scripts/audit/run-all.sh &&
   ! grep -q 'cargo deny check --format human' scripts/audit/run-all.sh; then
  pass "CREDIBLE-1540: scripts/audit/run-all.sh uses valid cargo deny --format human check advisories bans syntax"
else
  fail "CREDIBLE-1540: scripts/audit/run-all.sh still uses broken cargo deny check --format human syntax"
fi

if grep -q 'echo "exit=\$rc" >> "\$GITHUB_OUTPUT"' .github/workflows/audit-weekly.yml; then
  pass "CREDIBLE-1540: .github/workflows/audit-weekly.yml captures exit=\$rc before exiting"
else
  fail "CREDIBLE-1540: .github/workflows/audit-weekly.yml missing exit=\$rc capture"
fi

# 5. Inventory table resolution check
for gap_tag in "Resolved (CREDIBLE-1532)" "Resolved (CREDIBLE-1533)" "Resolved (CREDIBLE-1536)" "Resolved (CREDIBLE-1540)"; do
  if grep -qF "$gap_tag" docs/process/CI_GATES_INVENTORY.md; then
    pass "CI_GATES_INVENTORY.md records $gap_tag"
  else
    fail "CI_GATES_INVENTORY.md missing $gap_tag"
  fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
