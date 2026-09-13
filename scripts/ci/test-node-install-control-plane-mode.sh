#!/usr/bin/env bash
# OOTB contract: a Chump node without a usable provider installs safely as a
# control plane, and only a credentialed re-install enables work execution.

# The installer deliberately runs without `-e`: optional credential fields use
# empty grep results as normal control flow. Mirror that shell posture here.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLER="$ROOT/scripts/setup/chump-node-install.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/chump-control-plane.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

export CHUMP_NODE_DIR="$TMP/node"
export CHUMP_STATE_DIR="$TMP/state"
mkdir -p "$CHUMP_NODE_DIR/bin" "$CHUMP_STATE_DIR" "$TMP/bin"

set --
# shellcheck disable=SC1090
. "$INSTALLER"

failures=0
pass() { printf '  ok   %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*"; failures=$((failures + 1)); }

# No providers.env must not be mistaken for a work-ready node.
if provider_creds_ready; then
  fail "missing providers.env was accepted as work-ready"
else
  pass "missing provider credentials selects control-plane mode"
fi
write_node_env >/dev/null
grep -qx 'export CHUMP_NODE_WORK_ENABLED=0' "$CHUMP_STATE_DIR/node.env" \
  && pass "node.env persists work-disabled mode without credentials" \
  || fail "node.env did not persist control-plane mode"
if worker_execution_enabled; then
  fail "worker execution enabled without credentials"
else
  pass "worker remains disabled without credentials"
fi

# A ready credential file enables work on a normal re-install, while the
# explicit operator switch still wins during a subscription outage.
printf 'CLAUDE_CODE_OAUTH_TOKEN=test-token\nGH_TOKEN=test-token\n' > "$CHUMP_STATE_DIR/providers.env"
CONTROL_PLANE_ONLY=0
write_node_env >/dev/null
grep -qx 'export CHUMP_NODE_WORK_ENABLED=1' "$CHUMP_STATE_DIR/node.env" \
  && pass "credentialed re-install enables work mode" \
  || fail "credentialed re-install did not enable work mode"
if worker_execution_enabled; then
  pass "worker execution enabled with credentials"
else
  fail "worker execution stayed disabled with credentials"
fi
CONTROL_PLANE_ONLY=1
write_node_env >/dev/null
if worker_execution_enabled; then
  fail "--control-plane-only did not override present credentials"
else
  pass "--control-plane-only overrides present credentials"
fi

# Systemd organs source the supported providers.env syntax at runtime, never by
# baking values into generated units. Stub systemctl so the test stays host-neutral.
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/systemctl"
chmod +x "$TMP/bin/systemctl"
PATH="$TMP/bin:$PATH"
SUPERVISOR=systemd
SVC_DIR="$TMP/units"
mkdir -p "$SVC_DIR"
DRY=0
svc_install worker /bin/true
if grep -Fq "$CHUMP_STATE_DIR/providers.env" "$SVC_DIR/chump-worker.service" \
  && ! grep -Fq 'test-token' "$SVC_DIR/chump-worker.service"; then
  pass "systemd worker sources providers.env without embedding secret values"
else
  fail "systemd worker unit does not safely source providers.env"
fi

# A fresh Linux install wires its durable refresh timer to the exact node binary
# the worker prioritizes, rather than an ambient ~/.cargo or ~/.local copy.
mkdir -p "$CHUMP_NODE_DIR/repo/scripts/setup"
printf '%s\n' '#!/bin/bash' 'printf "%s|%s\\n" "$CHUMP_NODE_REPO" "$CHUMP_NODE_BIN" > "$REFRESH_CAPTURE"' \
  > "$CHUMP_NODE_DIR/repo/scripts/setup/install-node-refresh-systemd.sh"
chmod +x "$CHUMP_NODE_DIR/repo/scripts/setup/install-node-refresh-systemd.sh"
export REFRESH_CAPTURE="$TMP/refresh-capture"
HOST_KIND=linux-systemd
BIN="$CHUMP_NODE_DIR/bin/chump"
install_binary_refresh
if [ "$(sed -n '1p' "$REFRESH_CAPTURE")" = "$CHUMP_NODE_DIR/repo|$BIN" ]; then
  pass "refresh installer receives the canonical node binary"
else
  fail "refresh installer did not receive the canonical node binary"
fi

# Fleet-server installation is explicit, private by default, and shares the
# node's managed bin directory rather than creating a second ad-hoc location.
printf '%s\n' '#!/bin/bash' 'printf "%s|%s|%s\\n" "$CHUMP_NODE_REPO" "$CHUMP_NODE_DIR" "$CHUMP_FLEET_SERVER_BIN" > "$SERVER_CAPTURE"' \
  > "$CHUMP_NODE_DIR/repo/scripts/setup/install-fleet-server-node.sh"
printf '%s\n' '#!/bin/bash' 'exit 0' > "$CHUMP_NODE_DIR/bin/chump-fleet-server"
chmod +x "$CHUMP_NODE_DIR/repo/scripts/setup/install-fleet-server-node.sh" "$CHUMP_NODE_DIR/bin/chump-fleet-server"
export SERVER_CAPTURE="$TMP/server-capture"
WITH_FLEET_SERVER=1
install_fleet_server
if [ "$(sed -n '1p' "$SERVER_CAPTURE")" = "$CHUMP_NODE_DIR/repo|$CHUMP_NODE_DIR|$CHUMP_NODE_DIR/bin/chump-fleet-server" ]; then
  pass "fleet-server installer receives the canonical node server path"
else
  fail "fleet-server installer did not receive the canonical node server path"
fi
grep -qx 'BIND="${CHUMP_FLEET_SERVER_BIND:-127.0.0.1}"' "$ROOT/scripts/setup/install-fleet-server-node.sh" \
  && pass "fleet-server defaults to localhost rather than public exposure" \
  || fail "fleet-server default bind is not localhost"

if [ "$failures" -eq 0 ]; then
  echo "PASS: OOTB control-plane install contract holds"
  exit 0
fi
echo "FAIL: $failures assertion(s) failed" >&2
exit 1
