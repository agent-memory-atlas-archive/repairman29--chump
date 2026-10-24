#!/usr/bin/env bash
# INFRA-2043 — assert inbox-check-urgent.sh is wired as a PreToolUse hook (not PostToolUse).
#
# Why: PostToolUse stdout is suppressed by Claude Code, so a hook on that channel
# fires but never surfaces its <system-reminder> XML to the mid-session agent.
# Only PreToolUse stdout is injected as context for the next tool call. This test
# guards against a regression where inbox-check-urgent.sh accidentally returns to
# the PostToolUse bucket — a class of silent-A2A-failure that took multiple sessions
# to diagnose.
#
# See: docs/process/CLAUDE_GOTCHAS.md "Claude Code hook output channels".

set -euo pipefail

REPO_ROOT="${CHUMP_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
SETTINGS="$REPO_ROOT/.claude/settings.json"

if [[ ! -f "$SETTINGS" ]]; then
  echo "[FAIL] .claude/settings.json not found at $SETTINGS" >&2
  exit 1
fi

pass=0
fail=0

assert() {
  local name="$1"
  local cond="$2"
  if [[ "$cond" == "true" ]]; then
    echo "[PASS] $name"
    pass=$((pass + 1))
  else
    echo "[FAIL] $name" >&2
    fail=$((fail + 1))
  fi
}

# Helpers — jq one-liners returning literal "true"/"false".
in_pretool=$(jq -r '
  [.hooks.PreToolUse // []
   | .[]?.hooks // []
   | .[]?.command // ""]
  | map(select(test("inbox-check-urgent\\.sh")))
  | length > 0' "$SETTINGS")

in_posttool=$(jq -r '
  [.hooks.PostToolUse // []
   | .[]?.hooks // []
   | .[]?.command // ""]
  | map(select(test("inbox-check-urgent\\.sh")))
  | length > 0' "$SETTINGS")

poll_in_posttool=$(jq -r '
  [.hooks.PostToolUse // []
   | .[]?.hooks // []
   | .[]?.command // ""]
  | map(select(test("inbox-poll\\.sh")))
  | length > 0' "$SETTINGS")

assert "inbox-check-urgent.sh is registered under PreToolUse" "$in_pretool"
assert "inbox-check-urgent.sh is NOT under PostToolUse (would be silent)" "$([ "$in_posttool" = "false" ] && echo true || echo false)"
assert "inbox-poll.sh remains under PostToolUse (digest append, session-keyed)" "$poll_in_posttool"

# Also assert the script itself exists and is executable.
URGENT_SCRIPT="$REPO_ROOT/scripts/coord/inbox-check-urgent.sh"
if [[ -x "$URGENT_SCRIPT" ]]; then
  assert "scripts/coord/inbox-check-urgent.sh exists and is executable" "true"
else
  assert "scripts/coord/inbox-check-urgent.sh exists and is executable" "false"
fi

# CREDIBLE-1581 AC1 + AC3:
# (a) inbox-check-urgent.sh must not print ship commands (bot-merge / --auto-merge)
if grep -qE 'bot-merge|--auto-merge|drive them to merge' "$URGENT_SCRIPT"; then
  assert "CREDIBLE-1581 AC3: inbox-check-urgent.sh contains no bot-merge / --auto-merge ship command" "false"
else
  assert "CREDIBLE-1581 AC3: inbox-check-urgent.sh contains no bot-merge / --auto-merge ship command" "true"
fi

# Run inbox-check-urgent.sh against a synthetic fix_trunk_priority_signal and assert no ship command in output
_tmp_inbox="$(mktemp -d)"
printf '%s\n' '{"ts":"2026-10-24T00:00:00Z","kind":"fix_trunk_priority_signal","gap_id":"INFRA-9999","priority":"P0","worktree":"/tmp/wt"}' > "$_tmp_inbox/urgent.jsonl"
_out="$(CHUMP_URGENT_INBOX="$_tmp_inbox/urgent.jsonl" CHUMP_URGENT_INBOX_CURSOR="$_tmp_inbox/cursor" CHUMP_AMBIENT_LOG="$_tmp_inbox/ambient.jsonl" bash "$URGENT_SCRIPT" 2>/dev/null || true)"
rm -rf "$_tmp_inbox"
if printf '%s' "$_out" | grep -q "FIX-TRUNK PRIORITY SIGNAL" && ! printf '%s' "$_out" | grep -qE "bot-merge|--auto-merge"; then
  assert "CREDIBLE-1581 AC3: fix_trunk_priority_signal output has no ship command" "true"
else
  assert "CREDIBLE-1581 AC3: fix_trunk_priority_signal output has no ship command" "false"
fi

# (b) headless claude spawn sites (src/dispatch.rs::headless_command_skeleton, architect-tick.sh, review-ro-claude.sh) pass disableAllHooks
_skel_body="$(awk '/^fn headless_command_skeleton\(/,/^\}/' "$REPO_ROOT/src/dispatch.rs" | grep -vE '^[[:space:]]*//')"
if printf '%s\n' "$_skel_body" | grep -q 'disableAllHooks'; then
  assert "CREDIBLE-1581 AC1: dispatch.rs::headless_command_skeleton disables hooks via --settings disableAllHooks" "true"
else
  assert "CREDIBLE-1581 AC1: dispatch.rs::headless_command_skeleton disables hooks via --settings disableAllHooks" "false"
fi
for _site in "$REPO_ROOT/scripts/dispatch/architect-tick.sh" "$REPO_ROOT/scripts/dispatch/review-ro-claude.sh"; do
  if grep -vE '^[[:space:]]*#' "$_site" | grep -q "disableAllHooks"; then
    assert "CREDIBLE-1581 AC1: $(basename "$_site") disables hooks via --settings disableAllHooks" "true"
  else
    assert "CREDIBLE-1581 AC1: $(basename "$_site") disables hooks via --settings disableAllHooks" "false"
  fi
done

echo ""
echo "Passed: $pass  Failed: $fail"

if (( fail > 0 )); then
  exit 1
fi
