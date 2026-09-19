#!/usr/bin/env bash
# test-race-control.sh — CREDIBLE-296: Race Control merge-mix board fixture tests
#
# Depth tier: offline fixture tests (title/label → expected class), no gh
# network calls — same class of coverage as test-autonomous-ship-rate.sh.
# Gaps not covered (green-not-covered rule): does not exercise the live `gh
# api` fetch path, the systemd timer/service files themselves (no systemd in
# CI sandbox — verified by hand via VERIFY-LIVE in the shipping PR), or the
# organ-reconcile revival path (RESILIENT-366's roll-call test covers the
# manifest/installer coherence half separately).
#
# Tests:
#   1. Classification: each sample title lands in its expected bucket
#      (reconcile-waste / self-maintenance / user-value)
#   2. Percentages sum to 100 and counts match the fixture size
#   3. race_control_mix ambient event emitted on every run (not just alarm runs)
#   4. race_control_waste_alarm fires (+ non-zero exit) when reconcile-waste%
#      exceeds --threshold
#   5. No alarm (+ zero exit) when reconcile-waste% is under threshold
#   6. Metrics JSONL row has all required fields
#   7. Explicit label (reconcile-waste/user-value/self-maintenance) wins over
#      title heuristic
#   8. CHUMP_RACE_DATE injects a deterministic date into the JSONL row
#
# All tests are offline: fixture data is fed via CHUMP_RACE_FIXTURE env var;
# no live gh calls are made.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/coord/race-control.sh"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

[[ -f "$SCRIPT" ]] || fail "race-control.sh not found at $SCRIPT"
[[ -x "$SCRIPT" ]] || fail "race-control.sh not executable"

TMP="$(mktemp -d -t test-race-control.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

METRICS_DIR="$TMP/metrics"
AMBIENT="$TMP/ambient.jsonl"
FIXTURE="$TMP/fixture.json"

BASE_ENV=(
    env
    CHUMP_RACE_FIXTURE="$FIXTURE"
    CHUMP_RACE_DATE="2026-08-21"
    CHUMP_METRICS_DIR="$METRICS_DIR"
    CHUMP_AMBIENT_LOG="$AMBIENT"
)

# ── Test 1+2: classification rules (title → expected class) ──────────────────
# 6 PRs: 3 reconcile-waste, 2 self-maintenance, 1 user-value → 50/33.3/16.7%
cat > "$FIXTURE" <<'JSON'
[
  {"number": 1, "title": "gaps(INFRA-1502): reconcile stale per-file gap YAML — already shipped via #4087", "labels": []},
  {"number": 2, "title": "fix(RESILIENT-366): backlog-sync writer roll-call — close the roster/manifest coherence gap", "labels": []},
  {"number": 3, "title": "docs(INFRA-1386): fix stale 'pending decision' comment — all 3 gates already dispositioned", "labels": []},
  {"number": 4, "title": "docs(governance): add Role Registry — operational ownership map", "labels": []},
  {"number": 5, "title": "chore(ci): tighten clippy lint", "labels": []},
  {"number": 6, "title": "feat(product): add onboarding flow", "labels": []}
]
JSON

OUT1="$("${BASE_ENV[@]}" bash "$SCRIPT" --json --dry-run 2>/dev/null || true)"
if echo "$OUT1" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['window']==6, f\"window: expected 6, got {d['window']}\"
assert d['reconcile_waste_count']==3, f\"reconcile_waste_count: expected 3, got {d['reconcile_waste_count']}\"
assert d['self_maintenance_count']==2, f\"self_maintenance_count: expected 2, got {d['self_maintenance_count']}\"
assert d['user_value_count']==1, f\"user_value_count: expected 1, got {d['user_value_count']}\"
" 2>/dev/null; then
    pass "Test 1: classification — 3 reconcile-waste, 2 self-maintenance, 1 user-value"
else
    fail "Test 1: unexpected classification: $OUT1"
fi

if echo "$OUT1" | python3 -c "
import json,sys
d=json.load(sys.stdin)
total=round(d['reconcile_waste_pct']+d['self_maintenance_pct']+d['user_value_pct'],1)
assert abs(total-100.0)<0.2, f\"percentages sum to {total}, not ~100\"
"; then
    pass "Test 2: percentages sum to ~100"
else
    fail "Test 2: percentages did not sum to 100 ($OUT1)"
fi

# ── Test 3: race_control_mix emitted on every run ─────────────────────────────
rm -f "$AMBIENT"
"${BASE_ENV[@]}" bash "$SCRIPT" --threshold 90 2>/dev/null > /dev/null || true
if grep -q '"kind":"race_control_mix"' "$AMBIENT" 2>/dev/null; then
    pass "Test 3: race_control_mix emitted to ambient.jsonl on every run"
else
    fail "Test 3: expected race_control_mix in $AMBIENT"
fi

# ── Test 4: alarm fires + non-zero exit when over threshold ──────────────────
rm -f "$AMBIENT"
set +e
"${BASE_ENV[@]}" bash "$SCRIPT" --threshold 30 2>/dev/null > /dev/null
EXIT4=$?
set -e
if [[ "$EXIT4" -ne 0 ]] && grep -q '"kind":"race_control_waste_alarm"' "$AMBIENT" 2>/dev/null; then
    pass "Test 4: race_control_waste_alarm fires + non-zero exit (50% > 30% threshold)"
else
    fail "Test 4: expected alarm + non-zero exit (got exit=$EXIT4, ambient=$(cat "$AMBIENT" 2>/dev/null))"
fi

# ── Test 5: no alarm + zero exit when under threshold ─────────────────────────
rm -f "$AMBIENT"
set +e
"${BASE_ENV[@]}" bash "$SCRIPT" --threshold 90 2>/dev/null > /dev/null
EXIT5=$?
set -e
if [[ "$EXIT5" -eq 0 ]] && ! grep -q '"kind":"race_control_waste_alarm"' "$AMBIENT" 2>/dev/null; then
    pass "Test 5: no alarm + zero exit when reconcile-waste under threshold (50% < 90%)"
else
    fail "Test 5: expected no alarm + zero exit (got exit=$EXIT5)"
fi

# ── Test 6: metrics JSONL row has required fields ─────────────────────────────
METRICS_FILE="$METRICS_DIR/race-control.jsonl"
if [[ -f "$METRICS_FILE" ]]; then
    ROW="$(tail -1 "$METRICS_FILE")"
    FIELDS_OK="$(echo "$ROW" | python3 -c "
import json,sys
d=json.load(sys.stdin)
required=['date','window','user_value_pct','self_maintenance_pct','reconcile_waste_pct']
missing=[k for k in required if k not in d]
print('OK' if not missing else 'MISSING:'+','.join(missing))
" 2>/dev/null || echo "parse_error")"
    if [[ "$FIELDS_OK" == "OK" ]]; then
        pass "Test 6: metrics JSONL row has all required fields"
    else
        fail "Test 6: metrics row missing fields: $FIELDS_OK (row: $ROW)"
    fi
else
    fail "Test 6: metrics file not created at $METRICS_FILE"
fi

# ── Test 7: explicit label wins over title heuristic ──────────────────────────
cat > "$FIXTURE" <<'JSON'
[
  {"number": 10, "title": "feat(product): looks like user-value but labeled reconcile-waste", "labels": ["reconcile-waste"]}
]
JSON
OUT7="$("${BASE_ENV[@]}" bash "$SCRIPT" --json --dry-run 2>/dev/null || true)"
if echo "$OUT7" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['reconcile_waste_count']==1, f\"expected label to force reconcile-waste, got {d}\"
"; then
    pass "Test 7: explicit PR label overrides title heuristic"
else
    fail "Test 7: label override failed: $OUT7"
fi

# ── Test 8: CHUMP_RACE_DATE injects deterministic date ─────────────────────────
cat > "$FIXTURE" <<'JSON'
[{"number": 1, "title": "feat(product): x", "labels": []}]
JSON
rm -f "$METRICS_FILE"
"${BASE_ENV[@]}" bash "$SCRIPT" --json 2>/dev/null > /dev/null
DATE_IN_ROW="$(tail -1 "$METRICS_FILE" | python3 -c "import json,sys; print(json.load(sys.stdin)['date'])" 2>/dev/null || echo "?")"
if [[ "$DATE_IN_ROW" == "2026-08-21" ]]; then
    pass "Test 8: CHUMP_RACE_DATE injected correctly into JSONL row (got $DATE_IN_ROW)"
else
    fail "Test 8: expected date=2026-08-21, got $DATE_IN_ROW"
fi

# ── Test 9: fleet-status.sh renders merge-mix from race-control.jsonl (INFRA-3844) ──
# merge-mix-board.sh was retired; race-control.sh is now the sole emitter and
# fleet-status.sh must read its metrics file (race-control.jsonl) with its
# field names (window/self_maintenance_pct), not the old merge-mix-board.jsonl
# shape (self_maint_pct). This fails without the fix: fleet-status.sh would
# either find no file (old path) or KeyError on the old field name.
# Best-effort like test-autonomous-ship-rate.sh Test 6: fleet-status.sh's main
# body drives a tmux dashboard / arg-parsing flow unrelated to this gap, so we
# extract just the render_merge_mix() function (awk range match on its brace
# block) and eval it in isolation rather than running the whole script.
FLEET_STATUS="$REPO_ROOT/scripts/dispatch/fleet-status.sh"
if [[ -f "$FLEET_STATUS" ]]; then
    echo '{"date":"2026-08-21","window":6,"user_value_count":1,"self_maintenance_count":2,"reconcile_waste_count":3,"user_value_pct":16.7,"self_maintenance_pct":33.3,"reconcile_waste_pct":50.0}' \
        > "$METRICS_DIR/race-control.jsonl"
    rm -f "$METRICS_DIR/merge-mix-board.jsonl"
    RENDER_FN="$(awk '/^render_merge_mix\(\)/,/^}/' "$FLEET_STATUS")"
    FLEET_OUT="$(CHUMP_METRICS_DIR="$METRICS_DIR" bash -c "$RENDER_FN"$'\n'"render_merge_mix" 2>/dev/null || true)"
    if echo "$FLEET_OUT" | grep -q "merge-mix: user-value=17% self-maint=33% reconcile-waste=50%"; then
        pass "Test 9: fleet-status render_merge_mix reads race-control.jsonl"
    else
        fail "Test 9: expected merge-mix line sourced from race-control.jsonl, got: $FLEET_OUT"
    fi
else
    pass "Test 9: fleet-status.sh not found — skipping render test (optional)"
fi


# ── Test 10: producer/consumer schema parity end-to-end (INFRA-7638) ─────────
# Test 9 proves fleet-status.sh reads race-control.jsonl's field names via a
# HAND-WRITTEN fixture row. This test closes the remaining gap: run the real
# race-control.sh emitter (the ONLY merge-mix emitter left post-INFRA-3844)
# against a fixture, then feed its ACTUAL JSONL row — not a hand-written
# stand-in — into fleet-status.sh's render_merge_mix(). If the producer ever
# renamed/dropped a field the consumer depends on, this fails; if a second
# emitter were reintroduced with a different schema, the retired-script check
# below fails first. Together they prove "single canonical emitter, zero
# field drift" rather than merely asserting it via comment.
if [[ -f "$FLEET_STATUS" ]]; then
    cat > "$FIXTURE" <<'JSON'
[
  {"number": 1, "title": "gaps(INFRA-1502): reconcile stale per-file gap YAML — already shipped via #4087", "labels": []},
  {"number": 2, "title": "fix(RESILIENT-366): backlog-sync writer roll-call — close the roster/manifest coherence gap", "labels": []},
  {"number": 3, "title": "docs(INFRA-1386): fix stale 'pending decision' comment — all 3 gates already dispositioned", "labels": []},
  {"number": 4, "title": "docs(governance): add Role Registry — operational ownership map", "labels": []},
  {"number": 5, "title": "chore(ci): tighten clippy lint", "labels": []},
  {"number": 6, "title": "feat(product): add onboarding flow", "labels": []}
]
JSON
    rm -f "$METRICS_DIR/race-control.jsonl" "$METRICS_DIR/merge-mix-board.jsonl"
    "${BASE_ENV[@]}" bash "$SCRIPT" --json > /dev/null 2>&1 || true
    REAL_ROW="$(tail -1 "$METRICS_DIR/race-control.jsonl" 2>/dev/null || echo "")"
    if [[ -z "$REAL_ROW" ]]; then
        fail "Test 10: race-control.sh did not write a row to $METRICS_DIR/race-control.jsonl"
    fi
    RENDER_FN="$(awk '/^render_merge_mix\(\)/,/^}/' "$FLEET_STATUS")"
    FLEET_OUT="$(CHUMP_METRICS_DIR="$METRICS_DIR" bash -c "$RENDER_FN"$'\n'"render_merge_mix" 2>/dev/null || true)"
    if echo "$FLEET_OUT" | grep -q "merge-mix: user-value=17% self-maint=33% reconcile-waste=50%"; then
        pass "Test 10: fleet-status render_merge_mix parses race-control.sh's real emitted row (no drift)"
    else
        fail "Test 10: real race-control.sh row unreadable by render_merge_mix (schema drift): row=$REAL_ROW rendered=$FLEET_OUT"
    fi
else
    pass "Test 10: fleet-status.sh not found — skipping parity test (optional)"
fi

# ── Test 11: no second merge-mix emitter has been reintroduced (INFRA-7638) ──
# INFRA-3844 retired scripts/coord/merge-mix-board.sh so race-control.sh is
# the sole emitter. This guards against silent reintroduction of a second
# emitter (which is exactly how field drift happens in the first place).
if [[ -f "$REPO_ROOT/scripts/coord/merge-mix-board.sh" ]]; then
    fail "Test 11: scripts/coord/merge-mix-board.sh has been reintroduced — a second merge-mix emitter re-creates field-drift risk (INFRA-3844/INFRA-7638)"
else
    pass "Test 11: no second merge-mix emitter present — race-control.sh remains sole canonical source"
fi

echo ""
echo "All CREDIBLE-296 / INFRA-7638 race-control checks passed (11/11)."
