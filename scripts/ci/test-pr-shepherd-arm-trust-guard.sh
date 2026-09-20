#!/usr/bin/env bash
# test-pr-shepherd-arm-trust-guard.sh
#
# The BLOCKED_GREEN tier of pr-shepherd-daemon.sh arms `gh pr merge --auto`. This repo is public,
# main requires zero approvals, and merged main deploys to fleet nodes, so that tier must never
# act on a PR whose author is not on TRUST_AUTHORS.
#
# DEPTH: smoke + structural, against the REAL daemon file (not a harness copy of its loop; the
# harness copies in test-pr-shepherd-daemon.sh would stay green if the guard were deleted).
#   1. unit: the real _is_trusted_author, extracted from the daemon, on trusted / stranger /
#      empty / near-miss / injected-comma authors.
#   2. structural: inside the BLOCKED_GREEN branch, the trust check appears BEFORE the
#      `pr merge ... --auto` call, and its failure path `continue`s.
# GAPS: does not execute a real tick against a fixture PR list; does not cover the rebase tier
# (which pushes to the PR branch and is a separate question).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
D="$ROOT/scripts/coord/pr-shepherd-daemon.sh"
fail=0; ok() { echo "  PASS: $1"; }; bad() { echo "  FAIL: $1"; fail=1; }

fn="$(sed -n '/^_is_trusted_author() {/,/^}/p' "$D")"
[ -n "$fn" ] || { echo "  FAIL: _is_trusted_author not found in daemon"; exit 1; }
eval "$fn"
TRUST_AUTHORS="fleet-bot,dependabot[bot],claude-bot,repairman29"

_is_trusted_author "repairman29"        && ok "owner is trusted"                 || bad "owner should be trusted"
_is_trusted_author "dependabot[bot]"    && ok "dependabot is trusted"            || bad "dependabot should be trusted"
_is_trusted_author "some-stranger"      && bad "stranger must NOT be trusted"    || ok "stranger is refused"
_is_trusted_author ""                   && bad "empty author must fail closed"   || ok "empty author fails closed"
_is_trusted_author "repairman29-evil"   && bad "prefix look-alike must be refused" || ok "prefix look-alike refused"
_is_trusted_author "x,repairman29"      && bad "comma-injected login must be refused" || ok "comma-injected login refused"
_is_trusted_author "Repairman29"        && bad "case variant must be refused (GitHub logins are matched exactly here)" || ok "case variant refused"

branch="$(awk '/elif \[ "\$c" = "BLOCKED_GREEN" \]; then/{f=1} f{print} f&&/--auto --squash/{exit}' "$D")"
[ -n "$branch" ] || { bad "BLOCKED_GREEN branch with --auto --squash not found"; exit 1; }
guard_line=$(printf '%s\n' "$branch" | grep -n '_is_trusted_author "\$author"' | head -1 | cut -d: -f1)
merge_line=$(printf '%s\n' "$branch" | grep -n -- '--auto --squash' | head -1 | cut -d: -f1)
if [ -n "$guard_line" ] && [ -n "$merge_line" ] && [ "$guard_line" -lt "$merge_line" ]; then ok "trust check precedes the auto-merge call (line +$guard_line < +$merge_line)"; else bad "trust check missing or after the auto-merge call"; fi
printf '%s\n' "$branch" | sed -n "${guard_line:-1},$(( ${guard_line:-1} + 3 ))p" | grep -q 'continue' && ok "untrusted path continues (skips the PR)" || bad "untrusted path does not skip"
printf '%s\n' "$branch" | grep -q 'untrusted_author' && ok "skip is recorded in the event stream" || bad "skip is not recorded"

[ "$fail" -eq 0 ] && echo "[test-pr-shepherd-arm-trust-guard] PASS" || { echo "[test-pr-shepherd-arm-trust-guard] FAIL"; exit 1; }
