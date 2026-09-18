#!/usr/bin/env bash
# INFRA-7298 (INFRA-3629 slice): --creds-file materializes ~/.chump/providers.env
# with the exact key-value pairs from the supplied file, without ever echoing
# the file's path or contents to logs.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLER="$ROOT/scripts/setup/chump-node-install.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/chump-creds-file.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

export CHUMP_NODE_DIR="$TMP/node"
export CHUMP_STATE_DIR="$TMP/state"
mkdir -p "$CHUMP_NODE_DIR/bin" "$CHUMP_STATE_DIR"

set --
# shellcheck disable=SC1090
. "$INSTALLER"

failures=0
pass() { printf '  ok   %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*"; failures=$((failures + 1)); }

SECRET_VALUE="s3cr3t-token-do-not-log-me"
SRC_CREDS="$TMP/source-creds.env"
printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\nGH_TOKEN=other-secret\n' "$SECRET_VALUE" > "$SRC_CREDS"

CREDS_FILE="$SRC_CREDS"
DRY=0
log_output="$(materialize_creds 2>&1)"

# AC1: the file is read and $CREDS is materialized.
if [ -f "$CREDS" ]; then
  pass "--creds-file materialized $CREDS"
else
  fail "--creds-file did not materialize $CREDS"
fi

# AC3: exact key-value pairs from the supplied file.
if diff -q "$SRC_CREDS" "$CREDS" >/dev/null 2>&1; then
  pass "materialized providers.env matches supplied --creds-file exactly"
else
  fail "materialized providers.env diverges from supplied --creds-file"
fi

# AC2: neither the path nor the contents are echoed in logs.
if printf '%s' "$log_output" | grep -qF "$SRC_CREDS"; then
  fail "--creds-file path was echoed in logs"
else
  pass "--creds-file path is not echoed in logs"
fi
if printf '%s' "$log_output" | grep -qF "$SECRET_VALUE"; then
  fail "--creds-file secret value was echoed in logs"
else
  pass "--creds-file secret value is not echoed in logs"
fi

# Idempotent: a second call with an existing $CREDS must not clobber it or
# touch the (now stale) source file again.
printf 'CLAUDE_CODE_OAUTH_TOKEN=different\n' > "$SRC_CREDS"
materialize_creds >/dev/null 2>&1
if grep -qF "$SECRET_VALUE" "$CREDS"; then
  pass "existing providers.env left untouched on re-run (no clobber)"
else
  fail "materialize_creds clobbered an existing providers.env"
fi

if [ "$failures" -eq 0 ]; then
  echo "PASS: --creds-file materialization contract holds"
  exit 0
fi
echo "FAIL: $failures assertion(s) failed" >&2
exit 1
