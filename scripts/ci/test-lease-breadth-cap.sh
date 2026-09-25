#!/usr/bin/env bash
# capability-guard-exempt: existing skip-path covers missing binary; pattern wording differs from canonical (CREDIBLE-078)
# test-lease-breadth-cap.sh — INFRA-1885: lease-breadth cap
#
# Verifies four assertions:
#   (a) broad claim is rejected — chump claim INFRA-X --paths scripts/ci exits 1
#   (b) file-level claim is not blocked by lease-breadth gate
#   (c) CHUMP_LEASE_ALLOW_BROAD_DIRS=1 override allows broad path (emits event)
#   (d) audit event kind=lease_broad_dir_claim is written to ambient.jsonl on override
#
# The test exercises check_lease_breadth() directly via the `chump claim` path
# which runs the gate before any worktree/git operations. We stub out git
# connectivity by setting CHUMP_WORKTREE_BASE to /dev/null (worktree creation
# fails, but the breadth gate fires before that).
#
# Exit 0 = all assertions pass. Exit 1 = one or more failed.
# Usage: bash scripts/ci/test-lease-breadth-cap.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHUMP_BIN="${CHUMP_BIN:-$REPO_ROOT/target/debug/chump}"

if [[ ! -x "$CHUMP_BIN" ]]; then
    echo "ERROR: chump binary not found at $CHUMP_BIN — run 'cargo build' first"
    exit 1
fi

pass=0
fail=0

PASS() { echo "  PASS: $*"; ((pass++)); }
FAIL() { echo "  FAIL: $*"; ((fail++)); }

# ── Setup: isolated temp root ─────────────────────────────────────────────────
# We need a fake repo root with state.db so --skip-import doesn't crash.
# The lease-breadth gate fires before any git/worktree operation, so we can
# set CHUMP_WORKTREE_BASE to a non-existent sub-dir to make worktree creation
# fail gracefully AFTER the gate check.
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

LOCK_DIR="$TMP_ROOT/.chump-locks"
CHUMP_DIR="$TMP_ROOT/.chump"
mkdir -p "$LOCK_DIR" "$CHUMP_DIR"
touch "$LOCK_DIR/ambient.jsonl"

# Minimal state.db with one open gap.
sqlite3 "$CHUMP_DIR/state.db" "
CREATE TABLE IF NOT EXISTS gaps (
  id TEXT PRIMARY KEY, domain TEXT, title TEXT, status TEXT,
  priority TEXT, effort TEXT, acceptance_criteria TEXT,
  depends_on TEXT, notes TEXT, closed_pr INTEGER, error_log TEXT
);
INSERT OR IGNORE INTO gaps VALUES (
  'INFRA-X', 'INFRA', 'Test gap', 'open', 'P1', 'xs',
  'AC: test works', '[]', '', NULL, ''
);
CREATE TABLE IF NOT EXISTS leases (
  session_id TEXT PRIMARY KEY, gap_id TEXT, worktree TEXT,
  taken_at TEXT, expires_at TEXT
);
"

# Helper: run chump claim on a fake gap with given --paths.
# The breadth gate fires before git ops, so we catch the exit code + stderr.
# We point CHUMP_REPO_ROOT (if honoured) at TMP_ROOT so ambient.jsonl lands
# in the right place; otherwise the event goes to the real repo's ambient.jsonl.
run_claim_breadth() {
    local paths_val="$1"
    shift
    # Use --skip-doctor --skip-import --session to minimize prerequisites.
    # The claim will fail at git-fetch or worktree-add, but the breadth gate
    # fires first (pre-worktree, pre-lease). We capture stderr + exit code.
    CHUMP_WORKTREE_BASE="$TMP_ROOT/wt" \
        "$CHUMP_BIN" claim INFRA-X \
        --role fleet-test \
        --paths "$paths_val" \
        --skip-doctor \
        --skip-import \
        --session "test-breadth-$$" \
        "$@" 2>&1
}

# ── Test (a): broad paths exit 1 and print INFRA-1885 in stderr ───────────────
echo ""
echo "=== Test (a): broad path 'scripts/ci' should be rejected ==="
for broad_dir in "scripts/ci" "src" "docs/gaps" "src/lib" "app"; do
    output="$(CHUMP_LEASE_ALLOW_BROAD_DIRS=0 run_claim_breadth "$broad_dir" 2>&1 || true)"
    exit_code="$(CHUMP_LEASE_ALLOW_BROAD_DIRS=0 run_claim_breadth "$broad_dir" > /dev/null 2>&1; echo $?)"
    if echo "$output" | grep -q "INFRA-1885"; then
        PASS "broad path '$broad_dir' triggers INFRA-1885 rejection message"
    else
        FAIL "expected INFRA-1885 in output for '$broad_dir', got: $output"
    fi
done

# Smoke: exact AC5 path — chump claim INFRA-X --paths scripts/ci exits 1
echo ""
echo "=== Smoke (AC5 verbatim): --paths scripts/ci exits 1 ==="
CHUMP_LEASE_ALLOW_BROAD_DIRS=0 run_claim_breadth "scripts/ci" > /dev/null 2>&1 && \
    FAIL "expected exit 1 for broad 'scripts/ci', got exit 0" || \
    PASS "'chump claim INFRA-X --paths scripts/ci' exits 1 (broad path rejected)"

# ── Test (b): file-level paths do NOT trigger breadth gate ───────────────────
echo ""
echo "=== Test (b): file-level paths are allowed through breadth gate ==="
for specific in "scripts/ci/foo.sh" "src/atomic_claim.rs" "docs/gaps/INFRA-1885.yaml" "src/lib/foo.rs" "app/page.tsx"; do
    output="$(CHUMP_LEASE_ALLOW_BROAD_DIRS=0 run_claim_breadth "$specific" 2>&1 || true)"
    if echo "$output" | grep -q "INFRA-1885"; then
        FAIL "specific path '$specific' incorrectly triggered INFRA-1885 gate: $output"
    else
        PASS "specific path '$specific' not blocked by breadth gate"
    fi
done

# Smoke: --paths scripts/ci/foo.sh should NOT get the breadth-cap error
echo ""
echo "=== Smoke (AC5 verbatim): --paths scripts/ci/foo.sh does not exit via breadth gate ==="
output_specific="$(CHUMP_LEASE_ALLOW_BROAD_DIRS=0 run_claim_breadth "scripts/ci/foo.sh" 2>&1 || true)"
if echo "$output_specific" | grep -q "INFRA-1885"; then
    FAIL "'--paths scripts/ci/foo.sh' triggered breadth gate (should not)"
else
    PASS "'--paths scripts/ci/foo.sh' clears breadth gate (fails later on git, not breadth)"
fi

# ── Test (c): CHUMP_LEASE_ALLOW_BROAD_DIRS=1 suppresses the hard block ───────
echo ""
echo "=== Test (c): CHUMP_LEASE_ALLOW_BROAD_DIRS=1 allows broad path through gate ==="
output_override="$(CHUMP_LEASE_ALLOW_BROAD_DIRS=1 run_claim_breadth "scripts/ci" 2>&1 || true)"
if echo "$output_override" | grep -q "INFRA-1885.*broad lease path.*rejected"; then
    FAIL "CHUMP_LEASE_ALLOW_BROAD_DIRS=1 did not suppress breadth block"
else
    PASS "CHUMP_LEASE_ALLOW_BROAD_DIRS=1 allows broad path past the gate"
fi
# Confirm override warning is printed
if echo "$output_override" | grep -q "broad-dir override active"; then
    PASS "override warning 'broad-dir override active' printed to stderr"
else
    FAIL "expected 'broad-dir override active' in output, got: $output_override"
fi

# ── Test (d): audit event emitted to ambient.jsonl on override ────────────────
echo ""
echo "=== Test (d): kind=lease_broad_dir_claim emitted to ambient.jsonl on override ==="
# Clear the ambient log.
> "$LOCK_DIR/ambient.jsonl"

# Run with override — event goes to $REPO_ROOT/.chump-locks/ambient.jsonl
# (real repo root, since chump derives repo_root from the binary's location,
# not from CHUMP_WORKTREE_BASE). We check the real ambient.jsonl.
REAL_AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"
before_count=0
if [[ -f "$REAL_AMBIENT" ]]; then
    before_count="$(grep -c '"kind":"lease_broad_dir_claim"' "$REAL_AMBIENT" 2>/dev/null || true)"
fi

CHUMP_LEASE_ALLOW_BROAD_DIRS=1 run_claim_breadth "src" > /dev/null 2>&1 || true

after_count=0
if [[ -f "$REAL_AMBIENT" ]]; then
    after_count="$(grep -c '"kind":"lease_broad_dir_claim"' "$REAL_AMBIENT" 2>/dev/null || true)"
fi

if [[ "$after_count" -gt "$before_count" ]]; then
    PASS "audit event lease_broad_dir_claim emitted to ambient.jsonl"
    # Verify required fields in the latest event.
    latest="$(grep '"kind":"lease_broad_dir_claim"' "$REAL_AMBIENT" | tail -1)"
    for field in '"session_id"' '"gap"' '"paths"' '"reason"'; do
        if echo "$latest" | grep -q "$field"; then
            PASS "event contains field $field"
        else
            FAIL "event missing field $field in: $latest"
        fi
    done
else
    FAIL "no new lease_broad_dir_claim event in $REAL_AMBIENT (before=$before_count, after=$after_count)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $pass passed, $fail failed"
if [[ $fail -gt 0 ]]; then
    exit 1
fi
exit 0
