#!/usr/bin/env bash
# INFRA-592: assert that 'chump gap reserve' emits phase lines on stderr only;
# stdout must contain only the bare gap ID (for --json piping compatibility).
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
export CHUMP_ALLOW_MAIN_WORKTREE=1 \
       CHUMP_GAP_RESERVE_SKIP_PR=1 \
       FLEET_029_AMBIENT_GLANCE_SKIP=1 \
       CHUMP_RESERVE_VERIFY=0 \
       CHUMP_SESSION_ID="progtest$$"

TMPOUT="$(mktemp)"
TMPERR="$(mktemp)"
cleanup() { rm -f "$TMPOUT" "$TMPERR"; }
trap cleanup EXIT

# ── default mode: progress lines must appear on stderr, not stdout ──────────
cargo run --quiet -- gap reserve --domain TEST --title "progress output test $$" --force \
    >"$TMPOUT" 2>"$TMPERR"

STDOUT="$(cat "$TMPOUT")"
STDERR="$(cat "$TMPERR")"

# stdout must be exactly the bare gap ID (e.g. "TEST-042"), nothing more
if ! echo "$STDOUT" | grep -qE '^[A-Z]+-[0-9]+$'; then
    echo "FAIL: stdout is not a bare gap ID: '$STDOUT'" >&2
    exit 1
fi

# stderr must contain the two expected phase tokens
if ! echo "$STDERR" | grep -q "reserving ID"; then
    echo "FAIL: stderr missing 'reserving ID' phase line" >&2
    echo "stderr was: $STDERR" >&2
    exit 1
fi

if ! echo "$STDERR" | grep -q "done ${STDOUT}"; then
    echo "FAIL: stderr missing 'done <ID>' completion token" >&2
    echo "stderr was: $STDERR" >&2
    exit 1
fi

# stdout must NOT contain phase lines
if echo "$STDOUT" | grep -q "reserving\|checking"; then
    echo "FAIL: progress text leaked onto stdout" >&2
    echo "stdout was: $STDOUT" >&2
    exit 1
fi

# ── --quiet mode: stderr must be silent (no phase lines) ────────────────────
TMPOUT2="$(mktemp)"
TMPERR2="$(mktemp)"
trap 'cleanup; rm -f "$TMPOUT2" "$TMPERR2"' EXIT

# CREDIBLE-1519: --force skips the RESILIENT-069 farmer gate so a farmer-RED
# host can't inject an extra stderr line / exit 1 and break these stdout/stderr
# assertions (progress phase lines are unaffected by --force).
cargo run --quiet -- gap reserve --domain TEST --title "progress quiet test $$" --quiet --force \
    >"$TMPOUT2" 2>"$TMPERR2"

STDOUT2="$(cat "$TMPOUT2")"
STDERR2="$(cat "$TMPERR2")"

if ! echo "$STDOUT2" | grep -qE '^[A-Z]+-[0-9]+$'; then
    echo "FAIL (--quiet): stdout is not a bare gap ID: '$STDOUT2'" >&2
    exit 1
fi

if echo "$STDERR2" | grep -q "reserving\|checking"; then
    echo "FAIL (--quiet): phase lines appeared on stderr despite --quiet" >&2
    echo "stderr was: $STDERR2" >&2
    exit 1
fi

echo "ok: progress phases on stderr only; --quiet suppresses them"
