#!/usr/bin/env bash
# test-pick-and-claim-exclusion-reasons.sh — RESILIENT-1509
#
# Root cause: worker.sh ran _pick_and_claim_gap.py with stderr sent to
# /dev/null, so an empty cycle always logged a bare "no pickable gap" —
# indistinguishable from a crash, a failed claim, or an over-broad
# exclusion. The claimer now dumps a JSON per-exclusion-reason count to
# stderr whenever it returns without a gap. This asserts that dump exists
# and attributes exclusions to the right reason bucket.

set -euo pipefail
PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CLAIMER="$REPO_ROOT/scripts/dispatch/_pick_and_claim_gap.py"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LOCK_DIR="$TMP/locks"
mkdir -p "$LOCK_DIR"

AC='the gap is fixed and tested'

run() {
    GAP_JSON_FILE="$TMP/gaps.json" \
    CHUMP_LOCK_DIR="$LOCK_DIR" \
    CHUMP_SESSION_ID="test-session-$$" \
    CHUMP_REBALANCE=0 \
    WORKER_INDEX=1 WORKER_ID=1 \
    FLEET_PRIORITY_FILTER="P0,P1" FLEET_DOMAIN_FILTER="INFRA" FLEET_EFFORT_FILTER="xs,s,m" \
      python3 "$CLAIMER"
}

# All candidates excluded for distinct, attributable reasons: one P2 (fails
# priority filter), one with unresolved deps, one superseded. INFRA-200's
# blocker INFRA-999 must EXIST as genuine open work: a dangling dep id is
# treated as resolved (RESILIENT-1114), which would let INFRA-200 be picked.
# INFRA-999 itself is excluded by the domain filter (DOC, not INFRA).
cat > "$TMP/gaps.json" <<JSON
[
  {"id":"INFRA-100","status":"open","priority":"P2","effort":"s","domain":"INFRA","depends_on":"[]","acceptance_criteria":"$AC"},
  {"id":"INFRA-200","status":"open","priority":"P1","effort":"s","domain":"INFRA","depends_on":"[\"INFRA-999\"]","acceptance_criteria":"$AC"},
  {"id":"INFRA-300","status":"open","priority":"P1","effort":"s","domain":"INFRA","depends_on":"[]","acceptance_criteria":"$AC","notes":"SUPERSEDED by INFRA-301"},
  {"id":"INFRA-999","status":"open","priority":"P1","effort":"s","domain":"DOC","depends_on":"[]","acceptance_criteria":"$AC"}
]
JSON

stderr_file="$TMP/stderr"
out="$(run 2>"$stderr_file" || true)"
err="$(cat "$stderr_file")"

[[ -z "$out" ]] && pass "no gap claimed (all 4 excluded)" \
    || fail "expected no pick, got '$out'"

[[ -n "$err" ]] && pass "stderr is non-empty on the empty cycle (not silently swallowed)" \
    || fail "stderr was empty — the empty-cycle dump is missing"

echo "$err" | grep -q '"pick_empty_cycle": true' \
    && pass "stderr dump marks pick_empty_cycle" \
    || fail "stderr dump missing pick_empty_cycle marker: $err"

echo "$err" | grep -q '"priority_filter": 1' \
    && pass "priority_filter reason counted for INFRA-100 (P2 excluded by P0,P1 filter)" \
    || fail "priority_filter count missing/wrong: $err"

echo "$err" | grep -q '"unresolved_deps": 1' \
    && pass "unresolved_deps reason counted for INFRA-200" \
    || fail "unresolved_deps count missing/wrong: $err"

echo "$err" | grep -q '"superseded": 1' \
    && pass "superseded reason counted for INFRA-300" \
    || fail "superseded count missing/wrong: $err"

echo "$err" | grep -q '"domain_filter": 1' \
    && pass "domain_filter reason counted for INFRA-999 (DOC excluded by INFRA filter)" \
    || fail "domain_filter count missing/wrong: $err"

echo "$err" | grep -q '"total_gaps": 4' \
    && pass "total_gaps reflects full input size" \
    || fail "total_gaps missing/wrong: $err"

# INFRA-8603: verify external_repo gate cycle logging when gate is closed vs open
cat > "$TMP/gaps.json" <<JSON
[
  {"id":"INFRA-400","status":"open","priority":"P1","effort":"s","domain":"INFRA","depends_on":"[]","skills_required":"external_repo:repairman29/olive","acceptance_criteria":"$AC"},
  {"id":"INFRA-401","status":"open","priority":"P1","effort":"s","domain":"INFRA","depends_on":"[]","skills_required":"external_repo","acceptance_criteria":"$AC"}
]
JSON

stderr_ext_closed="$TMP/stderr-ext-closed"
out_ext_closed="$(CHUMP_EXTERNAL_REPO_PICK_OK=0 run 2>"$stderr_ext_closed" || true)"
err_ext_closed="$(cat "$stderr_ext_closed")"

[[ -z "$out_ext_closed" ]] && pass "INFRA-8603: external_repo gaps skipped when gate closed" \
    || fail "INFRA-8603: expected no pick when gate closed, got '$out_ext_closed'"

echo "$err_ext_closed" | grep -q "2 external gaps skipped: gate closed" \
    && pass "INFRA-8603: logs '2 external gaps skipped: gate closed'" \
    || fail "INFRA-8603: missing '2 external gaps skipped: gate closed' in: $err_ext_closed"

echo "$err_ext_closed" | grep -q "external_repo gate: closed (2 gaps blocked)" \
    && pass "INFRA-8603: logs 'external_repo gate: closed (2 gaps blocked)'" \
    || fail "INFRA-8603: missing 'external_repo gate: closed (2 gaps blocked)' in: $err_ext_closed"

# ── INFRA-8640: wave role + lease scan + duplicate-pr-detector review-held ──
ROOT="$REPO_ROOT"
PICKER="$CLAIMER"
if grep -Eq "^  - name: wave" "$ROOT/docs/process/AGENT_ROLES.yaml"; then
    pass "INFRA-8640: AGENT_ROLES.yaml defines wave role"
else
    fail "INFRA-8640: AGENT_ROLES.yaml missing wave role"
fi

mkdir -p "$TMP/i8640/.chump-locks" "$TMP/i8640/scripts/dispatch" "$TMP/i8640-bin"
cp "$ROOT/scripts/dispatch/picker-policy.json" "$TMP/i8640/scripts/dispatch/picker-policy.json"
NOW_ISO="$(python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
EXP_ISO="$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(hours=2)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
cat > "$TMP/i8640/.chump-locks/claim-INFRA-9991-wave.json" <<EOF
{"gap_id":"INFRA-9991","session_id":"wave-sess-1","role":"wave","worktree":"/tmp/wt-wave","claimed_at":"$NOW_ISO","heartbeat_at":"$NOW_ISO","expires_at":"$EXP_ISO","files":["scripts/foo.sh"]}
EOF
cat > "$TMP/gaps.json" <<JSON
[
  {"id":"INFRA-9991","title":"Leased by wave","status":"open","priority":"P1","domain":"INFRA","effort":"s","depends_on":"[]","acceptance_criteria":"$AC"}
]
JSON
GAP_JSON_FILE="$TMP/gaps.json" REPO_ROOT="$TMP/i8640" CHUMP_REPO="$TMP/i8640" CHUMP_LOCK_DIR="$TMP/i8640/.chump-locks" \
python3 "$PICKER" --dry-run --dump-reasons >"$TMP/i8640.out" 2>"$TMP/i8640.err" || true
if [[ ! -s "$TMP/i8640.out" ]] && grep -q '"active_or_missing_id": 1' "$TMP/i8640.err"; then
    pass "INFRA-8640: picker excludes gap with active .chump-locks/claim-*.json lease"
else
    fail "INFRA-8640: picker did not exclude lease-claimed gap"
fi

sed 's/return leased/return set()/' "$PICKER" > "$TMP/picker_mutant_8640.py"
cp "$ROOT/scripts/dispatch/_dep_resolution.py" "$TMP/_dep_resolution.py"
GAP_JSON_FILE="$TMP/gaps.json" REPO_ROOT="$TMP/i8640" CHUMP_REPO="$TMP/i8640" CHUMP_LOCK_DIR="$TMP/i8640/.chump-locks" \
python3 "$TMP/picker_mutant_8640.py" --dry-run --dump-reasons >"$TMP/i8640_mut.out" 2>/dev/null || true
if grep -q "INFRA-9991" "$TMP/i8640_mut.out"; then
    pass "INFRA-8640 mutant: disabling _load_active_leased_gaps is caught"
else
    fail "INFRA-8640 mutant: mutant picker did not offer INFRA-9991"
fi

cat > "$TMP/open_prs.json" <<EOF
[
  {"number": 5701, "title": "fix(INFRA-8616): first implementation", "head": {"ref": "fix/INFRA-8616-first"}, "created_at": "2026-10-25T10:00:00Z"},
  {"number": 5705, "title": "Follow-up duplicate implementation", "head": {"ref": "claude/infra-8616-dup"}, "created_at": "$NOW_ISO"}
]
EOF
cat > "$TMP/i8640-bin/gh" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "repo" && "\${2:-}" == "view" ]]; then echo "repairman29/chump"; exit 0; fi
if [[ "\${1:-}" == "api" && "\${2:-}" == "repos/repairman29/chump/pulls?state=open&per_page=100" ]]; then cat "$TMP/open_prs.json"; exit 0; fi
echo "\$*" >> "$TMP/gh_calls.log"
exit 0
EOF
chmod +x "$TMP/i8640-bin/gh"
PATH="$TMP/i8640-bin:$PATH" CHUMP_REPO_ROOT="$TMP/i8640" \
bash "$ROOT/scripts/coord/duplicate-pr-detector.sh" --apply --skip-fresh-mins 15 >/dev/null
if grep -Eq '"kind":"duplicate_pr_held"' "$TMP/i8640/.chump-locks/ambient.jsonl" \
   && grep -q "labels\[\]=review-held" "$TMP/gh_calls.log"; then
    pass "INFRA-8640: duplicate-pr-detector.sh holds duplicate PR #5705 and emits duplicate_pr_held"
else
    fail "INFRA-8640: duplicate-pr-detector.sh did not emit duplicate_pr_held"
fi

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
