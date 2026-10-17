#!/usr/bin/env bash
# scripts/ci/test-pr-auto-rearm.sh — INFRA-1907
#
# Smoke test for the auto-rearm sweeper daemon. Mocks gh output to verify:
# (1) BLOCKED + disarmed PRs get re-armed
# (2) BLOCKED + already armed are skipped
# (3) DIRTY are skipped (not our job — that's pr-auto-rebase)
# (4) Throttle prevents re-arm within window
# (5) Bypass env var short-circuits
# (6) Ambient emit shape correct

set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TARGET="$REPO/scripts/coord/pr-auto-rearm.sh"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -f "$TARGET" ]] || fail "$TARGET missing"
[[ -x "$TARGET" ]] || fail "$TARGET not executable"
bash -n "$TARGET" || fail "syntax error"
ok "script exists, executable, parses"

# ── Structural ────────────────────────────────────────────────────────────
grep -q 'CHUMP_PR_AUTO_REARM_DISABLED' "$TARGET" || fail "no bypass env"
ok "bypass env present"

grep -q 'pr_auto_rearmed' "$TARGET" || fail "no ambient kind"
ok "emits kind=pr_auto_rearmed"

grep -q 'autoMergeRequest == null' "$TARGET" || fail "no disarmed-filter"
ok "filters on autoMergeRequest == null"

grep -q 'mergeStateStatus == "BLOCKED"' "$TARGET" || fail "no BLOCKED filter"
ok "filters on BLOCKED state"

grep -q 'CHUMP_PR_AUTO_REARM_THROTTLE_MIN' "$TARGET" || fail "no throttle env"
ok "throttle (CHUMP_PR_AUTO_REARM_THROTTLE_MIN) present"

grep -q 'INFRA-1907' "$TARGET" || fail "no INFRA-1907 attribution"
ok "INFRA-1907 attribution present"

# ── Functional: mock gh, run script ───────────────────────────────────────
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.chump-locks"

# Mock gh
cat > "$TMP/gh" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "pr" && "$2" == "list" ]]; then
cat <<JSON
[
  {"number": 9001, "mergeStateStatus": "BLOCKED", "autoMergeRequest": null},
  {"number": 9002, "mergeStateStatus": "BLOCKED", "autoMergeRequest": {"mergeMethod": "SQUASH"}},
  {"number": 9003, "mergeStateStatus": "DIRTY",   "autoMergeRequest": null},
  {"number": 9004, "mergeStateStatus": "BLOCKED", "autoMergeRequest": null}
]
JSON
    exit 0
fi
if [[ "$1" == "pr" && "$2" == "merge" ]]; then
    echo "$3" >> "$REARM_LOG"
    exit 0
fi
exit 0
MOCK
chmod +x "$TMP/gh"

REARM_LOG="$TMP/rearms.log"
touch "$REARM_LOG"
export REARM_LOG

# Run script in synthetic repo
SYN="$TMP/syn-repo"
mkdir -p "$SYN/scripts/coord" "$SYN/scripts/dev" "$SYN/.chump-locks"
(cd "$SYN" && git init -q)
cp "$TARGET" "$SYN/scripts/coord/pr-auto-rearm.sh"
# RESILIENT-1613: pr-auto-rearm.sh sources the shared arm policy.
mkdir -p "$SYN/scripts/coord/lib"
cp "$(dirname "$TARGET")/lib/arm-policy.sh" "$SYN/scripts/coord/lib/arm-policy.sh"

# Mock ambient-emit too (so the real version isn't called)
cat > "$SYN/scripts/dev/ambient-emit.sh" <<'MOCK'
#!/usr/bin/env bash
echo "[mock-emit] $*"
MOCK
chmod +x "$SYN/scripts/dev/ambient-emit.sh"

out="$(cd "$SYN" && PATH="$TMP:$PATH" CHUMP_AMBIENT_LOG="$SYN/.chump-locks/ambient.jsonl" bash "$SYN/scripts/coord/pr-auto-rearm.sh" 2>&1 || true)"

# Should re-arm 9001 + 9004 (BLOCKED+disarmed); skip 9002 (already armed); skip 9003 (DIRTY)
echo "$out" | grep -q "re-arming #9001" || fail "did not re-arm #9001 (BLOCKED+disarmed); got: $out"
echo "$out" | grep -q "re-arming #9004" || fail "did not re-arm #9004 (BLOCKED+disarmed)"
echo "$out" | grep -q "9002" && fail "should NOT touch #9002 (already armed)"
echo "$out" | grep -q "9003" && fail "should NOT touch #9003 (DIRTY — not our job)"
ok "re-arms only BLOCKED+disarmed (9001, 9004); skips armed (9002) + DIRTY (9003)"

# Verify rearm log shows correct PRs
if grep -q "9001" "$REARM_LOG" && grep -q "9004" "$REARM_LOG"; then
    ok "rearm log records #9001 + #9004"
else
    fail "rearm log missing entries; saw: $(cat $REARM_LOG)"
fi
if grep -q "9002\|9003" "$REARM_LOG"; then
    fail "rearm log incorrectly recorded #9002 or #9003"
fi
ok "rearm log does NOT touch armed or DIRTY PRs"

# Second run — throttle should kick in for 9001 + 9004
out2="$(cd "$SYN" && PATH="$TMP:$PATH" CHUMP_AMBIENT_LOG="$SYN/.chump-locks/ambient.jsonl" bash "$SYN/scripts/coord/pr-auto-rearm.sh" 2>&1 || true)"
if echo "$out2" | grep -qE "SKIP #(9001|9004).*throttle"; then
    ok "throttle prevents re-arm within window"
else
    fail "throttle did not fire; got: $out2"
fi

# Bypass test
out_bypass="$(cd "$SYN" && PATH="$TMP:$PATH" CHUMP_PR_AUTO_REARM_DISABLED=1 bash "$SYN/scripts/coord/pr-auto-rearm.sh" 2>&1 || true)"
if [[ -z "$out_bypass" ]]; then
    ok "CHUMP_PR_AUTO_REARM_DISABLED=1 short-circuits silently"
else
    fail "bypass did not short-circuit; got: $out_bypass"
fi

# Ambient emit shape (run once more after fresh state, no throttle)
rm "$SYN/.chump-locks/pr-auto-rearm-state.jsonl" 2>/dev/null || true
(cd "$SYN" && PATH="$TMP:$PATH" CHUMP_AMBIENT_LOG="$SYN/.chump-locks/ambient.jsonl" bash "$SYN/scripts/coord/pr-auto-rearm.sh" 2>&1) >/dev/null
if grep -q '"kind":"pr_auto_rearmed"' "$SYN/.chump-locks/ambient.jsonl"; then
    ok "ambient.jsonl received pr_auto_rearmed event"
else
    fail "no pr_auto_rearmed event in ambient.jsonl"
fi

echo ""
echo "ALL INFRA-1907 pr-auto-rearm assertions passed."
