#!/usr/bin/env bash
# scripts/ci/test-open-pr-dup-detection.sh — INFRA-1982
#
# Tests for the open-PR-for-gap dedup gate added to chump claim.
# Verifies:
#   1. check_open_pr_for_gap() and emit_claim_open_pr_dup_blocked() exist in source
#   2. Gate is wired into run_claim() with CHUMP_CLAIM_ALLOW_DUPLICATE_PR bypass
#   3. Gate is wired into run_check_only() as "open-pr-for-gap"
#   4. gap reserve similarity block (>= 0.85) no longer calls process::exit(1)
#   5. Ambient event kind=claim_open_pr_dup_blocked is registered in EVENT_REGISTRY.yaml
#   6. Cargo unit tests for the new gate pass

set -uo pipefail
PASS=0; FAIL=0; FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC="$REPO_ROOT/crates/chump-atomic-claim/src/atomic_claim.rs"
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"

# CREDIBLE-1156: resolve the gap-reserve-similarity source file dynamically
# instead of hardcoding src/main.rs — the similarity check may be relocated
# (e.g. to src/commands/gap.rs) by a future refactor without this test
# needing an update. Prefer the conventional new home, fall back to any
# file under src/ that actually contains the anchor comment, and finally
# fall back to the historical src/main.rs path so a fresh clone still works.
MAIN_CANDIDATE="$REPO_ROOT/src/commands/gap.rs"
if [[ -f "$MAIN_CANDIDATE" ]] && grep -q "INFRA-1149: reserve-time title similarity check" "$MAIN_CANDIDATE"; then
    MAIN="$MAIN_CANDIDATE"
else
    MAIN="$(grep -rl "INFRA-1149: reserve-time title similarity check" "$REPO_ROOT/src" 2>/dev/null | head -1)"
    if [[ -z "$MAIN" ]]; then
        MAIN="$REPO_ROOT/src/main.rs"
    fi
fi

echo "=== INFRA-1982 open-PR dedup detection tests ==="

# ── 1. Source symbols exist ─────────────────────────────────────────────────
echo ""
echo "--- 1. Source symbols in atomic_claim.rs ---"
for sym in \
    "pub fn check_open_pr_for_gap" \
    "fn emit_claim_open_pr_dup_blocked" \
    "claim_open_pr_dup_blocked" \
    "CHUMP_CLAIM_ALLOW_DUPLICATE_PR" \
    "open-pr-for-gap" \
    "INFRA-1982"; do
    if grep -qF -- "$sym" "$SRC"; then ok "atomic_claim.rs contains: $sym"; else fail "missing in atomic_claim.rs: $sym"; fi
done

# ── 2. run_claim wires the gate before worktree creation ────────────────────
echo ""
echo "--- 2. Gate wired into run_claim() ---"
if grep -q "check_open_pr_for_gap" "$SRC"; then
    ok "check_open_pr_for_gap called in atomic_claim.rs"
else
    fail "check_open_pr_for_gap not called in atomic_claim.rs"
fi

# The emit must appear after check_open_pr_for_gap in the same block
emit_line=$(grep -n "emit_claim_open_pr_dup_blocked" "$SRC" | grep -v "^.*fn emit_claim_open_pr_dup_blocked" | head -1 | cut -d: -f1)
check_line=$(grep -n "check_open_pr_for_gap" "$SRC" | grep -v "^.*fn check_open_pr_for_gap" | head -1 | cut -d: -f1)
if [[ -n "$emit_line" && -n "$check_line" && "$emit_line" -gt "$check_line" ]]; then
    ok "emit_claim_open_pr_dup_blocked follows check_open_pr_for_gap (lines $check_line → $emit_line)"
else
    fail "emit_claim_open_pr_dup_blocked ordering vs check_open_pr_for_gap unexpected (check=$check_line emit=$emit_line)"
fi

# ── 3. run_check_only has the gate ──────────────────────────────────────────
echo ""
echo "--- 3. Gate wired into run_check_only() as 'open-pr-for-gap' ---"
if grep -q '"open-pr-for-gap"' "$SRC"; then
    ok 'run_check_only contains gate "open-pr-for-gap"'
else
    fail 'run_check_only missing gate "open-pr-for-gap"'
fi

# ── 4. gap reserve similarity no longer exits on block threshold ────────────
echo ""
echo "--- 4. gap reserve similarity demoted to WARN (no exit at >= 0.85) ---"
# The block we care about: the similarity section should NOT have
# "exit(1)" after the gap_reserve_similarity_block event emit.
# We test by checking that the similarity_block kind is gone and only
# similarity_warn remains.
if grep -q '"gap_reserve_similarity_block"' "$MAIN"; then
    fail 'main.rs still emits gap_reserve_similarity_block (should emit gap_reserve_similarity_warn for both thresholds)'
else
    ok 'main.rs no longer emits gap_reserve_similarity_block kind'
fi

# Both thresholds should now emit gap_reserve_similarity_warn
warn_count=$(grep -c '"gap_reserve_similarity_warn"' "$MAIN" || true)
if [[ "$warn_count" -ge 2 ]]; then
    ok "main.rs emits gap_reserve_similarity_warn for both thresholds ($warn_count occurrences)"
else
    fail "expected >= 2 gap_reserve_similarity_warn in main.rs, found $warn_count"
fi

# The "BLOCK (score" label at >= 0.85 in the SIMILARITY section should be demoted
# to WARN. (The offline-compliance gate uses "[reserve] BLOCK:" separately and
# is intentionally kept — we scope this check to the similarity block only.)
sim_block=$(awk '/INFRA-1149: reserve-time title similarity check/,/INFRA-1152: pillar-balance guard/' "$MAIN")
if echo "$sim_block" | grep -q '\[reserve\] BLOCK'; then
    fail 'similarity check block in main.rs still has "[reserve] BLOCK" label (should be "[reserve] WARN")'
else
    ok 'no "[reserve] BLOCK" label in similarity check block — demoted to WARN'
fi

# No process::exit in the similarity check section (between the INFRA-1149 comment
# and the INFRA-1152 pillar-balance comment)
# We use a crude but reliable range check: extract just that block
sim_block=$(awk '/INFRA-1149: reserve-time title similarity check/,/INFRA-1152: pillar-balance guard/' "$MAIN")
if echo "$sim_block" | grep -q 'process::exit'; then
    fail 'process::exit still present in similarity check block in main.rs'
else
    ok 'no process::exit in similarity check block — gate is purely advisory'
fi

# ── 5. EVENT_REGISTRY.yaml has claim_open_pr_dup_blocked ────────────────────
echo ""
echo "--- 5. EVENT_REGISTRY.yaml registration ---"
if grep -q "claim_open_pr_dup_blocked" "$REGISTRY"; then
    ok "EVENT_REGISTRY.yaml contains claim_open_pr_dup_blocked"
else
    fail "EVENT_REGISTRY.yaml missing claim_open_pr_dup_blocked"
fi

for field in "gap" "open_pr" "waste_prevented" "INFRA-1982"; do
    if grep -A10 "claim_open_pr_dup_blocked" "$REGISTRY" | grep -q "$field"; then
        ok "registry entry contains field/marker: $field"
    else
        fail "registry entry missing field/marker: $field"
    fi
done

# ── 6. Cargo unit tests ─────────────────────────────────────────────────────
echo ""
echo "--- 6. Cargo unit tests ---"
if command -v cargo >/dev/null 2>&1 && [[ -f "$REPO_ROOT/Cargo.toml" ]]; then
    echo "  [running cargo test open_pr_dup ...]"
    if (cd "$REPO_ROOT" && cargo test --bin chump open_pr_dup --quiet -- --test-threads=1 2>&1 | tail -15); then
        ok "cargo test open_pr_dup passed"
    else
        fail "cargo test open_pr_dup failed"
    fi
else
    echo "  [skipping cargo tests — cargo not available]"
fi

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
