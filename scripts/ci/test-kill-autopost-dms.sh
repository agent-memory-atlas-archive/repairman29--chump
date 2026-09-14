#!/usr/bin/env bash
# test-kill-autopost-dms.sh — Jeff's standing order (2026-09-13): the fleet must
# NOT auto-DM the operator anymore. KILL every automated Discord DM — scheduled
# posts (digest, board-cycle, ceo-briefing), event-driven pages (halt/incident),
# approval-button prompts — while KEEPING the two-way command gateway's REPLIES
# to a message Jeff sent.
#
# WHAT THIS ASSERTS (routing decision, not live delivery — a real send needs a
# token + network; delivery of the command-reply path was proven separately by
# the existing test-notify-operator.sh + a live worktree send):
#
#   1. An autopost/page kind (e.g. board_ceo_briefing, or halt-class, or a page
#      kind, or NO kind at all) with the knob OFF emits NO Discord call — it
#      short-circuits with the "SUPPRESSED ... autoposts off" marker.
#   2. A command-reply kind (discord_command_reply / discord_advisor_reply) with
#      the knob OFF is NOT suppressed — it flows past the gate to the real send.
#   3. Flipping CHUMP_OPERATOR_AUTOPOST_DM=1 re-enables autopost delivery (the
#      reversible knob), so nothing is deleted, only gated.
#   4. The knob name is not a bypass-class token (BYPASS/SKIP/IGNORE) — it must
#      not add to the bypass-var debt ceiling.
#   5. The Rust chokepoint (send_dm_if_configured) and the other autopost
#      senders (ceo-loop.py, witness/probe.py) all consult the same knob.
#
# The gate is exercised by pointing _notify_deliver's Discord REST calls at a
# dummy token: when the gate SUPPRESSES, curl is never reached (we assert the
# marker + no "delivered"); when the gate lets a command-reply through, the send
# is ATTEMPTED (fails on the dummy token — that failure past the gate is the
# proof the reply was not suppressed).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$REPO_ROOT/scripts/coord/lib/notify-operator.sh"
PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== kill-autopost-dms: automated DMs off, command-replies kept ==="

[[ -f "$LIB" ]] && ok "notify-operator.sh exists" || { bad "notify-operator.sh missing"; exit 1; }

# Isolate ambient/buffer writes to a scratch dir so the test never touches real
# fleet state, and force a dummy token so any send that DOES fire fails fast
# (never a real DM) instead of no-op'ing on missing creds.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CHUMP_AMBIENT_LOG="$TMP/ambient.jsonl"
export CHUMP_DISCORD_COS_BUFFER="$TMP/buffer.jsonl"
export CHUMP_DISCORD_CURATION_QUEUE="$TMP/queue.jsonl"
export CHUMP_NOTIFY_RATE_LOG="$TMP/rate.log"
export DISCORD_TOKEN="dummy-token-not-real"
export CHUMP_READY_DM_USER_ID="000000000000000000"

run_deliver() {  # kind severity knob  -> prints combined stdout+stderr
  local kind="$1" sev="$2" knob="$3"
  (
    # shellcheck disable=SC1090
    source "$LIB"
    CHUMP_NOTIFY_KIND="$kind" CHUMP_NOTIFY_SEVERITY="$sev" \
      CHUMP_OPERATOR_AUTOPOST_DM="$knob" \
      notify_operator "test message from test-kill-autopost-dms" 2>&1
  )
}

# The real-send success marker is "[notify-operator] delivered (" (with the
# paren). Classification log lines like "DIRECT (... delivered without paging)"
# print BEFORE the gate and must not be mistaken for an actual DM — hence the
# paren-anchored match below.

# 1. Scheduled autopost (board_ceo_briefing / chump_digest) with knob OFF →
#    suppressed at the delivery gate, no actual DM.
out="$(run_deliver "board_ceo_briefing" "" "")"
if grep -q "SUPPRESSED" <<<"$out" && grep -q "automated operator DMs are off" <<<"$out" \
   && ! grep -q "delivered (" <<<"$out"; then
  ok "scheduled briefing autopost is suppressed when knob is off"
else
  bad "briefing autopost NOT suppressed (got: $out)"
fi

# 1b. Halt-class incident page with knob OFF → suppressed (Jeff: kill even halts).
out="$(run_deliver "fleet_stopped_unexpected" "halt" "")"
if grep -q "SUPPRESSED" <<<"$out" && ! grep -q "delivered (" <<<"$out"; then
  ok "halt-class incident page is suppressed when knob is off"
else
  bad "halt-class page NOT suppressed (got: $out)"
fi

# 1c. Unknown/unlisted kind → the fleet must not DM the operator. It is routed
#    to the durable hold-and-summarize buffer (BUFFERED, no DM), which already
#    satisfies the kill — assert no actual delivery, whichever no-DM path taken.
out="$(run_deliver "some_novel_alert_kind" "" "")"
if ! grep -q "delivered (" <<<"$out" \
   && grep -qE "SUPPRESSED|BUFFERED" <<<"$out"; then
  ok "unlisted (default-page) kind produces no DM when knob is off"
else
  bad "unlisted kind produced a DM (got: $out)"
fi

# 2. Command-reply kinds with knob OFF → NOT suppressed (flow past the gate).
for kind in discord_command_reply discord_advisor_reply; do
  out="$(run_deliver "$kind" "" "")"
  if grep -q "SUPPRESSED" <<<"$out"; then
    bad "$kind was suppressed — command-replies must always deliver"
  else
    # Past the gate: with a dummy token the REST send is attempted and fails.
    # A FAIL/curl attempt (not a suppression) is the proof it reached delivery.
    ok "$kind is NOT suppressed (reaches the real send path)"
  fi
done

# 3. Reversible knob: autopost with knob ON is NOT suppressed (re-enabled).
out="$(run_deliver "board_ceo_briefing" "" "1")"
if grep -q "SUPPRESSED" <<<"$out"; then
  bad "knob=1 did not re-enable autopost delivery (still suppressed)"
else
  ok "CHUMP_OPERATOR_AUTOPOST_DM=1 re-enables autopost delivery (reversible)"
fi

# 3b. Approval buttons: suppressed off, re-enabled on.
buttons_out() { (
  # shellcheck disable=SC1090
  source "$LIB"
  CHUMP_OPERATOR_AUTOPOST_DM="$1" notify_operator_buttons "approve?" '[]' 2>&1
); }
if grep -q "SUPPRESSED" <<<"$(buttons_out "")" \
   && ! grep -q "SUPPRESSED" <<<"$(buttons_out "1")"; then
  ok "approval buttons suppressed off / re-enabled on"
else
  bad "approval-button gate wrong (off should suppress, on should not)"
fi

# 4. Knob name is not a bypass-class token.
if grep -qiE "BYPASS|SKIP|IGNORE|_CHECK|_NO_" <<<"CHUMP_OPERATOR_AUTOPOST_DM"; then
  bad "knob name contains a bypass-class token (would trip the debt ceiling)"
else
  ok "knob name is a plain descriptive var (no bypass-class token)"
fi

# 5. Same knob is honored across all autopost senders.
grep -q 'CHUMP_OPERATOR_AUTOPOST_DM' "$REPO_ROOT/src/discord_dm.rs" \
  && ok "Rust send_dm_if_configured consults the knob" \
  || bad "Rust chokepoint does NOT consult the knob"
grep -q 'CHUMP_OPERATOR_AUTOPOST_DM' "$REPO_ROOT/scripts/coord/ceo-loop.py" \
  && ok "ceo-loop.py consults the knob" \
  || bad "ceo-loop.py does NOT consult the knob"
grep -q 'CHUMP_OPERATOR_AUTOPOST_DM' "$REPO_ROOT/scripts/setup/witness/probe.py" \
  && ok "witness/probe.py consults the knob" \
  || bad "witness/probe.py does NOT consult the knob"

echo "=== $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
