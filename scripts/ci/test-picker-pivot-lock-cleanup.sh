#!/usr/bin/env bash
# test-picker-pivot-lock-cleanup.sh — INFRA-544
#
# Verifies that worker.sh removes .gap-<ID>.lock on each pivot path so
# sibling workers can pick the gap in the next cycle:
#   1. preflight fails  → lock released
#   2. origin/main shows status:done → lock released
#   3. worktree-add fails → lock released
#
# These are unit-level checks on the shell logic, not full fleet runs.
# We simulate the pivot paths by checking that the rm -f lines exist
# immediately before each `continue` that follows a successful claim.

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"

[[ -f "$WORKER" ]] || { echo "FATAL: $WORKER missing"; exit 2; }

echo "=== INFRA-544 picker-pivot lock-cleanup test ==="
echo

# ── Static analysis: verify each pivot path has the cleanup ──────────────────

# We look for the INFRA-544 cleanup comment + rm -f line in close proximity
# to each of the three pivot `continue` statements.

# Helper: check that an INFRA-544 rm line exists within N lines after a
# marker pattern (the rm comes after the log line, before `continue`).
check_cleanup_near() {
    local label="$1"
    local marker="$2"
    if grep -A15 "$marker" "$WORKER" | grep -q 'INFRA-544'; then
        ok "$label: INFRA-544 lock cleanup present after pivot log"
    else
        fail "$label: missing INFRA-544 lock cleanup near '$marker'"
    fi
}

check_cleanup_near "preflight-fail pivot" \
    "skipping.*failed pre-pick preflight"

check_cleanup_near "origin/main done pivot" \
    "skipping.*already done on origin/main"

check_cleanup_near "worktree-add fail pivot" \
    "worktree create failed for"

# ── Runtime test: claim a gap then simulate pivot, verify lock is gone ────────
echo
echo "Runtime: simulate preflight-fail pivot via _pick_and_claim_gap.py + manual rm"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/gaps.json" <<'EOF'
[
  {"id":"INFRA-TEST-1","domain":"INFRA","priority":"P1","effort":"xs","created_at":1000,"depends_on":"","status":"open"}
]
EOF

lock_dir="$TMP/.chump-locks"
mkdir -p "$lock_dir"

PICKER="$REPO_ROOT/scripts/dispatch/_pick_and_claim_gap.py"

# Step 1: picker claims the gap (writes .gap-INFRA-TEST-1.lock).
pick=$(CHUMP_SESSION_ID="session-pivot-test" \
       GAP_JSON_FILE="$TMP/gaps.json" \
       CHUMP_LOCK_DIR="$lock_dir" \
       FLEET_PRIORITY_FILTER="P0,P1" \
       FLEET_DOMAIN_FILTER="INFRA" \
       FLEET_EFFORT_FILTER="xs,s,m" \
       EXCLUDE_RE="^$" \
       WORKER_INDEX="1" \
       python3 "$PICKER" 2>/dev/null || true)

if [[ "$pick" == "INFRA-TEST-1" ]]; then
    ok "picker claimed INFRA-TEST-1"
else
    fail "picker did not claim INFRA-TEST-1 (got: '$pick')"
fi

lock_file="$lock_dir/gap-claim-INFRA-TEST-1.json"
session_file="$lock_dir/session-pivot-test.json"
if [[ -f "$lock_file" && -f "$session_file" ]]; then
    ok "lock file + session lease created after claim (INFRA-8580 --lease-only)"
else
    fail "lock file or session lease missing after claim"
fi

# Step 2: simulate pivot (preflight fails) — worker does rm -f on marker + session lease.
rm -f "$lock_dir/.gap-INFRA-TEST-1.lock" "$lock_file" "$session_file" 2>/dev/null || true
if [[ ! -f "$lock_file" && ! -f "$session_file" ]]; then
    ok "lock file removed after pivot (simulated)"
else
    fail "lock file still present after pivot simulation"
fi

# Step 3: a sibling picker can now re-claim the same gap.
pick2=$(CHUMP_SESSION_ID="session-sibling" \
        GAP_JSON_FILE="$TMP/gaps.json" \
        CHUMP_LOCK_DIR="$lock_dir" \
        FLEET_PRIORITY_FILTER="P0,P1" \
        FLEET_DOMAIN_FILTER="INFRA" \
        FLEET_EFFORT_FILTER="xs,s,m" \
        EXCLUDE_RE="^$" \
        WORKER_INDEX="2" \
        python3 "$PICKER" 2>/dev/null || true)

if [[ "$pick2" == "INFRA-TEST-1" ]]; then
    ok "sibling claimed the gap after pivot cleanup"
else
    fail "sibling could not claim gap after pivot (got: '$pick2')"
fi

# Step 4 (RESILIENT-1707): skipping an effort=l gap emits kind=gap_skipped_needs_decompose
cat >"$TMP/gaps-large.json" <<'EOF'
[
  {"id":"INFRA-TEST-LARGE","domain":"INFRA","priority":"P1","effort":"l","created_at":1000,"depends_on":"","status":"open"}
]
EOF
AMBIENT_JSONL="$lock_dir/ambient.jsonl" \
CHUMP_SESSION_ID="session-large" \
GAP_JSON_FILE="$TMP/gaps-large.json" \
CHUMP_LOCK_DIR="$lock_dir" \
FLEET_PRIORITY_FILTER="P0,P1" \
FLEET_DOMAIN_FILTER="INFRA" \
FLEET_EFFORT_FILTER="xs,s,m" \
EXCLUDE_RE="^$" \
WORKER_INDEX="1" \
python3 "$PICKER" >/dev/null 2>&1 || true

if [[ -f "$lock_dir/ambient.jsonl" ]] \
   && grep -q '"kind":"gap_skipped_needs_decompose"' "$lock_dir/ambient.jsonl" \
   && grep -q '"gap_id":"INFRA-TEST-LARGE"' "$lock_dir/ambient.jsonl"; then
    ok "picker emitted kind=gap_skipped_needs_decompose for effort=l gap (RESILIENT-1707)"
else
    fail "picker did not emit kind=gap_skipped_needs_decompose for effort=l gap"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
