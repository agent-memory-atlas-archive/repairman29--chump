#!/usr/bin/env bash
# INFRA-7297: zero-touch credential materialization from $CHUMP_BOOTSTRAP_CREDS
# (INFRA-3629 slice). Locks in the 3 acceptance criteria:
#   1. materialize_creds succeeds (no interactive prompt) when the env var is set
#   2. ~/.chump/providers.env is written with the supplied credential lines
#   3. the credential VALUES never appear in the script's own stdout/stderr

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLER="$ROOT/scripts/setup/chump-node-install.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/chump-bootstrap-creds.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

export CHUMP_NODE_DIR="$TMP/node"
export CHUMP_STATE_DIR="$TMP/state"
mkdir -p "$CHUMP_NODE_DIR/bin" "$CHUMP_STATE_DIR"

failures=0
pass() { printf '  ok   %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*"; failures=$((failures + 1)); }

SECRET_OAUTH="sk-test-secret-oauth-value-should-never-appear"
SECRET_GH="ghp-test-secret-gh-value-should-never-appear"
export CHUMP_BOOTSTRAP_CREDS="CLAUDE_CODE_OAUTH_TOKEN=$SECRET_OAUTH
GH_TOKEN=$SECRET_GH"

set --
# shellcheck disable=SC1090
. "$INSTALLER" >"$TMP/out.log" 2>"$TMP/err.log"

CREDS_PATH="$CHUMP_STATE_DIR/providers.env"

# AC1: materialize_creds completes without prompting/failing when the env var is set.
if materialize_creds; then
  pass "materialize_creds succeeds non-interactively with \$CHUMP_BOOTSTRAP_CREDS set"
else
  fail "materialize_creds failed with \$CHUMP_BOOTSTRAP_CREDS set"
fi

# AC2: providers.env is created containing the supplied credentials.
if [ -f "$CREDS_PATH" ] \
  && grep -qF "CLAUDE_CODE_OAUTH_TOKEN=$SECRET_OAUTH" "$CREDS_PATH" \
  && grep -qF "GH_TOKEN=$SECRET_GH" "$CREDS_PATH"; then
  pass "providers.env written with the supplied credential lines"
else
  fail "providers.env missing or does not contain supplied credentials"
fi

mode="$(stat -c %a "$CREDS_PATH" 2>/dev/null || stat -f %Lp "$CREDS_PATH" 2>/dev/null)"
if [ "$mode" = "600" ]; then
  pass "providers.env written with mode 600"
else
  fail "providers.env has mode $mode, expected 600"
fi

# AC3: the secret values never reach stdout, stderr, or any log file this run produced.
leaked=0
grep -rlF "$SECRET_OAUTH" "$TMP/out.log" "$TMP/err.log" 2>/dev/null && leaked=1
grep -rlF "$SECRET_GH" "$TMP/out.log" "$TMP/err.log" 2>/dev/null && leaked=1
if [ "$leaked" = 0 ]; then
  pass "credential values never appear in stdout/stderr"
else
  fail "credential values leaked into stdout/stderr"
fi

# Idempotency: an existing providers.env is left untouched on re-run.
before="$(cat "$CREDS_PATH")"
export CHUMP_BOOTSTRAP_CREDS="CLAUDE_CODE_OAUTH_TOKEN=different-token
GH_TOKEN=different-token"
materialize_creds
after="$(cat "$CREDS_PATH")"
if [ "$before" = "$after" ]; then
  pass "existing providers.env is left untouched (idempotent)"
else
  fail "materialize_creds clobbered an existing providers.env"
fi

if [ "$failures" -eq 0 ]; then
  echo "PASS: CHUMP_BOOTSTRAP_CREDS zero-touch materialization contract holds"
  exit 0
fi
echo "FAIL: $failures assertion(s) failed" >&2
exit 1
