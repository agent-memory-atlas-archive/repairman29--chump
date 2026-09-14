#!/usr/bin/env bash
# RESILIENT-263: guard the operator escalation channel.
#
# WHY THIS TEST IS SHAPED THIS WAY. The failure mode being guarded is not "the
# notifier is broken" — it is "the notifier silently does nothing and everyone
# assumes someone was told." Two real instances:
#
#   * The operator-recall handler (INFRA-665) has been configured-but-dead since
#     2026-05-08 — enabled=true in the toml, zero processes running.
#   * pr-failure-auto-rescue recorded an outcome literally named `operator_alert`
#     that wrote a log line and alerted nobody, and closed PR #3510 on a false
#     red while the operator learned of it hours later by asking.
#
# So this asserts WIRING and SAFETY, not delivery. Delivery is proven by an
# actual send during development (done: HTTP 200 from a worktree), because a
# green "the function was called" test is exactly how the dead handler passed
# for three months.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# This suite exercises the delivery/escalation MACHINERY (rate ceiling, halt
# bypass, buffering). Since 2026-09-13 that machinery is gated OFF by default
# (Jeff's "kill everything automated" order — see test-kill-autopost-dms.sh,
# which owns the default-off policy). Enable it here so the machinery is under
# test; the kill-switch policy is asserted by the dedicated test.
export CHUMP_OPERATOR_AUTOPOST_DM=1

echo "=== RESILIENT-263: operator escalation channel ==="

LIB="$REPO_ROOT/scripts/coord/lib/notify-operator.sh"
RESCUE="$REPO_ROOT/scripts/coord/pr-failure-auto-rescue.sh"

[[ -f "$LIB" ]] && ok "notify-operator.sh exists" || bad "notify-operator.sh missing"

# 1. The daemon must actually CALL it — the whole bug was a named-but-unwired alert.
if grep -q "notify_operator" "$RESCUE"; then
    ok "pr-failure-auto-rescue calls notify_operator"
else
    bad "pr-failure-auto-rescue does NOT call notify_operator (the INFRA-1600 bug)"
fi

# 2. The close path is where a line actually stops. It must notify.
if awk '/terminal_dispose.*closed_refiled/,/^}/' "$RESCUE" | grep -q "notify_operator"; then
    ok "the PR-close path notifies the operator"
else
    bad "the PR-close path does NOT notify — PR #3510 died here unannounced"
fi

# 3. `operator_alert` must alert an operator. It is named that.
if awk '/operator_alert/,/return 0/' "$RESCUE" | grep -q "notify_operator"; then
    ok "operator_alert outcome actually alerts the operator"
else
    bad "operator_alert still alerts nobody"
fi

# 4. NEVER print the token. Non-negotiable.
if grep -nE '(echo|printf|say)[^|]*\$\{?(token|TOKEN)' "$LIB" | grep -qv 'redacted'; then
    bad "notify-operator may print the token"
else
    ok "token is never echoed"
fi

# 5. A broken notifier must not take down the daemon it reports on.
if grep -q 'notify_operator() { echo "\[notify-operator\] MISSING' "$RESCUE"; then
    ok "missing helper degrades to a no-op (daemon still runs)"
else
    bad "no fallback — a missing helper could break PR automation"
fi

# 6. Worktree resolution. .env is gitignored and lives only in the main
#    checkout, while `chump claim` creates a worktree per gap. Without this the
#    alert is dead exactly when it is needed. Found by a real send, not review.
if grep -q "git-common-dir" "$LIB"; then
    ok "resolves .env from a worktree via git-common-dir"
else
    bad "no worktree fallback — alerts will silently skip from claim worktrees"
fi

# 7. Unconfigured must be a quiet no-op, not a crash, and must exit 0.
out="$(bash -c "unset DISCORD_TOKEN CHUMP_READY_DM_USER_ID; CHUMP_HOME=/nonexistent-$$; \
     cd /tmp && source '$LIB' 2>/dev/null && notify_operator 'x' 2>&1")"; rc=$?
if [[ $rc -eq 0 ]]; then
    ok "unconfigured is a no-op with exit 0 (rc=$rc)"
else
    bad "unconfigured returned rc=$rc — must never break the caller"
fi

# 8. Chunk, never truncate. The first cut of notify-operator.sh capped at 1900
#    chars and appended an ellipsis — which drops the tail, and on an escalation
#    the tail is the link and the ask. Assert the truncation pattern is gone and
#    that a long message splits into numbered parts.
if grep -qE 'content="\$\{content:0:1899\}' "$LIB"; then
    bad "notify-operator still TRUNCATES long messages (drops the link and the ask)"
else
    ok "no truncation of long messages"
fi
if grep -q "i}/{len(out)}" "$LIB"; then
    ok "long messages split into numbered parts"
else
    bad "no chunking — a >2000 char alert will be rejected or lose content"
fi

# 9. INFRA-3835: the escalation VERDICT + emit behavior. The advisor's answer
#    used to default to PAGE (unclassified kind), firing a spurious operator_paged
#    ambient event on top of the real reply DM — and a crash added a second page.
#    Assert the classification and the emit that follows from it, with an isolated
#    ambient log and Discord unconfigured (so notify_operator no-ops after
#    emitting; the emit happens before token resolution). This tests the actual
#    behavior, not merely that the registry file contains a line.
REG="$REPO_ROOT/scripts/coord/operator-escalation-registry.txt"

# Helper: run notify_operator for a kind against a throwaway ambient log; echo
# the emitted event kinds (one per line). Discord intentionally unconfigured.
_verdict_emits() {
    local kind="$1" log; log="$(mktemp)"
    bash -c "unset DISCORD_TOKEN CHUMP_READY_DM_USER_ID; \
        export CHUMP_AMBIENT_LOG='$log'; \
        source '$LIB' 2>/dev/null; \
        CHUMP_NOTIFY_KIND='$kind' notify_operator 'regression probe' >/dev/null 2>&1"
    grep -oE '"kind":"[a-zA-Z0-9_]+"' "$log" 2>/dev/null | sed 's/.*:"//;s/"//'
    rm -f "$log"
}

# 9a. Registry classifies the advisor reply as `direct` (deliver, don't page).
if grep -qE '^discord_advisor_reply[[:space:]]+direct\b' "$REG"; then
    ok "registry classifies discord_advisor_reply as direct"
else
    bad "discord_advisor_reply is not classified direct — advisor replies will page"
fi

# 9b. A direct-classified reply emits operator_direct_message and NEVER operator_paged.
emits="$(_verdict_emits discord_advisor_reply)"
if grep -q "operator_direct_message" <<<"$emits" && ! grep -q "operator_paged" <<<"$emits"; then
    ok "discord_advisor_reply emits operator_direct_message, not operator_paged"
else
    bad "discord_advisor_reply emitted [$emits] — expected operator_direct_message and no operator_paged"
fi

# 9c. A failed advisor turn is suppressed (quiet diagnostic), never a phone page.
if grep -qE '^discord_advisor_agent_failed[[:space:]]+suppress\b' "$REG"; then
    ok "registry classifies discord_advisor_agent_failed as suppress"
else
    bad "discord_advisor_agent_failed is not suppressed — a crashed turn will page"
fi
emits="$(_verdict_emits discord_advisor_agent_failed)"
if grep -q "operator_notify_suppressed" <<<"$emits" && ! grep -q "operator_paged" <<<"$emits"; then
    ok "discord_advisor_agent_failed emits operator_notify_suppressed, not operator_paged"
else
    bad "discord_advisor_agent_failed emitted [$emits] — expected operator_notify_suppressed only"
fi

# 9d. Regression: a genuinely page-worthy kind still emits operator_paged.
emits="$(_verdict_emits security_incident)"
if grep -q "operator_paged" <<<"$emits"; then
    ok "page-classified kind still emits operator_paged (escalation intact)"
else
    bad "security_incident emitted [$emits] — page path regressed, escalations lost"
fi

# 9f. RESILIENT-1092: the hourly board_ceo_briefing must not page the phone —
#     without a registry entry it falls through to the fail-loud PAGE default,
#     turning a scheduled strategy briefing into a 24x/day false-alarm page.
if grep -qE '^board_ceo_briefing[[:space:]]+direct\b' "$REG"; then
    ok "registry classifies board_ceo_briefing as direct"
else
    bad "board_ceo_briefing is not classified direct — hourly briefing will page the phone"
fi
emits="$(_verdict_emits board_ceo_briefing)"
if grep -q "operator_direct_message" <<<"$emits" && ! grep -q "operator_paged" <<<"$emits"; then
    ok "board_ceo_briefing emits operator_direct_message, not operator_paged"
else
    bad "board_ceo_briefing emitted [$emits] — expected operator_direct_message and no operator_paged"
fi

# 9e. The new operator_direct_message emit MUST NOT be counted by the page-rate
#     vital sign (that metric is the cry-wolf tripwire this whole fix protects).
VITAL="$REPO_ROOT/scripts/ops/vital-signs.sh"
if [[ -f "$VITAL" ]] && grep -q "operator_direct_message" "$VITAL"; then
    bad "vital-signs.sh counts operator_direct_message as a page — it must not"
else
    ok "operator_direct_message is not counted against the operator page-rate"
fi

# 10. RESILIENT-1095: global page-rate ceiling on the `direct` path. Direct
#     messages skip the RESILIENT-1093 curation queue by design ("deliver
#     every time"), which made them the one cross-source burst path with no
#     ceiling at all — three direct messages in one window is three separate
#     DMs. Fire 3 direct-verdict signals with a ceiling of 2: the first 2
#     must attempt immediate delivery, the 3rd must be held and coalesced
#     into the curation queue instead.
TMPDIR2="$(mktemp -d)"
trap 'rm -rf "$TMPDIR2"' RETURN 2>/dev/null || true

RATE_LOG="${TMPDIR2}/rate.log"
QUEUE="${TMPDIR2}/queue.jsonl"
AMBIENT="${TMPDIR2}/ambient.jsonl"

out="$(bash -c "
    unset DISCORD_TOKEN CHUMP_READY_DM_USER_ID
    export CHUMP_NOTIFY_RATE_CEILING=2
    export CHUMP_NOTIFY_RATE_WINDOW_S=300
    export CHUMP_NOTIFY_RATE_LOG='$RATE_LOG'
    export CHUMP_DISCORD_CURATION_QUEUE='$QUEUE'
    export CHUMP_AMBIENT_LOG='$AMBIENT'
    source '$LIB'
    CHUMP_NOTIFY_KIND='discord_advisor_reply' notify_operator 'reply one'
    CHUMP_NOTIFY_KIND='discord_advisor_reply' notify_operator 'reply two'
    CHUMP_NOTIFY_KIND='discord_advisor_reply' notify_operator 'reply three'
" 2>&1)"

immediate_attempts="$(grep -c '^\[notify-operator\] SKIP:' <<<"$out" || true)"
if [[ "$immediate_attempts" == "2" ]]; then
    ok "2 direct messages under the ceiling attempt immediate delivery"
else
    bad "expected 2 immediate delivery attempts under the ceiling, got ${immediate_attempts} -- output: $out"
fi

if grep -q 'DIRECT held' <<<"$out"; then
    ok "the 3rd direct message over the ceiling is held, not sent immediately"
else
    bad "the 3rd direct message was not held at the ceiling -- output: $out"
fi

if [[ -s "$QUEUE" ]] && [[ "$(wc -l < "$QUEUE" | tr -d ' ')" == "1" ]]; then
    ok "the held direct message landed in the curation queue (exactly 1 entry)"
else
    bad "expected exactly 1 entry in the curation queue after the ceiling was hit"
fi

held_count="$(grep -c '"kind":"operator_notify_rate_held"' "$AMBIENT" 2>/dev/null || true)"
if [[ "$held_count" == "1" ]]; then
    ok "operator_notify_rate_held emitted once for the held message"
else
    bad "expected 1 operator_notify_rate_held event, got '${held_count}'"
fi

# 10b. Halt severity must bypass the rate ceiling entirely, same as it
#      bypasses curation — an emergency can never be held for a later flush.
halt_out="$(bash -c "
    unset DISCORD_TOKEN CHUMP_READY_DM_USER_ID
    export CHUMP_NOTIFY_RATE_CEILING=2
    export CHUMP_NOTIFY_RATE_WINDOW_S=300
    export CHUMP_NOTIFY_RATE_LOG='$RATE_LOG'
    export CHUMP_DISCORD_CURATION_QUEUE='$QUEUE'
    export CHUMP_AMBIENT_LOG='$AMBIENT'
    source '$LIB'
    CHUMP_NOTIFY_SEVERITY='halt' notify_operator 'fleet is on fire'
" 2>&1)"
if grep -q '^\[notify-operator\] SKIP:' <<<"$halt_out"; then
    ok "halt severity still attempts immediate delivery even after the ceiling was hit"
else
    bad "halt severity did not attempt immediate delivery -- output: $halt_out"
fi

rm -rf "$TMPDIR2"

# 11. RESILIENT-1094: unclassified (no registry entry) non-halt signals must
#     BUFFER, not page. Before this change every new organ DMing without a
#     registry line paged the phone by default — this proves that's gone.
BUF="$(mktemp)"; rm -f "$BUF"
emits="$(bash -c "unset DISCORD_TOKEN CHUMP_READY_DM_USER_ID; \
    export CHUMP_AMBIENT_LOG='$(mktemp)'; export CHUMP_DISCORD_COS_BUFFER='$BUF'; \
    source '$LIB' 2>/dev/null; \
    CHUMP_NOTIFY_KIND='totally_novel_unregistered_kind_$$' notify_operator 'regression probe' >/dev/null 2>&1; \
    cat \"\$CHUMP_AMBIENT_LOG\"")"
if grep -q "operator_notify_buffered" <<<"$emits" && ! grep -q "operator_paged" <<<"$emits"; then
    ok "unclassified kind emits operator_notify_buffered, not operator_paged"
else
    bad "unclassified kind emitted [$emits] — expected operator_notify_buffered only (RESILIENT-1094 regression)"
fi
if [[ -f "$BUF" ]] && grep -q "totally_novel_unregistered_kind_$$" "$BUF" && grep -q "regression probe" "$BUF"; then
    ok "unclassified signal lands durably in the discord-cos buffer"
else
    bad "unclassified signal did NOT land in the buffer — RESILIENT-1094's never-silently-drop guarantee is broken"
fi
rm -f "$BUF"

# 12. A kind with NO CHUMP_NOTIFY_KIND at all (the original unclassified-caller
#     case) must also buffer, not page.
BUF="$(mktemp)"; rm -f "$BUF"
emits="$(bash -c "unset DISCORD_TOKEN CHUMP_READY_DM_USER_ID CHUMP_NOTIFY_KIND; \
    export CHUMP_AMBIENT_LOG='$(mktemp)'; export CHUMP_DISCORD_COS_BUFFER='$BUF'; \
    source '$LIB' 2>/dev/null; \
    notify_operator 'no kind at all' >/dev/null 2>&1; \
    cat \"\$CHUMP_AMBIENT_LOG\"")"
if grep -q "operator_notify_buffered" <<<"$emits" && ! grep -q "operator_paged" <<<"$emits"; then
    ok "no-kind caller buffers instead of paging"
else
    bad "no-kind caller emitted [$emits] — expected operator_notify_buffered only"
fi
rm -f "$BUF"

# 13. CHUMP_NOTIFY_SEVERITY=halt must still bypass the buffer and page,
#     regardless of registry state — the fail-loud escape hatch is preserved.
emits="$(bash -c "unset DISCORD_TOKEN CHUMP_READY_DM_USER_ID; \
    export CHUMP_AMBIENT_LOG='$(mktemp)'; \
    source '$LIB' 2>/dev/null; \
    CHUMP_NOTIFY_SEVERITY=halt CHUMP_NOTIFY_KIND='totally_novel_unregistered_kind_$$' notify_operator 'halt probe' >/dev/null 2>&1; \
    cat \"\$CHUMP_AMBIENT_LOG\"")"
if ! grep -q "operator_notify_buffered" <<<"$emits"; then
    ok "halt severity bypasses the buffer entirely (no operator_notify_buffered emitted)"
else
    bad "halt severity emitted [$emits] — halt must never be buffered, always fail loud"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] || exit 1
echo "PASS"
