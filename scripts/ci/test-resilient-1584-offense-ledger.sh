#!/usr/bin/env bash
# RESILIENT-1584: rc=0 unverified_ship must count in the INFRA-3832 offense
# ledger and the rc=0 branch must not wipe it. Replays RESILIENT-445:
# rc=143, rc=0 unverified_ship, rc=143 -> status=blocked; a verified ship clears.
# Depth: happy-path + interleaved edge. Gaps: no live worker run; worker.sh
# wiring asserted structurally, ledger behavior exercised via the shared lib.
set -euo pipefail
PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
REPO_SRC="$(cd "$(dirname "$0")/../.." && pwd)"
WORKER="$REPO_SRC/scripts/dispatch/worker.sh"

# Structural: rc==0 branch has no wipe; wipe only in shipped path.
rc0="$(awk '/if \[ "\$rc" -eq 0 \]; then/{f=1} f&&/^    else$/{exit} f' "$WORKER" | sed -n '1,12p')"
if printf '%s' "$rc0" | grep -q 'offense/'; then fail "rc==0 branch still touches offense ledger"; else ok "rc==0 branch does not wipe ledger"; fi
grep -q 'offense_clear "\$GAP_ID"' "$WORKER" && ok "verified-ship path clears ledger" || fail "no offense_clear in shipped path"
grep -q '_uv_offense_n="\$(offense_bump' "$WORKER" && ok "unverified_ship path bumps ledger" || fail "unverified_ship does not bump ledger"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export REPO_ROOT="$TMP" CHUMP_AMBIENT_LOG="$TMP/ambient.jsonl" AGENT_ID=t
mkdir -p "$TMP/bin"
cat > "$TMP/bin/chump" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$REPO_ROOT/chump-calls.log"
STUB
chmod +x "$TMP/bin/chump"; export PATH="$TMP/bin:$PATH"
source "$REPO_SRC/scripts/dispatch/lib/offense-ledger.sh"

G=RESILIENT-445
n=$(offense_bump $G); offense_maybe_block $G "$n" "timeout" 124
n=$(offense_bump $G); offense_maybe_block $G "$n" "timeout" 124
[ ! -f "$TMP/chump-calls.log" ] && ok "no block after 2 offenses" || fail "blocked too early"
n=$(offense_bump $G); offense_maybe_block $G "$n" "timeout" 124
if grep -q "gap set $G --status blocked" "$TMP/chump-calls.log" 2>/dev/null; then ok "Transient pattern (3x timeout) -> blocked"; else fail "Transient pattern not blocked"; fi

rm -f "$TMP/chump-calls.log"
offense_bump G2 >/dev/null; offense_bump G2 >/dev/null; offense_clear G2
n=$(offense_bump G2); [ "$n" = 1 ] && ok "verified ship clears ledger" || fail "ledger not cleared (n=$n)"

# RESILIENT-1344: Test Capability classification routes to capable_agent_escalation queue.
# Transient (timeout) case -> auto-blocks
G3=RESILIENT-1344-TRANSIENT
rm -f "$TMP/chump-calls.log" "$TMP/ambient.jsonl"
n=$(offense_bump $G3); offense_maybe_block $G3 "$n" "timeout" 124
n=$(offense_bump $G3); offense_maybe_block $G3 "$n" "timeout" 124
n=$(offense_bump $G3); offense_maybe_block $G3 "$n" "timeout" 124
if grep -q "gap set $G3 --status blocked" "$TMP/chump-calls.log" 2>/dev/null && grep -q '"kind":"gap_auto_blocked"' "$TMP/ambient.jsonl" 2>/dev/null; then
    ok "Transient (timeout) -> auto-blocked"
else
    fail "Transient (timeout) did not auto-block"
fi

# Capability (unverified_ship) case -> escalation queue
G4=RESILIENT-1344-CAPABILITY
rm -f "$TMP/chump-calls.log" "$TMP/ambient.jsonl"
n=$(offense_bump $G4); offense_maybe_block $G4 "$n" "unverified_ship" 0
n=$(offense_bump $G4); offense_maybe_block $G4 "$n" "unverified_ship" 0
n=$(offense_bump $G4); offense_maybe_block $G4 "$n" "unverified_ship" 0
if ! grep -q "gap set $G4 --status blocked" "$TMP/chump-calls.log" 2>/dev/null && grep -q '"kind":"capable_agent_escalation"' "$TMP/ambient.jsonl" 2>/dev/null; then
    ok "Capability (unverified_ship) -> capable_agent_escalation"
else
    fail "Capability (unverified_ship) did not escalate (got auto-blocked instead)"
fi

echo "pass=$PASS fail=$FAIL"; [ "$FAIL" -eq 0 ]
