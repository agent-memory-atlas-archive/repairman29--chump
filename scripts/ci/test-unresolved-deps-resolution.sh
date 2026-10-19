#!/usr/bin/env bash
# scripts/ci/test-unresolved-deps-resolution.sh
#
# CREDIBLE-1552: restored from the deleted test-ghost-gap-thrash-fix.sh (Part 1
# only — the Part 2 "widened merged-PR title-scan window" assertions went away
# with the title-closer itself, which CREDIBLE-1550/1552 deleted in favour of
# the gap_prs FK).
#
# scripts/dispatch/_dep_resolution.py::unresolved_deps must count EVERY
# terminal/done-like status as resolved (not only "done"), and must treat a
# dangling/nonexistent dep ID as resolved — otherwise superseded/closed
# dep-edges (observed ~1,142 of them) falsely pin ~456 open gaps shut and
# workers starve on ghosts.
#
# Depth: edge/adversarial (terminal, dangling, active, unknown-status, mixed).

set -euo pipefail
PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

python3 - "$REPO_ROOT" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/scripts/dispatch")
from _dep_resolution import unresolved_deps, _DONE_LIKE_STATUSES

gaps = [
    {"id": "A", "status": "done"},
    {"id": "B", "status": "superseded"},
    {"id": "C", "status": "open"},
    {"id": "D", "status": "closed"},
    {"id": "E", "status": "already_satisfied"},
    {"id": "F", "status": "duplicate"},
    {"id": "G", "status": "OPEN"},        # case-insensitive gate
    {"id": "H", "status": "weird-status"},  # unknown -> stays gating
]

def check(desc, got, want):
    if got == want:
        print(f"[PASS] {desc}")
        return 0
    print(f"[FAIL] {desc}: got {got!r} want {want!r}")
    return 1

rc = 0
rc |= check("done dep resolves", unresolved_deps(["A"], gaps, set()), [])
rc |= check("superseded dep resolves (NEW)", unresolved_deps(["B"], gaps, set()), [])
rc |= check("closed dep resolves (NEW)", unresolved_deps(["D"], gaps, set()), [])
rc |= check("already_satisfied dep resolves (NEW)", unresolved_deps(["E"], gaps, set()), [])
rc |= check("duplicate dep resolves (NEW)", unresolved_deps(["F"], gaps, set()), [])
rc |= check("open dep still gates", unresolved_deps(["C"], gaps, set()), ["C"])
rc |= check("OPEN (any case) still gates", unresolved_deps(["G"], gaps, set()), ["G"])
rc |= check("unknown status stays gating (conservative)", unresolved_deps(["H"], gaps, set()), ["H"])
rc |= check("dangling/nonexistent dep resolves (NEW)", unresolved_deps(["ZZZ-999"], gaps, set()), [])
rc |= check("active dep resolves", unresolved_deps(["C"], gaps, {"C"}), [])
rc |= check("mixed: only open C/G/H gate", unresolved_deps(["A","B","C","D","E","F","G","H","NOPE-1"], gaps, set()), ["C","G","H"])
# Sanity: the resolver reuses the picker's done-like set, not a private copy.
assert "superseded" in _DONE_LIKE_STATUSES and "done" in _DONE_LIKE_STATUSES
print("[PASS] _DONE_LIKE_STATUSES reused (single source of truth)")
sys.exit(rc)
PY
if [ $? -eq 0 ]; then pass "unresolved_deps terminal+dangling resolution"; else fail "unresolved_deps regressions"; fi

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
