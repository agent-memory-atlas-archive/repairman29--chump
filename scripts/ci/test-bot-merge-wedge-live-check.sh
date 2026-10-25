#!/usr/bin/env bash
# test-bot-merge-wedge-live-check.sh — INFRA-2463 smoke test.
#
# Verifies that bot-merge.sh wedge guard does a live gh api rate_limit check
# when ambient shows a recent graphql_exhausted event but no recovery event.
#
# Test matrix (AC#2 from INFRA-2463):
#   1. Recent graphql_exhausted + live remaining=4234 (>= threshold)
#      → bot-merge emits bot_merge_graphql_wedge_cleared with note=stale-event-cleared
#        and live_remaining=4234; does NOT emit bot_merge_graphql_wedge_aborted;
#        does NOT print "WEDGE: bot-merge cannot proceed" on stderr
#   2. Recent graphql_exhausted + live remaining=50 (< threshold default=100)
#      → bot-merge exits 4, emits bot_merge_graphql_wedge_aborted
#   3. No recent graphql_exhausted
#      → bot-merge proceeds past wedge guard (no live-check needed, no abort event)

set -uo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOT_MERGE="$SCRIPT_DIR/../coord/bot-merge.sh"

[ -f "$BOT_MERGE" ] || { echo "FATAL: bot-merge.sh missing at $BOT_MERGE"; exit 1; }

echo "=== INFRA-2463 bot-merge.sh wedge guard live rate_limit check ==="

NOW_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Helper: create a fake `gh` wrapper that returns a given remaining value
# for `gh api rate_limit --jq .resources.graphql.remaining`,
# and delegates everything else to the real gh.
make_fake_gh() {
    local fake_bin="$1"
    local remaining="$2"
    local real_gh
    real_gh="$(command -v gh 2>/dev/null || echo gh)"
    mkdir -p "$fake_bin"
    cat > "$fake_bin/gh" <<GHEOF
#!/usr/bin/env bash
# Fake gh for INFRA-2463 test — intercept rate_limit only.
if [ "\$1" = "api" ] && [ "\$2" = "rate_limit" ]; then
    echo "${remaining}"
    exit 0
fi
exec "${real_gh}" "\$@"
GHEOF
    chmod +x "$fake_bin/gh"
}

# ── Test 1: recent graphql_exhausted + live remaining=4234 → stale-event-cleared ──
# Detection strategy: check ambient for wedge_cleared (not wedge_aborted) and
# absence of the WEDGE stderr message. We don't assert rc==0 because bot-merge
# may exit non-zero for other reasons downstream (e.g. no real PR to merge).
TMP1="$(mktemp -d)"
trap 'rm -rf "$TMP1"' EXIT

mkdir -p "$TMP1/.chump-locks" "$TMP1/bin"
# CREDIBLE-1584: initialize isolated temp git repo so bot-merge never touches caller checkout
git -C "$TMP1" init -q -b feat/wedge-probe
git -C "$TMP1" config user.email "t@chump.local"
git -C "$TMP1" config user.name "t"
git -C "$TMP1" commit -q --allow-empty -m "init" --no-verify
printf '{"ts":"%s","kind":"graphql_exhausted","source":"test","remaining":0}\n' "$NOW_TS" \
    > "$TMP1/.chump-locks/ambient.jsonl"
make_fake_gh "$TMP1/bin" "4234"

PATH="$TMP1/bin:$PATH" \
    CHUMP_AMBIENT_LOG="$TMP1/.chump-locks/ambient.jsonl" \
    CHUMP_REPO_ROOT="$TMP1" \
    CHUMP_GRAPHQL_WEDGE_LIVE_THRESHOLD=100 \
    timeout 30 bash "$BOT_MERGE" --gap none --dry-run >/tmp/wlc-test1-out 2>&1 || true
# (rc ignored — may fail downstream; wedge guard is tested via ambient events + stderr)

# Must emit bot_merge_graphql_wedge_cleared with stale-event-cleared
if grep -q '"bot_merge_graphql_wedge_cleared"' "$TMP1/.chump-locks/ambient.jsonl" 2>/dev/null \
        && grep -q 'stale-event-cleared' "$TMP1/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "Test 1: ambient contains bot_merge_graphql_wedge_cleared with note=stale-event-cleared"
else
    fail "Test 1: ambient missing bot_merge_graphql_wedge_cleared or note=stale-event-cleared"
    grep '"bot_merge_graphql_wedge_' "$TMP1/.chump-locks/ambient.jsonl" 2>/dev/null || true
fi

# live_remaining=4234 must appear in the cleared event
if grep -q '"live_remaining":4234' "$TMP1/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "Test 1: bot_merge_graphql_wedge_cleared contains live_remaining=4234"
else
    fail "Test 1: bot_merge_graphql_wedge_cleared missing live_remaining=4234"
    grep '"bot_merge_graphql_wedge_cleared"' "$TMP1/.chump-locks/ambient.jsonl" 2>/dev/null || true
fi

# Must NOT emit bot_merge_graphql_wedge_aborted (the stale event was cleared)
if grep -q '"bot_merge_graphql_wedge_aborted"' "$TMP1/.chump-locks/ambient.jsonl" 2>/dev/null; then
    fail "Test 1: ambient wrongly contains bot_merge_graphql_wedge_aborted (stale-event-cleared should prevent abort)"
else
    ok "Test 1: bot_merge_graphql_wedge_aborted NOT emitted (correct — stale event cleared)"
fi

# Must NOT print the WEDGE: stderr message
if grep -q "WEDGE: bot-merge cannot proceed under graphql_exhausted" /tmp/wlc-test1-out 2>/dev/null; then
    fail "Test 1: WEDGE stderr message wrongly printed despite live remaining=4234"
else
    ok "Test 1: no WEDGE stderr message (live check correctly cleared stale event)"
fi

# ── Test 2: recent graphql_exhausted + live remaining=50 → real exhaustion, aborts ──
TMP2="$(mktemp -d)"
mkdir -p "$TMP2/.chump-locks" "$TMP2/bin"
# CREDIBLE-1584: initialize isolated temp git repo so bot-merge never touches caller checkout
git -C "$TMP2" init -q -b feat/wedge-probe
git -C "$TMP2" config user.email "t@chump.local"
git -C "$TMP2" config user.name "t"
git -C "$TMP2" commit -q --allow-empty -m "init" --no-verify
printf '{"ts":"%s","kind":"graphql_exhausted","source":"test","remaining":0}\n' "$NOW_TS" \
    > "$TMP2/.chump-locks/ambient.jsonl"
make_fake_gh "$TMP2/bin" "50"

PATH="$TMP2/bin:$PATH" \
    CHUMP_AMBIENT_LOG="$TMP2/.chump-locks/ambient.jsonl" \
    CHUMP_REPO_ROOT="$TMP2" \
    CHUMP_GRAPHQL_WEDGE_LIVE_THRESHOLD=100 \
    timeout 30 bash "$BOT_MERGE" --gap none --dry-run >/tmp/wlc-test2-out 2>&1
rc2=$?

if [ "$rc2" = "4" ]; then
    ok "Test 2: exits 4 when live remaining=50 < threshold=100 (real exhaustion)"
else
    fail "Test 2: expected exit 4 for real exhaustion (remaining=50 < 100), got rc=$rc2"
    tail -5 /tmp/wlc-test2-out >&2 || true
fi

# Ambient should have bot_merge_graphql_wedge_aborted
if grep -q '"bot_merge_graphql_wedge_aborted"' "$TMP2/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "Test 2: ambient contains bot_merge_graphql_wedge_aborted"
else
    fail "Test 2: ambient missing bot_merge_graphql_wedge_aborted"
fi

# Must NOT emit cleared (real exhaustion was detected)
if grep -q '"bot_merge_graphql_wedge_cleared"' "$TMP2/.chump-locks/ambient.jsonl" 2>/dev/null; then
    fail "Test 2: ambient wrongly contains bot_merge_graphql_wedge_cleared for real exhaustion"
else
    ok "Test 2: bot_merge_graphql_wedge_cleared NOT emitted (correct — real exhaustion)"
fi

# ── Test 3: no recent graphql_exhausted → proceeds (no live-check needed) ──
# No wedge event at all → neither abort nor cleared should be emitted.
# We also confirm no WEDGE: message on stderr.
TMP3="$(mktemp -d)"
mkdir -p "$TMP3/.chump-locks" "$TMP3/bin"
# CREDIBLE-1584: initialize isolated temp git repo so bot-merge never touches caller checkout
git -C "$TMP3" init -q -b feat/wedge-probe
git -C "$TMP3" config user.email "t@chump.local"
git -C "$TMP3" config user.name "t"
git -C "$TMP3" commit -q --allow-empty -m "init" --no-verify
touch "$TMP3/.chump-locks/ambient.jsonl"
# Fake gh returns 50 — if live-check fires unnecessarily, it WOULD cause a false wedge.
# We verify it doesn't by checking no wedge_aborted is emitted.
make_fake_gh "$TMP3/bin" "50"

PATH="$TMP3/bin:$PATH" \
    CHUMP_AMBIENT_LOG="$TMP3/.chump-locks/ambient.jsonl" \
    CHUMP_REPO_ROOT="$TMP3" \
    CHUMP_GRAPHQL_WEDGE_LIVE_THRESHOLD=100 \
    timeout 10 bash "$BOT_MERGE" --gap none --dry-run >/tmp/wlc-test3-out 2>&1 || true

# No wedge_aborted means the guard didn't trip (live-check not triggered unnecessarily)
if grep -q '"bot_merge_graphql_wedge_aborted"' "$TMP3/.chump-locks/ambient.jsonl" 2>/dev/null; then
    fail "Test 3: bot_merge_graphql_wedge_aborted emitted with no graphql_exhausted event — live-check wrongly triggered"
else
    ok "Test 3: no abort event when ambient has no graphql_exhausted event"
fi

# No WEDGE: stderr message either
if grep -q "WEDGE: bot-merge cannot proceed under graphql_exhausted" /tmp/wlc-test3-out 2>/dev/null; then
    fail "Test 3: WEDGE stderr message wrongly printed with no graphql_exhausted in ambient"
else
    ok "Test 3: no WEDGE stderr message when ambient is empty"
fi

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
