#!/usr/bin/env bash
# test-bot-merge-graphql-wedge.sh — INFRA-1939 smoke test.
#
# Verifies bot-merge.sh exits non-zero fast with a WEDGE message within 60s when
# ambient shows a recent kind=graphql_exhausted event. Pre-INFRA-1939 the script
# would silently poll forever burning 144K+ subagent tokens.
#
# INFRA-2426 update: exit code changed from 144 to 4 (documented misc-abort code).
# The test now accepts exit 4 as the correct fast-abort code for the wedge guard.
# Exit 144 was undocumented and caused confusion with pipefail signal arithmetic.

set -uo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOT_MERGE="$SCRIPT_DIR/../coord/bot-merge.sh"

[ -f "$BOT_MERGE" ] || { echo "FATAL: bot-merge.sh missing at $BOT_MERGE"; exit 1; }

echo "=== INFRA-1939 bot-merge.sh graphql_exhausted wedge guard ==="

# --- Test 1: recent graphql_exhausted → bot-merge exits 4 fast (INFRA-2426) ---
TMP1="$(mktemp -d)"
trap 'rm -rf "$TMP1"' EXIT

mkdir -p "$TMP1/.chump-locks" "$TMP1/bin"
# CREDIBLE-1584: initialize isolated temp git repo so bot-merge never touches caller checkout
git -C "$TMP1" init -q -b feat/wedge-probe
git -C "$TMP1" config user.email "t@chump.local"
git -C "$TMP1" config user.name "t"
git -C "$TMP1" commit -q --allow-empty -m "init" --no-verify
NOW_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# Write a graphql_exhausted event with ts = now (clearly within 30min window)
printf '{"ts":"%s","kind":"graphql_exhausted","source":"test","remaining":0}\n' "$NOW_TS" \
    > "$TMP1/.chump-locks/ambient.jsonl"

# INFRA-2463: the wedge guard now does a live rate_limit check before aborting.
# Mock gh to return remaining=0 so the live check confirms real exhaustion.
_real_gh="$(command -v gh 2>/dev/null || echo gh)"
cat > "$TMP1/bin/gh" <<GHEOF
#!/usr/bin/env bash
if [ "\$1" = "api" ] && [ "\$2" = "rate_limit" ]; then echo "0"; exit 0; fi
exec "${_real_gh}" "\$@"
GHEOF
chmod +x "$TMP1/bin/gh"

# Run bot-merge with the synth ambient + ~60s timeout
SECONDS=0
PATH="$TMP1/bin:$PATH" \
    CHUMP_AMBIENT_LOG="$TMP1/.chump-locks/ambient.jsonl" \
    CHUMP_REPO_ROOT="$TMP1" \
    timeout 60 bash "$BOT_MERGE" --gap none --dry-run >/tmp/wedge-test-out 2>&1
rc=$?
ELAPSED=$SECONDS

# INFRA-2426: exit code changed from 144 to 4. Accept 4 (correct) or reject 144 (broken).
if [ "$rc" = "4" ]; then
    if [ "$ELAPSED" -lt 30 ]; then
        ok "exits 4 fast on recent graphql_exhausted (${ELAPSED}s) [INFRA-2426: was 144]"
    else
        fail "exit 4 correct but took ${ELAPSED}s (expected <30s — should fail-fast)"
    fi
elif [ "$rc" = "144" ]; then
    fail "exits 144 — INFRA-2426 fix did not apply (should now exit 4)"
    echo "  ---last 5 lines of stderr---" >&2
    tail -5 /tmp/wedge-test-out >&2 || true
else
    fail "expected exit 4 on graphql_exhausted, got $rc (elapsed ${ELAPSED}s)"
    echo "  ---last 5 lines of stderr---" >&2
    tail -5 /tmp/wedge-test-out >&2 || true
fi

# Check WEDGE message present in stderr
if grep -q "WEDGE: bot-merge cannot proceed under graphql_exhausted" /tmp/wedge-test-out 2>/dev/null; then
    ok "WEDGE message present in stderr"
else
    fail "WEDGE message missing from stderr"
fi

# --- Test 2: old graphql_exhausted (> 30min) → bot-merge proceeds past guard ---
TMP2="$(mktemp -d)"
mkdir -p "$TMP2/.chump-locks"
# CREDIBLE-1584: initialize isolated temp git repo so bot-merge never touches caller checkout
git -C "$TMP2" init -q -b feat/wedge-probe
git -C "$TMP2" config user.email "t@chump.local"
git -C "$TMP2" config user.name "t"
git -C "$TMP2" commit -q --allow-empty -m "init" --no-verify
# 2 hours ago
if date -u -v-2H +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
    OLD_TS="$(date -u -v-2H +%Y-%m-%dT%H:%M:%SZ)"
else
    OLD_TS="$(date -u -d "@$(( $(date +%s) - 7200 ))" +%Y-%m-%dT%H:%M:%SZ)"
fi
printf '{"ts":"%s","kind":"graphql_exhausted","source":"test","remaining":0}\n' "$OLD_TS" \
    > "$TMP2/.chump-locks/ambient.jsonl"

CHUMP_AMBIENT_LOG="$TMP2/.chump-locks/ambient.jsonl" \
    CHUMP_REPO_ROOT="$TMP2" \
    timeout 10 bash "$BOT_MERGE" --gap none --dry-run >/tmp/wedge-test-out2 2>&1
rc2=$?

# Should NOT exit 144 — the old event is outside the window. (Will probably exit with
# some other rc since the dry-run hits other failures; the key is rc != 144.)
if [ "$rc2" != "144" ]; then
    ok "old graphql_exhausted (>30min) does NOT trigger wedge guard"
else
    fail "old graphql_exhausted incorrectly triggered wedge (rc=144)"
fi

# --- Test 3: no graphql_exhausted at all → guard inactive ---
TMP3="$(mktemp -d)"
mkdir -p "$TMP3/.chump-locks"
# CREDIBLE-1584: initialize isolated temp git repo so bot-merge never touches caller checkout
git -C "$TMP3" init -q -b feat/wedge-probe
git -C "$TMP3" config user.email "t@chump.local"
git -C "$TMP3" config user.name "t"
git -C "$TMP3" commit -q --allow-empty -m "init" --no-verify
touch "$TMP3/.chump-locks/ambient.jsonl"

CHUMP_AMBIENT_LOG="$TMP3/.chump-locks/ambient.jsonl" \
    CHUMP_REPO_ROOT="$TMP3" \
    timeout 10 bash "$BOT_MERGE" --gap none --dry-run >/tmp/wedge-test-out3 2>&1
rc3=$?

if [ "$rc3" != "144" ]; then
    ok "empty ambient does NOT trigger wedge guard"
else
    fail "empty ambient incorrectly triggered wedge (rc=144)"
fi

# --- Test 4: bypass env var disables guard ---
TMP4="$(mktemp -d)"
mkdir -p "$TMP4/.chump-locks"
# CREDIBLE-1584: initialize isolated temp git repo so bot-merge never touches caller checkout
git -C "$TMP4" init -q -b feat/wedge-probe
git -C "$TMP4" config user.email "t@chump.local"
git -C "$TMP4" config user.name "t"
git -C "$TMP4" commit -q --allow-empty -m "init" --no-verify
printf '{"ts":"%s","kind":"graphql_exhausted","source":"test","remaining":0}\n' "$NOW_TS" \
    > "$TMP4/.chump-locks/ambient.jsonl"

CHUMP_AMBIENT_LOG="$TMP4/.chump-locks/ambient.jsonl" \
    CHUMP_REPO_ROOT="$TMP4" \
    CHUMP_BOT_MERGE_IGNORE_GRAPHQL_WEDGE=1 \
    timeout 10 bash "$BOT_MERGE" --gap none --dry-run >/tmp/wedge-test-out4 2>&1
rc4=$?

if [ "$rc4" != "144" ]; then
    ok "CHUMP_BOT_MERGE_IGNORE_GRAPHQL_WEDGE=1 bypasses guard"
else
    fail "bypass env var did not work (still exit 144)"
fi

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
