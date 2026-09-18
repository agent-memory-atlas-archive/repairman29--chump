#!/usr/bin/env bash
# INFRA-7301 (INFRA-6802 / INFRA-3631 slice): install-gap-substrate.sh DB +
# role provisioning is idempotent — second run leaves the database, roles,
# and passwords unchanged and exits 0.
#
# Sources only the DB+ROLES phase (everything above the "# ---------- run
# ----------" marker) so the test doesn't pay for the SCHEMA/POSTGREST/
# SERVICE phases (cargo build + binary download) that AC1-4 don't cover.
# Requires a reachable local Postgres with passwordless psql access for the
# invoking user or a `postgres` OS role (same assumption install-gap-substrate.sh
# itself makes) — skips cleanly if neither is available.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/setup/install-gap-substrate.sh"

if ! command -v psql >/dev/null 2>&1 || ! pg_isready -h localhost -p 5432 >/dev/null 2>&1; then
  echo "SKIP: no reachable local Postgres — cannot exercise DB+ROLES phase"
  exit 0
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/chump-substrate-idempotent.XXXXXX")"
DB_NAME="chump_fleet_test_infra7301_$$"
cleanup() {
  sudo -n -u postgres psql -tAc "DROP DATABASE IF EXISTS $DB_NAME" >/dev/null 2>&1 \
    || psql -tAc "DROP DATABASE IF EXISTS $DB_NAME" -h localhost -p 5432 -U "$(whoami)" >/dev/null 2>&1
  rm -rf "$TMP"
}
trap cleanup EXIT

failures=0
pass() { printf '  ok   %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*"; failures=$((failures + 1)); }

export CHUMP_STATE_DIR="$TMP/state"
export CHUMP_SUBSTRATE_DB_NAME="$DB_NAME"
mkdir -p "$CHUMP_STATE_DIR"

# Load only the function definitions (DB+ROLES phase and its deps) — strip
# the unconditional "run everything" tail the full script executes when
# invoked directly.
LIB="$TMP/lib.sh"
sed -n '1,/^# ---------- run ----------/p' "$SCRIPT" | sed '$d' > "$LIB"
set --
# shellcheck disable=SC1090
. "$LIB"

DRY=0
ensure_postgres
ensure_db_and_roles
CREDS="$CHUMP_STATE_DIR/providers.env"

# AC2: database created.
db_exists="$(psql_admin -c "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'")"
if [[ -n "$db_exists" ]]; then
  pass "database $DB_NAME created"
else
  fail "database $DB_NAME was not created"
fi

# AC3: roles created, password sourced from providers.env, never hard-coded.
role_check="$(psql_admin -d "$DB_NAME" -c "SELECT 1 FROM pg_roles WHERE rolname='$PG_AUTHENTICATOR'")"
[[ -n "$role_check" ]] && pass "role $PG_AUTHENTICATOR exists" || fail "role $PG_AUTHENTICATOR missing"
role_check="$(psql_admin -d "$DB_NAME" -c "SELECT 1 FROM pg_roles WHERE rolname='$PG_ANON'")"
[[ -n "$role_check" ]] && pass "role $PG_ANON exists" || fail "role $PG_ANON missing"

if grep -q '^CHUMP_SUBSTRATE_DB_PASSWORD=' "$CREDS" 2>/dev/null; then
  pass "password persisted to $CREDS (not hard-coded in script)"
else
  fail "password was not persisted to $CREDS"
fi
if grep -E "PASSWORD '\\\$" "$SCRIPT" >/dev/null; then
  pass "SQL PASSWORD clauses interpolate a shell variable, not a literal"
else
  fail "SQL PASSWORD clause does not reference a shell variable"
fi

FIRST_PW="$SUBSTRATE_PW"

# AC4: re-run leaves DB, roles, and password unchanged, exits 0.
ensure_db_and_roles
rc=$?
SECOND_PW="$SUBSTRATE_PW"

[[ "$rc" -eq 0 ]] && pass "second ensure_db_and_roles call exits 0" || fail "second ensure_db_and_roles call exited $rc"
[[ "$SECOND_PW" == "$FIRST_PW" ]] && pass "password unchanged across re-runs" || fail "password changed across re-runs ($FIRST_PW != $SECOND_PW)"

db_exists_after="$(psql_admin -c "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'")"
[[ -n "$db_exists_after" ]] && pass "database still present after re-run" || fail "database disappeared after re-run"
role_check="$(psql_admin -d "$DB_NAME" -c "SELECT 1 FROM pg_roles WHERE rolname='$PG_AUTHENTICATOR'")"
[[ -n "$role_check" ]] && pass "role $PG_AUTHENTICATOR still present after re-run" || fail "role $PG_AUTHENTICATOR disappeared after re-run"

if [[ "$failures" -eq 0 ]]; then
  echo "PASS: install-gap-substrate.sh DB+ROLES phase is idempotent"
  exit 0
fi
echo "FAIL: $failures assertion(s) failed" >&2
exit 1
