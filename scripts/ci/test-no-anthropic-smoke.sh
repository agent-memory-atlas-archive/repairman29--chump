#!/usr/bin/env bash
# capability-guard-exempt: existing skip-path covers missing binary; pattern wording differs from canonical (CREDIBLE-078)
# test-no-anthropic-smoke.sh — CREDIBLE-046
#
# Proves chump's coordination layer works without ANY Anthropic credentials.
# This enforces the "chump-first" doctrine: Claude is one backend among many.
#
# What is tested (the coordination contract):
#   1. chump gap list  — reads state.db, no API call
#   2. chump gap reserve — writes state.db, no API call (ZERO-WASTE-020,
#      2026-07-19: no longer writes a YAML mirror — state.db is canonical)
#   3. chump gap ship  — flips status in state.db, no API call
#   4. No Anthropic credential is consumed at any point
#
# Worker spawn (Ollama/opencode) is explicitly NOT tested here — that is an
# integration concern. This test covers the coordination substrate that must
# work independently of any LLM backend.
#
# Usage in CI:
#   ANTHROPIC_API_KEY="" CLAUDE_CODE_OAUTH_TOKEN="" bash scripts/ci/test-no-anthropic-smoke.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

# Hard-unset Anthropic credentials — any test below that calls the Anthropic
# API will fail with a timeout or 401, which is exactly what we want to catch.
unset ANTHROPIC_API_KEY
unset CLAUDE_CODE_OAUTH_TOKEN
export ANTHROPIC_API_KEY=""
export CLAUDE_CODE_OAUTH_TOKEN=""

# Resolve chump binary
CHUMP_BIN="${CHUMP_BIN:-chump}"
command -v "$CHUMP_BIN" >/dev/null 2>&1 || fail "Cannot find chump binary at CHUMP_BIN=$CHUMP_BIN"

TMP="$(mktemp -d -t test-credible-046.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

echo "=== CREDIBLE-046: no-Anthropic smoke test ==="
echo "CHUMP_BIN=$CHUMP_BIN"
echo "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-(unset)}"
echo ""

# ── Test 1: chump gap list works without creds ──────────────────────────────
echo "--- Test 1: gap list ---"
# Use a fresh temp state.db so we don't depend on main repo state in CI
export CHUMP_STATE_DB="$TMP/state.db"
output=$("$CHUMP_BIN" gap list --status open 2>&1 || true)
# Should not error out, may print "state.db is empty" or a list
# INFRA-1900: anchor the grep to actual Anthropic-call failure markers, not
# gap-title substrings. Old pattern "Error.*anthropic\|401\|API key" tripped
# false-positive on gap titles like "INFRA-1893: HTTP 401 Bad credentials"
# or gaps referencing "API key" when auto-import populated the temp state.db
# from docs/gaps/ on empty-state.db path (INFRA-821) and dumped them.
# New pattern matches concrete failure phrases the Anthropic SDK actually
# emits when a real API call is attempted without creds.
if echo "$output" | grep -qE "ANTHROPIC_API_KEY (not set|missing|required)|anthropic\.com.*401|HTTP 401 .* api\.anthropic\.com|reqwest::Error.*api\.anthropic"; then
    fail "gap list made an Anthropic API call: $output"
fi
pass "gap list works without Anthropic creds"

# ── Test 2: chump gap reserve works without creds ──────────────────────────
echo "--- Test 2: gap reserve ---"
# CREDIBLE-1519: --force bypasses the RESILIENT-069 farmer-RED claim gate so
# this fixture seed is hermetic against host farmer state (the no-creds path
# under test is unaffected by --force).
gap_id=$(FLEET_029_AMBIENT_GLANCE_SKIP=1 "$CHUMP_BIN" gap reserve \
    --domain TEST \
    --title "TEST: CREDIBLE-046 no-anthropic smoke fixture" \
    --priority P3 --force 2>&1 | grep '^TEST-' | tail -1)
[ -n "$gap_id" ] || fail "gap reserve failed or returned no gap ID"
# ZERO-WASTE-020: state.db is canonical; gap reserve no longer writes a
# docs/gaps/<ID>.yaml mirror. Read state via `gap show` instead.
# NOTE: capture to a variable before grepping — `cmd | grep -q` races: grep -q
# exits the instant it finds a match, which can SIGPIPE the still-writing
# producer and make `pipefail` report the pipeline as failed even though the
# match was found (observed intermittently, ~1-in-5, while authoring this).
show_out=$("$CHUMP_BIN" gap show "$gap_id" 2>&1)
echo "$show_out" | grep -q "status: open" || fail "gap status is not 'open' after reserve"
pass "gap reserve works without Anthropic creds (gap=$gap_id)"

# ── Test 3: chump gap show works without creds ─────────────────────────────
echo "--- Test 3: gap show ---"
show_out=$("$CHUMP_BIN" gap show "$gap_id" 2>&1)
echo "$show_out" | grep -q "id: $gap_id" || fail "gap show did not return expected ID"
if echo "$show_out" | grep -q "Error.*anthropic\|401\|API key"; then
    fail "gap show made an Anthropic API call"
fi
pass "gap show works without Anthropic creds"

# ── Test 4: chump gap ship works without creds ─────────────────────────────
echo "--- Test 4: gap ship ---"
# INFRA-2423: CHUMP_BYPASS_PROOF_OF_MERGE deleted; ship auto-fetches origin/main.
# Satisfy proof-of-merge by pointing CHUMP_REPO at an isolated git repo whose
# main branch has a commit mentioning $gap_id. The state.db is still read from
# CHUMP_STATE_DB=$TMP/state.db so the gap record is found correctly.
proof_repo="$TMP/proof-repo-$$"
mkdir -p "$proof_repo"
git -C "$proof_repo" init -q
git -C "$proof_repo" config user.email "test@integration.local"
git -C "$proof_repo" config user.name "Integration Test"
echo "proof" > "$proof_repo/marker.txt"
git -C "$proof_repo" add marker.txt
git -C "$proof_repo" commit -q -m "feat(${gap_id}): no-anthropic smoke proof-of-merge marker"
CHUMP_REPO="$proof_repo" \
CHUMP_SKIP_SUPERSEDED_CLOSE=1 \
CHUMP_SHIP_NO_AUTOSTAGE=1 \
CHUMP_ALLOW_STALE_DESTRUCTIVE=1 \
CHUMP_GAP_SHIP_SKIP_STALE_CHECK=1 \
"$CHUMP_BIN" gap ship "$gap_id" --closed-pr 9999 \
    || fail "gap ship failed"
# ZERO-WASTE-020: state.db is canonical; gap ship no longer writes a
# docs/gaps/<ID>.yaml mirror (--update-yaml is now a documented no-op).
# NOTE: capture to a variable before grepping — see Test 2's comment above
# for why a live `cmd | grep -q` pipe is a pipefail/SIGPIPE race.
show_out=$("$CHUMP_BIN" gap show "$gap_id" 2>&1)
echo "$show_out" | grep -q "status: done" || fail "gap status not 'done' after ship"
pass "gap ship works without Anthropic creds"

# ── Test 5: no Anthropic API calls in ambient log ──────────────────────────
echo "--- Test 5: no Anthropic API calls ---"
ambient="$REPO_ROOT/.chump-locks/ambient.jsonl"
if [ -f "$ambient" ]; then
    # Check last 20 events — none should have provider=anthropic from this session
    recent_anthropic=$(tail -20 "$ambient" 2>/dev/null | \
        python3 -c "
import sys,json
count=0
for line in sys.stdin:
    try:
        e=json.loads(line.strip())
        if e.get('provider')=='anthropic' and 'TEST-' in str(e):
            count+=1
    except: pass
print(count)
" 2>/dev/null || echo "0")
    if [ "$recent_anthropic" -gt 0 ]; then
        fail "Detected $recent_anthropic Anthropic API call(s) for TEST gap — chump-first contract violated"
    fi
    pass "no Anthropic API calls emitted for coordination operations"
else
    pass "ambient log check skipped (not available in this environment)"
fi

# ── Cleanup: nothing to remove — ZERO-WASTE-020 means gap reserve/ship
#    never wrote a docs/gaps/<ID>.yaml fixture file to clean up. The test
#    fixture gap lives only in $CHUMP_STATE_DB, which `trap cleanup EXIT`
#    (rm -rf "$TMP") already removes.

echo ""
echo "All CREDIBLE-046 no-Anthropic smoke tests passed."
echo "chump's coordination layer is Anthropic-independent."
