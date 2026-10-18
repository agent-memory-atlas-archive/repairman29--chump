#!/usr/bin/env bash
# INFRA-589: assert that --why flag prints one-line rationale to stderr for
# gap reserve, gap claim, and gap ship without polluting stdout.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
export CHUMP_ALLOW_MAIN_WORKTREE=1 \
       CHUMP_GAP_RESERVE_SKIP_PR=1 \
       FLEET_029_AMBIENT_GLANCE_SKIP=1 \
       CHUMP_RESERVE_VERIFY=0 \
       CHUMP_SESSION_ID="whytest$$"

TMPOUT="$(mktemp)"
TMPERR="$(mktemp)"
cleanup() { rm -f "$TMPOUT" "$TMPERR"; }
trap cleanup EXIT

# ── 1. gap reserve --why ─────────────────────────────────────────────────────
# CREDIBLE-1519: --force skips the RESILIENT-069 farmer gate so a farmer-RED
# host can't inject a stderr refusal / exit 1 and break the --why stderr
# assertion (the --why rationale is unaffected by --force).
cargo run --quiet -- gap reserve --domain TEST --title "why flag test $$" --why --force \
    >"$TMPOUT" 2>"$TMPERR"

STDOUT="$(cat "$TMPOUT")"
STDERR="$(cat "$TMPERR")"

if ! echo "$STDOUT" | grep -qE '^[A-Z]+-[0-9]+$'; then
    echo "FAIL (reserve): stdout is not a bare gap ID: '$STDOUT'" >&2
    exit 1
fi

if ! echo "$STDERR" | grep -q "reserved.*why:"; then
    echo "FAIL (reserve): stderr missing 'reserved ... why:' line" >&2
    echo "stderr was: $STDERR" >&2
    exit 1
fi

# why must NOT appear on stdout
if echo "$STDOUT" | grep -q "why:"; then
    echo "FAIL (reserve): why text leaked onto stdout" >&2
    exit 1
fi

GAP_ID="$STDOUT"
echo "ok: gap reserve --why emits rationale on stderr only (gap=$GAP_ID)"

# ── 2. gap claim --why ───────────────────────────────────────────────────────
>"$TMPOUT"; >"$TMPERR"
cargo run --quiet -- gap claim "$GAP_ID" --why \
    >"$TMPOUT" 2>"$TMPERR"

STDERR="$(cat "$TMPERR")"
STDOUT="$(cat "$TMPOUT")"

if ! echo "$STDERR" | grep -q "claimed.*why:"; then
    echo "FAIL (claim): stderr missing 'claimed ... why:' line" >&2
    echo "stderr was: $STDERR" >&2
    exit 1
fi

if echo "$STDOUT" | grep -q "why:"; then
    echo "FAIL (claim): why text leaked onto stdout" >&2
    exit 1
fi

echo "ok: gap claim --why emits rationale on stderr only"

# ── 3. gap ship --why ────────────────────────────────────────────────────────
>"$TMPOUT"; >"$TMPERR"
cargo run --quiet -- gap ship "$GAP_ID" --why \
    >"$TMPOUT" 2>"$TMPERR"

STDERR="$(cat "$TMPERR")"
STDOUT="$(cat "$TMPOUT")"

if ! echo "$STDERR" | grep -q "shipped.*why:"; then
    echo "FAIL (ship): stderr missing 'shipped ... why:' line" >&2
    echo "stderr was: $STDERR" >&2
    exit 1
fi

if echo "$STDOUT" | grep -q "why:"; then
    echo "FAIL (ship): why text leaked onto stdout" >&2
    exit 1
fi

echo "ok: gap ship --why emits rationale on stderr only"
echo "ok: all --why flag assertions passed"
