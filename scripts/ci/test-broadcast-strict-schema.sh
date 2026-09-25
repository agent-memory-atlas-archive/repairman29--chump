#!/usr/bin/env bash
# scripts/ci/test-broadcast-strict-schema.sh — INFRA-1948 (slice E of INFRA-1862)
#
# Smoke test: broadcast.sh --strict schema validation. Verifies:
#   (a) STUCK <gap-id> with no reason succeeds (defaults reason=unspecified)
#       when --strict is NOT given (backward compat, INFRA-1862 AC #7)
#   (b) STUCK <gap-id> with no reason FAILS under --strict with a clear
#       "missing required field: reason" message (the exact bug that
#       motivated INFRA-1862 — positional-arg confusion silently defaulted)
#   (c) STUCK <gap-id> "<reason>" succeeds under --strict when reason given
#   (d) a malformed gap id (e.g. "not-a-gap-id") is rejected under --strict
#       but accepted without --strict
#   (e) ALERT kind=<kind> with no message fails under --strict

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
BROADCAST="$REPO_ROOT/scripts/coord/broadcast.sh"

[[ -x "$BROADCAST" ]] || { echo "[FAIL] broadcast.sh not executable at $BROADCAST" >&2; exit 1; }

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SANDBOX="$TMP/repo"
mkdir -p "$SANDBOX"
git -C "$TMP" init -q "$SANDBOX"
git -C "$SANDBOX" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

export CHUMP_SESSION_ID="test-strict-sender"
export CHUMP_NO_FANOUT=1

cd "$SANDBOX"

# (a) non-strict STUCK with no reason succeeds
if ! "$BROADCAST" STUCK INFRA-9001 >/dev/null 2>&1; then
    fail "non-strict STUCK with no reason should succeed (backward compat)"
fi
ok "non-strict STUCK with no reason succeeds (backward compat)"

# (a2) INFRA-5763 AC #2: non-strict STUCK with no reason prints a clear
# stderr warning about the silent default, instead of failing silently.
WARN_OUT="$("$BROADCAST" STUCK INFRA-9001 2>&1 >/dev/null)"
echo "$WARN_OUT" | grep -q "no reason" || fail "expected stderr warning about defaulted reason, got: $WARN_OUT"
ok "non-strict STUCK with no reason emits a clear stderr warning"

# (b) strict STUCK with no reason fails with a clear message
OUT="$("$BROADCAST" --strict STUCK INFRA-9001 2>&1 || true)"
if "$BROADCAST" --strict STUCK INFRA-9001 >/dev/null 2>/dev/null; then
    fail "strict STUCK with no reason should have failed"
fi
echo "$OUT" | grep -q "missing required field: reason" || fail "expected 'missing required field: reason' in: $OUT"
ok "strict STUCK with no reason fails with clear message"

# (c) strict STUCK with a reason succeeds
if ! "$BROADCAST" --strict STUCK INFRA-9001 "disk full" >/dev/null 2>&1; then
    fail "strict STUCK with a reason should succeed"
fi
ok "strict STUCK with a reason succeeds"

# (d) malformed gap id rejected under --strict, accepted without
if ! "$BROADCAST" STUCK not-a-gap-id "reason" >/dev/null 2>&1; then
    fail "non-strict malformed gap id should still succeed (backward compat)"
fi
if "$BROADCAST" --strict STUCK not-a-gap-id "reason" >/dev/null 2>/dev/null; then
    fail "strict malformed gap id should have failed"
fi
ok "strict rejects malformed gap id; non-strict still accepts it"

# (e) strict ALERT with no message fails
if "$BROADCAST" --strict ALERT kind=disk_full >/dev/null 2>/dev/null; then
    fail "strict ALERT with no message should have failed"
fi
ok "strict ALERT with no message fails"

echo "[test-broadcast-strict-schema] all checks passed"
