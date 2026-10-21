#!/usr/bin/env bash
# scripts/ci/test-chump-test-sandbox.sh — INFRA-2088
#
# Smoke test for scripts/coord/lib/test-sandbox.sh: verifies the canonical
# sandbox primitive actually isolates `chump` invocations from the real
# .chump/state.db (the INFRA-2080 class this primitive exists to kill).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../coord/lib/test-sandbox.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/coord/lib/test-sandbox.sh"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

REAL_STATE_DB="$REPO_ROOT/.chump/state.db"
SANDBOX_TITLE="sandbox-test-title-INFRA-2088-$$"

TMPROOT=$(mktemp -d)
SANDBOX="$TMPROOT/sandbox"
trap 'rm -rf "$TMPROOT"' EXIT

FIXTURE_DIR="$TMPROOT/fixture-gaps"
mkdir -p "$FIXTURE_DIR"
cat > "$FIXTURE_DIR/ZZTEST-001.yaml" <<'YAML'
- id: ZZTEST-001
  domain: ZZTEST
  title: "sandbox-smoke-fixture-gap"
  status: open
  priority: P3
  effort: xs
  acceptance_criteria:
    - "fixture gap used only by test-chump-test-sandbox.sh"
YAML

# ── (a) setup with fixture: state.db exists, env vars all set ─────────────
chump_test_sandbox_setup "$SANDBOX" --seed-yaml "$FIXTURE_DIR"

if [ -f "$SANDBOX/.chump/state.db" ]; then
    pass "(a) sandbox state.db created"
else
    fail "(a) sandbox state.db missing at $SANDBOX/.chump/state.db"
fi

if [ "$CHUMP_HOME" = "$SANDBOX" ] && [ "$CHUMP_REPO" = "$SANDBOX" ] && \
   [ "$CHUMP_REPO_ROOT" = "$SANDBOX" ] && \
   [ "$CHUMP_STATE_DB" = "$SANDBOX/.chump/state.db" ] && \
   [ "$CHUMP_LOCK_DIR" = "$SANDBOX/.chump-locks" ]; then
    pass "(a) all isolation env vars set correctly"
else
    fail "(a) isolation env vars not set as expected (CHUMP_HOME=$CHUMP_HOME CHUMP_REPO=$CHUMP_REPO CHUMP_REPO_ROOT=$CHUMP_REPO_ROOT CHUMP_STATE_DB=$CHUMP_STATE_DB CHUMP_LOCK_DIR=$CHUMP_LOCK_DIR)"
fi

# RESILIENT-1652: the lib must pin CHUMP_STATE_DIR to the sandbox's .chump so the
# farmer gate (which resolves the node state dir from CHUMP_STATE_DIR first) reads
# the sandbox node.env, never an inherited real one.
if [ "${CHUMP_STATE_DIR:-}" = "$SANDBOX/.chump" ]; then
    pass "(a) CHUMP_STATE_DIR pinned to sandbox .chump"
else
    fail "(a) CHUMP_STATE_DIR not pinned to sandbox (CHUMP_STATE_DIR=${CHUMP_STATE_DIR:-<unset>})"
fi

if chump gap list --json 2>/dev/null | grep -q "ZZTEST-001"; then
    pass "(a) fixture gap ZZTEST-001 present in sandbox state.db"
else
    fail "(a) fixture gap ZZTEST-001 NOT found in sandbox state.db"
fi

# ── (b) chump gap reserve lands in sandbox state.db, not real ─────────────
CHUMP_GAP_RESERVE_SKIP_PR=1 CHUMP_RESERVE_SCAN_OPEN_PRS=0 CHUMP_ALLOW_MAIN_WORKTREE=1 \
    chump gap reserve --domain ZZTEST --title "$SANDBOX_TITLE" \
    --no-outcome-required --force >/dev/null 2>&1

if chump gap list --json 2>/dev/null | grep -q "$SANDBOX_TITLE"; then
    pass "(b) reserved gap landed in sandbox state.db"
else
    fail "(b) reserved gap NOT found in sandbox state.db"
fi

if sqlite3 "$REAL_STATE_DB" "SELECT title FROM gaps;" 2>/dev/null | grep -q "$SANDBOX_TITLE"; then
    fail "(b) reserved gap LEAKED into real state.db at $REAL_STATE_DB"
else
    pass "(b) real state.db does not contain the sandbox-reserved gap"
fi

# ── (c) cleanup removes everything + unsets env vars ───────────────────────
chump_test_sandbox_cleanup "$SANDBOX"

if [ -d "$SANDBOX" ]; then
    fail "(c) sandbox dir still exists after cleanup"
else
    pass "(c) sandbox dir removed"
fi

if [ -z "${CHUMP_HOME:-}" ] && [ -z "${CHUMP_REPO:-}" ] && [ -z "${CHUMP_REPO_ROOT:-}" ] && \
   [ -z "${CHUMP_STATE_DB:-}" ] && [ -z "${CHUMP_LOCK_DIR:-}" ] && [ -z "${CHUMP_STATE_DIR:-}" ]; then
    pass "(c) isolation env vars unset after cleanup"
else
    fail "(c) isolation env vars still set after cleanup"
fi

# ── (d) real state.db untouched by the whole exercise ──────────────────────
if sqlite3 "$REAL_STATE_DB" "SELECT id FROM gaps;" 2>/dev/null | grep -q "^ZZTEST-"; then
    fail "(d) real state.db was polluted with a ZZTEST- gap"
else
    pass "(d) real state.db has no ZZTEST- gaps — sandbox never bled through"
fi

# ── (e) RESILIENT-1652: the lib pins CHUMP_STATE_DIR to the sandbox even when an
#        inherited CHUMP_STATE_DIR points at a real, paused node state dir, and
#        that inherited dir is left byte-identical. ───────────────────────────
source "$REPO_ROOT/scripts/ci/lib/sandbox-healthy-node.sh"

SENTINEL_DIR="$TMPROOT/paused-real-node"
mkdir -p "$SENTINEL_DIR"
printf 'CHUMP_NODE_MODE=paused\nCHUMP_NODE_WORK_ENABLED=0\n' >"$SENTINEL_DIR/node.env"
SENTINEL_BEFORE="$(cd "$SENTINEL_DIR" && find . -type f -exec sha256sum {} \; | sort)"

export CHUMP_STATE_DIR="$SENTINEL_DIR"   # the dangerous inherited env
SANDBOX2="$TMPROOT/sandbox2"
chump_test_sandbox_setup "$SANDBOX2"

if [ "${CHUMP_STATE_DIR:-}" = "$SANDBOX2/.chump" ]; then
    pass "(e) inherited CHUMP_STATE_DIR overridden to sandbox2 .chump"
else
    fail "(e) inherited CHUMP_STATE_DIR not overridden (CHUMP_STATE_DIR=${CHUMP_STATE_DIR:-<unset>})"
fi

# the fixture function writes the 3 healthy-node files, only inside the sandbox
write_sandbox_healthy_node "$SANDBOX2"
if [ -f "$SANDBOX2/.chump/oauth-token.json" ] && [ -f "$SANDBOX2/.chump/node.env" ] && \
   [ -f "$SANDBOX2/.chump/farmer-heartbeat" ]; then
    pass "(e) fixture wrote oauth-token.json + node.env + farmer-heartbeat in sandbox"
else
    fail "(e) fixture did not write the expected files in sandbox2/.chump"
fi
if grep -q '"token":"sk-' "$SANDBOX2/.chump/oauth-token.json" 2>/dev/null; then
    pass "(e) fixture oauth token carries the sk- content shape the gate checks"
else
    fail "(e) fixture oauth token missing the sk- content shape"
fi

SENTINEL_AFTER="$(cd "$SENTINEL_DIR" && find . -type f -exec sha256sum {} \; | sort)"
if [ "$SENTINEL_BEFORE" = "$SENTINEL_AFTER" ]; then
    pass "(e) inherited paused state dir byte-identical after setup + fixture"
else
    fail "(e) inherited paused state dir was MUTATED (setup/fixture leaked outside the sandbox)"
fi

# ── (f) the fixture refuses (exit 2) a dir that is not the lib's CHUMP_HOME, and
#        writes nothing when it refuses. ────────────────────────────────────────
OUTSIDE_DIR="$TMPROOT/not-the-sandbox"
mkdir -p "$OUTSIDE_DIR"
OUTSIDE_BEFORE="$(cd "$OUTSIDE_DIR" && find . | sort)"
# subshell: `exit 2` in the sourced function would otherwise kill this test
( write_sandbox_healthy_node "$OUTSIDE_DIR" ) >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 2 ]; then
    pass "(f) fixture refuses a dir != CHUMP_HOME with exit 2"
else
    fail "(f) fixture did not exit 2 on a dir != CHUMP_HOME (rc=$rc)"
fi
( write_sandbox_healthy_node ) >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 2 ]; then
    pass "(f) fixture refuses a missing argument with exit 2"
else
    fail "(f) fixture did not exit 2 on a missing argument (rc=$rc)"
fi
OUTSIDE_AFTER="$(cd "$OUTSIDE_DIR" && find . | sort)"
if [ "$OUTSIDE_BEFORE" = "$OUTSIDE_AFTER" ]; then
    pass "(f) fixture wrote nothing into the refused dir"
else
    fail "(f) fixture wrote into the refused dir despite exiting 2"
fi

chump_test_sandbox_cleanup "$SANDBOX2"

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
