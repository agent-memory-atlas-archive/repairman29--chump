#!/usr/bin/env bash
# test-discord-curation.sh — RESILIENT-1093: single-voice curation layer.
#
# The bug this guards: 18 independent notify_operator call sites each dial
# Discord the moment they have something page-worthy to say. When several
# organs fire in the same window (a real production shape — see the gap's
# evidence: pr-approval-surface-beat, board-cycle-escalate, discord-advisor
# etc. all post directly), the operator gets N separate DMs instead of one
# curated voice, diverging from docs/DISCORD_OPERATOR_CONSOLE.md's "one
# curated voice, never a firehose" surface.
#
# This test proves the fix directly: fire 3 page-worthy signals from 3
# different sources, assert NONE of them attempt an immediate Discord send
# (they should defer into the curation queue), then flush the queue and
# assert exactly ONE combined send is attempted.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# This suite exercises the curation MACHINERY (batch N page-worthy signals into
# ONE combined send). Since 2026-09-13 outbound automated DMs are gated OFF by
# default (Jeff's "kill everything automated" order — the default-off policy is
# asserted by test-kill-autopost-dms.sh). Enable delivery here so the batching
# behavior is actually under test rather than short-circuited by the kill-switch.
export CHUMP_OPERATOR_AUTOPOST_DM=1

PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== RESILIENT-1093: Discord single-voice curation layer ==="

LIB="$REPO_ROOT/scripts/coord/lib/notify-operator.sh"
FLUSH="$REPO_ROOT/scripts/coord/discord-curator-flush.sh"

[[ -f "$LIB" ]] && ok "notify-operator.sh exists" || { bad "notify-operator.sh missing"; echo "=== Results: $PASS passed, $FAIL failed ==="; exit 1; }
[[ -x "$FLUSH" ]] && ok "discord-curator-flush.sh exists and is executable" || bad "discord-curator-flush.sh missing or not executable"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

QUEUE="${TMPDIR}/queue.jsonl"
AMBIENT="${TMPDIR}/ambient.jsonl"

# 1. Three distinct page-worthy signals fired in one window (the exact shape
#    from the gap evidence) must NOT each attempt an immediate Discord send.
out="$(bash -c "
    unset DISCORD_TOKEN CHUMP_READY_DM_USER_ID
    export CHUMP_AMBIENT_LOG='$AMBIENT'
    export CHUMP_DISCORD_CURATION_QUEUE='$QUEUE'
    source '$LIB'
    CHUMP_NOTIFY_KIND='pr_stuck_alpha'   notify_operator 'PR #101 stuck 5h'
    CHUMP_NOTIFY_KIND='pr_stuck_beta'    notify_operator 'PR #202 stuck 3h'
    CHUMP_NOTIFY_KIND='board_cycle_alert' notify_operator 'board cycle failed twice'
" 2>&1)"

immediate_skips="$(grep -c '^\[notify-operator\] SKIP:' <<<"$out" || true)"
if [[ "$immediate_skips" == "0" ]]; then
    ok "3 page-worthy signals produced 0 immediate delivery attempts (deferred to queue)"
else
    bad "expected 0 immediate delivery attempts, got ${immediate_skips} (curation not wired up) -- output: $out"
fi

# 2. The signals must actually have landed in the curation queue.
if [[ -s "$QUEUE" ]]; then
    ok "curation queue is non-empty after 3 page-worthy signals"
else
    bad "curation queue is empty — signals were dropped, not deferred"
fi
lines="$(wc -l < "$QUEUE" 2>/dev/null | tr -d ' ')"
if [[ "$lines" == "3" ]]; then
    ok "curation queue holds exactly 3 entries (one per signal)"
else
    bad "expected 3 queued entries, got '${lines}'"
fi

# 3. operator_paged still fires per-signal (page-rate accounting must not
#    regress just because delivery is deferred).
paged_count="$(grep -c '"kind":"operator_paged"' "$AMBIENT" 2>/dev/null || true)"
if [[ "$paged_count" == "3" ]]; then
    ok "operator_paged still emitted once per signal (page-rate accounting intact)"
else
    bad "expected 3 operator_paged events, got '${paged_count}'"
fi

# 4. Flushing the queue must produce exactly ONE combined delivery attempt —
#    the single-voice invariant. Without this fix (each call sending
#    immediately) this step is moot because the queue would already be empty
#    and this assertion would fail differently (0 attempts here, 3 earlier).
flush_out="$(bash -c "
    unset DISCORD_TOKEN CHUMP_READY_DM_USER_ID
    export CHUMP_DISCORD_CURATION_QUEUE='$QUEUE'
    bash '$FLUSH'
" 2>&1)"
flush_skips="$(grep -c '^\[notify-operator\] SKIP:' <<<"$flush_out" || true)"
if [[ "$flush_skips" == "1" ]]; then
    ok "flush produced exactly 1 combined delivery attempt for 3 queued signals"
else
    bad "expected exactly 1 combined delivery attempt at flush, got ${flush_skips} -- output: $flush_out"
fi

# 5. The queue must be drained after a successful flush.
if [[ ! -s "$QUEUE" ]]; then
    ok "queue is drained after flush"
else
    bad "queue still has content after flush"
fi

# 6. Duplicate content across sources collapses into one line, not N repeats
#    (a common burst shape: the same underlying event notified by two organs).
QUEUE2="${TMPDIR}/queue2.jsonl"
bash -c "
    unset DISCORD_TOKEN CHUMP_READY_DM_USER_ID
    export CHUMP_AMBIENT_LOG='${TMPDIR}/ambient2.jsonl'
    export CHUMP_DISCORD_CURATION_QUEUE='$QUEUE2'
    source '$LIB'
    CHUMP_NOTIFY_KIND='pr_stuck_alpha' notify_operator 'PR #101 stuck 5h'
    CHUMP_NOTIFY_KIND='pr_stuck_alpha' notify_operator 'PR #101 stuck 5h'
" >/dev/null 2>&1
dup_flush_out="$(bash -c "
    unset DISCORD_TOKEN CHUMP_READY_DM_USER_ID
    export CHUMP_DISCORD_CURATION_QUEUE='$QUEUE2'
    bash '$FLUSH'
" 2>&1)"
dup_skips="$(grep -c '^\[notify-operator\] SKIP:' <<<"$dup_flush_out" || true)"
if [[ "$dup_skips" == "1" ]]; then
    ok "duplicate signal content across a burst still collapses to 1 combined send"
else
    bad "expected 1 combined send for duplicate-content burst, got ${dup_skips}"
fi

# 7. halt severity must bypass curation entirely (a true emergency cannot wait
#    for the next flush tick).
QUEUE3="${TMPDIR}/queue3.jsonl"
halt_out="$(bash -c "
    unset DISCORD_TOKEN CHUMP_READY_DM_USER_ID
    export CHUMP_AMBIENT_LOG='${TMPDIR}/ambient3.jsonl'
    export CHUMP_DISCORD_CURATION_QUEUE='$QUEUE3'
    source '$LIB'
    CHUMP_NOTIFY_SEVERITY='halt' notify_operator 'fleet is on fire'
" 2>&1)"
halt_skips="$(grep -c '^\[notify-operator\] SKIP:' <<<"$halt_out" || true)"
if [[ "$halt_skips" == "1" && ! -s "$QUEUE3" ]]; then
    ok "halt severity delivers immediately, bypassing curation"
else
    bad "halt severity did not bypass curation (skips=${halt_skips}, queue exists=$( [[ -s "$QUEUE3" ]] && echo yes || echo no ))"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] || exit 1
echo "PASS"
