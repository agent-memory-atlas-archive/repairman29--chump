#!/usr/bin/env bash
# test-nats-merge-lock-cas.sh — INFRA-7714 (INFRA-2252 slice)
#
# Validates the NATS KV CAS lock used to serialize the local merge queue:
#  1. chump-coord lib exposes try_acquire_merge_lock / release_merge_lock / merge_lock_holder
#  2. `chump-coord merge-lock` CLI subcommand exists (acquire|release|status)
#  3. Functional (skips if NATS unreachable, mirrors test-multi-machine-lease.sh):
#     two holders race for the lock — first wins, second is refused (AC1, AC3);
#     release clears the entry so the next holder can acquire it (AC2).
#  4. NATS-unreachable path returns a distinct, clear exit code (AC4): exit 3,
#     not the same exit 1 used for "lock held by someone else".

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
LIB_RS="$REPO_ROOT/crates/chump-coord/src/lib.rs"
MAIN_RS="$REPO_ROOT/crates/chump-coord/src/main.rs"

echo "=== INFRA-7714 NATS KV CAS merge-lock test ==="
echo

# 1. Library primitives exist.
if grep -q 'fn try_acquire_merge_lock(' "$LIB_RS" \
    && grep -q 'fn release_merge_lock(' "$LIB_RS" \
    && grep -q 'fn merge_lock_holder(' "$LIB_RS"; then
    ok "try_acquire_merge_lock / release_merge_lock / merge_lock_holder exist"
else
    fail "merge-lock primitives missing from chump-coord/src/lib.rs"
fi

# 2. CLI subcommand exists.
if grep -q '"merge-lock" =>' "$MAIN_RS"; then
    ok "chump-coord merge-lock subcommand exists"
else
    fail "chump-coord merge-lock subcommand missing"
fi

echo
echo "--- functional (skips if NATS unreachable) ---"

COORD_BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump-coord"
if [[ ! -x "$COORD_BIN" ]]; then
    COORD_BIN="$(command -v chump-coord || true)"
fi

if [[ -z "$COORD_BIN" || ! -x "$COORD_BIN" ]]; then
    echo "  SKIP: chump-coord binary not built (run: cargo build -p chump-coord)"
elif ! "$COORD_BIN" ping >/dev/null 2>&1; then
    echo "  SKIP: NATS unreachable — run: docker run -d -p 4222:4222 nats:latest -js"
else
    # Best-effort cleanup from a prior failed run.
    "$COORD_BIN" merge-lock release >/dev/null 2>&1 || true

    # AC1 + AC3: first holder wins, second holder is refused with exit 1.
    if "$COORD_BIN" merge-lock acquire "holder-A-$$" >/tmp/mlock-a-$$.log 2>&1; then
        ok "holder A acquires the merge lock"
    else
        fail "holder A failed to acquire an uncontended lock"
    fi

    set +e
    "$COORD_BIN" merge-lock acquire "holder-B-$$" >/tmp/mlock-b-$$.log 2>&1
    conflict_rc=$?
    set -e
    if [[ "$conflict_rc" -eq 1 ]]; then
        ok "holder B refused while holder A holds the lock (exit 1)"
    else
        fail "holder B acquire returned exit $conflict_rc, expected 1 (CAS conflict)"
    fi

    # AC2: release clears the entry so the next holder can acquire it.
    "$COORD_BIN" merge-lock release >/dev/null 2>&1
    if "$COORD_BIN" merge-lock acquire "holder-C-$$" >/tmp/mlock-c-$$.log 2>&1; then
        ok "post-release reacquire succeeds (holder C)"
    else
        fail "post-release reacquire failed"
    fi
    "$COORD_BIN" merge-lock release >/dev/null 2>&1 || true

    # AC4: NATS-unreachable path returns a distinct exit code (3), not the
    # same code used for a CAS conflict (1).
    set +e
    CHUMP_NATS_URL="nats://127.0.0.1:1" CHUMP_NATS_TIMEOUT_MS=200 \
        "$COORD_BIN" merge-lock acquire "holder-D-$$" >/tmp/mlock-d-$$.log 2>&1
    unreachable_rc=$?
    set -e
    if [[ "$unreachable_rc" -eq 3 ]]; then
        ok "NATS-unreachable acquire returns distinct exit code 3 (AC4)"
    else
        fail "NATS-unreachable acquire returned exit $unreachable_rc, expected 3"
    fi

    rm -f /tmp/mlock-a-$$.log /tmp/mlock-b-$$.log /tmp/mlock-c-$$.log /tmp/mlock-d-$$.log
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
