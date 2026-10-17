#!/usr/bin/env bash
# scripts/ci/test-infra-3632-canonical-store-env.sh — INFRA-3632
#
# chump-node-install.sh writes ~/.chump/node.env with the canonical store
# settings (CHUMP_STATE_DIR/CHUMP_STATE_DB/CHUMP_TEAM_URL/CHUMP_TEAM_API_KEY/
# CHUMP_STORE_BACKEND), installs an interactive-shell hook that sources it,
# and the shared organ-unit rewriter wires EnvironmentFile= into every
# generated systemd unit — so no shell or organ falls back to a repo-local
# .chump/state.db (the split-brain gap-store bug this gap closes).
#
# Network-free + deterministic: sources the installer with its top-level run
# guarded off (BASH_SOURCE != 0), and drives write_node_env()/
# install_shell_hook() against a synthetic $HOME/$NODE_DIR.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALLER="$REPO_ROOT/scripts/setup/chump-node-install.sh"
LIB_UNIT="$REPO_ROOT/scripts/ops/lib/organ-unit-install-lib.sh"
[ -f "$INSTALLER" ] || { echo "FAIL: installer not found: $INSTALLER"; exit 1; }
[ -f "$LIB_UNIT" ] || { echo "FAIL: organ-unit-install-lib not found: $LIB_UNIT"; exit 1; }

fails=0
pass(){ printf '  ok   %s\n' "$*"; }
fail(){ printf '  FAIL %s\n' "$*"; fails=$((fails+1)); }

echo "=== test-infra-3632-canonical-store-env.sh ==="

TMP="$(mktemp -d "${TMPDIR:-/tmp}/chump-3632-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ── 1. write_node_env() exports CHUMP_STATE_DB (not just CHUMP_STATE_DIR) ──
FAKE_HOME="$TMP/home"
mkdir -p "$FAKE_HOME"
export HOME="$FAKE_HOME"
export CHUMP_NODE_DIR="$TMP/node"
export CHUMP_STATE_DIR="$FAKE_HOME/.chump"
# Hermetic: a node shell that sourced a real node.env exports these.
unset CHUMP_STATE_DB CHUMP_NODE_REPO
mkdir -p "$CHUMP_NODE_DIR/repo" "$CHUMP_STATE_DIR"

set --
# shellcheck disable=SC1090
. "$INSTALLER"

write_node_env >/dev/null 2>&1

NODE_ENV_FILE="$CHUMP_STATE_DIR/node.env"
if [ -f "$NODE_ENV_FILE" ]; then
  pass "node.env written at $NODE_ENV_FILE"
else
  fail "node.env not written"
fi

grep -q '^export CHUMP_STATE_DB=' "$NODE_ENV_FILE" 2>/dev/null \
  && pass "node.env exports CHUMP_STATE_DB (the exact var GapStore::db_path() reads)" \
  || fail "node.env missing CHUMP_STATE_DB export — GapStore::db_path() falls back to repo-local .chump/state.db"

# INFRA-8190: the pinned store is the REPO-LOCAL one (what pin-less organs —
# chump-fleet-server, worker.sh — resolve), not $CHUMP_STATE_DIR/state.db.
grep -qx "export CHUMP_STATE_DB=$CHUMP_NODE_DIR/repo/.chump/state.db" "$NODE_ENV_FILE" 2>/dev/null \
  && pass "node.env pins CHUMP_STATE_DB to the repo-local canonical store (INFRA-8190)" \
  || fail "node.env CHUMP_STATE_DB is not the repo-local store: $(grep '^export CHUMP_STATE_DB=' "$NODE_ENV_FILE" 2>/dev/null)"

# INFRA-8190: a legacy home-store pin inherited from an old node.env is the
# split itself; a re-install must re-point it, not perpetuate it.
legacy_out="$(CHUMP_STATE_DB="$CHUMP_STATE_DIR/state.db" INSTALLER="$INSTALLER" bash -c 'set --; . "$INSTALLER" >/dev/null 2>&1; printf %s "$CHUMP_STATE_DB"' 2>/dev/null)"
[ "$legacy_out" = "$CHUMP_NODE_DIR/repo/.chump/state.db" ] \
  && pass "an inherited legacy \$CHUMP_STATE_DIR/state.db pin is re-pointed at the repo-local store" \
  || fail "legacy pin not replaced (got: $legacy_out)"

grep -q '^export CHUMP_STATE_DIR=' "$NODE_ENV_FILE" 2>/dev/null \
  && pass "node.env exports CHUMP_STATE_DIR" \
  || fail "node.env missing CHUMP_STATE_DIR export"

grep -q '^export CHUMP_TEAM_URL=' "$NODE_ENV_FILE" 2>/dev/null \
  && pass "node.env exports CHUMP_TEAM_URL" \
  || fail "node.env missing CHUMP_TEAM_URL export"

grep -q '^export CHUMP_STORE_BACKEND=' "$NODE_ENV_FILE" 2>/dev/null \
  && pass "node.env exports CHUMP_STORE_BACKEND" \
  || fail "node.env missing CHUMP_STORE_BACKEND export"

# ── 1b. RESILIENT-1513: CHUMP_GAP_SERVER pins gap-filing clients
# (src/gap_file.rs, default 127.0.0.1:7070) to the CANONICAL store node —
# derived from CHUMP_GAP_STORE_URL's host, not left to default localhost —
# so a bat-phone filing never silently targets a stale local fleet-server.
grep -q '^export CHUMP_GAP_SERVER=' "$NODE_ENV_FILE" 2>/dev/null \
  && pass "node.env exports CHUMP_GAP_SERVER" \
  || fail "node.env missing CHUMP_GAP_SERVER export"

gap_server_value="$(grep '^export CHUMP_GAP_SERVER=' "$NODE_ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2-)"
expected_gap_server="$(printf '%s' "$CHUMP_GAP_STORE_URL" | sed -E 's#^(https?://[^:/]+).*#\1#'):7070"
[ "$gap_server_value" = "$expected_gap_server" ] \
  && pass "CHUMP_GAP_SERVER derives from CHUMP_GAP_STORE_URL's host at port 7070 ($gap_server_value)" \
  || fail "CHUMP_GAP_SERVER=$gap_server_value does not match expected $expected_gap_server (derived from CHUMP_GAP_STORE_URL=$CHUMP_GAP_STORE_URL)"

# An explicit operator override must win over the derived default.
(
  CHUMP_GAP_SERVER="http://override-host:9999"
  export CHUMP_GAP_SERVER
  write_node_env >/dev/null 2>&1
  grep -q '^export CHUMP_GAP_SERVER=http://override-host:9999$' "$NODE_ENV_FILE"
) && pass "an explicit CHUMP_GAP_SERVER override wins over the derived default" \
  || fail "explicit CHUMP_GAP_SERVER override was not honored"
unset CHUMP_GAP_SERVER
write_node_env >/dev/null 2>&1

# ── 2. interactive-shell hook: idempotent, sources node.env ────────────────
MARKER="chump-node-install: source node.env"
grep -qF "$MARKER" "$FAKE_HOME/.bashrc" 2>/dev/null \
  && pass ".bashrc hook installed by write_node_env()" \
  || fail ".bashrc hook NOT installed"

BASHRC_HITS_BEFORE="$(grep -cF "$MARKER" "$FAKE_HOME/.bashrc" 2>/dev/null || echo 0)"
install_shell_hook "$NODE_ENV_FILE" >/dev/null 2>&1
BASHRC_HITS_AFTER="$(grep -cF "$MARKER" "$FAKE_HOME/.bashrc" 2>/dev/null || echo 0)"
[ "$BASHRC_HITS_BEFORE" = "$BASHRC_HITS_AFTER" ] \
  && pass "install_shell_hook() is idempotent (re-run does not duplicate the block)" \
  || fail "install_shell_hook() duplicated its marker on re-run ($BASHRC_HITS_BEFORE -> $BASHRC_HITS_AFTER)"

# A shell actually sourcing .bashrc picks up the canonical store var.
( unset CHUMP_STATE_DB
  # shellcheck disable=SC1090
  . "$FAKE_HOME/.bashrc" >/dev/null 2>&1
  [ "${CHUMP_STATE_DB:-}" = "$CHUMP_NODE_DIR/repo/.chump/state.db" ]
) && pass "sourcing .bashrc actually sets CHUMP_STATE_DB to the canonical path" \
  || fail "sourcing .bashrc did not set CHUMP_STATE_DB"

# ── 3. organ-unit rewriter injects EnvironmentFile= for node.env ───────────
if ! sed --version 2>/dev/null | grep -qi gnu; then
  echo "SKIP organ-unit EnvironmentFile injection (non-GNU sed — Linux-deploy-only)"
else
  # shellcheck disable=SC1090
  source "$LIB_UNIT"
  SRCU="$TMP/unit-src.service"
  cat > "$SRCU" <<'EOF'
[Unit]
Description=x
[Service]
User=root
Environment=HOME=/root
ExecStart=/root/Projects/chump/scripts/x.sh
EOF
  DESTU="$TMP/unit-out.service"
  organ_unit_host_rewrite "$SRCU" "$DESTU" "ubuntu" "/home/ubuntu" 0 || fail "organ_unit_host_rewrite returned non-zero"
  grep -q '^EnvironmentFile=-/home/ubuntu/.chump/node.env$' "$DESTU" \
    && pass "organ_unit_host_rewrite injects EnvironmentFile=-<run_home>/.chump/node.env" \
    || fail "organ_unit_host_rewrite did not inject node.env EnvironmentFile (got: $(grep '^EnvironmentFile=' "$DESTU" 2>/dev/null))"

  # Idempotent: re-running the rewrite over an already-wired unit must not
  # duplicate the EnvironmentFile= line. (src != dest — organ_unit_host_rewrite
  # redirects into dest via `sed ... "$src" > "$dest"`, which would truncate a
  # shared file before sed ever reads it.)
  SRCU2="$TMP/unit-already-wired.service"
  cp "$DESTU" "$SRCU2"
  DESTU2="$TMP/unit-out-2.service"
  organ_unit_host_rewrite "$SRCU2" "$DESTU2" "ubuntu" "/home/ubuntu" 0 || fail "re-rewrite returned non-zero"
  HITS="$(grep -c '^EnvironmentFile=.*node\.env' "$DESTU2" 2>/dev/null || echo 0)"
  [ "$HITS" = "1" ] \
    && pass "re-running organ_unit_host_rewrite does not duplicate EnvironmentFile=" \
    || fail "EnvironmentFile= duplicated on re-rewrite (count=$HITS)"
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "ALL PASS"
  exit 0
else
  echo "$fails FAILURE(S)"
  exit 1
fi
