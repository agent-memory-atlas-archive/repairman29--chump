#!/usr/bin/env bash
# scripts/ci/test-digest-delivery-liveness.sh — RESILIENT-1496

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SCRIPT="$REPO_ROOT/scripts/coord/digest-delivery-liveness.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }
[ -x "$SCRIPT" ] || fail "missing or not executable"

export CHUMP_LOCK_DIR="$TMP/locks"
mkdir -p "$CHUMP_LOCK_DIR"
AMB="$CHUMP_LOCK_DIR/ambient.jsonl"

# ── Test 1: autopost off → healthy-and-quiet regardless of ambient state ──
out=$(CHUMP_OPERATOR_AUTOPOST_DM=0 "$SCRIPT") || fail "should exit 0 when autopost is off: $out"
echo "$out" | grep -q "quiet-by-design" || fail "missing quiet-by-design message: $out"
ok "autopost off → OK, quiet-by-design, exit 0"

# ── Test 2: autopost on, no digest cycle recorded yet → UNKNOWN, exit 0 ──
: > "$AMB"
out=$(CHUMP_OPERATOR_AUTOPOST_DM=1 "$SCRIPT") || fail "should exit 0 when no cycle recorded: $out"
echo "$out" | grep -q "UNKNOWN" || fail "missing UNKNOWN message: $out"
ok "no digest cycle recorded → UNKNOWN, exit 0"

# ── Test 3: autopost on, last cycle actually delivered → OK, exit 0 ──────
python3 -c "
import json
print(json.dumps({'ts': '2026-09-30T09:00:00Z', 'kind': 'chump_digest_posted'}))
" > "$AMB"
out=$(CHUMP_OPERATOR_AUTOPOST_DM=1 "$SCRIPT") || fail "should exit 0 when last cycle delivered: $out"
echo "$out" | grep -q "OK — last digest cycle delivered" || fail "missing delivered message: $out"
ok "last cycle delivered → OK, exit 0"

# ── Test 4: autopost on, last cycle was suppressed (the false-positive class
#    RESILIENT-1496 exists to catch) → ALARM, exit 1, ambient event appended ──
python3 -c "
import json
print(json.dumps({'ts': '2026-09-30T09:00:00Z', 'kind': 'chump_digest_suppressed'}))
" > "$AMB"
if CHUMP_OPERATOR_AUTOPOST_DM=1 "$SCRIPT" 2>"$TMP/err"; then
    fail "should exit non-zero when the last cycle was suppressed but autopost is on"
fi
grep -q "ALARM" "$TMP/err" || fail "missing ALARM message: $(cat "$TMP/err")"
grep -q "digest_delivery_broken" "$AMB" || fail "alarm event not appended to ambient"
ok "last cycle suppressed while autopost is on → ALARM, exit 1, ambient event"

echo
echo "All RESILIENT-1496 digest-delivery-liveness tests passed."
