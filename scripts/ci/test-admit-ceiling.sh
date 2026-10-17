#!/usr/bin/env bash
# test-admit-ceiling.sh — INFRA-8219
#
# Proves the Rust `chump admit` node-wide admission ceiling (src/admit.rs,
# porting RESILIENT-1604):
#   1. Below the ceiling → exit 0 (slot free).
#   2. At/over the ceiling with --wait-s → exit 75 (deferred) + emits
#      kind=admission_deferred to ambient.jsonl.
#   3. Deferral proven with REAL fake processes (sentinel `sleep`) counted via
#      pgrep + the pattern test-seam — not only the static count seam.
#   4. --json shape, help, and usage errors.
#   5. EVENT_REGISTRY.yaml registers admission_deferred.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REG="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"

# Don't let a CI-workflow-injected ambient/lock dir hijack our fixtures.
unset CHUMP_REPO CHUMP_LOCK_DIR CHUMP_AMBIENT_IN_PROMPT || true

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; kill $(jobs -p) 2>/dev/null || true' EXIT

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

CHUMP="$REPO_ROOT/target/debug/chump"
[[ ! -x "$CHUMP" ]] && CHUMP="$REPO_ROOT/target/release/chump"
[[ ! -x "$CHUMP" ]] && CHUMP="${HOME}/.cargo/bin/chump"
[[ ! -x "$CHUMP" ]] && CHUMP="$(command -v chump 2>/dev/null || echo "")"
if [[ -z "$CHUMP" || ! -x "$CHUMP" ]]; then
    echo "building chump (debug) ..."
    ( cd "$REPO_ROOT" && PATH="$HOME/.cargo/bin:$PATH" cargo build --quiet --bin chump )
    CHUMP="$REPO_ROOT/target/debug/chump"
fi
[[ -x "$CHUMP" ]] || fail "chump binary not found/built"

AMB="$TMP/ambient.jsonl"
# Isolate from any real node.env; ceiling comes from the process env below.
export CHUMP_STATE_DIR="$TMP"
export CHUMP_AMBIENT_IN_PROMPT="$AMB"
# Keep polls snappy so the bounded waits don't drag the test out.
export CHUMP_ADMISSION_POLL_INTERVAL_S=1

# ---------------------------------------------------------------------------
# 1. Below ceiling → exit 0 (static count seam = 0, ceiling = 4).
# ---------------------------------------------------------------------------
rc=0
CHUMP_MAX_CONCURRENT_CLAUDE=4 CHUMP_ADMISSION_TEST_CLAUDE_COUNT=0 \
    "$CHUMP" admit claude >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 0 ]] || fail "below-ceiling admit should exit 0, got $rc"
ok "below ceiling → exit 0"

# ---------------------------------------------------------------------------
# 2. At/over ceiling via static seam → exit 75 + ambient emit.
# ---------------------------------------------------------------------------
: > "$AMB"
rc=0
CHUMP_MAX_CONCURRENT_CLAUDE=2 CHUMP_ADMISSION_TEST_CLAUDE_COUNT=5 \
    "$CHUMP" admit claude >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 75 ]] || fail "over-ceiling admit should exit 75, got $rc"
grep -q '"kind":"admission_deferred"' "$AMB" \
    || fail "expected kind=admission_deferred in ambient.jsonl"
grep -q '"resource":"claude"' "$AMB" \
    || fail "admission_deferred should carry resource=claude"
ok "over ceiling (static seam) → exit 75 + admission_deferred emitted"

# ---------------------------------------------------------------------------
# 3. Deferral proven with REAL fake processes (sentinel sleeps) + pgrep.
#    ceiling=1, two live sentinel procs → active=2 >= 1 → deferred.
# ---------------------------------------------------------------------------
: > "$AMB"
# Unique per-run arg so concurrent test/preflight runs can't cross-count each
# other's sentinels (the active:2 assertion below depends on an exact count).
SENTINEL="sleep 8484$$"
# shellcheck disable=SC2086
$SENTINEL & SP1=$!
# shellcheck disable=SC2086
$SENTINEL & SP2=$!
sleep 0.4   # let the procs register in the process table
rc=0
CHUMP_MAX_CONCURRENT_CLAUDE=1 \
    CHUMP_ADMISSION_COUNT_PATTERN_CLAUDE="$SENTINEL" \
    "$CHUMP" admit claude --wait-s 1 --json >"$TMP/out.json" 2>/dev/null || rc=$?
kill "$SP1" "$SP2" 2>/dev/null || true
[[ "$rc" -eq 75 ]] || fail "real-process deferral should exit 75, got $rc (out: $(cat "$TMP/out.json"))"
grep -q '"admitted":false' "$TMP/out.json" || fail "--json should report admitted:false"
grep -q '"active":2' "$TMP/out.json" || fail "--json should report active:2 (two sentinels), got: $(cat "$TMP/out.json")"
grep -q '"kind":"admission_deferred"' "$AMB" || fail "real-process deferral should emit admission_deferred"
ok "over ceiling (real sentinel procs, pgrep count) → exit 75, active=2"

# ---------------------------------------------------------------------------
# 4. --json free shape, help, usage errors.
# ---------------------------------------------------------------------------
CHUMP_MAX_CONCURRENT_CLAUDE=4 CHUMP_ADMISSION_TEST_CLAUDE_COUNT=0 \
    "$CHUMP" admit claude --json >"$TMP/free.json" 2>/dev/null
grep -q '"admitted":true' "$TMP/free.json" || fail "free --json should report admitted:true"
grep -q '"state":"free"' "$TMP/free.json" || fail "free --json should report state:free"
ok "--json free shape"

"$CHUMP" admit --help >/dev/null 2>&1 || fail "--help should exit 0"
ok "--help exits 0"

rc=0; "$CHUMP" admit >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 2 ]] || fail "missing resource should exit 2, got $rc"
rc=0; "$CHUMP" admit bogus >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 2 ]] || fail "unknown resource should exit 2, got $rc"
rc=0; CHUMP_ADMISSION_TEST_CARGO_COUNT=0 "$CHUMP" admit cargo >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 0 ]] || fail "cargo resource should be accepted, got $rc"
ok "usage errors exit 2; cargo resource accepted"

# ---------------------------------------------------------------------------
# 5. EVENT_REGISTRY registration.
# ---------------------------------------------------------------------------
grep -q 'kind: admission_deferred' "$REG" \
    || fail "admission_deferred not registered in EVENT_REGISTRY.yaml"
ok "EVENT_REGISTRY registers admission_deferred"

echo
ok "all admission-ceiling checks passed"
