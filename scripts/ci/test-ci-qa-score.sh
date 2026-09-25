#!/usr/bin/env bash
# test-ci-qa-score.sh — INFRA-1872 smoke test.
#
# Exercises scripts/ops/ci-qa-score.sh with stubbed `gh` on PATH and a
# synthetic ambient.jsonl. Verifies:
#   1. CHUMP_CI_QA_SCORE=0 bypasses cleanly (exit 0, "bypassed" in output).
#   2. Empty PR list emits status=unknown and exits 0.
#   3. All-clean sample → pct=100, status=green, exit 0, emits kind=ci_qa_score.
#   4. Mixed sample (3/5 bypassed) → pct=40, status=red, exit 2.
#   5. Mid sample (1/10 bypassed) → pct=90, status=amber, exit 1.
#   7. INFRA-3854: every status emitted across the run is one of the
#      canonical green|amber|red|unknown vocabulary (parent INFRA-3841
#      slice 6/9) — the same vocabulary scripts/ops/vital-signs.sh uses.
#
# Network-free: stubs `gh` via PATH; writes to a tmp ambient.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ops/ci-qa-score.sh"

[[ -x "$SCRIPT" ]] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
export PATH="$TMP/bin:$PATH"

AMBIENT="$TMP/ambient.jsonl"
touch "$AMBIENT"
export CHUMP_AMBIENT_LOG="$AMBIENT"

make_gh_stub() {
    # $1 = newline-separated PR numbers (empty for no PRs).
    # The real call is `gh pr list ... --json number --jq '.[].number'` which
    # outputs ONE PR number per line, or nothing for an empty list. Mimic that
    # directly — we accept the args but always emit the canned list.
    {
        echo '#!/usr/bin/env bash'
        echo 'set -e'
        # Heredoc body holds the literal PR list (may be empty).
        echo "cat <<'PRS_EOF'"
        printf '%s' "$1"
        # Ensure newline at end if non-empty.
        [[ -n "$1" ]] && echo ""
        echo "PRS_EOF"
    } > "$TMP/bin/gh"
    chmod +x "$TMP/bin/gh"
}

# ── Test 1: CHUMP_CI_QA_SCORE=0 bypasses ─────────────────────────────────────
echo "Test 1: CHUMP_CI_QA_SCORE=0 bypasses"
out=$(CHUMP_CI_QA_SCORE=0 "$SCRIPT" 2>&1) || rc=$?
if [[ "$out" == *"bypassed"* ]]; then
    echo "  PASS"
else
    echo "  FAIL: expected 'bypassed' in output, got: $out"
    exit 1
fi

# ── Test 2: empty PR list → unknown ──────────────────────────────────────────
echo "Test 2: empty PR list emits status=unknown"
make_gh_stub ""
> "$AMBIENT"
out=$("$SCRIPT" --json 2>&1)
if echo "$out" | grep -q '"status":"unknown"'; then
    echo "  PASS"
else
    echo "  FAIL: expected status=unknown, got: $out"
    exit 1
fi

# ── Test 3: all-clean sample → pct=100, green ────────────────────────────────
echo "Test 3: all-clean sample → pct=100"
make_gh_stub $'2001\n2002\n2003'
> "$AMBIENT"
# Add some noise events that should NOT count as bypasses for our PRs
printf '{"ts":"2026-05-23T00:00:00Z","kind":"github_api_call","script":"gh"}\n' >> "$AMBIENT"
printf '{"ts":"2026-05-23T00:00:01Z","kind":"audit_no_verify","pr":1999,"reason":"unrelated"}\n' >> "$AMBIENT"

out=$("$SCRIPT" --window 3 --json 2>&1)
rc=$?
if echo "$out" | grep -qE '"pct":100,"sample_size":3,"bypassed":0' \
    && echo "$out" | grep -q '"status":"green"' \
    && [[ "$rc" -eq 0 ]]; then
    echo "  PASS"
else
    echo "  FAIL: expected pct=100 sample=3 bypassed=0 status=green rc=0, got rc=$rc: $out"
    exit 1
fi

# ── Test 4: 3/5 bypassed → pct=40, red, rc=2 ─────────────────────────────────
echo "Test 4: 3/5 bypassed → pct=40 red"
make_gh_stub $'3001\n3002\n3003\n3004\n3005'
> "$AMBIENT"
printf '{"ts":"2026-05-23T00:00:00Z","kind":"audit_no_verify","pr":3001,"reason":"hot fix"}\n' >> "$AMBIENT"
printf '{"ts":"2026-05-23T00:00:01Z","kind":"preflight_bypassed","pr_number":3002}\n' >> "$AMBIENT"
printf '{"ts":"2026-05-23T00:00:02Z","kind":"ci_flake_rerun","pr":3003}\n' >> "$AMBIENT"
out=$("$SCRIPT" --window 5 --json 2>&1) && rc=0 || rc=$?
if echo "$out" | grep -qE '"pct":40,"sample_size":5,"bypassed":3' \
    && echo "$out" | grep -q '"status":"red"' \
    && [[ "$rc" -eq 2 ]]; then
    echo "  PASS"
else
    echo "  FAIL: expected pct=40 bypassed=3 status=red rc=2, got rc=$rc: $out"
    exit 1
fi

# Verify the ambient line was actually written (one ci_qa_score row per call).
ci_count=$(grep -c '"kind":"ci_qa_score"' "$AMBIENT" || true)
if [[ "$ci_count" -lt 1 ]]; then
    echo "  FAIL: expected at least 1 kind=ci_qa_score line in ambient, got $ci_count"
    exit 1
fi

# ── Test 5: 1/10 bypassed → pct=90 amber rc=1 ────────────────────────────────
echo "Test 5: 1/10 bypassed → pct=90 amber rc=1"
make_gh_stub $'4001\n4002\n4003\n4004\n4005\n4006\n4007\n4008\n4009\n4010'
> "$AMBIENT"
printf '{"ts":"2026-05-23T00:00:00Z","kind":"ci_flake_rerun","pr":4007}\n' >> "$AMBIENT"
out=$("$SCRIPT" --window 10 --json 2>&1) && rc=0 || rc=$?
if echo "$out" | grep -qE '"pct":90,"sample_size":10,"bypassed":1' \
    && echo "$out" | grep -q '"status":"amber"' \
    && [[ "$rc" -eq 1 ]]; then
    echo "  PASS"
else
    echo "  FAIL: expected pct=90 bypassed=1 status=amber rc=1, got rc=$rc: $out"
    exit 1
fi

# ── Test 6: --dry-run does not emit to ambient ───────────────────────────────
echo "Test 6: --dry-run skips ambient emit"
make_gh_stub $'5001\n5002'
> "$AMBIENT"
"$SCRIPT" --window 2 --dry-run --json > /dev/null 2>&1
if [[ ! -s "$AMBIENT" ]]; then
    echo "  PASS"
else
    echo "  FAIL: --dry-run should not write to ambient.jsonl"
    cat "$AMBIENT"
    exit 1
fi

# ── Test 7: only the canonical green|amber|red|unknown vocabulary is ever
#           emitted, across every reachable code path (INFRA-3854) ──────────
echo "Test 7: emitted statuses are all within {green,amber,red,unknown}"
> "$AMBIENT"

make_gh_stub ""
"$SCRIPT" --json > /dev/null 2>&1 || true                     # unknown (no data)

make_gh_stub $'6001\n6002'
"$SCRIPT" --window 2 --json > /dev/null 2>&1 || true           # green (all-clean)

make_gh_stub $'6003\n6004\n6005'
printf '{"ts":"2026-05-23T00:00:00Z","kind":"audit_no_verify","pr":6003,"reason":"x"}\n' >> "$AMBIENT"
printf '{"ts":"2026-05-23T00:00:01Z","kind":"audit_no_verify","pr":6004,"reason":"x"}\n' >> "$AMBIENT"
"$SCRIPT" --window 3 --json > /dev/null 2>&1 || true           # red (2/3 bypassed)

make_gh_stub $'6006\n6007\n6008\n6009\n6010\n6011\n6012\n6013\n6014\n6015'
printf '{"ts":"2026-05-23T00:00:02Z","kind":"ci_flake_rerun","pr":6006}\n' >> "$AMBIENT"
"$SCRIPT" --window 10 --json > /dev/null 2>&1 || true          # amber (1/10 bypassed)

seen="$(grep -oE '"status":"[a-z_]+"' "$AMBIENT" | sed -E 's/"status":"([a-z_]+)"/\1/' | sort -u)"
bad="$(printf '%s\n' "$seen" | grep -vE '^(green|amber|red|unknown)$' || true)"
if [[ -z "$bad" ]] && printf '%s\n' "$seen" | grep -q green \
    && printf '%s\n' "$seen" | grep -q amber \
    && printf '%s\n' "$seen" | grep -q red \
    && printf '%s\n' "$seen" | grep -q unknown; then
    echo "  PASS (observed: $(printf '%s' "$seen" | tr '\n' ' '))"
else
    echo "  FAIL: expected exactly {green,amber,red,unknown}, got: $seen"
    exit 1
fi

echo
echo "All 7 ci-qa-score smoke tests passed."
