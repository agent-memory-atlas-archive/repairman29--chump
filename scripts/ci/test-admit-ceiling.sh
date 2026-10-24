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

CHUMP="${CHUMP_BIN:-}"
[[ -z "$CHUMP" || ! -x "$CHUMP" ]] && [[ -n "${CARGO_TARGET_DIR:-}" ]] && CHUMP="${CARGO_TARGET_DIR}/debug/chump"
[[ -z "$CHUMP" || ! -x "$CHUMP" ]] && [[ -n "${CARGO_TARGET_DIR:-}" ]] && CHUMP="${CARGO_TARGET_DIR}/release/chump"
[[ -z "$CHUMP" || ! -x "$CHUMP" ]] && CHUMP="$REPO_ROOT/target/debug/chump"
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

# ---------------------------------------------------------------------------
# 6. RESILIENT-1679: lease visible in `chump admit status` + `release` +
#    5 concurrent callers against C=2 never exceed 2 active leases.
# ---------------------------------------------------------------------------
"$CHUMP" admit release claude >/dev/null 2>&1 || true
"$CHUMP" admit release cargo >/dev/null 2>&1 || true

CHUMP_MAX_CONCURRENT_CLAUDE=2 CHUMP_ADMISSION_TEST_CLAUDE_COUNT=0 \
    "$CHUMP" admit claude --owner-pid "$$" >/dev/null 2>&1
"$CHUMP" admit status --json >"$TMP/status.json" 2>/dev/null
grep -q '"leased":1' "$TMP/status.json" || fail "admit status --json should report leased:1, got: $(cat "$TMP/status.json")"
grep -q "\"pid\":$$" "$TMP/status.json" || fail "admit status --json should list owner pid $$, got: $(cat "$TMP/status.json")"
ok "RESILIENT-1679: active lease visible in chump admit status --json"

"$CHUMP" admit release claude --owner-pid "$$" >/dev/null 2>&1
"$CHUMP" admit status --json >"$TMP/status-after.json" 2>/dev/null
grep -q '"leased":0' "$TMP/status-after.json" || fail "admit release should clear lease, got: $(cat "$TMP/status-after.json")"
ok "RESILIENT-1679: chump admit release clears lease"

# Spawn 5 concurrent callers holding a slot for 400ms against ceiling C=2.
PIDS=()
for idx in 1 2 3 4 5; do
    CHUMP_MAX_CONCURRENT_CLAUDE=2 CHUMP_ADMISSION_TEST_CLAUDE_COUNT=0 \
        "$CHUMP" admit claude --wait-s 3 --hold-ms 400 >/dev/null 2>&1 &
    PIDS+=("$!")
done
sleep 0.15
"$CHUMP" admit status --json >"$TMP/status-concurrent.json" 2>/dev/null
grep -q '"leased":2' "$TMP/status-concurrent.json" \
    || fail "5 concurrent callers against C=2 must cap active leases at 2, got: $(cat "$TMP/status-concurrent.json")"
for p in "${PIDS[@]}"; do
    wait "$p" || fail "concurrent caller $p failed to acquire slot within --wait-s 3"
done
ok "RESILIENT-1679: 5 concurrent callers against C=2 capped at 2 active leases and all 5 completed"

# ---------------------------------------------------------------------------
# 7. RESILIENT-1640: cargo admission ceiling wired into bot-merge.sh, pre-push,
#    and src/dispatch.rs ship phase; CHUMP_ADMISSION_TEST_CARGO_COUNT proves
#    bot-merge's cargo gate waits at a full ceiling and proceeds when freed.
# ---------------------------------------------------------------------------
grep -q 'chump_admission_wait_cargo' "$REPO_ROOT/scripts/coord/bot-merge.sh" \
    || fail "RESILIENT-1640: scripts/coord/bot-merge.sh must call chump_admission_wait_cargo"
grep -q 'chump_admission_wait_cargo' "$REPO_ROOT/scripts/git-hooks/pre-push" \
    || fail "RESILIENT-1640: scripts/git-hooks/pre-push must call chump_admission_wait_cargo"
grep -q 'gate_cargo_before_ship' "$REPO_ROOT/src/dispatch.rs" \
    || fail "RESILIENT-1640: src/dispatch.rs ship() must call gate_cargo_before_ship"
ok "RESILIENT-1640: bot-merge.sh, pre-push, and src/dispatch.rs all wire cargo admission"

: > "$AMB"
# Full cargo ceiling via CHUMP_ADMISSION_TEST_CARGO_COUNT=2 >= C=1:
# chump_admission_wait_cargo waits bounded by CHUMP_ADMISSION_WAIT_TIMEOUT_S=1,
# emits kind=admission_deferred for resource=cargo, and logs its decision.
CARGO_WAIT_LOG="$TMP/cargo-wait.log"
(
    source "$REPO_ROOT/scripts/coord/lib/admission-gate.sh"
    CHUMP_BIN="$CHUMP" \
    CHUMP_MAX_CONCURRENT_CARGO_JOBS=1 \
    CHUMP_ADMISSION_TEST_CARGO_COUNT=2 \
    CHUMP_ADMISSION_WAIT_TIMEOUT_S=1 \
    CHUMP_ADMISSION_POLL_INTERVAL_S=1 \
        chump_admission_wait_cargo
) >"$CARGO_WAIT_LOG" 2>&1
grep -q '"kind":"admission_deferred"' "$AMB" \
    && grep -q '"resource":"cargo"' "$AMB" \
    || fail "RESILIENT-1640: full cargo ceiling must emit admission_deferred for cargo: $(cat "$AMB")"
grep -q '\[admission-gate\] cargo:' "$CARGO_WAIT_LOG" \
    || fail "RESILIENT-1640: admission-gate must log cargo decision: $(cat "$CARGO_WAIT_LOG")"
ok "RESILIENT-1640: CHUMP_ADMISSION_TEST_CARGO_COUNT blocks at full cargo ceiling and logs decision"

# Now hold 1 cargo slot for ~1s while a second caller (bot-merge helper) waits
# with CHUMP_ADMISSION_TEST_CARGO_COUNT=0 and C=1; verify it waits and then
# proceeds with "admitted" once the slot frees.
CHUMP_MAX_CONCURRENT_CARGO_JOBS=1 CHUMP_ADMISSION_TEST_CARGO_COUNT=0 \
    "$CHUMP" admit cargo --wait-s 2 --hold-ms 1200 >/dev/null 2>&1 &
HOLD_PID=$!
sleep 0.2
CARGO_FREE_LOG="$TMP/cargo-free.log"
(
    source "$REPO_ROOT/scripts/coord/lib/admission-gate.sh"
    CHUMP_BIN="$CHUMP" \
    CHUMP_MAX_CONCURRENT_CARGO_JOBS=1 \
    CHUMP_ADMISSION_TEST_CARGO_COUNT=0 \
    CHUMP_ADMISSION_WAIT_TIMEOUT_S=4 \
    CHUMP_ADMISSION_POLL_INTERVAL_S=1 \
        chump_admission_wait_cargo
) >"$CARGO_FREE_LOG" 2>&1
wait "$HOLD_PID" 2>/dev/null || true
grep -q '\[admission-gate\] cargo: admitted' "$CARGO_FREE_LOG" \
    || fail "RESILIENT-1640: cargo helper should proceed with admitted once slot frees: $(cat "$CARGO_FREE_LOG")"
ok "RESILIENT-1640: bot-merge cargo admission helper waits at full ceiling and proceeds when freed"

echo
ok "all admission-ceiling checks passed"

