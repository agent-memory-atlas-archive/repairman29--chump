#!/usr/bin/env bash
# scripts/ci/test-node-orchestrator-svc-heal.sh — INFRA-3649 AC3
#
# Proves node-orchestrator.sh's heal() revives HOUSEKEEPING organs through
# svc-abstraction.sh's svc_is_alive/svc_revive instead of a blind
# `systemctl is-active`/`restart` — the fix for the CJ incident where
# HOUSEKEEPING organs run as bare ~/.chump/organs/<name>.sh process loops
# (not systemd units), so systemctl silently no-ops on both the liveness
# check and the restart.
#
# Covers:
#   1. heal() revives a HOUSEKEEPING organ via the PROCESS mechanism when no
#      matching chump-<name>.service unit is registered (the CJ shape).
#   2. heal() is a no-op for an organ svc_is_alive already reports alive.
#   3. heal() still works through the SYSTEMD mechanism when a unit IS
#      registered (a systemd-supervised node), proving neither path regressed.
#
# Uses `export` + a plain `source` (not `VAR=val source file`) so overrides
# survive past the sourcing statement — svc-abstraction.sh's own test uses
# the same convention for the same reason (see test-svc-abstraction.sh).

set -uo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ORCH="$REPO_ROOT/scripts/ops/node-orchestrator.sh"

[[ -f "$ORCH" ]] || { echo "[FAIL] $ORCH not found"; exit 1; }

echo "=== INFRA-3649 node-orchestrator heal() svc-abstraction wiring ==="

TMPDIR_TEST="$(mktemp -d)"
trap 'pkill -f "$TMPDIR_TEST/organs/rot-reaper.sh" >/dev/null 2>&1 || true; rm -rf "$TMPDIR_TEST"' EXIT

STATE_DIR_TEST="$TMPDIR_TEST/state"
AMBIENT_TEST="$TMPDIR_TEST/.chump-locks/ambient.jsonl"
ORGANS_DIR="$TMPDIR_TEST/organs"
LOGS_DIR="$TMPDIR_TEST/logs"
BACKOFF_DIR="$TMPDIR_TEST/organ-backoff"
mkdir -p "$STATE_DIR_TEST" "$ORGANS_DIR" "$LOGS_DIR" "$(dirname "$AMBIENT_TEST")"

cat > "$ORGANS_DIR/rot-reaper.sh" <<EOF
#!/usr/bin/env bash
sleep 30
EOF
chmod +x "$ORGANS_DIR/rot-reaper.sh"

export CHUMP_STATE_DIR="$STATE_DIR_TEST"
export CHUMP_AMBIENT_LOG="$AMBIENT_TEST"
export CHUMP_SVC_ORGANS_DIR="$ORGANS_DIR"
export CHUMP_SVC_LOGS_DIR="$LOGS_DIR"
export CHUMP_SVC_SYSTEMCTL_BIN="$TMPDIR_TEST/no-such-systemctl"
export CHUMP_ORGAN_RECONCILE_BACKOFF_DIR="$BACKOFF_DIR"

# shellcheck source=/dev/null
source "$ORCH" 2>/dev/null || true

if declare -f heal >/dev/null 2>&1 && declare -f svc_revive >/dev/null 2>&1; then
  ok "node-orchestrator.sh sources svc-abstraction.sh (svc_revive available to heal())"
else
  fail "heal()/svc_revive not available after sourcing node-orchestrator.sh"
fi

# ── 1. process-mechanism revive (the CJ shape: no systemd unit registered) ──
HOUSEKEEPING="chump-rot-reaper.service"
heal >/dev/null 2>&1
sleep 0.3
if pgrep -f "$ORGANS_DIR/rot-reaper.sh" >/dev/null 2>&1; then
  ok "heal() revives a down HOUSEKEEPING organ via the process mechanism"
else
  fail "heal() did not revive rot-reaper via process mechanism"
fi
grep -q '"kind":"organ_self_healed"' "$AMBIENT_TEST" 2>/dev/null && grep -q '"mechanism":"process"' "$AMBIENT_TEST" 2>/dev/null \
  && ok "heal()'s revive emitted kind=organ_self_healed mechanism=process" \
  || fail "expected organ_self_healed/mechanism=process event missing from ambient log (got: $(cat "$AMBIENT_TEST" 2>/dev/null))"

# ── 2. no-op when already alive ─────────────────────────────────────────────
: > "$AMBIENT_TEST"
heal >/dev/null 2>&1
if [[ ! -s "$AMBIENT_TEST" ]]; then
  ok "heal() is a no-op (no revive, no emit) once the organ is already alive"
else
  fail "heal() re-revived an already-alive organ (ambient log: $(cat "$AMBIENT_TEST"))"
fi
pkill -f "$ORGANS_DIR/rot-reaper.sh" >/dev/null 2>&1 || true
sleep 0.2

# ── 3. systemd-mechanism path still works when a unit IS registered ────────
STUB="$TMPDIR_TEST/systemctl-stub"
CALL_LOG="$TMPDIR_TEST/calls.log"
cat > "$STUB" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CALL_LOG"
args=("\$@")
if [[ "\${args[0]}" == "--user" ]]; then exit 1; fi
case "\${args[0]}" in
  list-unit-files)
    if [[ "\${args[1]}" == "chump-disk-monitor.service" ]]; then
      echo "chump-disk-monitor.service enabled"; exit 0
    fi
    exit 0 ;;
  is-active) exit 1 ;;
  reset-failed) exit 0 ;;
  restart) exit 0 ;;
esac
exit 1
EOF
chmod +x "$STUB"
: > "$CALL_LOG"
: > "$AMBIENT_TEST"

export CHUMP_SVC_SYSTEMCTL_BIN="$STUB"
export CHUMP_SVC_FORCE_MECHANISM=""
HOUSEKEEPING="chump-disk-monitor.service" heal >/dev/null 2>&1

grep -q "restart chump-disk-monitor.service" "$CALL_LOG" && ok "heal() revives via systemd mechanism when a unit is registered" \
  || fail "heal() did not call systemctl restart for a registered unit (calls: $(cat "$CALL_LOG" | tr '\n' ';'))"
grep -q '"mechanism":"systemd"' "$AMBIENT_TEST" 2>/dev/null && ok "systemd-path revive emitted mechanism=systemd" \
  || fail "expected mechanism=systemd event missing from ambient log"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
